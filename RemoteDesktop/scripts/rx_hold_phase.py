#!/usr/bin/env python3
"""Measure whether iPad receive holds lock to a fixed radio schedule.

Reads FT-IRX records (iPad TCP receive-callback gaps, iPad host clock) from an E2E iPad log
and reports:
  - phase-lock strength R (0 = random, 1 = perfectly periodic) of hold start/end times at the
    512 TU (524.288 ms) cycle's harmonics, averaged over 20 s windows to tolerate clock drift;
  - a null R from random times (the noise floor);
  - where in the 512 TU cycle holds start (32-bin histogram);
  - the share of time spent inside receive gaps >= 60 ms.
Run 1247cc4 (en0, ch157/80MHz): two holds per 512 TU cycle, ~96 ms each, R ~0.8, 45% of time.

Usage: rx_hold_phase.py IPAD_LOG
"""
import math
import random
import re
import statistics as st
import sys

TU = 1024  # us
CYCLE = 512 * TU

gaps = []
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"FT-IRX n=\d+ (\S+)", line)
    if m:
        for e in m.group(1).split(";"):
            f = e.split(",")
            if len(f) == 3:
                gaps.append(tuple(int(x) for x in f))
if not gaps:
    sys.exit("no FT-IRX records")


def r_at(times, period):
    c = sum(math.cos(2 * math.pi * (t % period) / period) for t in times)
    s = sum(math.sin(2 * math.pi * (t % period) / period) for t in times)
    return math.hypot(c, s) / len(times)


def windowed_r(times, period, win=20e6):
    t0, buckets = times[0], {}
    for t in times:
        buckets.setdefault(int((t - t0) // win), []).append(t)
    rs = [(r_at(v, period), len(v)) for v in buckets.values() if len(v) >= 8]
    n = sum(k for _, k in rs)
    return sum(r * k for r, k in rs) / n if n else float("nan")


holds = [(s, g, b) for s, g, b in gaps if g >= 60000]
starts = sorted(s for s, g, b in holds)
pure = sorted(s + g for s, g, b in holds if b < 8000)
print(f"rx gaps>=15ms {len(gaps)}  >=60ms {len(holds)}  (small next callback {len(pure)})")
for name, ts in (("hold starts", starts), ("pure hold ends", pure)):
    if len(ts) < 8:
        continue
    print(f"{name}: R@CYCLE/3={windowed_r(ts, CYCLE / 3):.3f} R@CYCLE/5={windowed_r(ts, CYCLE / 5):.3f} "
          f"R@100TU={windowed_r(ts, 100 * TU):.3f}")
if len(starts) >= 8:
    rnd = sorted(random.uniform(starts[0], starts[-1]) for _ in starts)
    print(f"null (random times): R@CYCLE/3={windowed_r(rnd, CYCLE / 3):.3f}")

    # Phase histogram over the 512 TU cycle, aligned per 20 s window on the CYCLE/3 mean phase.
    t0, win = gaps[0][0], {}
    for s, g, b in gaps:
        win.setdefault(int((s - t0) // 20e6), []).append((s, g))
    hist, durs = [0] * 32, [[] for _ in range(32)]
    q = CYCLE / 3
    for v in win.values():
        big = [(s, g) for s, g in v if g >= 60000]
        if len(big) < 8:
            continue
        c = sum(math.cos(2 * math.pi * (s % q) / q) for s, _ in big)
        sn = sum(math.sin(2 * math.pi * (s % q) / q) for s, _ in big)
        ref = math.atan2(sn, c) / (2 * math.pi) * q
        for s, g in big:
            i = int(((s - ref) % CYCLE) / CYCLE * 32)
            hist[i] += 1
            durs[i].append(g / 1000)
    print("hold starts across the 512 TU cycle:")
    for i in range(32):
        med = f"med {st.median(durs[i]):.0f}ms" if durs[i] else ""
        print(f"  {i * CYCLE / 32 / 1000:5.0f}ms {hist[i]:4d} {'#' * (hist[i] // 4)} {med}")

held = sum(g for s, g, b in holds) / 1e6
span = (gaps[-1][0] - gaps[0][0]) / 1e6
print(f"time inside >=60ms rx gaps: {held:.1f}s of {span:.1f}s ({100 * held / span:.0f}%)")
