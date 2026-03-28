---
phase: 02-foundation
plan: 05
subsystem: codec
tags: [videotoolbox, hevc, lz4, vt-compression-session, vt-decompression-session, delta-xor, objc, swift]

# Dependency graph
requires:
  - phase: 02-01
    provides: "Shared C headers (protocol.h, delta.h, lz4.h), vendored LZ4, delta module"
  - phase: 02-02
    provides: "FrameCompressor.c with LZ4+delta hot path and CompressOutput struct"
  - phase: 02-03
    provides: "Protocol.swift with MediaFrameHeader Swift mirror for flag parsing"
provides:
  - "HEVCEncoder.m -- VideoToolbox HEVC hardware encode with AverageBitRate and low-latency mode"
  - "HEVCDecoder.swift -- VideoToolbox HEVC hardware decode with SPS/PPS extraction"
  - "LZ4Decompressor.swift -- LZ4 decompress + XOR delta apply via bridging header"
  - "Eco mode support: HEVC at 1080p/720p 30fps via session recreation"
affects: [02-06, 02-07, 02-08, 02-09, 02-10]

# Tech tracking
tech-stack:
  added: [VideoToolbox (HEVC encode/decode)]
  patterns: [VTCompressionSession with AverageBitRate for low-latency HEVC, VTDecompressionSession with SPS/PPS extraction from Annex-B and length-prefixed NAL units, pre-allocated decompress buffers with no per-frame malloc]

key-files:
  created:
    - RemoteDesktop/macOS/Encode/HEVCEncoder.h
    - RemoteDesktop/macOS/Encode/HEVCEncoder.m
    - RemoteDesktop/iPadOS/Decode/HEVCDecoder.swift
    - RemoteDesktop/iPadOS/Decode/LZ4Decompressor.swift
  modified:
    - RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj
    - RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj

key-decisions:
  - "HEVC encoder uses kVTVideoEncoderSpecification_EnableLowLatencyRateControl -- avoids DataRateLimits conflict"
  - "HEVCDecoder extracts VPS/SPS/PPS from both Annex-B start codes and 4-byte length-prefixed formats"
  - "LZ4Decompressor updates keyframe reference after both keyframe and delta decode -- ensures correct base for next delta"

patterns-established:
  - "VTCompressionSession low-latency: EnableLowLatencyRateControl=YES + AverageBitRate + AllowFrameReordering=false + RealTime=true"
  - "Eco mode via session recreation: tear down existing VTCompressionSession, recreate at reduced dimensions"
  - "Pre-allocated decompress buffers: decompressBuffer + keyframeReference + tempDeltaBuffer, all allocated at init"
  - "MediaFrameHeader flags drive decode path: isKeyframe -> LZ4 keyframe, isDelta -> LZ4 delta + XOR apply, isHEVC -> VTDecompressionSession"

requirements-completed: [RD-COMP-06, RD-COMP-07, RD-REND-04]

# Metrics
duration: 6min
completed: 2026-03-28
---

# Phase 2 Plan 5: HEVC Encode/Decode + iPad LZ4 Decompressor Summary

**VideoToolbox HEVC encoder (macOS) with AverageBitRate low-latency mode and eco mode, HEVC decoder (iPad) with SPS/PPS extraction, LZ4 decompressor (iPad) with XOR delta apply via bridging header -- pre-allocated buffers on all decode paths**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-28T17:04:12Z
- **Completed:** 2026-03-28T17:10:32Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- macOS HEVC encoder using VTCompressionSession with AverageBitRate (NOT ConstantBitRate), low-latency rate control, no B-frames, and eco mode support via session recreation at 1080p/720p 30fps
- iPad HEVC decoder using VTDecompressionSession with format description creation from VPS/SPS/PPS parameter sets, supporting both Annex-B start code and 4-byte length-prefixed NAL unit formats
- iPad LZ4 decompressor wrapping LZ4_decompress_safe and apply_delta C functions via bridging header, with pre-allocated buffers (no per-frame malloc) for decompress, keyframe reference, and delta temp

## Task Commits

Each task was committed atomically:

