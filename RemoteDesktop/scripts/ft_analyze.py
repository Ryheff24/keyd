#!/usr/bin/env python3
"""Join FT-M (Mac) and FT-I (iPad) per-frame timelines on capture ts_us and classify
every gap >= 50 ms in iPad frame completion and in presentation.

Usage: ft_analyze.py MAC_LOG IPAD_LOG
"""
import re
import sys
from statistics import median

mac_log, ipad_log = sys.argv[1], sys.argv[2]

mac = {}
for line in open(mac_log, errors="replace"):
    m = re.search(r"FT-M line=\d+ n=\d+ (\S+)", line)
    if not m:
        continue
    for e in m.group(1).split(";"):
        if not e:
            continue
        f = e.split(",")
        if len(f) != 9:
            continue
        seq, ts, by, fl, enc, sub, done, inf, oc = f
        enc = int(enc); sub = int(sub); done = int(done)
        mac[int(ts)] = dict(seq=int(seq), bytes=int(by), flags=int(fl), enc=enc,
                            sub=enc + sub if sub >= 0 else None,
                            done=enc + done if done >= 0 else None,
                            inflight=int(inf), outcome=oc)

ipad = {}
rxgaps = []
for line in open(ipad_log, errors="replace"):
    m = re.search(r"FT-I line=\d+ n=\d+ (\S+)", line)
    if m:
        for e in m.group(1).split(";"):
            f = e.split(",")
            if len(f) != 12:
                continue
            seq, ts, by, fl, first = map(int, f[:5])
            offs = [int(x) for x in f[5:]]
            ab = [first + o if o >= 0 else None for o in offs]
            ipad[ts] = dict(seq=seq, bytes=by, flags=fl, first=first, last=ab[0], complete=ab[1],
                            decsub=ab[2], decdone=ab[3], enq=ab[4], deq=ab[5], target=ab[6])
        continue
    m = re.search(r"FT-IRX n=\d+ (\S+)", line)
    if m:
        for e in m.group(1).split(";"):
            f = e.split(",")
            if len(f) == 3:
                rxgaps.append(tuple(int(x) for x in f))

def pct(v, p):
    if not v:
        return float("nan")
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100 * len(v)))]

print(f"Mac records {len(mac)}  iPad records {len(ipad)}  iPad rx gaps>=15ms {len(rxgaps)}")
outc = {}
for r in mac.values():
    outc[r["outcome"]] = outc.get(r["outcome"], 0) + 1
print("Mac outcomes", outc)

joined = sorted((ts for ts in ipad if ts in mac and mac[ts]["sub"] is not None),
                key=lambda t: ipad[t]["complete"])
print(f"joined frames {len(joined)}")
if not joined:
    sys.exit(0)

# Clock-free one-way delay: lastRx(iPad clock) - submit(Mac clock) minus its floor.
d = {ts: ipad[ts]["last"] - mac[ts]["sub"] for ts in joined}
small = [d[ts] for ts in joined if ipad[ts]["bytes"] < 20000]
base = pct(small or list(d.values()), 1)
ex = {ts: (d[ts] - base) / 1000.0 for ts in joined}
exs = list(ex.values())
print(f"excess one-way delay ms (submit->lastRx, floor-relative): p50 {pct(exs,50):.1f} p90 {pct(exs,90):.1f} p99 {pct(exs,99):.1f} max {max(exs):.1f}  >50ms {sum(e>50 for e in exs)}")

sleep = [(mac[ts]["sub"] - mac[ts]["enc"]) / 1000 for ts in joined]
print(f"Mac encOut->submit ms: p50 {pct(sleep,50):.1f} p90 {pct(sleep,90):.1f} p99 {pct(sleep,99):.1f} max {max(sleep):.1f}")
cap = [(mac[ts]["enc"] - ts) / 1000 for ts in joined]
print(f"Mac capture->encOut ms: p50 {pct(cap,50):.1f} p90 {pct(cap,90):.1f} p99 {pct(cap,99):.1f} max {max(cap):.1f}")
comp = [(mac[ts]["done"] - mac[ts]["sub"]) / 1000 for ts in joined if mac[ts]["done"]]
print(f"Mac submit->completion ms: p50 {pct(comp,50):.1f} p90 {pct(comp,90):.1f} p99 {pct(comp,99):.1f} max {max(comp):.1f}")

# Transfer duration for big frames: first->last receive callback.
big = [(ipad[ts]["bytes"], (ipad[ts]["last"] - ipad[ts]["first"]) / 1000) for ts in joined if ipad[ts]["bytes"] >= 100000]
if big:
    rates = [b * 8 / (ms / 1000) / 1e6 for b, ms in big if ms > 1]
    print(f"frames >=100KB: {len(big)}  rx span ms p50 {pct([m for _,m in big],50):.1f} max {max(m for _,m in big):.1f}  effective Mb/s p50 {pct(rates,50):.0f} p10 {pct(rates,10):.0f}")

