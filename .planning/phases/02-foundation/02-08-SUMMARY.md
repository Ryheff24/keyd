---
phase: 02-foundation
plan: 08
subsystem: app
tags: [swiftui, metal, cametallayer, session-orchestration, hud, qr-pairing, reconnection, uiviewrepresentable]

# Dependency graph
requires:
  - phase: 02-05
    provides: "HEVCDecoder and LZ4Decompressor for frame decode pipeline"
  - phase: 02-06
    provides: "MetalRenderer with CAMetalDisplayLink for rendering decoded frames"
  - phase: 02-03
    provides: "USBNetworkTransport and WirelessTransport for media/input receive"
  - phase: 02-04
    provides: "QRPairing for initial device pairing via QR scan"
provides:
  - "ContentView -- main SwiftUI view switching between pairing, connecting, streaming, reconnecting states"
  - "SessionManager -- iPad session orchestration wiring transport -> decode -> render pipeline"
  - "MetalRenderView -- UIViewRepresentable with plain UIView (CAMetalLayer layerClass, NOT MTKView)"
  - "MetalHostView -- UIView subclass with layerClass = CAMetalLayer for CAMetalDisplayLink compatibility"
  - "QRScannerView -- UIViewRepresentable wrapping AVCaptureVideoPreviewLayer"
  - "ReconnectingOverlay -- frozen last frame + semi-transparent overlay with Retry Now"
  - "HUDView -- frosted glass pill with compact/expanded states and auto-hide"
  - "HUDViewModel -- transport info, FPS, latency, eco mode, resolution match relay"
affects: [02-09, 02-10, 03-01, 03-02]

# Tech tracking
tech-stack:
  added: [SwiftUI @Observable, UIViewRepresentable, CAMetalLayer layerClass override]
  patterns: [Plain UIView with CAMetalLayer for CAMetalDisplayLink hosting, DragGesture for swipe-down HUD reveal (not UIScreenEdgePanGestureRecognizer), exponential backoff reconnection with frozen frame overlay]

key-files:
  created:
    - RemoteDesktop/iPadOS/App/ContentView.swift
    - RemoteDesktop/iPadOS/App/SessionManager.swift
    - RemoteDesktop/iPadOS/HUD/HUDView.swift
    - RemoteDesktop/iPadOS/HUD/HUDViewModel.swift
  modified:
    - RemoteDesktop/iPadOS/App/RemoteDesktopApp.swift
    - RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj

key-decisions:
  - "MetalHostView uses layerClass override (not MTKView) for CAMetalDisplayLink compatibility"
  - "DragGesture on top 44pt zone for HUD reveal -- does not use UIScreenEdgePanGestureRecognizer (RD-APP-07)"
  - "Reconnection shows frozen last frame (not black screen) with semi-transparent overlay"
  - "Resolution match request sent as InputEventHeader type=0x20 subtype=0x01 via TCP"

patterns-established:
  - "UIView with layerClass = CAMetalLayer.self wrapped in UIViewRepresentable for Metal rendering"
  - "Session state machine: awaitingPairing -> connecting -> streaming -> reconnecting -> disconnected"
  - "Frame receive pipeline: transport callback -> parse MediaFrameHeader -> decode (LZ4/HEVC) -> MetalRenderer.updateFrame"
  - "HUD auto-hide: 3-second Timer.scheduledTimer that collapses and hides on expiry"
  - "Exponential backoff reconnection: 0.5s * 2^attempt, capped at 8s"

requirements-completed: [RD-APP-02, RD-APP-03, RD-APP-07]

# Metrics
duration: 4min
completed: 2026-03-28
---

# Phase 2 Plan 8: iPad App Shell Summary

