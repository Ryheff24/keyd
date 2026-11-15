#!/usr/bin/env python3
"""Print the proof steps that tlapm could not prove, as qualified labels.

Usage: tlapm ... MODULE.tla 2>&1 | proof-steps.py MODULE.tla
Prints one line: the sorted, space-separated steps (e.g. "NextIInv.<1>12"),
or "BACKEND" if tlapm reported a backend error other than an unproved goal.
Used by the Makefile so that a proof control must fail at the steps of the
mechanism it removes, not anywhere (METHOD.md, Proof control).
"""
import re
import sys

path = sys.argv[1]
src = open(path).read().split("\n")
out = sys.stdin.read()

# Every [ERROR] must be one of: an unproved goal located in the proof module, or
# the single "N/M obligations failed" summary whose N equals the number of goals.
# Anything else (another file, a parse error, a backend crash) is BACKEND.
errors = re.findall(r'(?:File "([^"]*)", line (\d+)[^\n]*\n)?\[ERROR\]: ([^\n]*)', out)
goals, summaries, other = [], [], []
for f, line, msg in errors:
    m = re.match(r"(\d+)/\d+ obligations failed", msg)
    if m:
        summaries.append(int(m.group(1)))
    elif msg.startswith("Could not prove") and f.lstrip("./") == path:
        goals.append(int(line))
    else:
        other.append(msg)
if other or len(summaries) != 1 or summaries[0] != len(goals) or not goals:
    print("BACKEND")
    sys.exit(0)


def label(n):
    """Qualified label of the step containing line n, prefixed by its lemma or
    theorem, e.g. "NextIInv.<1>15.<2>1" (a lemma proved in one BY: its name)."""
    parts = []
    want = None  # only levels above the one already found
    for i in range(n - 1, -1, -1):
        m = re.match(r"(?:LEMMA|THEOREM) (\w+)", src[i])
        if m:
            parts.append(m.group(1))
            break
        # A numbered step "<1>5." or an unnumbered one "<1> QED" (also USE,
        # SUFFICES, ...): a failure in an unnumbered step is labelled by its
        # keyword, never by the numbered step above it.
        m = re.match(r"\s*<(\d+)>(?:(\d+)\.|\s+([A-Z]+))", src[i])
        if m and want != 1:
            lvl = int(m.group(1))
            if want is None or lvl < want:
                parts.append(f"<{lvl}>{m.group(2) or m.group(3)}")
                want = lvl
    return ".".join(reversed(parts))


print(" ".join(sorted({label(n) for n in goals})))
