---
phase: 01-transport-and-core-keyboard
plan: 06
subsystem: transport
tags: [swift, fsm, state-machine, nwconnection, awdl, usb, transport-protocol, event-log]

# Dependency graph
requires:
  - phase: 01-transport-and-core-keyboard
    provides: "TransportManager (macOS + iOS), AWDLTransport, USBTransport, SharedProtocol messages"
provides:
  - "agentTransportTransition() — pure free function for macOS transport FSM"
  - "iOSTransportTransition() — pure free function for iOS transport FSM"
  - "AgentTransportState/Event/SideEffect enums (macOS)"
  - "iOSTransportState/Event/SideEffect enums (iOS)"
  - "AWDLConnectionState enum replacing isConnecting/isReady/autoConnectEnabled booleans"
  - "TransportEventLog circular buffer with exportJSON() for test trace replay"
  - "Background lifecycle modeled as backgroundSuspended FSM state on iOS"
affects: [01-07-test-suite, phase-2-text-sync]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure transition function pattern: free function returning (State, [SideEffect])"
    - "Side effect executor pattern: TransportManager executes returned effects, FSM stays pure"
    - "Circular buffer event log: TransportEventLog captures all transitions for trace export"
    - "AWDLConnectionState enum: explicit connection lifecycle vs boolean flags"

key-files:
  created:
    - SharedProtocol/Sources/SharedProtocol/TransportEvent.swift
    - SharedProtocol/Sources/SharedProtocol/TransportEventLog.swift
    - macOS/KeydAgent/Transport/TransportStateMachine.swift
    - KeydApp/KeydApp/Transport/TransportStateMachine.swift
  modified:
    - macOS/KeydAgent/Transport/TransportManager.swift
    - KeydApp/KeydApp/Transport/TransportManager.swift
    - KeydApp/KeydApp/Transport/AWDLTransport.swift
    - macOS/KeydAgent.xcodeproj/project.pbxproj
    - KeydApp/KeydApp.xcodeproj/project.pbxproj

key-decisions:
  - "Event-outer switch pattern (switch event { case .X: switch state { ... } }) avoids tuple exhaustiveness issues in Swift 6"
  - "Connection resources (NWConnection, decoder, encoder) kept in TransportManager, NOT in FSM state enum"
  - "suppressAWDLStatusUntilPaired kept as policy flag (not FSM state) — it gates UI only, not transport lifecycle"
  - "iOS @Published connectionState derived from fsmState via displayState() computed mapping for SwiftUI compatibility"
  - "AWDLConnectionState.isReady/isConnecting are computed properties on the enum, not stored booleans"
  - "Single-paired model: kept as-is per TRANSPORT-STATE-ANALYSIS.md recommendation"

patterns-established:
  - "Pure FSM pattern: all transport code should follow transition-function + side-effect-executor architecture"
  - "Free function testability: agentTransportTransition/iOSTransportTransition are free functions for direct XCTest access"
  - "Structured event log: TransportEventEntry with JSON export enables trace-driven regression tests (01-07)"

requirements-completed: [TRANS-03, TRANS-04, TRANS-07]

# Metrics
duration: 14min
completed: 2026-03-01
---

# Phase 1 Plan 06: FSM Formalization Summary

**Pure transport state machines on both macOS and iOS — illegal state combinations now impossible, every transition testable in isolation via free functions**

## Performance

- **Duration:** 14 min
- **Started:** 2026-03-01T17:29:03Z
- **Completed:** 2026-03-01T17:43:07Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments

- Created pure `agentTransportTransition()` and `iOSTransportTransition()` free functions — no network, no instances, direct XCTest access
- Replaced 5 connection pools + 19-case switch in macOS TransportManager with `AgentTransportState` enum and side-effect executor
- Absorbed 3 boolean flags (`awdlEnabledForCurrentSession`, `awaitingAWDLHeartbeatAck`, `suppressAWDLStatus`) into iOS FSM state
- Replaced `isConnecting/isReady/autoConnectEnabled` booleans in AWDLTransport with `AWDLConnectionState` enum
- Added `TransportEventLog` circular buffer (500 entries) with JSON export for test trace replay (feeds 01-07)
- Modeled iOS app lifecycle as `backgroundSuspended` FSM state with `beginBackgroundTask`/`endBackgroundTask` side effects
- Both macOS and iOS build clean with zero new warnings

## Task Commits

Each task was committed atomically:

