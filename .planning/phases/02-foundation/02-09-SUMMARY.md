---
phase: 02-foundation
plan: 09
subsystem: pipeline-wiring
tags: [session-handshake, frame-pipeline, resolution-matching, transport-failover, latency-probe, fps-counter, cgdisplaysetdisplaymode, lz4, hevc, eco-mode]

# Dependency graph
requires:
  - phase: 02-07
    provides: "SessionManager (Mac) with session lifecycle, transport FSM, encode mode switching"
  - phase: 02-08
    provides: "SessionManager (iPad) with transport monitoring, frame receive pipeline, HUD, ContentView"
provides:
  - "End-to-end wired pipeline: Mac capture -> compress -> header -> send; iPad receive -> parse -> decompress -> render"
  - "Session handshake exchanges display geometry before first frame"
  - "Resolution matching: iPad sends 0x21 with dimensions, Mac changes display via CGDisplaySetDisplayMode, sends 0x23 geometry update, reverts on disconnect"
  - "Transport failover switches encode mode throughout pipeline (LZ4 <-> HEVC)"
  - "Latency probe: iPad sends 0xFF every 1s, Mac echoes, iPad computes RTT/2"
  - "Rolling window FPS counter (60-frame window)"
  - "Eco mode: iPad requests via TCP, Mac reconfigures HEVC at 1080p/30fps"
affects: [02-10, 03-01, 03-02]

# Tech tracking
tech-stack:
  added: [CGDisplaySetDisplayMode, CGDisplayCopyAllDisplayModes, CGDisplayCopyDisplayMode]
  patterns: [Resolution match via InputEventHeader 0x21/0x22/0x23 message types, Latency probe echo pattern, Rolling FPS window, Send helper methods for transport-agnostic frame/input delivery]

key-files:
  modified:
    - RemoteDesktop/Shared/protocol.h
    - RemoteDesktop/macOS/App/SessionManager.h
    - RemoteDesktop/macOS/App/SessionManager.m
    - RemoteDesktop/iPadOS/Transport/Protocol.swift
    - RemoteDesktop/iPadOS/App/SessionManager.swift

key-decisions:
  - "Resolution match uses dedicated message types (0x21/0x22/0x23) instead of mode change subtypes -- cleaner protocol separation"
  - "CGDisplaySetDisplayMode for resolution matching with mode revert on disconnect -- preserves user's original resolution"
  - "Rolling 60-frame window for FPS instead of simple per-second count -- smoother and more accurate"
  - "Latency probe sent from iPad (not Mac) so iPad controls measurement timing -- Mac just echoes"
  - "Session handshake parsed from TCP input channel (not media UDP) -- guaranteed delivery"

patterns-established:
  - "Transport-agnostic send helpers: sendMediaFrameToiPad/sendInputEventToiPad check USB first, then wireless"
  - "Resolution match protocol: 0x21 request -> 0x22 response + 0x23 geometry update"
  - "Geometry update triggers decompressor reinit + viewport recalc on iPad"
  - "Eco mode request flows: iPad HUD -> TCP 0x20 subtype 0x02 -> Mac HEVC reconfigure"

requirements-completed: [RD-PERF-04, RD-AGENT-07]

# Metrics
duration: 6min
completed: 2026-03-28
---

# Phase 2 Plan 9: End-to-End Pipeline Wiring Summary

**Full pipeline wired: Mac capture->compress->send and iPad receive->decompress->render, with session handshake, resolution matching via CGDisplaySetDisplayMode, transport failover encode switching, latency probes, and eco mode**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-28T17:28:53Z
- **Completed:** 2026-03-28T17:34:51Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Full end-to-end pipeline wired on both Mac and iPad: capture -> LZ4/HEVC compress -> MediaFrameHeader + payload -> UDP -> parse -> decompress -> Metal render
- Resolution matching end-to-end: iPad sends 0x21 with native dimensions, Mac finds best display mode via CGDisplayCopyAllDisplayModes, applies via CGDisplaySetDisplayMode, sends 0x23 geometry update, iPad reinitializes decompressor and viewport; Mac reverts resolution on disconnect
- Session handshake sent over TCP after connection with display geometry, capabilities, and agent version; iPad configures viewport and decompressor from handshake before first frame
- Transport failover reconfigures encode mode throughout pipeline: LZ4 for USB NCM, HEVC for wireless, with transport change notification to iPad
- Latency probe: iPad sends 0xFF every 1s, Mac echoes immediately, iPad computes one-way estimate (RTT/2)
- Rolling 60-frame FPS counter replaces simple per-second count
- Eco mode handler: iPad toggle -> Mac reconfigures HEVC at 1080p/30fps/8Mbps

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire Mac pipeline (capture -> compress -> transport) with session handshake + resolution matching** - `0546ef9` (feat)
2. **Task 2: Wire iPad pipeline (receive -> parse -> decompress -> render) with handshake + resolution match request** - `70a3d67` (feat)

## Files Created/Modified
- `RemoteDesktop/Shared/protocol.h` - Added resolution match (0x21/0x22/0x23) message types, ResolutionMatchPayload, ResolutionMatchResponse, GeometryUpdatePayload structs
- `RemoteDesktop/macOS/App/SessionManager.h` - Added handleReceivedInputEvent method declaration
- `RemoteDesktop/macOS/App/SessionManager.m` - Full Mac pipeline wiring: resolution match handler with CGDisplaySetDisplayMode, eco mode handler, transport change notifications, latency probe echo, display mode revert, transport-agnostic send helpers
- `RemoteDesktop/iPadOS/Transport/Protocol.swift` - Added resMatchRequest/resMatchResponse/geometryUpdate input event types, ResolutionMatchPayload, ResolutionMatchResponse, GeometryUpdatePayload Swift structs
- `RemoteDesktop/iPadOS/App/SessionManager.swift` - Full iPad pipeline wiring: resolution match request with native dimensions, geometry update handler (decompressor reinit + viewport recalc), latency probe sender, rolling FPS counter, handshake parsed from TCP, mode change handler

## Decisions Made
- **Dedicated resolution match message types (0x21/0x22/0x23):** Used separate InputEventHeader types instead of piggybacking on mode change (0x20) with subtypes. Cleaner protocol separation and easier to extend.
- **Mac reverts display mode on disconnect:** Stored original CGDisplayModeRef before applying resolution match, reverts via CGDisplaySetDisplayMode on session stop or reconnection. User's display preferences are preserved.
- **Rolling 60-frame FPS window:** Replaced the simple "count frames per second" approach with a rolling window of timestamps. Produces smoother, more accurate FPS readings.
- **Latency probe from iPad side:** iPad initiates probes every 1s, Mac echoes immediately. iPad computes RTT/2 for one-way estimate. This puts timing control on the consumer side.
- **Session handshake via TCP input channel:** Handshake is parsed from the TCP connection (not UDP media), ensuring guaranteed delivery of display geometry before any frames arrive.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Full end-to-end pipeline wired and ready for integration testing (Plan 10)
- Resolution matching available from iPad HUD "Match iPad Resolution" button
- Transport failover switches encode mode throughout both Mac and iPad pipelines
- Latency and FPS metrics flowing to HUD for real-time monitoring
- Eco mode toggle functional end-to-end
- Ready for Phase 3 input injection (touch-to-mouse, keyboard) -- input events flow over the same TCP channel

## Self-Check: PASSED

All 5 modified files verified present. Both task commits verified in git log (0546ef9, 70a3d67).

---
*Phase: 02-foundation*
*Completed: 2026-03-28*
