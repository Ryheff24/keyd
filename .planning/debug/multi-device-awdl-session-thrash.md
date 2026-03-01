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
