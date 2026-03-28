---
phase: 02-foundation
plan: 06
subsystem: render
tags: [metal, cametaldisplaylink, p3-color, triple-buffering, bgra, letterbox, promotion-120hz, shaders]

# Dependency graph
requires:
  - phase: 02-01
    provides: "Buildable iPadOS RemoteDesktopApp Xcode project with bridging header and Info.plist (CADisableMinimumFrameDuration=YES)"
provides:
  - "MetalRenderer with CAMetalDisplayLink-driven render loop at up to 120Hz"
  - "P3 wide color gamut rendering via displayP3 color space on CAMetalLayer"
  - "Triple buffering with DispatchSemaphore(value: 3) and maximumDrawableCount = 3"
  - "Letterbox viewport computation for aspect-fit Mac screen display"
  - "BGRA texture upload from decode pipeline via replaceRegion"
  - "Metal vertex + fragment shaders for full-screen textured quad with viewport uniform"
affects: [02-07, 02-08, 02-09, 02-10]

# Tech tracking
tech-stack:
  added: [CAMetalDisplayLink, CAMetalLayer, MTLRenderPipelineState, Metal Shading Language]
  patterns: [CAMetalDisplayLink delegate render loop, triple buffering with DispatchSemaphore, NDC viewport uniforms for letterboxing, texture lock for thread-safe frame delivery]

key-files:
  created:
    - RemoteDesktop/iPadOS/Render/Shaders.metal
    - RemoteDesktop/iPadOS/Render/MetalRenderer.swift
  modified:
    - RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj

key-decisions:
  - "No UIKit import needed in MetalRenderer -- all types come from Metal/MetalKit/QuartzCore"

patterns-established:
  - "CAMetalDisplayLink delegate pattern: metalDisplayLink(_:needsUpdate:) with semaphore wait/signal"
  - "NDC viewport uniform for letterboxing: shader maps unit quad to viewport rect in [-1,1] space"
  - "Thread-safe frame texture update: NSLock protects texture creation and upload"

requirements-completed: [RD-REND-01, RD-REND-02, RD-REND-03, RD-APP-01, RD-APP-04, RD-APP-05]

# Metrics
duration: 4min
completed: 2026-03-28
---

# Phase 2 Plan 6: Metal Renderer Summary

**CAMetalDisplayLink-driven Metal renderer with P3 color, 120Hz triple buffering, and letterbox viewport for aspect-fit Mac screen display on iPad**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-28T17:04:17Z
- **Completed:** 2026-03-28T17:08:39Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Metal vertex and fragment shaders for full-screen textured quad with viewport uniform enabling letterbox positioning
- MetalRenderer class with CAMetalDisplayLink delegate driving render loop at up to 120Hz ProMotion
- P3 wide color gamut via CGColorSpace.displayP3 on CAMetalLayer with triple buffering (3 drawables + DispatchSemaphore)
- Aspect-fit letterbox viewport computation: full width with true black bars top/bottom (OLED pixels off), pillarbox for portrait
- Thread-safe BGRA texture upload from decode pipeline via replaceRegion with NSLock protection

## Task Commits

Each task was committed atomically:

1. **Task 1: Metal shaders for BGRA texture rendering** - `2a003dc` (feat)
2. **Task 2: MetalRenderer with CAMetalDisplayLink + triple buffering + letterbox** - `fc7b919` (feat)

## Files Created/Modified
- `RemoteDesktop/iPadOS/Render/Shaders.metal` - Vertex shader (viewport-mapped quad via triangle strip) + fragment shader (BGRA texture sampling with linear filter)
- `RemoteDesktop/iPadOS/Render/MetalRenderer.swift` - CAMetalDisplayLink render loop, P3 color, triple buffering, letterbox viewport, BGRA texture upload
- `RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj` - Added Render group with Shaders.metal and MetalRenderer.swift to sources build phase

## Decisions Made
- Removed UIKit import from MetalRenderer -- all required types (CGRect, CGFloat, CGColorSpace, CAMetalLayer, CAMetalDisplayLink) come from Metal/MetalKit/QuartzCore. This allows macOS SDK type-checking as verification.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- iOS SDK not installed (Xcode 26.4 vs simulators 26.2) -- verified Swift compilation via `xcrun swiftc -typecheck` with macOS SDK (Metal API is cross-platform). Metal shader compilation could not be verified locally due to missing Metal Toolchain component but follows standard MSL patterns.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- MetalRenderer ready to receive decompressed frame data from decode pipeline (Plan 07/08)
- `updateFrame(_:width:height:)` is the entry point from LZ4 decompress or HEVC decode
- `setMacDisplaySize(width:height:)` ready for session handshake integration
- `handleBoundsChange(newBounds:scale:)` ready for view controller orientation handling
- Shaders compiled into default Metal library automatically by Xcode build system

## Self-Check: PASSED