1. **Task 1: HEVC encoder (macOS) + HEVC decoder (iPadOS)** - `7152e94` (feat)
2. **Task 2: iPad LZ4 decompressor with delta apply** - `9779835` (feat)

## Files Created/Modified
- `RemoteDesktop/macOS/Encode/HEVCEncoder.h` - ObjC interface: start, encode, stop, switchToEcoMode, switchToFullQuality
- `RemoteDesktop/macOS/Encode/HEVCEncoder.m` - VTCompressionSession with AverageBitRate, low-latency, output callback building MediaFrameHeader with HEVC flag
- `RemoteDesktop/iPadOS/Decode/HEVCDecoder.swift` - VTDecompressionSession with SPS/PPS extraction, synchronous decode returning CVPixelBuffer
- `RemoteDesktop/iPadOS/Decode/LZ4Decompressor.swift` - LZ4_decompress_safe + apply_delta, pre-allocated buffers, keyframe/delta dispatch
- `RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj` - Added Encode group with HEVCEncoder files and header search path
- `RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj/project.pbxproj` - Added Decode group with HEVCDecoder and LZ4Decompressor

## Decisions Made
- **Low-latency encoder spec:** Used `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` in encoder specification dictionary rather than setting it as a session property -- per VideoToolbox docs this must be in the encoder spec at session creation time.
- **Dual NAL unit format support:** HEVCDecoder parses both Annex-B (00 00 00 01 start codes) and 4-byte length-prefixed NAL units because VideoToolbox output may use either format depending on configuration.
- **Keyframe reference update on both paths:** LZ4Decompressor updates the keyframe reference buffer after both keyframe and delta decompression, ensuring the reference always reflects the latest full frame for the next delta operation.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed CMVideoDimensions comparison in HEVCDecoder**
- **Found during:** Task 1 (HEVCDecoder.swift type-check)
- **Issue:** `CMVideoDimensions` is a C struct without Swift `Equatable` conformance; `==` operator not available
- **Fix:** Compared `.width` and `.height` fields individually instead of using struct equality
- **Files modified:** RemoteDesktop/iPadOS/Decode/HEVCDecoder.swift
- **Verification:** `xcrun --sdk iphoneos swiftc -typecheck` passes cleanly
- **Committed in:** 7152e94

**2. [Rule 1 - Bug] Suppressed unused variable warning for kBitrate4K constant**
- **Found during:** Task 1 (HEVCEncoder.m compile)
- **Issue:** `kBitrate4K` preset constant was defined but not directly referenced (caller passes bitrate)
- **Fix:** Added `__attribute__((unused))` to suppress warning while retaining documentation value
- **Files modified:** RemoteDesktop/macOS/Encode/HEVCEncoder.m
- **Verification:** HEVCEncoder.o compiles without warnings
- **Committed in:** 7152e94

---

**Total deviations:** 2 auto-fixed (2 bugs -- type system mismatch and unused variable warning)
**Impact on plan:** Both fixes necessary for clean compilation. No scope creep.

## Issues Encountered
- Pre-existing build failures in USBNetworkTransport.m and WirelessTransport.m (CC_SHA256 undeclared -- missing CommonCrypto import). Out of scope -- these files are from plan 02-03 and the issue was already documented in 02-02-SUMMARY.md. Our files compile cleanly. Verified HEVCEncoder.o object file was successfully produced.
- iPadOS full xcodebuild blocked by iOS SDK not being installed. Verified compilation via `xcrun --sdk iphoneos swiftc -typecheck` for all Swift files.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- HEVCEncoder ready for integration with ScreenCapture (mode switching between LZ4 and HEVC based on transport)
- HEVCDecoder ready for integration with MetalRenderer (returns CVPixelBuffer in BGRA for texture upload)
- LZ4Decompressor ready for integration with transport receive path (decompresses frames for Metal rendering)
- Both codec paths (LZ4+delta and HEVC) now have full encode and decode implementations
- Decode group in iPadOS project established for future additions

## Self-Check: PASSED

All 4 created files verified present. Both task commits verified in git log (7152e94, 9779835).

---
*Phase: 02-foundation*
*Completed: 2026-03-28*
