#!/usr/bin/env python3
"""Strict whole-run metrics for an E2E (or any) session, judged against the METRICS goals.

Usage: e2e_strict.py MAC_LOG IPAD_LOG [--csv OUT.csv] [--goal-fps 120] [--goal-g2g 25]
                     [--goal-pipe 7] [--panel 2752x1786]

Every number covers the WHOLE run: the second grid runs from the first presented frame to the
last, and a second with no presented frame counts as 0 fps (stalls, reconnects, backgrounds
and relaunches are not carved out). With a few hundred seconds per run, "p0.1 of per-second
fps" is simply the worst second, so it is printed as that.

Sources (all already logged):
  iPad FT-I: per frame capture ts (Mac clock), firstRx, complete, decode done, present target
             (iPad clock). Only frames with a present target count as presented.
  Mac FT-M:  per encoded frame encOut time (Mac clock).
  iPad [TEST] clock-sync offset (ms): iPad clock = Mac clock - offset.
  iPad [TEST] lines mark the phase each second belongs to (attribution only).
  Link: iPad frame-pipeline transport=, Mac PEER-ADDR / Transitioned to.
  FrameLoop: FL IpadFail (decode refusals), FL IpadKey waitMs (handshake to first key).

Gates (a gate failing prints FAIL; exit 1 if any fails):
  worst-second fps >= goal fps; frame interval p99.9 <= 1.5 x (1000 / goal fps);
  glass-to-glass p99.9 <= goal; capture->decode p99.9 <= goal pipe;
  no decode refusals; no second on infrastructure Wi-Fi; delivered frame == panel size;
  handshake-to-first-key <= 250 ms each time.
"""
import argparse
import re
import sys
from collections import defaultdict

FT_I = re.compile(r"FT-I line=\d+ n=\d+ (\S+)")
FT_M = re.compile(r"FT-M line=\d+ n=\d+ (\S+)")
OFFSET = re.compile(r"\[TEST\] PASS: clock-sync \(offset=(-?\d+)ms")
TEST = re.compile(r"\[TEST\] (INFO|PASS|FAIL|START): ([\w-]+)")
LINK_I = re.compile(r"frame-pipeline seq=\d+ transport=(\w+)")
MAC_TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")
BG = re.compile(r"\[TEST\] INFO: background-cycle (entered|resumed) hostUs=(\d+)")
FRAME_SIZE = re.compile(r"(?:frame|resolution)[^\n]*?frame=(\d+)x(\d+)")


def pct(v, p):
    if not v:
        return float("nan")
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100.0 * len(v)))]


def parse_ipad(path):
    frames = {}          # ts -> dict
    phases = []          # (approx iPad us, name) in file order
    offset_ms = None
    fails = []
    keys = []
    links = []           # (approx iPad us, link)
    sizes = set()
    away = []            # (entered us, resumed us): the app was deliberately backgrounded
    in_away = False      # file order: between an entered and its resumed line
    last_us = None
    for line in open(path, errors="replace"):
        m = FT_I.search(line)
        if m:
            for e in m.group(1).split(";"):
                f = e.split(",")
                if len(f) != 12:
                    continue
                seq, ts, by, fl, first = map(int, f[:5])
                offs = [int(x) for x in f[5:]]
                ab = [first + o if o >= 0 else None for o in offs]
                frames[ts] = dict(seq=seq, bytes=by, key=bool(fl & 1), first=first,
                                  complete=ab[1], decdone=ab[3], ready=ab[4], target=ab[6])
                last_us = ab[1] or first
            continue
        m = OFFSET.search(line)
        if m:
            offset_ms = int(m.group(1))
        m = BG.search(line)
        if m:
            if m.group(1) == "entered":
                away.append([int(m.group(2)), None])
                in_away = True
            elif away and away[-1][1] is None:
                away[-1][1] = int(m.group(2))
                in_away = False
        m = TEST.search(line)
        if m and last_us is not None:
            phases.append((last_us, m.group(2)))
        m = LINK_I.search(line)
        if m and last_us is not None:
            links.append((last_us, m.group(1)))
        if "[CONSOLE] FL IpadFail" in line:
            fails.append((last_us, line.strip()[10:120], in_away))
        if "FL IpadKey " in line:
            w = re.search(r"waitMs=(\d+)", line)
            r = re.search(r"reason=(\S+)", line)
            if w:
                keys.append((last_us, int(w.group(1)), r.group(1) if r else "?"))
        for fm in FRAME_SIZE.finditer(line):
            sizes.add((int(fm.group(1)), int(fm.group(2))))
    return frames, phases, offset_ms, fails, keys, links, sizes, [tuple(w) for w in away if w[1]]


