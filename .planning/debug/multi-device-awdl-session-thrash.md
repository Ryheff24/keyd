# Debug Session: multi-device-awdl-session-thrash

## Symptoms

- Expected: a paired device should remain connected while another nearby device sits in pairing mode.
- Actual: the connected app flickers and the agent log shows rapid AWDL churn.
- Reproduction: keep one paired device connected, then open a second device in pairing mode nearby.

## Investigation

- Clarified scenario: the existing paired device is on AWDL, while the second device is attached by USB and sitting in pairing mode.
- The macOS agent log shows the active paired device repeatedly sending `Session resumed`, but the transport layer also logs repeated AWDL replacements and an immediate `USB promoted over AWDL (re-plug)` when the second device's USB tunnel comes up.
- The agent was treating the new USB tunnel as authoritative before it knew which device it belonged to, so a pairing-mode USB device could evict the live AWDL session.
- The pairing device also prewarms AWDL, so its extra AWDL socket could contend with the active AWDL session and amplify the reconnect loop.
- After app relaunch, the agent did not retain `pairedDeviceID`, so it also had no way to tell whether a newly arrived USB `sessionResume` belonged to the already-paired device.

## Root Cause

The transport manager lacked identity gating across both transports. It promoted any ready USB tunnel over the current AWDL session before validating the device, and it also allowed extra AWDL sockets to compete with the active AWDL connection. With one paired device on AWDL and another unpaired device on USB in pairing mode, that let the second device repeatedly destabilize the real session.

## Fix

- Remember the active paired device ID whenever the current device sends `sessionResume`.
- When USB comes up while AWDL is already active, keep the AWDL session live and decode USB traffic in a pending state until the USB side identifies itself.
- Promote USB only if the USB `sessionResume` matches the known paired device; otherwise reject the USB pairing attempt and drop that tunnel.
- Reject extra AWDL sockets while an AWDL session is already active instead of replacing the current session.

## Follow-up After Repro

- The macOS fix held: the new agent log no longer shows `USB promoted over AWDL (re-plug)` from the unpaired USB device.
- Remaining issue: the pairing iPad log shows `USB connected` once, then continuously logs `AWDL ready for pairing`.
- Root cause on iOS: in `KeydApp/KeydApp/Transport/TransportManager.swift`, the pairing-mode branch (`suppressAWDLStatusUntilPaired`) handled AWDL `onConnectionReady` before checking whether USB was already primary.
- That let an in-flight AWDL connection remain alive even after USB had already connected, so the unpaired device kept re-establishing AWDL and hammering the Mac listener.
- Fix: when AWDL becomes ready and `connectionState == .usbConnected`, always tear AWDL back down via `prepareForUSBStandby()` first, even in pairing mode.

## Follow-up: iPhone Retry Spam

- The paired iPhone's `Retry` path surfaced a second iOS-side issue: the iPhone log would repeatedly show `Connected via AWDL`, `AWDL connection event ignored`, `Sent session resume`, then immediate AWDL disconnects.
- Root cause: `KeydApp/KeydApp/Transport/AWDLTransport.swift` only stored the active `NWConnection` after it reached `.ready`, so stale in-flight AWDL attempts could overlap and later become the "current" connection.
- That let a newer, ignored AWDL socket replace the real one in `AWDLTransport`, causing `sendMessage(.sessionResume)` to target the wrong socket and churn the paired iPhone.
- Fix: track the pending AWDL connection immediately when dialing, ignore stale `.ready` callbacks from superseded sockets, and serialize `TransportManager.reconnect()` startup behind the prior transport teardown task.

## Follow-up: USB-First Startup Order

- A later physical repro showed a different failure mode even without tapping `Retry`: with the unpaired iPad already connected on USB, the paired iPhone would attempt AWDL and immediately get reset.
- The Mac's unified log showed `USB connected`, followed by every iPhone AWDL socket being logged as `AWDL connection arrived while USB is active; closing it`.
- Root cause: the macOS agent still treated a fresh USB tunnel as authoritative as soon as it became ready when no confirmed session was active, even before that USB device identified itself.
- That meant an unpaired USB device could still block the paired iPhone's AWDL session if USB connected first.
- Fix: when a device is already paired, keep new USB connections in the pending decoder path until they prove their identity, even from the `.disconnected` state. Only promote to `.usbConnected` after a matching USB `sessionResume`.

