---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: unknown
last_updated: "2026-03-01T21:15:13.465Z"
progress:
  total_phases: 2
  completed_phases: 1
  total_plans: 11
  completed_plans: 10
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.
**Current focus:** Phase 1 — Transport and Core Keyboard

## Current Position

Phase: 01.1 (Connected Integration Test Suite)
Plan: 4 of 4 in current phase (01.1-01, 01.1-02, 01.1-03, 01.1-04 complete)
Status: Phase 01.1 complete
Last activity: 2026-03-01 - Completed quick task 6: Fix bundle identifiers to always include .ryheff in all targets and plans

Progress: [██████████] 100% (Phase 01 complete) | Phase 01.1: [██████████] plans 1-4 done (COMPLETE)

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
| Phase 01.1 P02 | 9 | 3 tasks | 4 files |
| Phase 01.1 P03 | 9 | 2 tasks | 10 files |
| Phase 01.1 P04 | 2 | 2 tasks | 2 files |

## Accumulated Context

### Roadmap Evolution

- Phase 01.1 inserted after Phase 1: Connected Integration Test Suite (URGENT)

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
- [01.1-01]: Equatable added to KeydMessage and all payload structs — required for XCTAssertEqual on decoded messages; synthesis is free since all fields are already Equatable
- [01.1-01]: Test harness codec tests appended to TransportStateMachineTests.swift as KeydMessageCodecTests class — keeps file count low per plan instruction
- [01.1-01]: MessageEncoder.encode() throws — plan template omitted try, corrected inline (auto-fix Rule 1)
- [Phase 01.1-02]: TestMode? nil = production, non-nil = test: clean opt-in pattern, zero production overhead
- [Phase 01.1-02]: testReset allowed through not-paired guard so harness can reset before pairing completes
- [Phase 01.1-02]: Wire log format [TEST-MODE] [MSG|HB] {ts} SEND|RECV: {message} parseable by test harness stdout
- [Phase 01.1]: TransportManagerRegistry singleton used (no AppDelegate exists — app uses @main struct KeydApp: App)
- [Phase 01.1]: NotificationCenter-based message observer in TransportManager+Testing.swift: hooks into handleIncomingMessage via notifyTestObservers() — zero production-path impact
- [Phase 01.1]: IntegrationTestCase.swift NOT shared as source into XCTest target — types accessed via @testable import KeydApp to avoid duplicate symbol errors
- [Phase 01.1]: SuiteCHarness separate from IntegrationHarness: IntegrationHarness imports XCTest (cannot be imported in main app); SuiteCHarness conforms to IntegrationHarnessProtocol without XCTest
- [01.1-04]: test-integration mode uses $mac_binary --test-mode (not open -n $bundle) — open cannot pass CommandLine.arguments to the process
- [01.1-04]: deploy: test-integration prerequisite blocks make deploy on integration test failure

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
| 6 | fix bundle identifiers to always include .ryheff | 2026-03-01 | d0b4de5 | [6-fix-bundle-identifiers-to-always-include](./quick/6-fix-bundle-identifiers-to-always-include/) |

## Session Continuity

Last session: 2026-03-01T21:19:00Z
Stopped at: Completed 01.1-04-PLAN.md (CLI entry point: make test-integration + deploy gate; Phase 01.1 COMPLETE)

### What's already built (do not rebuild)
- `SharedProtocol/` SPM package — Messages (with testReset/testResetAck + Equatable), MessageEncoder, MessageDecoder, TransportStateMachine (FSM) — builds + 76 tests pass (plans 01-01, 01-07, 01.1-01)
- `macOS/KeydAgent/` Xcode project — Transport, Injection, MenuBar, App layers — builds clean with --test-mode support (plans 01-02, 01.1-02)
- `macOS/KeydAgent/App/KeydAgentApp.swift` — TestMode struct, --test-mode detection, SMAppService skip, permissions bypass in test mode (01.1-02)
- `macOS/KeydAgent/Pairing/PairingManager.swift` — init(testMode:), in-memory pairing path, resetInMemory() (01.1-02)
- `macOS/KeydAgent/Transport/TransportManager.swift` — wireLog(), nextConnectionLabel(), testReset handler, timeout parameterization (01.1-02)
- `KeydApp/` iOS Xcode project — USBTransport, AWDLTransport, TransportManager, KeyboardView, HotkeyPanel, ConnectionStatusBadge — builds clean (plan 01-03)
- `KeydApp/KeydApp/Pairing/` — Curve25519 ECDH pairing with Keychain storage (plan 01-04)
- `KeydApp/KeydApp/LiveActivity/` — ActivityKit attributes + manager (plan 01-04)
- `KeydApp/KeydLiveActivity/` — Widget Extension for Dynamic Island rendering (plan 01-04)
- `macOS/KeydAgent/Pairing/` + `macOS/KeydAgent/UI/` — macOS pairing + QR display (plan 01-04)
- `SharedProtocol/Tests/SharedProtocolTests/` — 73-test FSM suite (S01-S24 scenarios, INV-001-016 invariants, stress tests, event log tests) (plan 01-07)
- `KeydApp/KeydAppTests/` — 23-test iOS lifecycle XCTest suite (plan 01-07)
- `KeydApp/KeydApp/Debug/TransportTestRunner*` — On-device test runner UI with JSON trace export (plan 01-07)
- `KeydApp/KeydIntegrationTests/` — XCTest target: IntegrationHarness + PairingIntegrationTests + RegressionTests (6 test methods) (plan 01.1-03)
- `KeydApp/KeydApp/Debug/IntegrationTestCase.swift` — Shared test case implementations + IntegrationHarnessProtocol (plan 01.1-03)
- `KeydApp/KeydApp/Debug/TransportManager+Testing.swift` — NotificationCenter observer hook, injectTestPairingToken (plan 01.1-03)
- `KeydApp/KeydApp/Debug/TransportManagerRegistry.swift` — Singleton for test harness to locate TransportManager (plan 01.1-03)
- Suite C: Connected section in TransportTestRunnerView with SuiteCHarness and IntegrationSuiteCRunner (plan 01.1-03)
- `scripts/deploy-and-run.sh` test-integration mode: kill agent, build KeydIntegrationTests, start $mac_binary --test-mode, xcodebuild test, teardown (plan 01.1-04)
- `Makefile` make test-integration target + deploy: test-integration prerequisite (plan 01.1-04)

### What's NOT done yet
- Phase 2: Text sync and real-time cursor tracking
- Physical device validation: AWDL entitlements on self-signed provisioning, usbmuxd iOS 18 TCP forwarding
