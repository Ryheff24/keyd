---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: in_progress
last_updated: "2026-02-28T20:07:13Z"
progress:
  total_phases: 1
  completed_phases: 0
  total_plans: 5
  completed_plans: 4
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.
**Current focus:** Phase 1 — Transport and Core Keyboard

## Current Position

Phase: 1 of 3 (Transport and Core Keyboard)
Plan: 4 of 5 in current phase
Status: In progress
Last activity: 2026-02-28 - Completed quick task 2: Cmd-Shift-4 should crosshair, but it’s doing full-screen screenshots

Progress: [████████░░] 80% (4 of 5 phase plans with SUMMARY)

## Performance Metrics

**Velocity:**
- Total plans completed: 4
- Average duration: ~5 min/plan
- Total execution time: ~20 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-transport-and-core-keyboard | 4/5 | ~20 min | ~5 min |

**Recent Trend:**
- Last 4 plans: 01-01 (SharedProtocol), 01-02 (macOS agent), 01-03 (iOS app), 01-04 (pairing + Dynamic Island)
- Trend: Steady, fast execution

*Updated after each plan completion*
| Phase 01 P02 | 3 | 4 tasks | 13 files |
| Phase 01 P04 | 270 | 4 tasks | 14 files |

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
- [01-04]: Widget Extension is required architecture for Dynamic Island — main app alone cannot render in Dynamic Island
- [01-04]: KeydConnectionAttributes.swift shared between KeydApp and KeydLiveActivity targets via project.yml sources array
- [01-04]: TransportManager.State made Equatable to support didSet-based Live Activity lifecycle wiring

### Pending Todos

None.

### Blockers/Concerns

- [Phase 1]: AWDL entitlement requirements for self-signed personal-use provisioning are LOW confidence — must test NWBrowser + NWListener on a physical device with infrastructure Wi-Fi and Bluetooth disabled before writing any AWDL-dependent code
- [Phase 1]: usbmuxd iOS 18 TCP forwarding behavior needs physical-device validation before building the full transport layer
- [Phase 2]: AXObserver cross-process PID behavior for Safari and Firefox web content processes — verify before implementing real-time reflection

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 1 | swap the "select all" and "tab" shortcut positions | 2026-02-28 | c1b35cb | [1-swap-the-select-all-and-tab-shortcut-pos](./quick/1-swap-the-select-all-and-tab-shortcut-pos/) |
| 2 | Cmd-Shift-4 should crosshair, but it’s doing full-screen screenshots | 2026-02-28 | 22c3978 | [2-cmd-shift-4-should-crosshair-but-it-s-do](./quick/2-cmd-shift-4-should-crosshair-but-it-s-do/) |

## Session Continuity

Last session: 2026-02-28T15:00:00Z
Stopped at: Completed 01-04-PLAN.md (QR pairing + Dynamic Island Live Activity)

### What's already built (do not rebuild)
- `SharedProtocol/` SPM package — Messages, MessageEncoder, MessageDecoder — builds + tests pass (plan 01-01)
- `macOS/KeydAgent/` Xcode project — Transport, Injection, MenuBar, App layers — builds clean (plan 01-02)
- `KeydApp/` iOS Xcode project — USBTransport, AWDLTransport, TransportManager, KeyboardView, HotkeyPanel, ConnectionStatusBadge — builds clean (plan 01-03)
- `KeydApp/KeydApp/Pairing/` — Curve25519 ECDH pairing with Keychain storage (plan 01-04)
- `KeydApp/KeydApp/LiveActivity/` — ActivityKit attributes + manager (plan 01-04)
- `KeydApp/KeydLiveActivity/` — Widget Extension for Dynamic Island rendering (plan 01-04)
- `macOS/KeydAgent/Pairing/` + `macOS/KeydAgent/UI/` — macOS pairing + QR display (plan 01-04)

### What's NOT done yet
- Plan 01-05: Transport hardening + debug overlay (`autonomous: false` — requires human verify checkpoint)
