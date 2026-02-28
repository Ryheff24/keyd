# Debug Session: usb-state-shows-awdl-while-cabled

## Symptoms

- Expected: when the iPhone is cabled and USB is the only viable transport, the iPhone should show `USB`.
- Actual: the iPhone status badge consistently shows `AWDL`.
- No explicit runtime error is surfaced.
- Reproduction: launch both apps, connect by USB, pair if needed, disable Wi-Fi and Bluetooth on the Mac, keep the cable attached, observe typing still works while the badge remains `AWDL`.

## Investigation

- The iOS USB path in `KeydApp/KeydApp/Transport/USBTransport.swift` attempts an outbound `NWConnection` to `127.0.0.1:12345`.
- The macOS USB path in `macOS/KeydAgent/Transport/USBListener.swift` listens on `12345` and assumes usbmuxd forwards the iPhone's outbound TCP connect to that listener.
- That assumption is backwards for app-level usbmux traffic: the host side must open the usbmux tunnel to a listening port on the iPhone. The current code has the iPhone dialing the Mac, so USB never becomes ready.
- Because USB never becomes ready, `KeydApp/KeydApp/Transport/TransportManager.swift` leaves AWDL as the only connected transport, which matches the observed badge.

## Root Cause

The USB transport was implemented in the wrong direction. The code treats usbmuxd as a transparent reverse tunnel from iPhone to Mac, but the host side must initiate the device-port connection. As a result, the current USB path never reaches `.usbConnected`, so AWDL remains the active transport and the UI correctly reflects that fallback.

## Fix In Progress

- Refactor iOS `USBTransport` into a listener that accepts an inbound USB tunnel.
- Replace the macOS USB listener with a usbmuxd connector that opens a tunnel to the iPhone listener.
- Keep AWDL pre-warm behavior, but promote USB whenever the usbmux tunnel becomes ready.

## Follow-up After Device Check

- Confirmed: `AWDL -> USB` now switches cleanly; badge changes to USB and input continues.
- New failure: `USB -> AWDL` flips the badge to AWDL, but input stops.
- Cause: `macOS/KeydAgent/Transport/TransportManager.swift` was holding a one-byte standby `receive()` on the AWDL socket. After USB dropped, that pending read consumed the first byte of the first AWDL frame, corrupting the length-prefixed protocol stream and preventing further decoding.
- Fix: replace the one-byte standby probe with a full standby receive loop that drains frames without surfacing them, then reuse that same decoder when the standby connection is promoted to active.
