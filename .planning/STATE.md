---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: unknown
last_updated: "2026-03-01T18:06:34.138Z"
progress:
  total_phases: 3
  completed_phases: 1
  total_plans: 7
  completed_plans: 7
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.
**Current focus:** Phase 1 — Transport and Core Keyboard

## Current Position

Phase: 1 of 3 (Transport and Core Keyboard)
Plan: 7 of 7 in current phase
Status: Phase complete
Last activity: 2026-03-01 - Completed 01-07 Transport FSM Test Suite

Progress: [██████████] 100% (7 of 7 phase plans with SUMMARY)

## Performance Metrics

**Velocity:**
- Total plans completed: 4
- Average duration: ~5 min/plan
- Total execution time: ~20 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-transport-and-core-keyboard | 7/7 | ~58 min | ~8 min |

**Recent Trend:**
- Last 4 plans: 01-04 (pairing + Dynamic Island), 01-05 (transport hardening), 01-06 (FSM formalization), 01-07 (FSM test suite)
- Trend: Steady, fast execution

*Updated after each plan completion*
| Phase 01 P02 | 3 | 4 tasks | 13 files |
| Phase 01 P04 | 270 | 4 tasks | 14 files |
| Phase 01-transport-and-core-keyboard P07 | 19 | 3 tasks | 14 files |

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
- [01-06]: Event-outer switch pattern in transition functions avoids Swift 6 tuple exhaustiveness limitations
- [01-06]: Connection resources (NWConnection/decoder/encoder) held in TransportManager alongside FSM state, NOT inside FSM enum cases
- [01-06]: iOS suppressAWDLStatusUntilPaired kept as policy flag (not FSM state) — it's a UI gate, not transport lifecycle
- [01-06]: AWDLConnectionState enum replaces isConnecting/isReady/autoConnectEnabled booleans in AWDLTransport
- [Phase 01-07]: FSMs relocated to SharedProtocol for cross-platform testability (SPM swift test, iOS XCTest, on-device runner)
- [Phase 01-07]: Equatable added to FSM event/sideeffect enums for XCTest assertions; INV-001 scoped to TransportManager level (not FSM level)

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
| 3 | Hold Backspace for 0.5s -> entire word deleted in TextEdit (word-delete) doesnt work | 2026-02-28 | 261eebf | [3-hold-backspace-for-0-5s-entire-word-dele](./quick/3-hold-backspace-for-0-5s-entire-word-dele/) |
| 4 | disable shake to undo typing. | 2026-03-01 | 3492fd6 | [4-disable-shake-to-undo-typing](./quick/4-disable-shake-to-undo-typing/) |
| 5 | disable predictive text when using slide to type | 2026-03-01 | de52b41 | [5-disable-predictive-text-when-using-slide](./quick/5-disable-predictive-text-when-using-slide/) |

## Session Continuity

Last session: 2026-03-01T18:06:34Z
Stopped at: Completed 01-07-PLAN.md (Transport FSM test suite — XCTest suite covering all 24 AWDL_USB_SCENARIO_MATRIX scenarios and on-device test runner UI)

### What's already built (do not rebuild)
- `SharedProtocol/` SPM package — Messages, MessageEncoder, MessageDecoder, TransportStateMachine (FSM) — builds + tests pass (plans 01-01, 01-07)
- `macOS/KeydAgent/` Xcode project — Transport, Injection, MenuBar, App layers — builds clean (plan 01-02)
- `KeydApp/` iOS Xcode project — USBTransport, AWDLTransport, TransportManager, KeyboardView, HotkeyPanel, ConnectionStatusBadge — builds clean (plan 01-03)
- `KeydApp/KeydApp/Pairing/` — Curve25519 ECDH pairing with Keychain storage (plan 01-04)
- `KeydApp/KeydApp/LiveActivity/` — ActivityKit attributes + manager (plan 01-04)
- `KeydApp/KeydLiveActivity/` — Widget Extension for Dynamic Island rendering (plan 01-04)
- `macOS/KeydAgent/Pairing/` + `macOS/KeydAgent/UI/` — macOS pairing + QR display (plan 01-04)
- `SharedProtocol/Tests/SharedProtocolTests/` — 73-test FSM suite (S01-S24 scenarios, INV-001-016 invariants, stress tests, event log tests) (plan 01-07)
- `KeydApp/KeydAppTests/` — 23-test iOS lifecycle XCTest suite (plan 01-07)
- `KeydApp/KeydApp/Debug/TransportTestRunner*` — On-device test runner UI with JSON trace export (plan 01-07)

### What's NOT done yet
- Phase 2: Text sync and real-time cursor tracking
- Physical device validation: AWDL entitlements on self-signed provisioning, usbmuxd iOS 18 TCP forwarding
