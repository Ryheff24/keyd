#!/usr/bin/env python3
"""Check an E2E run's connection lifecycle against tla/Lifecycle.tla (Design).

Usage: lifecycle_trace.py MAC_LOG IPAD_LOG [IPAD_LOG ...]

Every lifecycle step logs one line tagged "LC <Action>" naming the model action it is
(Mac: os_log in WirelessTransport.m / SessionManager.m; iPad: [CONSOLE] prints). This
replays the Mac's LC lines through the design's guards and effects, per connection id,
and each iPad log (one per app instance, oldest first) through the iPad's, then checks:

  - every action's guard held when it was logged (a step the model does not allow is a
    divergence between code and spec, reported with its line);
  - RestartOnNewConn: each Mac READY while a session streams over Wi-Fi/AWDL is followed by
    "LC Restart" (a READY while USB carries the session is a standby link: Lifecycle v2,
    counted, not checked; the Mac's FSM state is read from "Transitioned to:" lines);
  - AuthBeforeDisplace: a connection becomes current only at READY, never at accept;
  - RestGood (observable part): each iPad instance that reached READY ends streaming
    (LC IpadHandshake or LC IpadFrame), i.e. no instance stuck at connecting;
  - no as-built takeover lines ("Replacing stale wireless input connection",
    "Duplicate wireless candidate") appear.

The iPad's console lines carry no timestamps (inventory U7), so the two sides are checked
each in its own order, and joined only by these per-instance outcomes.
Exit status 0 if the run conforms, 1 otherwise.
"""
import re
import sys

LC = re.compile(r"LC (\w+)(.*)")
KV = re.compile(r"(\w+)=([^ ]+)")
ASBUILT = ("Replacing stale wireless input connection", "Duplicate wireless candidate")
TRANSITION = re.compile(r"Transitioned to: (\S+)")


def events(path):
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            for bad in ASBUILT:
                if bad in line:
                    yield n, "AsBuiltTakeover", {"line": bad}, line
            t = TRANSITION.search(line)
            if t:
                yield n, "Transport", {"state": t.group(1)}, line
            m = LC.search(line)
            if m:
                yield n, m.group(1), dict(KV.findall(m.group(2))), line


def check_mac(path, errs):
    conn = {}            # cid -> none/accepted/ready/ended
    cur = 0              # mac.in
    streaming = False    # Mac session STREAMING (after the first Restart)
    need_restart = None  # (line, cid) of a READY that must be followed by LC Restart
    transport = "Idle"   # Mac FSM state ("Transitioned to:"); the model (v1) is wireless only
    standby = 0          # READYs while USB carried the session (Lifecycle v2, not checked)
    counts = {}
    for n, act, kv, line in events(path):
        counts[act] = counts.get(act, 0) + 1
        cid = int(kv.get("cid", "0") or 0)
        where = f"{path}:{n}"
        if act == "Transport":
            transport = kv["state"]
            if transport == "USB-NCM" and need_restart:
                need_restart = None  # the session continues on USB, outside Lifecycle v1
                standby += 1
            continue
        if act == "AsBuiltTakeover":
            errs.append(f"{where}: as-built takeover line ({kv['line']}): AuthBeforeDisplace not in effect")
        elif act == "MacAccept":
            if conn.get(cid, "none") != "none":
                errs.append(f"{where}: MacAccept cid={cid} twice")
            conn[cid] = "accepted"
        elif act == "MacReady":
            if conn.get(cid) != "accepted":
                errs.append(f"{where}: MacReady cid={cid} from {conn.get(cid, 'none')} (guard: accepted)")
            old = int(kv.get("replaced", "0") or 0)
            if old and old != cur:
                errs.append(f"{where}: MacReady replaced={old} but current was {cur}")
            if cur and cur != cid:
                conn[cur] = "ended"
            conn[cid] = "ready"
            cur = cid
            if need_restart:
                errs.append(f"{need_restart[0]}: MacReady cid={need_restart[1]} never restarted the session")
            if streaming and transport == "USB-NCM":
                standby += 1
                need_restart = None
            else:
                need_restart = (where, cid) if streaming else None
        elif act == "Restart":
            if "reason" in kv or "session" in kv:
                if need_restart and "session" in kv:
                    need_restart = None
                streaming = True
        elif act == "MacTlsFail":
            if conn.get(cid) not in ("accepted", None):
                errs.append(f"{where}: MacTlsFail cid={cid} from {conn.get(cid)} (guard: accepted)")
            if cid == cur:
                errs.append(f"{where}: MacTlsFail on the current connection cid={cid}")
            conn[cid] = "ended"
        elif act in ("MacEnd", "MacSilent"):
            branch = kv.get("branch", "silent" if act == "MacSilent" else "")
            if branch == "stale":
                if cid == cur and cid:
                    errs.append(f"{where}: MacEnd branch=stale on the current connection cid={cid}")
            else:
                if cid != cur:
                    errs.append(f"{where}: {act} cid={cid} branch={branch} but current is {cur}")
                cur = 0
                if branch != "degraded":
                    streaming = False if branch in ("disconnect", "silent") else streaming
            conn[cid] = "ended"
        elif act == "MediaEnd":
            if kv.get("branch") == "disconnect":
                cur = 0
                streaming = False
        elif act == "MacCurrentCleared":
            pass
        elif act in ("MacEncodeHold", "MacEncodeUnsent", "MacStaleReady"):
            pass
        else:
            errs.append(f"{where}: unknown Mac LC action {act}")
    if need_restart:
        errs.append(f"{need_restart[0]}: MacReady cid={need_restart[1]} never restarted the session")
    if standby:
        counts["StandbyReadyUnderUSB(unchecked,v2)"] = standby
    return counts


def check_ipad(path, errs):
    state = "connecting"
    dialing = ready = False
    counts = {}
    for n, act, kv, line in events(path):
        counts[act] = counts.get(act, 0) + 1
        where = f"{path}:{n}"
        if act == "IpadDial":
            if dialing or ready:
                pass  # a redial replaces the previous connection (iW tearDownConnections)
            dialing, ready = True, False
        elif act == "IpadReady":
            if not dialing:
                errs.append(f"{where}: IpadReady with no dial")
            ready = True
        elif act in ("IpadHandshake", "IpadFrame"):
            if not ready:
                errs.append(f"{where}: {act} before IpadReady")
            state = "streaming"
        elif act == "IpadLoss":
            dialing = ready = False
            if state == "streaming":
                state = "reconnecting"
    if counts.get("IpadReady") and state != "streaming":
        errs.append(f"{path}: instance reached READY but ended in {state} (RestGood: stuck, the takeover hang)")
    return state, counts


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    errs = []
    mac_counts = check_mac(sys.argv[1], errs)
    print("Mac LC actions:", " ".join(f"{k}={v}" for k, v in sorted(mac_counts.items())))
    for p in sys.argv[2:]:
        st, c = check_ipad(p, errs)
        print(f"iPad {p}: final={st} actions:", " ".join(f"{k}={v}" for k, v in sorted(c.items())))
    if errs:
        print(f"LIFECYCLE TRACE: {len(errs)} divergence(s)")
        for e in errs:
            print("  " + e)
        return 1
    print("LIFECYCLE TRACE: conforms to tla/Lifecycle.tla (Design)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
