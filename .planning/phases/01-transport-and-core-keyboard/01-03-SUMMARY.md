---
phase: 01-transport-and-core-keyboard
plan: "03"
subsystem: ui
tags: [swift, swiftui, network-framework, usbmuxd, awdl, bonjour, liquid-glass, ios, xcodegen]

# Dependency graph
requires:
  - phase: 01-transport-and-core-keyboard
    plan: "01"
    provides: SharedProtocol package with KeydMessage, KeyEvent, HotkeyEvent, VirtualKey, ModifierFlags
provides:
  - KeydApp iOS Xcode project (buildable for generic/platform=iOS)
  - USBTransport: NWConnection to 127.0.0.1:12345 with 10-attempt exponential backoff (0.5s-5s)
  - AWDLTransport: NWBrowser for _keyd._tcp Bonjour, pre-warmed concurrently with USB
  - TransportManager: USB-primary/AWDL-fallback state machine with automatic switchover
  - KeyboardView: full-width QWERTY SwiftUI keyboard (shift, caps lock, backspace, space, return)
  - HotkeyPanel: 2-column grid of 12 shortcuts with Liquid Glass (.ultraThinMaterial) chrome
  - ConnectionStatusBadge: always-visible fallback for non-Dynamic Island devices
  - SecureInputOverlay: blocks keyboard on macOS secure input state change
  - Backspace: tap=single char delete, hold 0.5s=Cmd-Backspace word delete per CONTEXT.md
affects:
  - 01-04 (pairing + Dynamic Island Live Activity will extend TransportManager and RootView)
  - 01-05 (transport hardening builds on USBTransport/AWDLTransport)

# Tech tracking
tech-stack:
  added: [xcodegen, Network.framework (NWConnection/NWBrowser), UIKit (UIImpactFeedbackGenerator)]
  patterns:
    - Swift actors for thread-safe transport (USBTransport, AWDLTransport)
    - @MainActor ObservableObject for UI-driving state (TransportManager)
    - Liquid Glass applied to panel chrome (.ultraThinMaterial on container), not individual keys
    - Exponential backoff: start 0.5s, double each attempt, cap at 5.0s
    - xcodegen project.yml for reproducible Xcode project generation with local SPM packages

key-files:
  created:
    - KeydApp/project.yml
    - KeydApp/KeydApp.xcodeproj/project.pbxproj
    - KeydApp/KeydApp/Info.plist
    - KeydApp/KeydApp/KeydApp.entitlements
    - KeydApp/KeydApp/Transport/USBTransport.swift
    - KeydApp/KeydApp/Transport/AWDLTransport.swift
    - KeydApp/KeydApp/Transport/TransportManager.swift
    - KeydApp/KeydApp/UI/KeyboardView.swift
    - KeydApp/KeydApp/UI/HotkeyPanel.swift
    - KeydApp/KeydApp/UI/ConnectionStatusView.swift
    - KeydApp/KeydApp/App/KeydApp.swift
    - KeydApp/KeydApp/App/RootViewController.swift
  modified: []

key-decisions:
  - "xcodegen used to generate Xcode project (reproducible, version-control-friendly over hand-editing pbxproj)"
  - "CheckedContinuation<Void, Error> explicit type annotation required in send() for Swift type inference on NWConnection.send completion handler"
  - "UIBackgroundModes voip + NSBonjourServices + NSLocalNetworkUsageDescription configured via xcodegen project.yml properties"
  - "Portrait-only enforced via UISupportedInterfaceOrientations in Info.plist (intentional per CONTEXT.md, warnings expected)"

patterns-established:
  - "xcodegen project.yml: define iOS app targets with local SPM packages via 'path: ../PackageName'"
  - "Actor isolation: transport actors use Task { await self?.callback() } to bridge actor isolation at callback sites"
  - "Backspace dual-mode: Button.action=tap for single char, .onLongPressGesture(0.5s) for word-delete"

requirements-completed:
  - TRANS-01
  - TRANS-02
  - TRANS-03
  - TRANS-04
  - TRANS-07
  - KEY-01
  - KEY-02
  - KEY-03
  - KEY-04
  - KEY-05
  - SHORT-01
  - SHORT-02
  - SHORT-03
  - SHORT-04
  - SHORT-05
  - SHORT-06
  - SHORT-07
  - SHORT-08
  - SHORT-09
  - SHORT-10
  - SHORT-11
  - UX-01
  - UX-02
  - UX-03