## Follow-up: Paired USB Rejected After Agent Relaunch

- A later repro hit the inverse transport order: an unpaired iPad sat on AWDL in pairing mode while the already-paired iPhone connected over USB.
- The iPhone log showed immediate `Pairing invalidated by Mac` after `Sent session resume`, and the Mac's unified log showed `USB connected while no confirmed session is active; waiting for USB session identity` followed by `Rejected USB session resume from non-paired device ...`.
- Root cause: the macOS agent only persisted the shared secret, not `pairedDeviceID`. After `KeydAgent` relaunched, `isPaired` restored as true but `pairedDeviceID` was nil, so the first paired USB `sessionResume` could never match and was rejected. QR repair also failed because the agent still considered itself paired.
- The prior AWDL resume path also blindly overwrote `pairedDeviceID` from any `sessionResume`, so identity recovery was inconsistent across transports.
- Fix: persist `pairedDeviceID` in the macOS keychain at pairing time, reload it on startup, and use a shared `validateOrAdoptPairedDevice` path for both USB and AWDL `sessionResume` handling. The adoption path only runs for legacy paired installs that have a stored secret but no saved device ID yet.

## Follow-up: AWDL-First Startup Order

- After the USB identity fix, the paired iPhone could reconnect over USB again, but a new AWDL-only repro still failed when both devices were on AWDL and the iPad remained unpaired.
- The iPhone log showed repeated `Connected via AWDL`, `Sent session resume`, then immediate socket resets, while the iPad log showed a single `AWDL ready for pairing`.
- The Mac's unified log showed one initial `AWDL connected`, then a sustained flood of `Additional AWDL connection arrived while AWDL is active; closing it`, with no successful `Session resumed`.
- Root cause: on macOS, the first AWDL socket was still treated as authoritative as soon as it reached `.ready` whenever the app was already paired. If the unpaired iPad's prewarmed pairing channel won that race, it occupied the only AWDL slot and the paired iPhone's later AWDL resumes were all rejected.
- Fix: when the Mac is already paired and has no confirmed active session, treat AWDL like USB: keep the first AWDL socket in an unconfirmed `pairingAWDL` state, allow later AWDL candidates to replace stale unconfirmed ones, and only promote to `awdlConnected` after a matching `sessionResume`. Unpaired AWDL `pairingRequest` traffic is rejected and the candidate socket is dropped without poisoning the paired session.

## Follow-up: USB-First Device Selection

- After the AWDL gating fix, another repro still failed when both devices were connected over USB and the unpaired iPad was attached first.
- In that case, the paired iPhone would give up on USB and fall back to AWDL even though it was physically connected over USB.
- Root cause: the macOS `USBListener` always asked usbmuxd for the first attached USB device and opened a tunnel only to that device. If the unpaired iPad was first and had the app listening, it could monopolize the only USB tunnel slot; after the app-layer rejection, the next reconnect would pick the same first USB device again, starving the paired iPhone.
- Fix: rotate USB tunnel attempts across all attached USB devices instead of always choosing the first one. The listener now enumerates every attached USB device, starts its next attempt after the last successfully connected usbmux device, and falls through to later devices if an earlier one rejects the port connection.

## Follow-up: Idle Pending USB Tunnel Starves Paired Device

- A follow-up repro showed the first USB-device rotation change was still incomplete.
- The Mac unified log showed `Connected to USB device 77 over usbmuxd on port 12345`, then `USB connected while no confirmed session is active; waiting for USB session identity`, and then nothing else on USB before the paired iPhone later resumed on AWDL.
- Root cause: the unpaired iPad's app could accept the USB tunnel and keep it open while sending no identifying traffic. Because the pending tunnel never disconnected, the usbmux connect loop never rotated to the next attached device, so the paired iPhone never got a USB attempt.
- Fix: add a short timeout for unconfirmed USB identity while the Mac is already paired. If the pending USB tunnel does not send `sessionResume` quickly, the agent drops that idle USB connection so `USBListener` can rotate to the next attached USB device.

## Follow-up: Architectural Overhaul — AWDL Reconnect Storm After Hard-Close

