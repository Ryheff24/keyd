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

`TransportManager` promoted to `awdlConnected` immediately after USB loss if `AWDLTransport` still held an `NWConnection` object. That check only reflected object presence, not whether the connection was still ready on a usable wireless path.

When the pre-warmed `NWConnection` lost its underlying path after USB unplug, Network.framework could keep the object alive briefly before the receive loop failed. During that gap, `hasConnection()` returned true and the UI showed `AWDL`, then dropped to `Disconnected` once the stale connection finally failed.

## Fix

- `AWDLTransport.hasConnection()` now requires an actually ready connection on a satisfied Wi-Fi path.
- `AWDLTransport` marks a previously ready connection unavailable as soon as the connection enters `.waiting`, instead of waiting for the later receive failure.
- `TransportManager` now re-checks AWDL after a short 200 ms settle window before promoting from USB to AWDL, giving Network.framework time to publish path-loss transitions.

## Verification

- `KeydApp` iOS Simulator build succeeded after the transport changes.
- Physical-device repro is still required to confirm the UI now switches directly from USB to `Disconnected` when all wireless transport is unavailable.

## Status

Root cause found and fix applied.