1. **Task 1: Create shared event log and define FSM contracts** - `56e3ac5` (feat)
2. **Task 2: Refactor TransportManagers to use FSM transition functions** - `bd8f494` (refactor)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `SharedProtocol/Sources/SharedProtocol/TransportEvent.swift` — TransportEventEntry struct (Codable, Sendable)
- `SharedProtocol/Sources/SharedProtocol/TransportEventLog.swift` — circular buffer, export(), exportJSON()
- `macOS/KeydAgent/Transport/TransportStateMachine.swift` — AgentTransportState/Event/SideEffect enums + agentTransportTransition()
- `KeydApp/KeydApp/Transport/TransportStateMachine.swift` — iOSTransportState/Event/SideEffect enums + iOSTransportTransition()
- `macOS/KeydAgent/Transport/TransportManager.swift` — rewritten to use agentTransportTransition() via handleEvent()
- `KeydApp/KeydApp/Transport/TransportManager.swift` — rewritten to use iOSTransportTransition() via handleEvent()
- `KeydApp/KeydApp/Transport/AWDLTransport.swift` — AWDLConnectionState enum replaces 3 boolean flags
- `macOS/KeydAgent.xcodeproj/project.pbxproj` — added TransportStateMachine.swift to build phase
- `KeydApp/KeydApp.xcodeproj/project.pbxproj` — added TransportStateMachine.swift to build phase

## Decisions Made

- **Event-outer switch pattern** used in transition functions (`switch event { case .X: switch state { ... } }`) to avoid Swift 6 exhaustiveness limitations on tuple patterns
- **Connection resources in TransportManager, not FSM**: NWConnection, decoder, encoder held separately so FSM stays pure and serializable
- **suppressAWDLStatusUntilPaired** kept as a Bool policy flag rather than FSM state — it's a UI-only gate that controls whether to show AWDL status during pairing; it doesn't affect transport lifecycle decisions
- **iOS @Published connectionState**: kept for SwiftUI backwards compatibility; derived from fsmState via `displayState()` mapping, published via `objectWillChange.send()` before assignment
- **AWDLConnectionState.isReady/isConnecting** are computed properties on the enum, not independent stored booleans — provides same API surface with less state surface area

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added TransportStateMachine.swift to Xcode project build phases**
- **Found during:** Task 2 (macOS build)
- **Issue:** New `TransportStateMachine.swift` files were not referenced in `project.pbxproj` files; compiler could not find `AgentTransportState`, `iOSTransportState` types
- **Fix:** Added PBXBuildFile, PBXFileReference, group reference, and Sources build phase entries to both `.xcodeproj/project.pbxproj` files
- **Files modified:** `macOS/KeydAgent.xcodeproj/project.pbxproj`, `KeydApp/KeydApp.xcodeproj/project.pbxproj`
- **Verification:** Both builds succeed
- **Committed in:** bd8f494 (Task 2 commit)

**2. [Rule 1 - Bug] Rewrote transition function switch structure for Swift 6 exhaustiveness**
- **Found during:** Task 1 (macOS build)
- **Issue:** Swift 6 requires exhaustive switch on tuples — `switch (state, event)` with associated values produces exhaustiveness errors even with wildcard patterns
- **Fix:** Restructured to event-outer pattern (`switch event { case .X: switch state { ... } }`) which is fully exhaustive per Swift's pattern matching rules
- **Files modified:** Both TransportStateMachine.swift files
- **Committed in:** bd8f494 (Task 2 commit, FSM files restaged)

**3. [Rule 1 - Bug] Fixed AWDLTransport.AWDLConnectionState Equatable conformance**
- **Found during:** Task 2 (iOS build)
- **Issue:** `AWDLConnectionState` was not `Equatable` but used in `guard` equality comparisons
- **Fix:** Added `: Equatable` to the enum declaration
- **Files modified:** `KeydApp/KeydApp/Transport/AWDLTransport.swift`
- **Committed in:** bd8f494

---

**Total deviations:** 3 auto-fixed (1 blocking infrastructure, 2 bugs)
**Impact on plan:** All necessary for compilation. No scope creep.

## Issues Encountered

- Swift 6's exhaustiveness checker for tuple-based switch patterns is stricter than documented — patterns with associated values require exact coverage per case, not just wildcard coverage. The event-outer structure works naturally with Swift's exhaustiveness rules.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Pure transition functions are ready for direct XCTest coverage in plan 01-07
- `TransportEventLog.exportJSON()` enables trace export and replay as regression tests
- Both projects build clean — ready for 01-07 test harness
- Background lifecycle (backgroundSuspended state) wired but `handleScenePhaseBackground()`/`handleScenePhaseActive()` not yet called from KeydApp.swift — 01-07 can add that or it can be done as a quick task

## Self-Check: PASSED

- FOUND: SharedProtocol/Sources/SharedProtocol/TransportEvent.swift
- FOUND: SharedProtocol/Sources/SharedProtocol/TransportEventLog.swift
- FOUND: macOS/KeydAgent/Transport/TransportStateMachine.swift
- FOUND: KeydApp/KeydApp/Transport/TransportStateMachine.swift
- FOUND: .planning/phases/01-transport-and-core-keyboard/01-06-SUMMARY.md
- FOUND: commit 56e3ac5 (Task 1)
- FOUND: commit bd8f494 (Task 2)

---
*Phase: 01-transport-and-core-keyboard*
*Completed: 2026-03-01*
