---
status: investigating
trigger: "Investigate issue: ipad-sigtrap-during-usb-stream-with-wifi-fallback"
created: 2026-03-30T22:30:00-04:00
updated: 2026-03-30T22:30:00-04:00
---

## Current Focus

hypothesis: Background WiFi fallback activation creates a second active transport/media path while USB remains primary, leading to inconsistent frame/renderer state or an intentional trap on the iPad shortly after dual connectivity starts.
test: Inspect transport/session code paths for duplicate callbacks, state transitions, or assertions triggered only after wireless TCP/DTLS becomes ready during an existing USB stream.
expecting: If dual active transports are unsafe, code or logs will show WiFi remaining fully connected during USB streaming without gating, and a fix should prevent wireless media/input activity until failover is needed.
next_action: Read knowledge base if present, then search for signal-5/assertion/trap-related code and transport interaction points tied to background WiFi fallback.

## Symptoms

expected: USB LZ4 stream stays stable throughout E2E tests, even while background WiFi fallback browsing/connection is active.
actual: Test runs pass pairing/handshake/frame reception/latency/keepalive, then FPS declines after WiFi fallback connects and the iPad app dies with signal 5 before extended tests continue.
errors: /tmp/e2e-results.log ends with 'App terminated due to signal 5.' Mac log shows USB session active, WiFi advertising/connection comes up in background, then iPad dies. No direct crash stack yet.
reproduction: Run ./RemoteDesktop/scripts/run-e2e-tests.sh 240 from repo root with iPad attached over USB. Observe successful USB stream, background WiFi connection establishment, then iPad SIGTRAP.
started: Happening in current workspace after recent transport/LZ4 changes. A prior theory blamed LZ4 resize transition, but current logs contradict that.

## Eliminated

## Evidence

- timestamp: 2026-03-30T22:30:00-04:00
  checked: Initial required source and log read
  found: Geometry update is sent on macOS after viewport report and before ScreenCapture starts emitting complete frames; iPad log also shows geometry update before early LZ4 frames.
  implication: The earlier "geometry/frame-size race at stream start" hypothesis is weakened.

- timestamp: 2026-03-30T22:30:00-04:00
  checked: /tmp/e2e-results.log and /tmp/keyd-e2e-mac.log
  found: USB handshake, LZ4 decode, latency probe, and keepalive all succeed; after WiFi browsing/advertising starts, iPad establishes wireless TCP and DTLS while USB remains connected, then FPS drops from 39 to 21 before signal 5 terminates the app.
  implication: The crash correlates with dual active transport state, not initial USB session bring-up.

- timestamp: 2026-03-30T22:30:00-04:00
  checked: iPad SessionManager.swift transport setup
  found: startTransportMonitoring always starts USB monitoring and then starts WiFi browsing as background fallback; sendInputEventToMac prefers USB when both are connected, but wireless media receive callbacks remain active.
  implication: The iPad can receive wireless media/input activity concurrently with an active USB session.

- timestamp: 2026-03-30T22:30:00-04:00
  checked: iPad WirelessTransport.swift
  found: On wireless TCP ready it marks isConnected=true, fires onConnectionChanged, and establishes a DTLS media connection regardless of whether USB is already streaming.
  implication: Background WiFi fallback currently becomes a full secondary transport, not passive discovery-only fallback.

- timestamp: 2026-03-30T22:30:00-04:00
  checked: macOS SessionManager.m
  found: macOS intentionally starts WiFi advertising even while USB is connected, and wireless TCP/DTLS listeners accept the iPad connection without switching the FSM away from USB-NCM.
  implication: The system explicitly allows dual connected transports during USB streaming; any unsafe shared state here is a high-probability root-cause area.

## Resolution

root_cause:
fix:
verification:
files_changed: []
