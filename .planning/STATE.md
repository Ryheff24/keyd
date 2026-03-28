---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: Remote Desktop
status: executing
stopped_at: Completed 02-01-PLAN.md
last_updated: "2026-03-28T16:48:07.064Z"
last_activity: 2026-03-28 — Completed plan 02-01 (project scaffold)
progress:
  total_phases: 6
  completed_phases: 2
  total_plans: 21
  completed_plans: 12
  percent: 57
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-27)

**Core value:** The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input, hardware-accelerated, with near-zero Mac CPU cost.
**Current focus:** v2.0 Phase 2 — Foundation (executing)

## Current Position

Phase: 2 of 5 (Foundation — wired display pipeline)
Plan: 1 of 10 in current phase
Status: Executing
Last activity: 2026-03-28 — Completed plan 02-01 (project scaffold)

Progress: [██████░░░░] 57%

## Performance Metrics

**Velocity:**
- Total plans completed: 1 (v2.0)
- Average duration: 8min
- Total execution time: 8min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 02-01 | 8min | 3 tasks | 16 files |

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- v2.0 init: USB NCM (not usbmuxd) as primary transport — native UDP at full link speed
- v2.0 init: LZ4+delta for wired, HEVC for wireless and eco — proven Mac CPU budget
- v2.0 init: C+Obj-C on macOS only — no Swift runtime (~15-30 MB saved)
- v2.0 init: Binary protocol (24-byte media header, 9-byte input header) — no JSON in data path
- Research: USB NCM binding MUST use NWPathMonitor NWInterface object — never hardcode interface name
- Research: Delta XOR needs double-buffer + pthread_rwlock_t from day one — silent corruption otherwise
- Research: HEVC must use AverageBitRate (not ConstantBitRate) with low-latency mode
- Research: CoreAudio Tap (macOS 14.2+) for audio — NOT SCKit audio (broken on macOS 15)
- Research: Bonjour service name is _keydrd._tcp (distinct from keyd's _keyd._tcp)
- [Phase 02]: MediaFrameHeader uses u16 seq + u8 chunk_idx/chunk_total + reserved byte to fit 24-byte constraint
- [Phase 02]: Removed persistent-content-capture entitlement (unavailable on personal dev team) -- fallback via frame watchdog + re-auth

### Pending Todos

None yet.

### Blockers/Concerns

- Research gap: USB NCM iPad↔Mac direct-cable loopback — confirmed viable via forums but no canonical Apple sample code. Write UDP loopback test as first Phase 2 task before pipeline work.
- Research gap: com.apple.developer.screencapture.persist entitlement for self-signed personal-use apps — approval unknown. Design frame watchdog + menu bar re-auth fallback regardless.
- Research gap (Phase 5): CoreAudio Tap API poorly documented — study insidegui/AudioCap before planning Phase 5.

## Session Continuity

Last session: 2026-03-28T16:48:07.061Z
Stopped at: Completed 02-01-PLAN.md
Resume file: None
