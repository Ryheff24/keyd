---
phase: 02-foundation
plan: 02
subsystem: capture
tags: [screencapturekit, lz4, delta-xor, iosurface, cmsamplebuffer, compression, objc, c]

# Dependency graph
requires:
  - phase: 02-01
    provides: "Shared C headers (protocol.h, delta.h, lz4.h), vendored LZ4, delta module, macOS Xcode project"
provides:
  - "FrameCompressor.c — pure C LZ4+delta hot path with pre-allocated buffers"
  - "ScreenCapture.m — SCStream delegate with IOSurface frame delivery and 2s watchdog"
  - "CompressOutput struct with MediaFrameHeader ready for transport"
affects: [02-03, 02-04, 02-05, 02-06]

# Tech tracking
tech-stack:
  added: [zlib (crc32), os_log]
  patterns: [IOSurface lock/unlock pair for safe pointer access, CMSampleBuffer retain lifecycle for IOSurface pinning, dispatch_assert_queue for single-threaded enforcement, delta-to-keyframe fallback at 60% threshold, frame watchdog with CGDisplayIsAsleep check]

key-files:
  created:
    - RemoteDesktop/macOS/Compress/FrameCompressor.h
    - RemoteDesktop/macOS/Compress/FrameCompressor.c
    - RemoteDesktop/macOS/Capture/ScreenCapture.h
    - RemoteDesktop/macOS/Capture/ScreenCapture.m
  modified:
    - RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj

key-decisions:
  - "Used zlib crc32() for payload CRC -- always available on macOS, no additional dependency"
  - "Two separate dispatch queues (capture + compress) to decouple SCStream delivery from LZ4 work"
  - "Frame watchdog uses __weak/__strong dance to prevent retain cycles on dispatch timer"

patterns-established:
  - "IOSurface lock/unlock: always wrap IOSurfaceGetBaseAddress access in kIOSurfaceLockReadOnly pair"
  - "CMSampleBuffer retain: CFRetain before async dispatch, CFRelease after compress returns"
  - "Delta fallback: if compressed delta > 60% of last keyframe, discard and send keyframe"
  - "Pre-allocated buffers: malloc in init, never in hot path (output buf, delta scratch)"
  - "dispatch_assert_queue at entry to enforce single-threaded compress access"

requirements-completed: [RD-CAP-01, RD-CAP-02, RD-CAP-03, RD-CAP-04, RD-CAP-05, RD-COMP-02, RD-COMP-03, RD-COMP-04, RD-COMP-05, RD-COMP-08, RD-PERF-03]

# Metrics
duration: 6min
completed: 2026-03-28
---

# Phase 2 Plan 2: Screen Capture + LZ4 Delta Compression Summary

**SCStream delegate capturing Retina display at 120fps BGRA, with LZ4+delta compression hot path using pre-allocated buffers, IOSurface pinning, and 2-second frame watchdog for Sequoia re-auth detection**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-28T16:49:57Z
- **Completed:** 2026-03-28T16:56:09Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Pure C FrameCompressor with LZ4 block API compression for keyframes and XOR delta frames, 60% delta threshold fallback, pre-allocated buffers (no malloc in hot path), and dispatch_assert_queue enforcement
- Objective-C ScreenCapture wrapping SCStream with IOSurface zero-copy handoff, CMSampleBuffer retain lifecycle management, BGRA 120fps capture, and frame watchdog with display-sleep awareness
- Xcode project updated with Compress/Capture groups, libz.tbd, and header search paths for cross-module includes

## Task Commits

Each task was committed atomically:

1. **Task 1: FrameCompressor -- LZ4+delta compression hot path (pure C)** - `8f46d15` (feat)
2. **Task 2: ScreenCapture -- SCStream delegate with frame watchdog** - `642b9b6` (feat)

## Files Created/Modified
- `RemoteDesktop/macOS/Compress/FrameCompressor.h` - CompressOutput and FrameCompressorState structs, compress_frame API
- `RemoteDesktop/macOS/Compress/FrameCompressor.c` - LZ4+delta hot path: keyframe/delta decision, IOSurface lock, threshold fallback, CRC-32
- `RemoteDesktop/macOS/Capture/ScreenCapture.h` - SCStreamOutput interface with frame and re-auth callbacks
- `RemoteDesktop/macOS/Capture/ScreenCapture.m` - SCStream setup, 120fps BGRA, CMSampleBuffer retain/release, watchdog timer
- `RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj` - Added Compress/Capture groups, source files, libz.tbd, header search paths

## Decisions Made
- **zlib for CRC-32:** Used system zlib crc32() rather than rolling a custom CRC implementation. Always available on macOS, zero dependency cost.
- **Separate capture and compress queues:** SCStream output handler runs on `com.keydrd.capture` queue, then dispatches to `com.keydrd.compress` queue. This prevents SCStream frame delivery from blocking on LZ4 compression.
- **__typeof__ instead of typeof:** Used `__typeof__` for the weak/strong capture dance in watchdog timer to ensure portability across C language standards.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added zlib (libz.tbd) to project for CRC-32**
- **Found during:** Task 1 (FrameCompressor.c)
- **Issue:** Plan specified CRC-32 in MediaFrameHeader but no CRC implementation existed in the project
- **Fix:** Used system zlib crc32(), added libz.tbd to Xcode project frameworks
- **Files modified:** RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj
- **Verification:** Build succeeds, crc32 calls compile
- **Committed in:** 8f46d15

**2. [Rule 1 - Bug] Fixed const qualifier warning in block-captured CompressOutput**
- **Found during:** Task 2 (ScreenCapture.m)
- **Issue:** CompressOutput local variable captured in nested block was implicitly const, causing pointer qualifier mismatch warning
- **Fix:** Added `__block` storage qualifier to CompressOutput local variable
- **Files modified:** RemoteDesktop/macOS/Capture/ScreenCapture.m
- **Verification:** Clean compile with no warnings
- **Committed in:** 642b9b6

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for correctness. No scope creep.

## Issues Encountered
- Pre-existing build failures in USBNetworkTransport.m and WirelessTransport.m (uncommitted transport files from another plan with `strongSelf` errors). Out of scope -- logged to deferred-items.md. Our files compile cleanly.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- FrameCompressor provides CompressOutput with MediaFrameHeader ready for transport layer (plan 02-04/05)
- ScreenCapture.onFrame callback is the integration point for the transport sender
- Frame watchdog + onReauthorizationNeeded callback ready for menu bar integration (plan 02-09)
- Both modules compile cleanly as part of the macOS agent

## Self-Check: PASSED

All 4 created files verified present. Both task commits verified in git log (8f46d15, 642b9b6).

---
*Phase: 02-foundation*
*Completed: 2026-03-28*
