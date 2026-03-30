---
status: resolved
trigger: "Pairing timeout when clearing pairing on both sides and scanning QR code"
created: 2026-03-01
updated: 2026-03-01
---

## ROOT CAUSE FOUND

**Primary bug:** iOS heartbeats the pre-pairing AWDL channel before pairing is complete.
The Mac drops heartbeats when unpaired (production guard: `if testMode != nil { break }; return`).
The iOS heartbeat times out (5s: 3s delay + 2s wait) → AWDL connection torn down → QR scan finds no transport → `connectionTimedOut`.

**NOT related to integration-test-failures.md** (that's USB + test harness; this is real-device AWDL pairing).

## Evidence

### Log trace (logs/20260301-185639)

**iPhone.log sequence:**
1. `[AWDLTransport] Connected via AWDL` — AWDL connects (before QR scan)
2. `[TransportManager] AWDL ready for pairing` — iOS FSM fires `awdlReady` event
3. `[TransportManager] AWDL connected` — FSM transitions to `awdlConnected`, emits `startHeartbeat`
4. `[TransportManager] AWDL heartbeat timed out; reconnecting` — **no ack from Mac** (Mac drops heartbeats when unpaired)
5. `[AWDLTransport] Pairing mode: auto-reconnect disabled after connection close` — `pairingModeEnabled=true` blocks reconnect
6. `[TransportManager] AWDL unavailable; disconnected` — transport dead
7. `[TransportManager] QR scan received` — user scans
8. `[TransportManager] Waiting for pairing transport` — no transport available
9. `[PairingManager] Pairing failed: connectionTimedOut` — 8s timeout

**mac.log:**
- 18:56:42: AWDL connection accepted, pairing channel open
- 18:56:47: `AWDL connection closed: EOF` — Mac's channel dropped (iOS heartbeat killed iOS side)
- After: no more AWDL events — Mac never receives QR pairing request

### Code path confirmed

**Mac guard** (`macOS/KeydAgent/Transport/TransportManager.swift:654-666`):
```swift
case .transportHeartbeat, .transportHeartbeatAck:
    if testMode != nil { break }
    return  // ← drops heartbeats when unpaired in production
```

**iOS FSM `awdlReady` transition** (`SharedProtocol/.../TransportStateMachine.swift:775-783`):
```swift
case .awdlReady:
    switch state {
    case .connecting(_, let awdl) where awdl:
        return (.awdlConnected(awaitingHeartbeatAck: false), [
            .startHeartbeat,  // ← emitted even in pairing mode
            ...
        ])
```

**`startAWDLHeartbeat()`** has no guard for `suppressAWDLStatusUntilPaired`, unlike `sendSessionResume()` which does check it.

## Fix

**File:** `KeydApp/KeydApp/Transport/TransportManager.swift`

Two changes:
1. Guard `startAWDLHeartbeat()` against pairing mode (parallel to how `sendSessionResume()` is guarded)
2. Start heartbeat in `finalizePairingTransportState()` when AWDL is active transport

```swift
// 1. In startAWDLHeartbeat():
private func startAWDLHeartbeat() {
    guard !suppressAWDLStatusUntilPaired else { return }  // ← add this
    awdlHeartbeatTask?.cancel()
    ...
}

// 2. In finalizePairingTransportState(), AWDL branch:
if await awdlTransport.hasConnection() {
    if case .awdlConnected = fsmState { } else {
        fsmState = .awdlConnected(awaitingHeartbeatAck: false)
        setIdleTimerState(true)
        logConnectionEvent("AWDL connected")
    }
    startAWDLHeartbeat()  // ← add this: start keepalive now that pairing is complete
    return
}
```

## Why This Is Correct

The AWDL heartbeat is a session keepalive for post-pairing connections. It makes no sense
to heartbeat the pairing channel before pairing is established. `sendSessionResume()` already
has this guard. `startAWDLHeartbeat()` was missing it.

After the fix:
- Pre-pairing AWDL channel: no heartbeat → connection stays up → QR scan succeeds
- Post-pairing AWDL session: heartbeat starts in `finalizePairingTransportState()` ✓