### Symptoms (latest repro)
- iPhone (paired) connects via AWDL, user hard-closes app, reopens — enters infinite reconnect loop
- iPad (unpaired, app open) generates 455+ AWDL connect cycles
- Mac accepts 588 AWDL connections, closes 503 as candidates, only 1 successful session
- iPhone log: repeated "Connected via AWDL" -> immediate Code=-1005 or ECONNRESET, never stabilizes
- iPad log: continuous "AWDL ready for pairing" / Code=-1005 flap cycle (every ~1 second)

### Analysis: Why Incremental Fixes Keep Failing

After 8+ incremental fixes over the same issue, each fix addressed ONE edge case but the fundamental design produces new ones. The problem is structural:

**Problem 1: Single-slot AWDL state machine on Mac**
The Mac can hold exactly ONE AWDL connection at a time (`pairingAWDL(NWConnection)` or `awdlConnected(NWConnection)`). When two devices are browsing for `_keyd._tcp` simultaneously, every new connection DISPLACES the previous one before identity is known. This creates a destructive race.

**Problem 2: Unpaired device auto-reconnects infinitely on AWDL**
The iPad's `AWDLTransport` has `autoConnectEnabled = true` (set during `startBrowsing` flow). When the Mac closes/rejects its connection, `handleConnectionState` fires `.cancelled/.failed` -> `clearConnection` -> `maybeConnectIfNeeded` -> instant reconnect. There is NO backoff and NO pairing-awareness. An unpaired device hammers the Mac with ~1 connection/second indefinitely.

**Problem 3: Timing race between connect and sessionResume**
The iPhone sends `sessionResume` only after its `connectionState` transitions to `.awdlConnected`. But the Mac may have already replaced/closed that socket (because the iPad reconnected between `.ready` and `sessionResume` arrival). The sessionResume either never arrives or targets a dead socket.

**Problem 4: Both sides auto-reconnect, creating oscillation**
When the Mac closes the iPad's AWDL socket, the iPad reconnects. When the iPad's new connection displaces the iPhone's pending connection, the iPhone reconnects. Both sides independently retry, creating amplified oscillation instead of dampening.

### Root Cause

The architecture assumes a 1:1 relationship (one Mac, one iOS device) but operates in a multi-device environment without any mechanism to prevent unpaired devices from disrupting paired sessions at the transport layer. The incremental patches tried to add identity gating and slot management, but the core design — a single-slot listener with aggressive auto-reconnect on all clients — is fundamentally incompatible with multi-device AWDL.

### Fix: Three-Part Restructuring

**Part 1 (Mac): Multi-slot pending AWDL with identity timeout**
Replace single-slot `pairingAWDL(NWConnection)` with a pending connection pool. Accept ALL incoming AWDL connections into a pending set, give each a short identity timeout, and only promote to `awdlConnected` when a matching `sessionResume` arrives. Non-matching connections get rejected and dropped without affecting other pending connections.

**Part 2 (iOS): Unpaired devices must NOT auto-reconnect on AWDL**
When `suppressAWDLStatusUntilPaired` is true (pairing mode), disable `autoConnectEnabled` after the FIRST successful connection. The device connects once, sends its pairing request if the user scans QR, and waits. If the Mac closes the connection, the device does NOT reconnect until the user explicitly initiates pairing again.

**Part 3 (iOS): Paired device AWDL reconnect with exponential backoff**
When a paired iPhone's AWDL connection drops, instead of instant retry via `maybeConnectIfNeeded()`, add exponential backoff starting at 0.5s, doubling to max 8s. Reset backoff on successful `sessionResume` acknowledgment. This prevents the paired device from amplifying a thrash loop.

### Implementation

All three parts implemented and macOS build verified:

**Part 1 — Mac: Multi-slot pending AWDL pool**
- New `AgentConnectionState.awdlPending` state (holds no connection ref)
- `pendingAWDLSlots: [ObjectIdentifier: PendingAWDLSlot]` pool (max 4 slots)
- Each slot has its own `MessageDecoder`, `NWConnection`, and independent 3s identity timeout
- When a slot receives matching `sessionResume`, it promotes that connection and closes all other slots
- When a slot receives non-matching identity or times out, only that slot is closed
- Non-matching connections no longer displace the paired device's connection

