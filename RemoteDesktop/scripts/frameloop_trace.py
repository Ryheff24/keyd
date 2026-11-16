#!/usr/bin/env python3
"""Check an E2E run's media frame loop against tla/FrameLoop.tla (Design).

Usage: frameloop_trace.py MAC_LOG IPAD_LOG [IPAD_LOG ...]

Every frame-loop step logs one line tagged "FL <Action>" naming the model step it is (Mac:
os_log in SessionManager.m; iPad: [CONSOLE] prints in SessionManager.swift). Checks:

  - EpochMonotone: the Mac's handshake epochs (FL MacHs ep=) strictly increase over the whole
    Mac log, across agent relaunches.
  - HsConn: each iPad instance accepts only increasing epochs (FL IpadHs accepted=1), and a
    rejected handshake really was not newer (ep <= prevEp). An FL IpadReset starts over.
  - KeyOnBreak / IdleKey (Mac): every owed key (FL MacNeedKey) is followed by a keyframe
    sent (FL MacKey). A key still owed while the session is visibly live more than 3 s
    later (an FL MacHoldDelta or FL MacIdleKey line 3 s or more after the need) is a
    divergence. A session that simply ended with a key owed is not.
  - AwaitOnFail / RestGood (iPad): every await (an accepted handshake, or FL IpadFail
    current=1) ends with a decoded keyframe (FL IpadKey). An await that sent 6 or more key
    requests (FL IpadKeyRetry reason=await sent=1, 500 ms apart: about 3 s; the iPad log has
    no timestamps) with no key is a divergence: stuck. The count restarts at each accepted
    handshake and the check runs at every such point, not only at the end of the log.

Also reported: holds, foreign-connection drops, stale outputs and key wait times. Exit status
0 if the run conforms, 1 otherwise.
"""
import re
import sys
from datetime import datetime

FL = re.compile(r"FL (\w+)(.*)")
KV = re.compile(r"(\w+)=([^ ]+)")
TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")


def events(path):
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            m = FL.search(line)
            t = TS.match(line)
            ts = datetime.strptime(t.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f") if t else None
            if m:
                yield n, ts, m.group(1), dict(KV.findall(m.group(2))), line
            elif ts is not None:
                yield n, ts, None, {}, line


def pct(vals, p):
    if not vals:
        return 0
    v = sorted(vals)
    return v[min(len(v) - 1, int(p / 100 * len(v)))]


def check_mac(path, errs):
    counts, waits = {}, []
    last_ep = None
    need = None  # (line, ts, reason)
    last_ts = None
    for n, ts, act, kv, line in events(path):
        if ts:
            last_ts = ts
        if act is None:
            continue
        counts[act] = counts.get(act, 0) + 1
        where = f"{path}:{n}"
        if act == "MacHs":
            ep = int(kv.get("ep", "0"))
            if last_ep is not None and ep <= last_ep:
                errs.append(f"{where}: MacHs ep={ep} not above the previous {last_ep} (EpochMonotone)")
            last_ep = ep
        elif act == "MacNeedKey":
            if need is None:
                need = (where, ts, kv.get("reason", "?"))
        elif act == "MacKey":
            if need is None:
                errs.append(f"{where}: MacKey with no key owed")
            waits.append(int(kv.get("waitMs", "0")))
            need = None
        elif act in ("MacHoldDelta", "MacIdleKey") and need and need[1] and ts \
                and (ts - need[1]).total_seconds() >= 3.0:
            errs.append(f"{need[0]}: key owed (reason={need[2]}) and still not sent "
                        f"{(ts - need[1]).total_seconds():.1f} s later while the session is live "
                        f"({where}: {act}) (KeyOnBreak/IdleKey)")
            need = None  # one report per owed key
    return counts, waits


def check_ipad(path, errs):
    counts, waits = {}, []
    hs_ep = 0
    awaiting = None  # (line, reason, key requests sent)

    def stuck(at):
        if awaiting and awaiting[2] >= 6:
            errs.append(f"{awaiting[0]}: iPad awaiting a keyframe (reason={awaiting[1]}) through "
                        f"{awaiting[2]} key requests with no key, {at} (RestGood: stuck)")

    for n, _ts, act, kv, line in events(path):
        if act is None:
            continue
        counts[act] = counts.get(act, 0) + 1
        where = f"{path}:{n}"
        if act == "IpadHs":
            ep = int(kv.get("ep", "0"))
            prev = int(kv.get("prevEp", "0"))
            if kv.get("accepted") == "1":
                if ep <= hs_ep:
                    errs.append(f"{where}: IpadHs accepted ep={ep} not above {hs_ep} (HsConn)")
                hs_ep = ep
                stuck(f"until the handshake at {where}")
                awaiting = (where, "handshake", 0)
            elif ep > prev:
                errs.append(f"{where}: IpadHs rejected ep={ep} although above prevEp={prev}")
        elif act == "IpadReset":
            stuck(f"until the reset at {where}")
            hs_ep = 0
            awaiting = None
        elif act == "IpadFail" and kv.get("current") == "1":
            if awaiting is None:
                awaiting = (where, kv.get("reason", "fail"), 0)
        elif act == "IpadKeyRetry" and kv.get("reason") == "await" and kv.get("sent") == "1" \
                and awaiting:
            awaiting = (awaiting[0], awaiting[1], awaiting[2] + 1)
        elif act == "IpadKey":
            waits.append(int(kv.get("waitMs", "0")))
            awaiting = None
    stuck("to the end of the log")
    return counts, waits


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    errs = []
    mc, mw = check_mac(sys.argv[1], errs)
    print("Mac FL actions:", " ".join(f"{k}={v}" for k, v in sorted(mc.items())) or "none")
    if mw:
        print(f"Mac key wait ms: n={len(mw)} p50={pct(mw, 50)} p95={pct(mw, 95)} max={max(mw)}")
    for p in sys.argv[2:]:
        c, w = check_ipad(p, errs)
        print(f"iPad {p} FL actions:", " ".join(f"{k}={v}" for k, v in sorted(c.items())) or "none")
        if w:
            print(f"iPad {p} await-to-key ms: n={len(w)} p50={pct(w, 50)} p95={pct(w, 95)} max={max(w)}")
    if not mc.get("MacHs"):
        errs.append(f"{sys.argv[1]}: no FL MacHs line (agent without the FrameLoop gate?)")
    if errs:
        print(f"FRAMELOOP TRACE: {len(errs)} divergence(s)")
        for e in errs:
            print("  " + e)
        return 1
    print("FRAMELOOP TRACE: conforms to tla/FrameLoop.tla (Design)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
