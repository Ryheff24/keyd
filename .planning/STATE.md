---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: Remote Desktop
status: planning
stopped_at: Phase 2 context gathered
last_updated: "2026-03-28T15:49:07.484Z"
last_activity: 2026-03-27 — v2.0 roadmap created, Phase 2 ready for plan-phase
progress:
  total_phases: 6
  completed_phases: 2
  total_plans: 11
  completed_plans: 11
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-27)

**Core value:** The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input, hardware-accelerated, with near-zero Mac CPU cost.
**Current focus:** v2.0 Phase 2 — Foundation (ready to plan)

## Current Position

Phase: 2 of 5 (Foundation — wired display pipeline)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-03-27 — v2.0 roadmap created, Phase 2 ready for plan-phase

Progress: ░░░░░░░░░░ 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0 (v2.0)
- Average duration: —
- Total execution time: —

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

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

### Pending Todos

None yet.

### Blockers/Concerns

- Research gap: USB NCM iPad↔Mac direct-cable loopback — confirmed viable via forums but no canonical Apple sample code. Write UDP loopback test as first Phase 2 task before pipeline work.
- Research gap: com.apple.developer.screencapture.persist entitlement for self-signed personal-use apps — approval unknown. Design frame watchdog + menu bar re-auth fallback regardless.
- Research gap (Phase 5): CoreAudio Tap API poorly documented — study insidegui/AudioCap before planning Phase 5.

## Session Continuity

Last session: 2026-03-28T15:49:07.482Z
Stopped at: Phase 2 context gathered
Resume file: .planning/phases/02-foundation/02-CONTEXT.md