**Part 2 — iOS: Pairing mode stops auto-reconnect**
- `AWDLTransport.beginAutoConnect(pairingMode: Bool)` — new parameter
- When `pairingModeEnabled = true`, `scheduleReconnectIfNeeded()` sets `autoConnectEnabled = false` instead of reconnecting
- iPad in pairing mode connects once; if Mac closes it, iPad stops and waits for user-initiated pairing
- Eliminates the 455-connection iPad storm entirely

**Part 3 — iOS: Exponential backoff on AWDL reconnect**
- Replaced instant `maybeConnectIfNeeded()` in failure/cancel handlers with `scheduleReconnectIfNeeded()`
- Backoff starts at 0.5s, doubles each failure, caps at 8s
- Reset to 0 on successful connection (`.ready` state) and on heartbeat ack
- Even if paired iPhone fails repeatedly, it backs off instead of amplifying the storm

**Files changed:**
- `macOS/KeydAgent/Transport/TransportManager.swift` — multi-slot AWDL pool, new `.awdlPending` state
- `KeydApp/KeydApp/Transport/AWDLTransport.swift` — exponential backoff, pairing mode flag
- `KeydApp/KeydApp/Transport/TransportManager.swift` — pass pairingMode, reset backoff on heartbeat ack

### Verification Result: Partial Success

iPad backoff worked (1 attempt instead of 455). iPhone backoff increased properly (0.5→1→2→4→8s). But iPhone still never stabilized — every connection died with -1005 within ~1 second.

## Follow-up: Heartbeat Killing Healthy Connections

- After applying the multi-slot pool + backoff, the iPhone log showed proper backoff (0.5→1→2→4→8s) and the Mac log showed successful promotions every time. But the connection never stabilized.
- The Mac successfully promoted each iPhone connection and logged "Session resumed". But the iPhone reported "AWDL heartbeat timed out" followed by "Receive error: Code=-1005" on every attempt.
- Root cause: the -1005 was caused BY the heartbeat timeout, not by AWDL instability. The heartbeat fired immediately on connection, gave only 1 second for a response, and the Mac hadn't finished promoting the pending slot yet. `handleAWDLHeartbeatFailure` called `invalidateActiveConnection()` which canceled the NWConnection, causing the -1005 in `startReceiving`.
- Fix: added 3-second stabilization delay before first heartbeat (Mac needs time to receive sessionResume, promote from pending pool, and respond). Increased ack timeout from 1s to 2s and interval from 1s to 2s (AWDL has higher latency than LAN TCP).
- Also fixed: backoff was resetting on every `.ready` state (line 117 of AWDLTransport), so it never actually increased past 0.5s. Removed the reset — backoff only resets on confirmed session via `resetBackoff()` (called on heartbeat ack).
- Also fixed: promoted pending AWDL slots had their disconnect silently swallowed. The pending pool receive loop called `removePendingAWDLSlot` on error (no-op after promotion), never calling `handleDisconnect`. Now routes through `handleDisconnect` for promoted connections.
- Also fixed: `shouldProbeAWDLCandidateWhileActive()` blocked probing for 8 seconds after last activity. After hard-close, the stale connection lingered and all new iPhone connections were rejected. Now always allows one pending probe slot.
- Also added `--info` to mac log collector in `scripts/deploy-and-run.sh`.
- Result: iPhone now connects and stays connected on first attempt.

## Remaining Issue: iPad USB Churn (unpaired, connected via USB)

- The iPad (unpaired, on USB) is in a massive connect/reject loop with zero backoff.
- Pattern: USB tunnel ready → USB connected → Mac rejects after 2s pending timeout → iPad gets -1005 → iPad tries AWDL handoff → AWDL also rejected → loop repeats endlessly.
- The AWDL pairing-mode backoff works, but USB has no equivalent backoff for unpaired devices.
- Additionally, `handleUSBConnectionReady` clears ALL pending AWDL slots when any USB arrives, even from unpaired devices going into pending mode. This delays the paired iPhone's AWDL connection by ~10 seconds because the iPad's USB keeps interrupting iPhone's AWDL promotion.
- Needs: USB backoff for unpaired devices + don't clear AWDL pending slots for pending USB connections.

### Status
- status: partially_resolved
- updated: 2026-03-01