pres = [ts for ts in joined if ipad[ts]["target"]]
print(f"presented {len(pres)} / {len(joined)}  replaced-before-present {len(joined)-len(pres)}")
dec = [(ipad[ts]["decsub"] - ipad[ts]["complete"]) / 1000 for ts in joined if ipad[ts]["decsub"]]
dd = [(ipad[ts]["decdone"] - ipad[ts]["decsub"]) / 1000 for ts in joined if ipad[ts]["decdone"]]
print(f"iPad complete->decodeSubmit ms p50 {pct(dec,50):.1f} p99 {pct(dec,99):.1f} max {max(dec):.1f}; decode ms p50 {pct(dd,50):.1f} p99 {pct(dd,99):.1f}")

# ---- Classify iPad completion gaps >= 50 ms ----
print("\n== iPad frame-completion gaps >= 50 ms ==")
cls = {}
rows = []
for a, b in zip(joined, joined[1:]):
    ia, ib = ipad[a], ipad[b]
    gap = (ib["complete"] - ia["complete"]) / 1000
    if gap < 50:
        continue
    ma, mb = mac[a], mac[b]
    sub_gap = (mb["sub"] - ma["sub"]) / 1000
    enc_gap = (mb["enc"] - ma["enc"]) / 1000
    cap_gap = (b - a) / 1000
    sleep_b = (mb["sub"] - mb["enc"]) / 1000
    exb = ex[b]
    skipped = (ib["seq"] - ia["seq"]) % 65536 - 1
    if sub_gap >= 0.6 * gap:
        if cap_gap >= 0.6 * gap:
            c = "mac-capture"
        elif enc_gap >= 0.6 * gap:
            c = "mac-encode"
        else:
            c = "mac-scheduler"
    elif exb >= 0.5 * gap:
        span_b = (ib["last"] - ib["first"]) / 1000
        if span_b >= 0.5 * gap:
            c = "link-bigxfer"
        elif ex[a] >= 50:
            c = "link-queue"
        else:
            c = "link-hold"
    else:
        c = "mixed"
    cls[c] = cls.get(c, 0) + 1
    rows.append((ia["complete"], gap, c, sub_gap, cap_gap, enc_gap, sleep_b, exb, ib["bytes"], skipped))
for r in rows:
    print(f"t={r[0]/1e6:.3f}s gap {r[1]:6.1f}ms -> {r[2]:13s} macSubmitGap {r[3]:6.1f} captureGap {r[4]:6.1f} encGap {r[5]:6.1f} sleep {r[6]:5.1f} excessDelay {r[7]:6.1f} nextBytes {r[8]:7d} seqSkipped {r[9]}")
print("classes:", cls)

# ---- Presentation gaps >= 50 ms ----
print("\n== presentation (target) gaps >= 50 ms ==")
ps = sorted(pres, key=lambda t: ipad[t]["target"])
pc = {}
for a, b in zip(ps, ps[1:]):
    g = (ipad[b]["target"] - ipad[a]["target"]) / 1000
    if g < 50:
        continue
    cg = (ipad[b]["complete"] - ipad[a]["complete"]) / 1000
    c = "arrival" if cg >= 0.6 * g else "render-side"
    pc[c] = pc.get(c, 0) + 1
print("present gaps:", pc, "total", sum(pc.values()))

# Replaced frames: how close behind the next arrival?
rep = [ts for ts in joined if not ipad[ts]["target"]]
idx = {ts: i for i, ts in enumerate(joined)}
close = 0
for ts in rep:
    i = idx[ts]
    if i + 1 < len(joined) and (ipad[joined[i + 1]]["complete"] - ipad[ts]["complete"]) < 8300:
        close += 1
print(f"replaced frames followed by next arrival within 8.3 ms: {close}/{len(rep)}")

if rxgaps:
    g = [x[1] / 1000 for x in rxgaps]
    print(f"\nTCP receive-callback gaps >=15ms: n {len(g)} p50 {pct(g,50):.1f} p90 {pct(g,90):.1f} max {max(g):.1f}  >=50ms {sum(x>=50 for x in g)}")

# ---- per-second series ----
print("\n== per second: Mac bytes submitted, keyframes, drops vs median excess delay ==")
from collections import defaultdict
sec = defaultdict(lambda: dict(b=0, k=0, ex=[]))
t0 = min(mac[t]["sub"] for t in joined)
for t in joined:
    s_ = int((mac[t]["sub"] - t0) / 1e6)
    sec[s_]["b"] += mac[t]["bytes"]; sec[s_]["k"] += mac[t]["flags"] & 2 and 1 or 0; sec[s_]["ex"].append(ex[t])
drops = defaultdict(int)
for t, r in mac.items():
    if r["outcome"] == "D" and r["enc"] >= t0:
        drops[int((r["enc"] - t0) / 1e6)] += 1
for s_ in sorted(sec):
    e = sorted(sec[s_]["ex"])
    print(f"{s_:4d}s  {sec[s_]['b']*8/1e6:5.1f} Mb  key {sec[s_]['k']}  drops {drops[s_]:2d}  frames {len(e):3d}  excess p50 {e[len(e)//2]:7.1f} max {e[-1]:7.1f}")
