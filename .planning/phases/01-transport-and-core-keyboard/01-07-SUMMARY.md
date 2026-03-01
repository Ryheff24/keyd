---
phase: 01-transport-and-core-keyboard
plan: 07
subsystem: testing
tags: [xctest, swift, fsm, tdd, transport, awdl, usb, swiftui, shared-protocol]

requires:
  - phase: 01-transport-and-core-keyboard
    plan: 06
    provides: "Pure FSM transition functions agentTransportTransition/iOSTransportTransition in platform targets"

provides:
  - "SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift with public FSM types and both transition functions"
  - "XCTest suite: 24 scenario tests (S01-S24), 16 invariant helpers (INV-001-016), stress tests S20-S24"
  - "iOS XCTest: 23 lifecycle tests covering background, heartbeat, idle timer, USB/AWDL transitions"
  - "KeydAppTests Xcode test target wired to KeydApp scheme"
  - "KeydAgentTests Xcode test target wired to KeydAgent scheme"
  - "On-device test runner UI (TransportTestRunnerView) accessible from debug sheet"
  - "Event trace JSON export from debug sheet and per-scenario in test runner"

affects:
  - "Phase 2 and beyond — all future transport changes must maintain test coverage"
  - "CI: SharedProtocol swift test is now the regression gate for transport FSM changes"

tech-stack:
  added:
    - "XCTest (via xcodegen test targets and swift test)"
    - "SeededRNG (xorshift64) for deterministic stress test replay"
  patterns:
    - "FSMs in SharedProtocol for cross-platform testability"
    - "Pure transition function pattern: (State, Event) -> (State, [SideEffect])"
    - "Invariant assertion helpers as reusable free functions in test target"
    - "On-device test runner as ObservableObject with @Published results"

key-files:
  created:
    - SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift
    - SharedProtocol/Tests/SharedProtocolTests/TransportStateMachineTests.swift
    - SharedProtocol/Tests/SharedProtocolTests/TransportEventLogTests.swift
    - KeydApp/KeydAppTests/TransportStateMachineTests.swift
    - KeydApp/KeydApp/Debug/TransportTestScenario.swift
    - KeydApp/KeydApp/Debug/TransportTestRunner.swift
    - KeydApp/KeydApp/Debug/TransportTestRunnerView.swift
  modified:
    - macOS/KeydAgent/Transport/TransportStateMachine.swift (thin import re-export)
    - KeydApp/KeydApp/Transport/TransportStateMachine.swift (thin import re-export)
    - macOS/KeydAgent/Transport/TransportManager.swift (removed ConnectionKind definition)
    - KeydApp/KeydApp/Debug/DebugOverlayView.swift (added Transport Tests link + Export Trace)
    - KeydApp/project.yml (added KeydAppTests target with GENERATE_INFOPLIST_FILE=YES)
    - macOS/project.yml (added KeydAgentTests target)

key-decisions:
  - "FSMs relocated to SharedProtocol so all test targets (SPM swift test, iOS XCTest, on-device runner) can access pure transition functions without cross-platform import issues"
  - "ConnectionKind defined public in SharedProtocol; iOSConnectionKind added as typealias to avoid breaking iOS code"
  - "Equatable conformance added to all FSM event/sideeffect enums to enable XCTAssertEqual and contains() assertions"
  - "INV-001 (pairing enforcement) scoped to TransportManager level in tests — FSM accepts any identity, pairing check is pre-FSM in TransportManager.handleEvent"
  - "GENERATE_INFOPLIST_FILE=YES required in KeydAppTests target for simulator code signing to produce the test bundle executable"
  - "Stress tests S20/S24 validate INV-002 (structural correctness) only, not INV-001, because the FSM layer has no concept of paired vs unpaired"

requirements-completed: [TRANS-03, TRANS-04, TRANS-07]

duration: 18min
completed: 2026-03-01
---

# Phase 1 Plan 7: Transport FSM Test Suite Summary

**XCTest suite covering all 24 AWDL_USB_SCENARIO_MATRIX scenarios and 16 invariants via SharedProtocol, plus on-device test runner UI with event trace JSON export accessible from the debug sheet**

## Performance

- **Duration:** 18 min
- **Started:** 2026-03-01T17:47:09Z
- **Completed:** 2026-03-01T18:05:10Z
- **Tasks:** 3 (1 setup, 1 TDD, 1 UI)
- **Files modified:** 14

## Accomplishments

- Relocated both FSM transition functions to SharedProtocol as public API, making them accessible from SPM `swift test`, iOS XCTest, macOS XCTest, and the on-device runner — all without platform-specific imports
- Created 73-test SharedProtocol suite: 24 scenario tests (S01-S24), 16 invariant helpers (INV-001 through INV-016), stress tests with 200-500 seeded random events, and TransportEventLog unit tests with circular buffer and JSON round-trip coverage
- Created 23-test iOS XCTest suite covering background/foreground lifecycle, heartbeat management, idle timer, USB/AWDL fallback, and full lifecycle integration scenarios
- Built on-device test runner (TransportTestRunner + TransportTestRunnerView) displaying pass/fail for all 24 scenarios with expandable event trace and per-scenario JSON export

## Task Commits

1. **Task 1: Add test targets and relocate FSMs to SharedProtocol** - `d5b0e1d` (feat)
2. **Task 2: XCTest suite — invariant helpers and scenario matrix tests** - `1d2a78b` (test)
3. **Task 3: On-device test runner UI and event trace export** - `2bf06b2` (feat)