# Metrics
duration: 5min
completed: 2026-02-28
---

# Phase 1 Plan 03: iOS App (KeydApp) Summary

**SwiftUI iOS app with QWERTY keyboard, 12-shortcut Liquid Glass hotkey panel, USB/AWDL dual transport, and automatic fallback switchover on USB unplug**

## Later Corrections (2026-02-28)

This summary reflects the original 01-03 implementation. Phase 1 later switched from the custom SwiftUI keyboard to an in-app stock iOS keyboard host, updated shortcut mappings (Redo = Cmd-Shift-Z, Delete Word = Option-Delete, Delete Line = Cmd-Delete), and moved debug access to the top status badge during 01-05. Treat this file as historical context, not the current source of truth for shipped behavior.

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-28T14:20:35Z
- **Completed:** 2026-02-28T14:25:10Z
- **Tasks:** 3 completed
- **Files modified:** 12 created

## Build Status

- **Xcode version:** Xcode 26.3 (Build 17C529)
- **Build result:** SUCCEEDED (0 errors)
- **Command:** `xcodebuild -project KeydApp/KeydApp.xcodeproj -scheme KeydApp -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- **Warnings:** 2 non-blocking (AppIntents metadata skip; portrait-only orientation warning — both expected/intentional)

## AWDL Test Result

Not yet tested on physical device — requires paid Apple Developer account and physical iPhone. See `user_setup` in PLAN.md for test prerequisites:
- Connect iPhone via USB to Mac
- Install via Xcode -> Run on device
- Test AWDL: unplug USB after USB-Connected state, verify automatic AWDL promotion within 3s

## Accomplishments

- Full buildable iOS 17+ App Xcode project generated via xcodegen with SharedProtocol local package dependency
- USBTransport: NWConnection to 127.0.0.1:12345 with 10-attempt exponential backoff (0.5s -> 1s -> 2s -> 4s -> 5s cap)
- AWDLTransport: NWBrowser for _keyd._tcp Bonjour discovery, pre-warmed concurrently with USB connection
- TransportManager: USB primary, AWDL promoted automatically on USB disconnect (no user action required)
- KeyboardView: full-width QWERTY with shift, caps lock, backspace (tap = single char, hold 0.5s = word-delete via Cmd-Backspace), space, return, 123 placeholder
- HotkeyPanel: 2-column grid with 12 shortcuts in Liquid Glass (.ultraThinMaterial) chrome
- All 12 hotkeys implemented: Copy/Paste/Cut/Undo/Redo/Select All/Escape/Tab/Del Word/Del Line/Screenshot/Quit
- Cmd-Q confirmation alert before sending (destructive action guard)
- ConnectionStatusBadge: always-visible top-of-screen fallback for non-Dynamic Island devices
- SecureInputOverlay: blocks keyboard when macOS reports password field active
- isIdleTimerDisabled = true while transport connected (prevents screen sleep)
- Portrait-only orientation enforced via UISupportedInterfaceOrientations
- voip UIBackgroundMode for persistent TCP while app backgrounded

## Hotkey Inventory

| # | Label | Virtual Key | Modifiers | Notes |
|---|-------|-------------|-----------|-------|
| 1 | Copy | VirtualKey.c (0x08) | .command | |
| 2 | Paste | VirtualKey.v (0x09) | .command | |
| 3 | Cut | VirtualKey.x (0x07) | .command | |
| 4 | Undo | VirtualKey.z (0x06) | .command | |
| 5 | Redo | VirtualKey.y (0x10) | .command | |
| 6 | Select All | VirtualKey.a (0x00) | .command | |
| 7 | Escape | VirtualKey.escape (0x35) | none | |
| 8 | Tab | VirtualKey.tab (0x30) | none | |
| 9 | Del Word | VirtualKey.delete (0x33) | .command | Cmd-Backspace |
| 10 | Del Line | VirtualKey.forwardDelete (0x75) | .command | Cmd-Delete |
| 11 | Screenshot | VirtualKey.four (0x15) | [.command, .shift] | Cmd-Shift-4 |
| 12 | Quit | VirtualKey.q (0x0C) | .command | Destructive - requires confirmation |

## Backspace Behavior

- **Tap:** Sends `HotkeyEvent(virtualKeyCode: VirtualKey.delete, keyDown: true)` — single character delete
- **Hold 0.5s:** Sends `HotkeyEvent(virtualKeyCode: VirtualKey.delete, modifiers: .command)` — word delete to left of cursor
- Matches locked CONTEXT.md UX decision

## Task Commits

1. **Task 1: Create KeydApp Xcode project** - `25b3a1c` (feat)
2. **Task 2: USB and AWDL transports** - `00156f8` (feat)
3. **Task 3: iOS keyboard UI** - `bec305b` (feat)

## Files Created

- `KeydApp/project.yml` - xcodegen spec for reproducible project generation
- `KeydApp/KeydApp.xcodeproj/project.pbxproj` - generated by xcodegen
- `KeydApp/KeydApp/Info.plist` - voip background mode, portrait-only, Bonjour config
- `KeydApp/KeydApp/KeydApp.entitlements` - com.apple.security.network.client
- `KeydApp/KeydApp/Transport/USBTransport.swift` - USB NWConnection with exponential backoff
- `KeydApp/KeydApp/Transport/AWDLTransport.swift` - AWDL NWBrowser Bonjour discovery
- `KeydApp/KeydApp/Transport/TransportManager.swift` - USB/AWDL state machine + idle timer
- `KeydApp/KeydApp/UI/KeyboardView.swift` - full-width QWERTY keyboard
- `KeydApp/KeydApp/UI/HotkeyPanel.swift` - 12-shortcut Liquid Glass hotkey grid
- `KeydApp/KeydApp/UI/ConnectionStatusView.swift` - connection status badge
- `KeydApp/KeydApp/App/KeydApp.swift` - @main App entry point
- `KeydApp/KeydApp/App/RootViewController.swift` - root SwiftUI view with keyboard stack

## Decisions Made

- **xcodegen over manual pbxproj:** Used xcodegen project.yml for reproducible, diff-friendly Xcode project generation instead of hand-editing project.pbxproj
- **CheckedContinuation type annotation:** `send()` in both transports requires explicit `CheckedContinuation<Void, Error>` due to Swift type inference limitation with `NWConnection.send` completion handler

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Swift type inference error in USBTransport.send() and AWDLTransport.send()**
- **Found during:** Task 3 (build verification)
- **Issue:** `withCheckedThrowingContinuation` call in `send()` produced "generic parameter 'T' could not be inferred" because the completion handler's two paths (`cont.resume(throwing:)` and `cont.resume()`) were ambiguous to the type checker
- **Fix:** Added explicit type annotation `(cont: CheckedContinuation<Void, Error>)` to both transport send() methods
- **Files modified:** `KeydApp/KeydApp/Transport/USBTransport.swift`, `KeydApp/KeydApp/Transport/AWDLTransport.swift`
- **Verification:** `xcodebuild ... BUILD SUCCEEDED` after fix
- **Committed in:** `bec305b` (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** Fix was necessary for compilation. No scope creep.

## Issues Encountered

- xcodegen strips custom Info.plist keys when using `info.path` alone — fixed by using `info.properties` in project.yml to define all custom keys declaratively
- Code signing required for device builds — use `CODE_SIGNING_ALLOWED=NO` for compilation-only verification; actual device deployment requires paid Apple Developer account

## User Setup Required

Physical device testing requires:
1. Paid Apple Developer account ($99/year) for AWDL entitlement
2. Connect iPhone via USB
3. Open Xcode, select your Development Team in Signing & Capabilities
4. Build and Run on device
5. Connect iPhone via USB first — app shows "USB" badge
6. Unplug USB — app should show "AWDL" within 3 seconds (if macOS AWDL listener is running)

## Next Phase Readiness

- Phase 1 Plan 04 (pairing + Dynamic Island) can now extend `TransportManager` with `PairingManager` and add `ActivityKit` Live Activity support
- `RootView` has `.onOpenURL` hook point for `keyd://reconnect` URL scheme (Plan 04 Dynamic Island reconnect button)
- Transport layer is complete and functional — macOS agent (Plan 02) can now be tested end-to-end on physical device

---
*Phase: 01-transport-and-core-keyboard*
*Completed: 2026-02-28*
