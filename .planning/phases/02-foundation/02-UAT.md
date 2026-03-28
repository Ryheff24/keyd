---
status: complete
phase: 02-foundation
source: [02-01-SUMMARY.md, 02-02-SUMMARY.md, 02-03-SUMMARY.md, 02-04-SUMMARY.md, 02-05-SUMMARY.md, 02-06-SUMMARY.md, 02-07-SUMMARY.md, 02-08-SUMMARY.md, 02-09-SUMMARY.md]
started: 2026-03-28T17:40:00Z
updated: 2026-03-28T17:42:00Z
---

## Current Test

[testing complete]

## Tests

### 1. macOS Agent Builds and Launches
expected: Build succeeds with no errors. App launches as menu bar-only (no dock icon).
result: pass

### 2. Menu Bar Icon and Menu Items
expected: After launching the macOS agent, a status bar icon appears (disconnected antenna icon). Clicking it shows a menu with: connection state, encode mode, resolution info, pairing controls (Show QR Code, Reset Pairing), permission status for Screen Recording and Accessibility with links to System Settings, Fix Login Item, version, and Quit.
result: issue
reported: "'Fix Login Item' label is wrong — actual label is 'Fix Launch at Login'. It does not do anything when clicked. Does not appear to be a status given how it reads. All other items function as expected."
severity: major

### 3. Permission Gating Flow
expected: On first launch (before granting permissions), the menu shows Screen Recording and Accessibility as "not granted" with clickable links to System Settings. The agent polls every 3 seconds — after granting both permissions in System Settings, the menu updates to show them as granted without restarting the app.
result: issue
reported: "Labels say 'Required' not 'not granted'. Accessibility does not update after being granted without restart. Screen Recording shows system popup that app may need to quit to take effect. Neither permission is detected after granting — only detected after app restart, then shows 'Granted'."
severity: major

### 4. QR Code for Pairing
expected: Clicking "Show QR Code" in the menu bar displays a QR code window. The QR code contains JSON with the Mac's cert fingerprint, IP, port, and display geometry.
result: pass

### 5. iPad App Builds and Launches
expected: Build the iPad app (`xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination 'generic/platform=iOS'` or via Xcode to device). App launches on iPad showing a camera view for QR code scanning — no onboarding screens, straight to scanner.
result: pass

### 6. QR Pairing Flow
expected: Point the iPad camera at the Mac's QR code. iPad recognizes the QR code, establishes a TLS-pinned connection to the Mac, performs key exchange, and transitions to a "connecting" state (spinner). Both devices store the shared secret in Keychain for future reconnection.
result: issue
reported: "Nothing happens when scanning QR — the app just freezes."
severity: blocker

### 7. End-to-End Screen Streaming (USB)
expected: With iPad connected to Mac via USB cable (after pairing), the Mac's screen appears on the iPad in real-time. The image is aspect-fit with true black letterbox bars (top/bottom or sides depending on aspect ratio). The stream uses LZ4+delta compression over USB NCM.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 8. iPad HUD Overlay
expected: While streaming, swipe down from the top ~44pt of the iPad screen. A frosted glass pill (HUD) appears showing compact info: transport icon, latency, and FPS. Tap the pill to expand it — expanded view shows: eco mode toggle, resolution info, bitrate, "Match iPad Resolution" button, and Disconnect. HUD auto-hides after ~3 seconds of inactivity.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 9. Resolution Matching
expected: In the expanded HUD, tap "Match iPad Resolution." The Mac's display resolution changes to match the iPad's native resolution. The stream updates to fill the iPad screen without letterboxing. On disconnect, the Mac's original resolution is restored.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 10. Eco Mode Toggle
expected: In the expanded HUD, toggle eco mode ON. The stream switches from LZ4+delta to HEVC encoding at reduced quality (1080p/30fps). Toggle OFF returns to full quality LZ4+delta. Visible as slight quality/smoothness change.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 11. Wireless Fallback (Unplug USB)
expected: While streaming over USB, unplug the cable. The iPad briefly shows a reconnecting overlay (frozen last frame with semi-transparent overlay) then reconnects over Wi-Fi/AWDL. The menu bar icon changes from cable to wifi/antenna. Stream resumes with HEVC encoding (wireless mode).
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 12. Reconnection with Retry
expected: While streaming, kill the macOS agent (Cmd+Q or force quit). iPad shows the reconnecting overlay with a "Retry Now" button over the frozen last frame. Relaunch the Mac agent — iPad reconnects automatically (exponential backoff). Alternatively, tap "Retry Now" for immediate reconnect attempt.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 13. Latency and FPS in HUD
expected: While streaming, open the HUD. Latency (ms) and FPS values are displayed and updating in real-time. FPS should be close to display refresh rate on USB (up to 120fps on ProMotion iPad). Latency should be low single-digit ms on USB.
result: skipped
reason: Blocked by QR pairing failure (test 6)

### 14. Login Item Registration
expected: The macOS agent registers as a login item via SMAppService. Check System Settings > General > Login Items — RemoteDesktopAgent should appear in the list. The agent launches automatically on next login.
result: skipped
reason: Blocked by QR pairing failure (test 6)

## Summary

total: 14
passed: 3
issues: 3
pending: 0
skipped: 8
skipped: 8

## Gaps

- truth: "Menu bar shows 'Fix Login Item' that functions correctly"
  status: failed
  reason: "User reported: 'Fix Login Item' label is wrong — actual label is 'Fix Launch at Login'. It does not do anything when clicked. Does not appear to be a status given how it reads."
  severity: major
  test: 2
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""

- truth: "QR pairing completes: iPad scans QR, establishes TLS-pinned connection, performs ECDH key exchange, transitions to connecting state"
  status: failed
  reason: "User reported: Nothing happens when scanning QR — the app just freezes."
  severity: blocker
  test: 6
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""

- truth: "Permission status updates live without restarting the app after granting in System Settings"
  status: failed
  reason: "User reported: Labels say 'Required' not 'not granted'. Neither Accessibility nor Screen Recording detected after granting — only after app restart. Screen Recording shows system popup that app may need to quit. Polling does not detect changes live."
  severity: major
  test: 3
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
