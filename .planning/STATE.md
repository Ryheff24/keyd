---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: unknown
last_updated: "2026-02-28T14:29:29.383Z"
progress:
  total_phases: 1
  completed_phases: 0
  total_plans: 5
  completed_plans: 3
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.
**Current focus:** Phase 1 — Transport and Core Keyboard

## Current Position

Phase: 1 of 3 (Transport and Core Keyboard)
Plan: 3 of 5 in current phase
Status: In progress
Last activity: 2026-02-28 — Completed plan 01-03 (iOS app: KeydApp)

Progress: [██████░░░░] 40% (2 of 5 phase plans with SUMMARY; plan 01-02 is complete but SUMMARY not yet created by this session)

## Performance Metrics

**Velocity:**
- Total plans completed: 3
- Average duration: ~5 min/plan
- Total execution time: ~15 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-transport-and-core-keyboard | 3/5 | ~15 min | ~5 min |

**Recent Trend:**
- Last 3 plans: 01-01 (SharedProtocol), 01-02 (macOS agent), 01-03 (iOS app)
- Trend: Steady, fast execution

*Updated after each plan completion*
| Phase 01 P02 | 3 | 4 tasks | 13 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Pre-Phase 1]: USB primary, AWDL fallback — lowest latency on USB; AWDL preserves connection on unplug
- [Pre-Phase 1]: AX read + CGEvent write — AX value writes silently fail in Safari/Firefox; CGEvent is the only reliable write path
- [Pre-Phase 1]: Foreground UIViewController (not UIInputViewController) — extensions cannot initiate network connections
- [Pre-Phase 1]: Binary framing (4-byte length prefix) over JSON — required for sub-50ms latency
- [Pre-Phase 1]: No App Sandbox on macOS helper — sandbox blocks CGEventPost and AX operations
- [01-03]: xcodegen project.yml used for reproducible iOS Xcode project generation with local SPM packages
- [01-03]: CheckedContinuation<Void, Error> explicit type annotation required in send() for NWConnection completion handlers
- [01-03]: HotkeyPanel Liquid Glass applied to panel container, not individual key buttons
- [Phase 01]: App Sandbox disabled in entitlements (required for CGEventPost and AX operations)
- [Phase 01]: kAXTrustedCheckOptionPrompt used as string literal to avoid Swift 6 shared mutable state warning
- [Phase 01]: AWDL standby connection kept live while USB is active for sub-second handoff on USB disconnect

### Pending Todos

None.

### Blockers/Concerns

- [Phase 1]: AWDL entitlement requirements for self-signed personal-use provisioning are LOW confidence — must test NWBrowser + NWListener on a physical device with infrastructure Wi-Fi and Bluetooth disabled before writing any AWDL-dependent code
- [Phase 1]: usbmuxd iOS 18 TCP forwarding behavior needs physical-device validation before building the full transport layer
- [Phase 2]: AXObserver cross-process PID behavior for Safari and Firefox web content processes — verify before implementing real-time reflection

## Session Continuity

Last session: 2026-02-28T14:29:00Z
Stopped at: Completed 01-02-PLAN.md (macOS KeydAgent: CGEvent injection pipeline, USB/AWDL transport, permission gating, menu bar)

### What's already built (do not rebuild)
- `SharedProtocol/` SPM package — Messages, MessageEncoder, MessageDecoder — builds + tests pass (plan 01-01)
- `macOS/KeydAgent/` Xcode project — Transport, Injection, MenuBar, App layers — builds clean (plan 01-02)
- `KeydApp/` iOS Xcode project — USBTransport, AWDLTransport, TransportManager, KeyboardView, HotkeyPanel, ConnectionStatusBadge — builds clean (plan 01-03)

### What's NOT done yet
- Plan 01-04: Pairing + Dynamic Island Live Activity (Widget Extension via xcodegen)
- Plan 01-05: Transport hardening + debug overlay (`autonomous: false` — requires human verify checkpoint)