**SwiftUI app shell with ContentView (QR/Metal/HUD states), SessionManager (transport-decode-render pipeline), frosted glass HUD pill with auto-hide, and reconnection overlay over frozen frame**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-28T17:20:18Z
- **Completed:** 2026-03-28T17:25:02Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- ContentView with state-driven UI: QR scanner (no onboarding), connecting spinner, streaming (Metal + HUD), reconnecting (frozen frame + overlay), disconnected
- SessionManager wiring full pipeline: transport receive -> MediaFrameHeader parse -> LZ4/HEVC decode -> MetalRenderer.updateFrame, with FPS tracking, latency probe handling, eco mode relay, resolution match request
- MetalRenderView using plain UIView with CAMetalLayer layerClass (NOT MTKView) for CAMetalDisplayLink compatibility
- HUD overlay: frosted glass pill (ultraThinMaterial + Capsule) with compact (icon + latency + FPS) and expanded (eco toggle, resolution, bitrate, match iPad resolution, disconnect) states, 3-second auto-hide, swipe-down-from-top reveal

## Task Commits

Each task was committed atomically:

1. **Task 1: HUD overlay (frosted glass pill, compact/expanded, auto-hide)** - `3ef0955` (feat)
2. **Task 2: ContentView + SessionManager (main view + session orchestration)** - `7f287b8` (feat)

## Files Created/Modified
- `RemoteDesktop/iPadOS/HUD/HUDViewModel.swift` - @Observable view model: transport state, latency, FPS, eco mode, auto-hide timer, transport flash
- `RemoteDesktop/iPadOS/HUD/HUDView.swift` - SwiftUI frosted glass pill with compact/expanded states, swipe-down reveal gesture
- `RemoteDesktop/iPadOS/App/ContentView.swift` - Main view (QR/connecting/streaming/reconnecting/disconnected), MetalRenderView, MetalHostView, QRScannerView, ReconnectingOverlay
- `RemoteDesktop/iPadOS/App/SessionManager.swift` - Session orchestration: pairing flow, transport monitoring, frame pipeline, reconnection with exponential backoff
- `RemoteDesktop/iPadOS/App/RemoteDesktopApp.swift` - Updated with SessionManager @State and scenePhase lifecycle handling
- `RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj` - Added HUD group, ContentView, SessionManager to project and build phase

## Decisions Made
- **MetalHostView pattern:** Used `layerClass` override on plain UIView (not MTKView) because CAMetalDisplayLink requires owning its own CAMetalLayer without MTKView's competing drawable scheduling.
- **HUD reveal gesture:** Used SwiftUI DragGesture on top 44pt invisible zone rather than UIScreenEdgePanGestureRecognizer, per RD-APP-07 requirement that system edge swipes must not be intercepted.
- **Reconnection UX:** Frozen last frame with semi-transparent overlay and "Retry Now" button, per user decision (NOT black screen -- visual continuity).
- **Resolution match protocol:** Sends InputEventHeader with type=0x20 (modeChange) and subtype=0x01 via active transport's TCP connection.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added missing UIKit import in SessionManager**
- **Found during:** Task 2 (type-check verification)
- **Issue:** `UIScreen.main.nativeBounds` requires UIKit import, which was not included
- **Fix:** Added `import UIKit` to SessionManager.swift
- **Files modified:** RemoteDesktop/iPadOS/App/SessionManager.swift
- **Verification:** `xcrun --sdk iphoneos swiftc -typecheck` passes cleanly
- **Committed in:** 7f287b8

---

**Total deviations:** 1 auto-fixed (1 bug -- missing import)
**Impact on plan:** Trivial fix for correct compilation. No scope creep.

## Issues Encountered
None -- both tasks executed cleanly after the UIKit import fix.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Full iPad app shell ready: view hierarchy, session management, decode pipeline, HUD overlay
- SessionManager ready for input event integration (Phase 3: touch-to-mouse, keyboard)
- HUD eco mode toggle wired to Mac via TCP (Mac-side handler in Plan 09)
- Resolution match button wired to Mac via TCP (Mac-side handler in Plan 09)
- Reconnection logic ready for transport cascade testing (Plan 10)

## Self-Check: PASSED

All 4 created files verified present. Both task commits verified in git log (3ef0955, 7f287b8).
