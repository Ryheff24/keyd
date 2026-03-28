---
phase: 02-foundation
plan: 07
subsystem: agent-shell
tags: [appdelegate, smappservice, nsstatus-item, session-manager, menu-bar, permissions, screen-recording, accessibility, login-item, objc]

# Dependency graph
requires:
  - phase: 02-02
    provides: "ScreenCapture + FrameCompressor for capture pipeline"
  - phase: 02-04
    provides: "PairingManager with TLS identity, QR payload, ECDH"
provides:
  - "AppDelegate.m — menu bar app lifecycle, SMAppService login item, --test-mode flag"
  - "StatusBarController.m — NSStatusItem with connection state, mode, resolution, permissions, pairing controls"
  - "SessionManager.m — session orchestration: permissions -> pairing -> connecting -> streaming with exponential backoff reconnection"
affects: [02-08, 02-09, 02-10]

# Tech tracking
tech-stack:
  added: [SMAppService, ServiceManagement.framework]
  patterns: [NSApplicationActivationPolicyAccessory for dock-less menu bar app, permission polling with 3s timer, transport FSM effect execution, exponential backoff reconnection]

key-files:
  created:
    - RemoteDesktop/macOS/App/AppDelegate.h
    - RemoteDesktop/macOS/App/AppDelegate.m
    - RemoteDesktop/macOS/App/SessionManager.h
    - RemoteDesktop/macOS/App/SessionManager.m
    - RemoteDesktop/macOS/MenuBar/StatusBarController.h
    - RemoteDesktop/macOS/MenuBar/StatusBarController.m
  modified:
    - RemoteDesktop/macOS/main.m
    - RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj

key-decisions:
  - "Programmatic NSApplication delegate setup instead of NSApplicationMain + NIB -- no XIB/NIB needed for menu bar-only app"
  - "All pipeline components (capture, encoder, transports, pairing) created eagerly in SessionManager init -- simplifies lifecycle and avoids lazy-init race conditions"
  - "Permission polling uses AXIsProcessTrustedWithOptions(NULL) for subsequent checks (no re-prompt) vs @YES on first check"

patterns-established:
  - "Menu bar app pattern: NSApplicationActivationPolicyAccessory + NSStatusItem with dynamic SF Symbol icons"
  - "Permission gating: poll CGPreflightScreenCaptureAccess + AXIsProcessTrustedWithOptions every 3s until both granted"
  - "Transport FSM integration: SessionManager.handleTransportEvent feeds FSM, executes effects (encode mode switch), notifies StatusBarController"
  - "Reconnection: exponential backoff at 0.5s, 1s, 2s, 4s, 8s intervals with transport event re-check"

requirements-completed: [RD-AGENT-01, RD-AGENT-03, RD-AGENT-04, RD-AGENT-05, RD-AGENT-06]

# Metrics
duration: 4min
completed: 2026-03-28
---

# Phase 2 Plan 7: macOS Agent Shell Summary

**Menu bar agent with SMAppService login item, permission gating (Screen Recording + Accessibility), SessionManager orchestrating permissions->pairing->streaming lifecycle with transport FSM and exponential backoff reconnection**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-28T17:20:24Z
- **Completed:** 2026-03-28T17:24:35Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- AppDelegate runs as NSApplicationActivationPolicyAccessory (no dock icon), registers SMAppService login item with stuck-status detection, and creates SessionManager + StatusBarController
- StatusBarController provides full menu bar UI: connection state with SF Symbol icons (cable/wifi/antenna/disconnected), encode mode (LZ4/HEVC), resolution info, pairing controls, permission status with System Settings deep links, Fix Login Item, version, quit
- SessionManager orchestrates complete session lifecycle: permission gating (Screen Recording + Accessibility polling every 3s) -> TLS identity setup -> pairing -> transport monitoring -> session handshake -> frame delivery with LZ4/HEVC mode switching via transport FSM -> exponential backoff reconnection

## Task Commits

Each task was committed atomically:

1. **Task 1: AppDelegate + SMAppService + permission gating** - `93ebc6e` (feat)
   Note: SessionManager and StatusBarController implementations were included in this commit because AppDelegate.m depends on both at compile time. Task 2 verified the build with all components present.