## Files Created/Modified

- `SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift` — Public FSM types, ConnectionKind, iOSConnectionKind typealias, both transition functions
- `SharedProtocol/Tests/SharedProtocolTests/TransportStateMachineTests.swift` — 24 scenario tests, 16 invariant helpers, stress tests, SeededRNG
- `SharedProtocol/Tests/SharedProtocolTests/TransportEventLogTests.swift` — Circular buffer, export order, JSON round-trip, clear tests
- `KeydApp/KeydAppTests/TransportStateMachineTests.swift` — 23 iOS lifecycle tests via SharedProtocol
- `KeydApp/KeydApp/Debug/TransportTestScenario.swift` — All 24 scenarios as Swift data, stress scenario factory
- `KeydApp/KeydApp/Debug/TransportTestRunner.swift` — @MainActor engine calling agentTransportTransition() and checking invariants
- `KeydApp/KeydApp/Debug/TransportTestRunnerView.swift` — SwiftUI pass/fail list, ScenarioDetailView, ShareSheet export
- `macOS/KeydAgent/Transport/TransportStateMachine.swift` — Thin stub importing SharedProtocol
- `KeydApp/KeydApp/Transport/TransportStateMachine.swift` — Thin stub importing SharedProtocol
- `macOS/KeydAgent/Transport/TransportManager.swift` — Removed redundant ConnectionKind definition
- `KeydApp/KeydApp/Debug/DebugOverlayView.swift` — Transport FSM Tests NavigationLink + Export Live Trace button
- `KeydApp/project.yml` — KeydAppTests target with GENERATE_INFOPLIST_FILE=YES
- `macOS/project.yml` — KeydAgentTests target

## Decisions Made

- **FSM relocation to SharedProtocol:** Needed so pure functions are accessible from all test contexts. Both platform targets now use thin `import SharedProtocol` stubs.
- **Equatable conformance on FSM types:** Required for XCTAssertEqual comparisons and `contains()` on side-effect arrays. Added to AgentTransportEvent, AgentTransportSideEffect, iOSTransportEvent, iOSTransportSideEffect.
- **INV-001 scope:** INV-001 (unpaired device never gets confirmed session) is enforced at TransportManager level before FSM events are dispatched. Stress tests only validate INV-002 (structural correctness) at the FSM level.
- **GENERATE_INFOPLIST_FILE=YES:** Without this, the iOS test bundle has no code signature target and the binary isn't placed correctly — tests fail with "executable couldn't be located."

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added Equatable conformance to all FSM enum types**
- **Found during:** Task 2 (XCTest suite)
- **Issue:** XCTAssertEqual on side-effect arrays and `.contains(.startHeartbeat)` require Equatable conformance. The plan didn't specify it but it's required for the tests to compile.
- **Fix:** Added `: Equatable` to AgentTransportSideEffect, iOSTransportSideEffect, AgentTransportEvent, iOSTransportEvent in TransportStateMachine.swift
- **Files modified:** SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift
- **Committed in:** 1d2a78b (Task 2 commit)

**2. [Rule 3 - Blocking] Fixed GENERATE_INFOPLIST_FILE missing in KeydAppTests target**
- **Found during:** Task 2 verification (iOS test run)
- **Issue:** `xcodebuild test` failed with "Cannot code sign because the target does not have an Info.plist file"
- **Fix:** Added `GENERATE_INFOPLIST_FILE: YES` to KeydAppTests settings in KeydApp/project.yml; regenerated project
- **Files modified:** KeydApp/project.yml, KeydApp/KeydApp.xcodeproj
- **Committed in:** 1d2a78b (Task 2 commit)

**3. [Rule 1 - Bug] Fixed InvariantID namespace in TransportTestScenario.swift**
- **Found during:** Task 3 build verification
- **Issue:** `InvariantID.allCases` in the `allScenarios` array literal was unresolved at file scope
- **Fix:** Changed to `TransportTestScenario.InvariantID.allCases` with full qualified name
- **Files modified:** KeydApp/KeydApp/Debug/TransportTestScenario.swift
- **Committed in:** 2bf06b2 (Task 3 commit)

---

**Total deviations:** 3 auto-fixed (1 missing critical, 1 blocking, 1 bug)
**Impact on plan:** All necessary for compilation and test execution. No scope changes.

## Issues Encountered

- INV-001 stress test violation: the FSM correctly accepts any `usbIdentityConfirmed(deviceID: "U")` event because pairing is enforced at the TransportManager level, not inside the pure transition function. Resolved by scoping S20/S24 invariant checks to INV-002 only (structural FSM correctness), matching the actual layered architecture.
- JSON decode failure in TransportEventLogTests: `exportJSON()` uses `.iso8601` date encoding strategy but the test used the default decoder. Fixed by using matching iso8601 decoder in test.

## Next Phase Readiness

- Phase 1 complete: all 7 plans executed (SharedProtocol, macOS agent, iOS app, pairing/Dynamic Island, transport hardening, FSM formalization, regression test suite)
- The FSM regression test suite provides the automatic validation gate for all future transport changes
- Any new transport bug should be encoded as an S25+ scenario before fixing the code
- Physical device validation still needed (AWDL entitlements, usbmuxd iOS 18 behavior) before transport goes to production

---
*Phase: 01-transport-and-core-keyboard*
*Completed: 2026-03-01*
