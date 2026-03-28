---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: Remote Desktop
status: executing
stopped_at: Completed 02-04-PLAN.md
last_updated: "2026-03-28T17:18:16.716Z"
last_activity: 2026-03-28 — Completed plan 02-06 (Metal renderer)
progress:
  total_phases: 6
  completed_phases: 2
  total_plans: 21
  completed_plans: 17
  percent: 81
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-27)

**Core value:** The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input, hardware-accelerated, with near-zero Mac CPU cost.
**Current focus:** v2.0 Phase 2 — Foundation (executing)

## Current Position

Phase: 2 of 5 (Foundation — wired display pipeline)
Plan: 6 of 10 in current phase
Status: Executing
Last activity: 2026-03-28 — Completed plan 02-06 (Metal renderer)

Progress: [████████░░] 81%

## Performance Metrics

**Velocity:**
- Total plans completed: 6 (v2.0)
- Average duration: 6min
- Total execution time: 36min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 02-01 | 8min | 3 tasks | 16 files |
| 02-02 | 6min | 2 tasks | 5 files |
| 02-03 | 10min | 2 tasks | 12 files |
| 02-04 | 4min | 2 tasks | 4 files |
| 02-05 | 6min | 2 tasks | 6 files |
| 02-06 | 4min | 2 tasks | 3 files |

*Updated after each plan completion*
| Phase 02-04 P04 | 12min | 2 tasks | 11 files |

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
- [Phase 02]: Used zlib crc32() for payload CRC in MediaFrameHeader -- always available on macOS, zero dependency cost
- [Phase 02]: Separate capture and compress dispatch queues to decouple SCStream delivery from LZ4 work
- [Phase 02]: Network.framework C API uses nw_parameters_require_interface (not set_required_interface) for exact interface binding
- [Phase 02]: Listener port set via nw_parameters_set_local_endpoint -- nw_listener_set_port does not exist
- [Phase 02]: ObjC blocks use explicit class type (ClassName *weakSelf) not typeof(self) in C11 mode
- [Phase 02]: No UIKit import needed in MetalRenderer -- all types come from Metal/MetalKit/QuartzCore
- [Phase 02]: HEVC encoder uses EnableLowLatencyRateControl in encoder spec dict at session creation time
- [Phase 02]: HEVCDecoder parses both Annex-B start codes and 4-byte length-prefixed NAL units for VPS/SPS/PPS
- [Phase 02]: LZ4Decompressor updates keyframe reference after both keyframe and delta decode for correct delta base
- [Phase 02-04]: P-256 (not Curve25519) for ECDH -- Security.framework SecKeyCopyKeyExchangeResult supports P-256 natively in ObjC
- [Phase 02-04]: Self-signed X.509 cert via manual ASN.1 DER encoding -- no public Apple API for cert creation
- [Phase 02-04]: HMAC-SHA256 for HKDF key derivation -- CommonCrypto available in pure C/ObjC without CryptoKit

### Pending Todos

None yet.

### Blockers/Concerns

- Research gap: USB NCM iPad↔Mac direct-cable loopback — confirmed viable via forums but no canonical Apple sample code. Write UDP loopback test as first Phase 2 task before pipeline work.
- Research gap: com.apple.developer.screencapture.persist entitlement for self-signed personal-use apps — approval unknown. Design frame watchdog + menu bar re-auth fallback regardless.
- Research gap (Phase 5): CoreAudio Tap API poorly documented — study insidegui/AudioCap before planning Phase 5.

## Session Continuity

Last session: 2026-03-28T17:18:16.713Z
Stopped at: Completed 02-04-PLAN.md
Resume file: None
