# Debug Session: false-awdl-promotion-when-networking-unavailable

## Summary

Issue: AWDL is shown immediately after USB unplug even when no wireless transport is actually available, then falls back to `Disconnected` about 10 seconds later.

## Symptoms

- Expected: When USB is unplugged and no wireless transport is usable, the app should switch directly to `Disconnected`.
- Actual: Unplugging USB immediately shows `AWDL` even when wireless is unavailable. After about 10 seconds, it changes to `Disconnected`.
- Errors: No explicit error. AWDL appears to be treated as available before it is actually usable.
- Timeline: Observed during 01-05 transport stabilization after transport mode display and switching became more consistent.
- Reproduction:
  1. Connect and pair over USB.
  2. Turn off Mac Wi-Fi.
  3. Turn off Mac Bluetooth.
  4. Put iPhone in Airplane Mode if needed.
  5. Unplug USB.
  6. Observe the app immediately shows `AWDL`.
  7. Wait about 10 seconds.
  8. Observe the app changes to `Disconnected`.

## Root Cause

The original failure was larger than a bad readiness check. Both apps kept a live pre-warmed AWDL socket around while USB was active and treated that standby socket as if it would still be valid after USB dropped.

That standby socket could survive long after the peer-to-peer path was gone because the code only reacted to socket read/write failure, not to Bonjour discovery loss. As a result:

- USB unplug could promote a stale AWDL socket instead of forcing a fresh wireless connect.
- Active AWDL sessions could stay visually connected after networking died because the browser had already lost the peer, but the stale socket had not failed yet.
- Re-enabling networking could get stuck because reconnect logic was built around the old standby socket instead of the current browse results.

After removing live standby sockets, reconnect improved, but active AWDL disconnect still depended on Network.framework and Bonjour timing. In practice that meant networking loss while already on AWDL could still take 15+ seconds to surface if the socket stayed open and browse result expiration lagged.

## Fix

- iOS `AWDLTransport` now keeps AWDL in discovery mode while USB is primary. It stores the latest discovered endpoint, but it does not hold a live standby socket.
- When the Bonjour result set goes empty, iOS immediately tears down any active AWDL socket and reports disconnect instead of waiting for a later TCP failure.
- When the peer reappears in browse results and AWDL auto-connect is enabled, iOS reconnects from the fresh discovered endpoint automatically.
- USB disconnect now starts a fresh AWDL connect attempt only if a peer is currently discoverable; otherwise the app goes directly to `Disconnected`.
- macOS now closes AWDL connections that arrive while USB is active instead of retaining a standby AWDL socket for later promotion.
- SharedProtocol now includes `transportHeartbeat` and `transportHeartbeatAck`.
- While AWDL is active, iOS sends a heartbeat once per second and expects an ack within one second. If the ack is missed, it tears down the AWDL socket immediately and marks the session disconnected instead of waiting for Bonjour or TCP timeout.
- macOS responds to heartbeat probes on the active transport so iOS can detect dead AWDL sessions based on missed application-level liveness, not just socket failure.

## Verification

- `KeydApp` iOS Simulator build succeeded after the transport changes.
- `KeydAgent` macOS build succeeded after the transport changes.
- `swift test` passed in `SharedProtocol` after the new heartbeat messages were added.
- Physical-device repro is still required to confirm the stale standby path is gone and AWDL reconnects cleanly when networking returns.

## Status

Root cause found and fix applied.