def link_of_iface(iface):
    if iface.startswith(("awdl", "llw")):
        return "awdl"
    if iface == "en0":
        return "wifi"
    if re.fullmatch(r"en\d+", iface):
        return "usb"
    return iface or "?"


DIAGNOSTIC_PHASES = {"bw-probe"}
FT_IRX = re.compile(r"FT-IRX n=\d+ (\S+)")
PING_REPLY = re.compile(r"^(\d\d):(\d\d):(\d\d\.\d+) \d+ bytes from \S+ icmp_seq=(\d+) \S+ time=([\d.]+) ms")


def ping_report(mac_log, ipad_log, offset_ms, path):
    """Each iPad media receive silence of 0.5-3 s against the harness AWDL ping replies in the same
    window (Mac wall clock). Replies keep coming = the radio was up and the TCP stream alone stalled;
    replies stop too = the link was gone. Longer silences are the test's deliberate disconnects."""
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return
    replies = []          # (wall s-of-day, rtt ms)
    for line in lines:
        m = PING_REPLY.match(line)
        if m:
            replies.append((int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)), float(m.group(5))))
    if not replies or offset_ms is None:
        print(f"  AWDL ping: {len(replies)} replies{' (no clock offset)' if offset_ms is None else ''}")
        return
    # Mac host clock -> wall clock, from FT-M batches (the line is logged right after its last record)
    diffs = []
    for line in open(mac_log, errors="replace"):
        m, f = MAC_TS.match(line), FT_M.search(line)
        if not (m and f):
            continue
        hms = m.group(1).split(" ")[1].split(":")
        wall = int(hms[0]) * 3600 + int(hms[1]) * 60 + float(hms[2])
        eos = [int(e.split(",")[4]) for e in f.group(1).split(";") if e.count(",") == 8]
        if eos:
            diffs.append(wall - max(eos) / 1e6)
    if not diffs:
        print("  AWDL ping: no FT-M lines to align clocks")
        return
    wall_off = sorted(diffs)[len(diffs) // 2]
    sil = []
    for line in open(ipad_log, errors="replace"):
        f = FT_IRX.search(line)
        if not f:
            continue
        for e in f.group(1).split(";"):
            p3 = e.split(",")
            if len(p3) == 3 and 500_000 <= int(p3[1]) <= 3_000_000:
                start = (int(p3[0]) + offset_ms * 1000) / 1e6 + wall_off
                sil.append((start, int(p3[1]) / 1e6))
    rts = [r for _, r in replies]
    gaps = [(b[0] - a[0], a[0]) for a, b in zip(replies, replies[1:]) if b[0] - a[0] > 0.3]
    print(f"  AWDL ping (100 ms): {len(replies)} replies  rtt ms p99.9 {pct(rts, 99.9):.1f} max {max(rts):.1f}  "
          f"reply gaps >300 ms: {len(gaps)}")
    radio = tcp = 0
    for start, dur in sil:
        inside = [r for t, r in replies if start <= t <= start + dur]
        frac = len(inside) / max(1.0, dur / 0.1)
        if frac >= 0.5:
            verdict, tcp = "TCP-only (pings answered)", tcp + 1
        elif frac <= 0.1:
            verdict, radio = "link-down (pings stopped too)", radio + 1
        else:
            verdict = "partial (some pings answered)"
        hh, rem = divmod(start, 3600)
        mm, ss = divmod(rem, 60)
        print(f"    iPad silence {dur * 1000:.0f} ms at ~{int(hh):02d}:{int(mm):02d}:{ss:06.3f}: "
              f"{len(inside)} ping replies of ~{dur / 0.1:.0f} (rtt max {max(inside or [0]):.0f} ms) -> {verdict}")
    print(f"  iPad silences 0.5-3 s: {len(sil)}  link-down {radio}  TCP-only {tcp}  partial {len(sil) - radio - tcp}")


def parse_nettop(path):
    """nettop -x CSV (harness): per connection, cumulative bytes_out and re-tx bytes each second.
    Returns {conn: [(time str, iface, bytes_out, retx, rtt str)]} for established connections."""
    conns = defaultdict(list)
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return None
    for line in lines:
        f = line.split(",")
        if len(f) < 9 or f[3] != "Established" or "<->" not in f[1]:
            continue
        try:
            conns[f[1]].append((f[0], f[2], int(f[5] or 0), int(f[6] or 0), f[7]))
        except ValueError:
            continue
    return conns


def parse_ifq(path):
    """Harness snapshot of `netstat -I IF -q` per USB NCM interface: {iface: (dequeued, dropped,
    overflow, flow_control)} summed over classes."""
    out = {}
    cur = None
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("IFACE "):
            cur = line.split()[1]
            out[cur] = [0, 0, 0, 0]
            continue
        if cur is None:
            continue
        m = re.search(r"dequeued pkts:\s+(\d+)\s+bytes:\s+\d+\s+dropped pkts:\s+(\d+)", line)
        if m:
            out[cur][0], out[cur][1] = int(m.group(1)), int(m.group(2))
        m = re.search(r"drop overflow:\s+(\d+)", line)
        if m:
            out[cur][2] += int(m.group(1))
        m = re.search(r"flow control:\s+(\d+)", line)
        if m:
            out[cur][3] += int(m.group(1))
    return out


def parse_mac(path):
    enc = {}
    peers = []
    for line in open(path, errors="replace"):
        m = FT_M.search(line)
        if m:
            for e in m.group(1).split(";"):
                f = e.split(",")
                if len(f) != 9:
                    continue
                enc[int(f[1])] = int(f[4])
            continue
        if "PEER-ADDR=" in line:
            p = re.search(r"PEER-ADDR=\S+%(\w+)", line) or re.search(r"PEER-ADDR=(\S+)", line)
            t = MAC_TS.match(line)
            peers.append((t.group(1)[11:23] if t else "?", p.group(1) if p else "?"))
    return enc, peers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mac_log")
    ap.add_argument("ipad_log")
    ap.add_argument("--csv")
    ap.add_argument("--goal-fps", type=float, default=120.0)
    ap.add_argument("--goal-g2g", type=float, default=25.0)
    ap.add_argument("--goal-pipe", type=float, default=7.0)
    ap.add_argument("--panel", default="2752x1786")
    ap.add_argument("--nettop", help="harness nettop CSV (per-connection TCP retransmits)")
    ap.add_argument("--ping", help="harness AWDL ping6 --apple-time log")
    ap.add_argument("--ifq", nargs=2, metavar=("START", "END"),
                    help="harness `netstat -I IF -q` snapshots of the Mac USB NCM interface")
    a = ap.parse_args()

    frames, phases, offset_ms, fails, keys, links, sizes, away = parse_ipad(a.ipad_log)
    enc, peers = parse_mac(a.mac_log)
    pres = sorted((r["target"], ts) for ts, r in frames.items() if r["target"])
    if len(pres) < 2:
        print("STRICT: no presented frames with FT-I present targets")
        return 1

    t0, t1 = pres[0][0], pres[-1][0]
    nsec = int((t1 - t0) // 1_000_000) + 1
    per_fps = [0] * nsec
    per_maxint = [0.0] * nsec
    per_g2g = [0.0] * nsec
    per_enc = [0] * nsec
    per_phase = [""] * nsec
    per_link = [""] * nsec

    # Seconds the app was deliberately in the background (background-recovery phase) are not
    # stalls; they are marked and left out of the fps gates. The time from resume to the first
    # frame still counts: an interval spanning a background is measured from the resume.
    per_away = [False] * nsec
    for e, r in away:
        for k in range(max(0, int((e - t0) // 1_000_000)), min(nsec, int((r - t0) // 1_000_000) + 1)):
            per_away[k] = True

    for us, name in phases:
        s = int((us - t0) // 1_000_000)
        if 0 <= s < nsec:
            per_phase[s] = name
    cur = ""
    for s in range(nsec):
        cur = per_phase[s] or cur
        per_phase[s] = cur
    for us, link in links:
        s = int((us - t0) // 1_000_000)
        if 0 <= s < nsec:
            per_link[s] = link
    cur = ""
    for s in range(nsec):
        cur = per_link[s] or cur
        per_link[s] = cur
    # Test-only diagnostics that deliberately load the media link (bw-probe floods it with 64 KB
    # filler for 3 s) are not what a user sees: their seconds are left out of every gated number
    # and reported on their own line.
    per_diag = [per_phase[k] in DIAGNOSTIC_PHASES for k in range(nsec)]
    diag_intervals, diag_g2g = [], []

    intervals = []
    for i, (tgt, ts) in enumerate(pres):
        s = int((tgt - t0) // 1_000_000)
        per_fps[s] += 1
        if i:
            prev = pres[i - 1][0]
            for e, r in away:
                if prev < r <= tgt:
                    prev = r
            d = (tgt - prev) / 1000.0
            (diag_intervals if per_diag[s] else intervals).append(d)
            # charge an interval to every second it spans, so a long gap shows in each
            s0 = int((pres[i - 1][0] - t0) // 1_000_000)
            for k in range(s0, s + 1):
                per_maxint[k] = max(per_maxint[k], d)

    g2g, pipe = [], []
    if offset_ms is not None:
        off = offset_ms * 1000
        for tgt, ts in pres:
            v = (tgt - (ts - off)) / 1000.0
            s = int((tgt - t0) // 1_000_000)
            (diag_g2g if per_diag[s] else g2g).append(v)
            per_g2g[s] = max(per_g2g[s], v)
        for ts, r in frames.items():
            done = r["decdone"] or r["ready"]   # LZ4 frames log no decode time; ready = decoded
            if r["target"] and per_diag[min(nsec - 1, max(0, int((r["target"] - t0) // 1_000_000)))]:
                continue
            if done:
                pipe.append((done - (ts - off)) / 1000.0)
        for ts, eo in enc.items():
            s = int(((eo - off) - t0) // 1_000_000)
            if 0 <= s < nsec:
                per_enc[s] += 1

    for s in range(nsec):
        if per_away[s]:
            per_phase[s] = "app-backgrounded"

    gates = []

    def gate(name, ok, detail):
        gates.append((name, ok, detail))

    on_fps = [f for f, aw, dg in zip(per_fps, per_away, per_diag) if not aw and not dg]
    worst = min(on_fps)
    ws = next(s for s in range(nsec) if not per_away[s] and not per_diag[s] and per_fps[s] == worst)
    sorted_fps = sorted(on_fps)
    print(f"STRICT whole run: {nsec} s, {len(pres)} presented frames, "
          f"{len(enc)} encoded (Mac), clock offset {'%d ms' % offset_ms if offset_ms is not None else 'none (g2g n/a)'}")
    print(f"  per-second presented fps: worst {worst} (s{ws}, phase={per_phase[ws] or '-'}, "
          f"link={per_link[ws] or '-'})  p1 {pct(on_fps, 1)}  p5 {pct(on_fps, 5)}  "
          f"p50 {pct(on_fps, 50)}  mean {len(pres) / len(on_fps):.1f}"
          f"{'  (%d s app-backgrounded excluded)' % sum(per_away) if away else ''}"
          f"{'  (%d s diagnostic %s excluded)' % (sum(per_diag), sorted(DIAGNOSTIC_PHASES)) if any(per_diag) else ''}")
    if any(per_diag):
        print(f"  diagnostic seconds (not gated): fps {[per_fps[k] for k in range(nsec) if per_diag[k]]}  "
              f"interval max {max(diag_intervals or [0]):.1f} ms  g2g max {max(diag_g2g or [0]):.1f} ms")
    print(f"  seconds below goal {a.goal_fps:.0f}: {sum(f < a.goal_fps for f in on_fps)}/{len(on_fps)}   "
          f"below 60: {sum(f < 60 for f in on_fps)}   below 30: {sum(f < 30 for f in on_fps)}   "
          f"zero: {sum(f == 0 for f in on_fps)}")
    print(f"  lowest seconds: {sorted_fps[:10]}")
    gate("worst-second fps", worst >= a.goal_fps, f"{worst} fps (goal {a.goal_fps:.0f})")

    lim = 1.5 * 1000.0 / a.goal_fps
    print(f"  frame interval ms: p50 {pct(intervals, 50):.1f}  p99 {pct(intervals, 99):.1f}  "
          f"p99.9 {pct(intervals, 99.9):.1f}  max {max(intervals):.1f}  "
          f">{lim:.1f}ms: {sum(d > lim for d in intervals)}  >100ms: {sum(d > 100 for d in intervals)}")
    gate("frame interval p99.9", pct(intervals, 99.9) <= lim,
         f"{pct(intervals, 99.9):.1f} ms (limit {lim:.1f})")

    if g2g:
        print(f"  glass-to-glass ms: p50 {pct(g2g, 50):.1f}  p99 {pct(g2g, 99):.1f}  "
              f"p99.9 {pct(g2g, 99.9):.1f}  max {max(g2g):.1f}   worst-second p50 of per-second max "
              f"{pct(per_g2g, 50):.1f}")
        print(f"  capture->decode ms: p50 {pct(pipe, 50):.1f}  p99 {pct(pipe, 99):.1f}  "
              f"p99.9 {pct(pipe, 99.9):.1f}  max {max(pipe):.1f}")
        print(f"  Mac encoded per second: worst {min(per_enc)}  p50 {pct(per_enc, 50)}  "
              f"(seconds where Mac encoded >= {a.goal_fps * 0.9:.0f} but iPad presented < 60: "
              f"{sum(e >= a.goal_fps * 0.9 and f < 60 for e, f in zip(per_enc, per_fps))})")
        gate("glass-to-glass p99.9", pct(g2g, 99.9) <= a.goal_g2g,
             f"{pct(g2g, 99.9):.1f} ms (goal {a.goal_g2g:.0f})")
        gate("capture->decode p99.9", pct(pipe, 99.9) <= a.goal_pipe,
             f"{pct(pipe, 99.9):.1f} ms (goal {a.goal_pipe:.0f})")
        if enc:
            gate("Mac encode rate", min(per_enc) >= a.goal_fps,
                 f"worst second {min(per_enc)} encoded (goal {a.goal_fps:.0f}; source rate caps fps)")
        else:
            print("  Mac encode rate: n/a (no FT-M lines; the LZ4/USB send path logs none)")

    linkset = defaultdict(int)
    for l in per_link:
        linkset[l or "?"] += 1
    print(f"  link seconds: {dict(linkset)}   Mac peers: {sorted(set(p for _, p in peers))}")
    infra = sum(1 for l in per_link if l == "wifi") + sum(1 for _, p in peers if p.startswith("en0"))
    gate("never on infrastructure Wi-Fi", infra == 0,
         f"{sum(1 for l in per_link if l == 'wifi')} s on wifi, Mac peers {sorted(set(p for _, p in peers))}")

    # Refusals while the app was deliberately off screen (background-recovery) show nothing;
    # they are listed but not gated. Everything else counts.
    off = [f for f in fails if f[2]]
    on = [f for f in fails if not f[2]]
    print(f"  decode refusals (FL IpadFail): {len(on)} on screen, {len(off)} while backgrounded")
    for us, txt, bg in fails[:5]:
        print(f"    s{int((us - t0) // 1_000_000) if us else '?'}{' (backgrounded)' if bg else ''}: {txt}")
    gate("no decode refusals", not on, f"{len(on)} on screen ({len(off)} while backgrounded, not gated)")

    if keys:
        print(f"  handshake/await -> first key ms: {[(w, r) for _, w, r in keys]}")
        gate("await -> key <= 250 ms", max(w for _, w, _ in keys) <= 250,
             f"max {max(w for _, w, _ in keys)} ms")

    pw, ph = (int(x) for x in a.panel.split("x"))
    if sizes:
        print(f"  frame sizes seen: {sorted(sizes)}  panel {pw}x{ph}")
        gate("delivered frame == panel", all(s == (pw, ph) for s in sizes),
             f"{sorted(sizes)} vs {pw}x{ph}")

    if a.ping:
        ping_report(a.mac_log, a.ipad_log, offset_ms, a.ping)

    if a.nettop:
        conns = parse_nettop(a.nettop)
        if conns is None:
            print(f"  TCP (nettop): {a.nettop} missing")
        else:
            by_link = defaultdict(lambda: [0, 0, 0, 0, 0])  # bytes, retx, secs, secs with retx, max/s
            worst_s = defaultdict(list)
            for c, rows in conns.items():
                link = link_of_iface(rows[-1][1])
                L = by_link[link]
                L[0] += rows[-1][2]
                L[1] += rows[-1][3]
                for (t0_, _, b0, r0, _), (t1_, _, b1, r1, rtt) in zip(rows, rows[1:]):
                    L[2] += 1
                    d = r1 - r0
                    if d > 0:
                        L[3] += 1
                        L[4] = max(L[4], d)
                        worst_s[link].append((d, t1_[:8], (b1 - b0) * 8 / 1e6))
            for link, (b, r, n, nr, mx) in sorted(by_link.items()):
                top = sorted(worst_s[link], reverse=True)[:3]
                print(f"  TCP {link}: {b / 1e6:.0f} MB sent, retransmitted {r / 1e3:.0f} KB "
                      f"({100.0 * r / b if b else 0:.4f}%), {nr}/{n} s with retransmits, max {mx / 1e3:.0f} KB/s; "
                      f"worst {[(f'{d / 1e3:.0f}KB', t, f'{m:.0f}Mbps') for d, t, m in top]}")
            if "usb" in by_link:
                b, r, n, nr, _ = by_link["usb"]
                gate("USB link retransmits", r == 0,
                     f"{r / 1e3:.0f} KB in {nr}/{n} s (a wired link should lose nothing; each loss shrinks the TCP window)")

    if a.ifq:
        q0, q1 = parse_ifq(a.ifq[0]), parse_ifq(a.ifq[1])
        if not q0 or not q1:
            print(f"  Mac USB interface queue: no snapshot ({a.ifq[0]} / {a.ifq[1]})")
        else:
            tot_drop = 0
            for ifn in sorted(set(q0) & set(q1)):
                d = [b - c for b, c in zip(q1[ifn], q0[ifn])]
                tot_drop += d[1]
                print(f"  Mac USB interface {ifn} queue: {d[0]} pkts sent, {d[1]} dropped "
                      f"({d[2]} overflow), flow-control events {d[3]}")
            gate("Mac USB interface queue drops", tot_drop == 0,
                 f"{tot_drop} packets dropped by the Mac's own NCM queue (each one is a TCP loss)")

    if a.csv:
        with open(a.csv, "w") as f:
            f.write("second,presented_fps,max_interval_ms,max_g2g_ms,mac_encoded,phase,link\n")
            for s in range(nsec):
                f.write(f"{s},{per_fps[s]},{per_maxint[s]:.1f},{per_g2g[s]:.1f},{per_enc[s]},"
                        f"{per_phase[s]},{per_link[s]}\n")

    nfail = sum(not ok for _, ok, _ in gates)
    print(f"STRICT GATES: {len(gates) - nfail}/{len(gates)} pass")
    for name, ok, detail in gates:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