## Files Created/Modified
- `RemoteDesktop/macOS/App/AppDelegate.h` - AppDelegate interface with SessionManager + StatusBarController ownership
- `RemoteDesktop/macOS/App/AppDelegate.m` - Accessory activation policy, SMAppService registration, --test-mode support, wiring between SessionManager and StatusBarController
- `RemoteDesktop/macOS/App/SessionManager.h` - SessionState enum, pipeline component ownership, transport/mode/resolution callbacks
- `RemoteDesktop/macOS/App/SessionManager.m` - Full session lifecycle: permissions, pairing, transport FSM handling, LZ4/HEVC switching, frame delivery, reconnection with backoff
- `RemoteDesktop/macOS/MenuBar/StatusBarController.h` - Menu bar controller interface with state update methods
- `RemoteDesktop/macOS/MenuBar/StatusBarController.m` - NSStatusItem with 14 menu items, SF Symbol icon updates, System Settings deep links for permissions
- `RemoteDesktop/macOS/main.m` - Updated to programmatic delegate setup (no NIB)
- `RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj` - Added App/MenuBar groups, source files, ServiceManagement.framework, header search paths

## Decisions Made
- **Programmatic NSApplication setup:** Replaced NSApplicationMain with explicit [NSApplication sharedApplication] + delegate + [app run]. Menu bar-only apps don't need a NIB file.
- **Eager pipeline creation:** All components (ScreenCapture, HEVCEncoder, USBNetworkTransport, WirelessTransport, PairingManager) created in SessionManager init. Avoids lazy-init race conditions and simplifies lifecycle.
- **Permission re-check without prompt:** First check uses kAXTrustedCheckOptionPrompt:@YES to trigger system dialog. Subsequent polls use AXIsProcessTrustedWithOptions(NULL) to avoid re-prompting.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added ServiceManagement.framework for SMAppService**
- **Found during:** Task 1 (AppDelegate build)
- **Issue:** SMAppService requires ServiceManagement.framework which was not in the Xcode project
- **Fix:** Added ServiceManagement.framework to Frameworks group and build phase
- **Files modified:** RemoteDesktopAgent.xcodeproj/project.pbxproj
- **Verification:** BUILD SUCCEEDED
- **Committed in:** 93ebc6e

**2. [Rule 3 - Blocking] Updated main.m to programmatic delegate setup**
- **Found during:** Task 1 (AppDelegate build)
- **Issue:** NSApplicationMain expects a MainMenu NIB which doesn't exist for this menu bar-only app
- **Fix:** Replaced NSApplicationMain with explicit NSApplication + delegate + run pattern
- **Files modified:** main.m
- **Verification:** BUILD SUCCEEDED
- **Committed in:** 93ebc6e

**3. [Rule 3 - Blocking] Created all implementations in Task 1**
- **Found during:** Task 1 (AppDelegate.m compilation)
- **Issue:** AppDelegate.m imports and uses SessionManager and StatusBarController -- cannot compile without their implementations
- **Fix:** Created full SessionManager.m and StatusBarController.m in Task 1 instead of splitting across tasks
- **Files modified:** SessionManager.h/m, StatusBarController.h/m
- **Verification:** BUILD SUCCEEDED
- **Committed in:** 93ebc6e

---

**Total deviations:** 3 auto-fixed (3 blocking)
**Impact on plan:** All fixes necessary for compilation. The task split was adjusted for practical build dependency reasons. No scope creep -- all planned functionality was implemented.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- SessionManager provides the integration point for all pipeline components (capture, compress, encode, transport, pairing)
- StatusBarController's action callbacks (onPairRequested, onResetPairingRequested) ready for QR window integration (plan 02-09)
- SessionManager.onSessionStateChanged available for iPad shell to observe session lifecycle
- Frame delivery callback wired for both LZ4 and HEVC encode modes via transport FSM
- macOS agent builds and runs as menu bar app

## Self-Check: PASSED

All 6 created files verified present. Task commit verified in git log (93ebc6e).

---
*Phase: 02-foundation*
*Completed: 2026-03-28*
