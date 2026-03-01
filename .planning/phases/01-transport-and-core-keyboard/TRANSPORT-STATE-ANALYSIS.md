# Transport State Machine Analysis — Context for Plans 01-06 and 01-07

**Written:** 2026-03-01
**Purpose:** Feed into GSD planners for 01-06 (state machine formalization) and 01-07 (on-device test suite)

## Why This Exists

Phase 1 transport "works" — all 01-05 checklist items pass. But manual testing keeps surfacing new bugs because the transport state is implicit and scattered. The `multi-device-awdl-session-thrash` debug session alone required 7 follow-up fixes, each peeling back a new layer of unexpected state interactions. Three bugs remain open at the bottom of `01-05-SUMMARY.md` (slow reconnect, lag spike character floods, long reconnect after backgrounding). These are structural — more manual poking won't fix them.

The fix is two-fold:
1. **01-06:** Formalize the transport state machine so illegal transitions become impossible
2. **01-07:** Build an on-device test suite so regressions are caught automatically

## Current Transport Code Analysis

### macOS TransportManager (`macOS/KeydAgent/Transport/TransportManager.swift`) — WORST

**State enum (good start, insufficient):**
```swift
enum AgentConnectionState {
    case disconnected
    case usbConnected
    case awdlPending
    case pairingAWDL(NWConnection)
    case awdlConnected(NWConnection)
}
```

**5 parallel connection pools (the real problem):**
1. `activeDecoder` / `activeEncoder` — primary active session
2. `pendingUSBDecoder` — USB connection waiting for identity verification
3. `pendingAWDLSlots: [ObjectIdentifier: PendingAWDLSlot]` — up to 4 AWDL connections awaiting identity
4. `standbyAWDLConnection` / `standbyAWDLDecoder` — pre-warmed AWDL while USB active (NOTE: connection is cancelled immediately in current code — standby is effectively dead code)
5. Listeners retain connection references until promoted

**19-case `activateConnection()` switch** — this is where bugs live. Every new connection arrival branches on (current state × transport type × paired status). Cases include:
- USB while disconnected → wait for identity
- USB while AWDL active → wait for identity + clear pending AWDL slots
- AWDL while disconnected + paired → add to pending pool
- AWDL while disconnected + unpaired → enter pairingAWDL
- AWDL while AWDL connected + paired → probe candidate
- AWDL while USB connected → enter standby (which immediately cancels)
- ...and ~13 more combinations

**Implicit state in optionals:** `activeDecoder`, `activeEncoder`, `pendingUSBDecoder`, `standbyAWDLConnection`, `secureInputTimer`, `activeAWDLDeviceID`, `lastAWDLActivityAt` — all nil-checked as implicit state flags.

**Device identity validation is split:** partial validation happens in `addPendingAWDLSlot` timeout logic, real validation happens later in `handlePendingAWDLPoolMessage`.

### iOS TransportManager (`KeydApp/KeydApp/Transport/TransportManager.swift`) — MEDIUM

**State enum (clean):**
```swift
enum State: Equatable {
    case disconnected
    case connecting
    case usbConnected
    case awdlConnected
}
```

**Boolean flags as shadow state:**
- `awdlEnabledForCurrentSession: Bool` — controls whether AWDL is available
- `suppressAWDLStatusUntilPaired: Bool` — hides AWDL status during pairing
- `awaitingAWDLHeartbeatAck: Bool` — heartbeat timeout tracking

**Continuation optionals as state:** `connectionReadyContinuation` and `pairingResponseContinuation` — nil means not waiting, non-nil means waiting. These can leak if not properly cleared on all exit paths.

**`connectionState` didSet has 8 branching conditions** — calls `updateLiveActivity`, manages heartbeat task, resolves continuations. Side effects are entangled with state transitions.

### iOS AWDLTransport (`KeydApp/KeydApp/Transport/AWDLTransport.swift`) — MEDIUM

**Three state booleans with complex interdependencies:**
- `isConnecting: Bool`
- `isReady: Bool`
- `autoConnectEnabled: Bool`

Plus `pairingModeEnabled: Bool` (disables reconnect) and `reconnectBackoff: TimeInterval` (exponential backoff — this part is well-done).

`hasConnection()` buries real state checks: queries `isReady` AND `currentPath.status` AND `usesInterfaceType`.

### iOS USBTransport (`KeydApp/KeydApp/Transport/USBTransport.swift`) — CLEAN

Simple: `connection: NWConnection?` + `isReady: Bool`. Listener-based, waits for inbound tunnel. Not much to formalize here.

### macOS USBListener (`macOS/KeydAgent/Transport/USBListener.swift`) — CLEAN

Simple reconnect loop with `socketFD` state. Device affinity for preferential reconnect. Fine as-is.

### macOS AWDLListener (`macOS/KeydAgent/Transport/AWDLListener.swift`) — TRIVIAL

Just a `NWListener` wrapper. All complexity lives in TransportManager.

## Where Bugs Come From

Every debug session in `.planning/debug/` traces to one of these patterns:

1. **Unexpected state combination** — boolean flags + optional-as-state creates states that the enum alone doesn't represent (e.g., `.awdlConnected` but `awaitingAWDLHeartbeatAck = true` and `standbyAWDLConnection != nil`)
2. **Transition side effects** — `didSet` on `connectionState` triggers cascading changes that interact with in-flight async work
3. **Split validation** — identity checks happen at different times in different code paths, creating windows where unvalidated connections influence state
4. **Pool lifecycle races** — pending AWDL slots, pending USB, and standby AWDL all have independent lifecycles that can collide

The specific bugs from debug sessions:
- `usb-state-shows-awdl-while-cabled` → USB transport direction was backwards + standby probe corrupted frame stream
- `multi-device-awdl-session-thrash` → 7 follow-up fixes, each a different implicit state interaction
- `false-awdl-promotion-when-networking-unavailable` → stale pre-warmed AWDL sockets survived after peer disappeared
- Open bugs (slow reconnect, character floods, long reconnect after backgrounding) → all likely stem from reconnect state transitions interacting with buffered data and backoff state

## Design Questions the Planner Must Resolve

### Multiple simultaneous USB connections

Currently `USBListener` holds a single `socketFD` and round-robins through attached devices on failure. `TransportManager` has a single `pendingUSBDecoder`. This means only one USB device can be in pending-identity state at a time, causing rotation delays (S08, S13 bugs).

The FSM should support multiple concurrent pending USB connections — one per attached device. Each goes through identity verification independently. The first to identify as paired gets promoted.

### Multi-device pairing model

Currently `PairingManager` stores exactly one `pairedDeviceID` and one shared secret. Pairing device B silently overwrites device A's pairing on the Mac side, but device A's iOS Keychain still holds the old pairing — device A shows "connecting" forever with no feedback that its pairing was revoked.

Two options for the FSM:

1. **Single-paired (simpler):** Keep one pairing slot, but when a new device pairs, send `pairingInvalidated` to the previously paired device first (infrastructure exists). Device A sees "Pairing revoked" instead of hanging.

2. **Multi-paired (future-proof):** macOS stores `[deviceID: SharedSecret]` map. Multiple devices can be paired simultaneously, but only one active session at a time. When the active session drops, another paired device can take over. This is the natural model for iPhone + iPad usage.

The planner should decide which model to implement. Either way, device identity must be a first-class part of the FSM state, not a side-band property on `PairingManager`.

### Background execution and socket survival

Currently there is ZERO background handling. `KeydApp.swift` line 53 (`case .background: break`) does nothing. iOS suspends the process after a few seconds, killing TCP sockets. The "sometimes disconnects when backgrounded" bug is just iOS's nondeterministic suspension timing.

The FSM must model app lifecycle as part of transport state. Required:

1. **`UIApplication.beginBackgroundTask`** when entering background — buys ~30s guaranteed execution (sometimes up to 3 minutes). This is the only reliable API without audio/location background modes.
2. **Background state in the FSM** — transport should know the app is backgrounded and avoid triggering reconnect storms. When the background task is about to expire, gracefully close connections rather than letting iOS kill them mid-frame.
3. **Fast reconnect on foreground** — `scenePhase == .active` should immediately check connection liveness and reconnect if sockets died during suspension. The user wants this to feel instant, not go through the full backoff sequence.
4. **NWConnection behavior** — Network.framework connections CAN survive backgrounding if established while foreground, but only if the process isn't suspended. The `beginBackgroundTask` window protects this.

True 5-minute background persistence isn't possible with standard iOS APIs (no audio/location/push notification background mode applies here). But `beginBackgroundTask` + graceful teardown + instant foreground reconnect covers the real use case: quick app-switches to check a text or glance at another app should not require a full reconnect cycle.

## What 01-06 Should Accomplish (State Machine Formalization)

**Core idea:** Replace implicit state (booleans, optionals, continuation existence) with an explicit FSM where every legal state and transition is defined in one place.

### Design philosophy: make illegal states unrepresentable

The current code allows any combination of booleans, optionals, and connection references — the developer must mentally track which combinations are valid. Every new bug is a combination nobody anticipated.

The FSM must invert this: define ONLY the legal states as enum cases. If a state combination doesn't have a case, it cannot exist at runtime. The transition function is the single gateway — no state change happens outside it. This means:
- New transport events don't need exhaustive manual analysis of "what if X is also true" — the compiler forces you to handle every state × event pair
- Invariants from the scenario matrix (INV-001 through INV-016) become assertions on the state type itself, not runtime checks scattered across methods
- The 01-07 fuzz tests can throw randomized event sequences at the transition function and catch violations the developer never imagined — the FSM + invariant checker finds bugs without anyone having to think of the specific scenario

### macOS TransportManager (highest priority)

Replace the 5 connection pools + 19-case switch with:
- A single `State` enum that captures ALL transport state (including pending connections, identity verification status, standby)
- A pure `transition(from: State, on: Event) -> (State, [SideEffect])` function
- Side effects (start connection, close connection, send message, start timer) as an output list, not inline mutations
- Illegal transitions become assertions or compile-time errors
- The 19 cases still exist conceptually but are now explicit, auditable, and testable in isolation

### iOS TransportManager (medium priority)

- Absorb boolean flags into the state enum (e.g., `connecting(awdlEnabled: Bool)` or separate sub-states)
- Move `didSet` side effects into the transition function
- Continuations become part of state, not separate optionals

### iOS AWDLTransport (medium priority)

- Replace `isConnecting` + `isReady` + `autoConnectEnabled` with explicit connection state enum
- Keep the exponential backoff logic (it's already good)

### Built-in event log

Every state transition gets recorded to a circular buffer with: timestamp, previous state, event, new state, side effects triggered. This log is already partially implemented (`connectionEventLog`) but should become a first-class part of the FSM.

### What NOT to change in 01-06

- Don't rewrite USBTransport, USBListener, or AWDLListener — they're clean enough
- Don't change the protocol or message format
- Don't change the pairing flow logic — just make it go through the state machine
- Don't change UI behavior — same states, same transitions, just formalized

## What 01-07 Should Accomplish (On-Device Test Suite)

**Core idea:** Tests run ON the devices as part of the app, not from bash scripts in a terminal.

### On-device test runner

- iOS app gets a "Transport Tests" screen accessible from the debug sheet
- Test scenarios from `AWDL_USB_SCENARIO_MATRIX.md` are implemented as Swift test cases
- Each scenario injects events through the FSM's transition function (force USB drop, force AWDL drop, simulate candidate arrivals, advance virtual timers)
- Results display inline — tap to run one scenario or run the full suite
- Pass/fail with event trace on failure

### XCTest unit tests for the pure FSM

- The `transition(from:on:)` function is pure — no network, no device needed
- Every scenario from the matrix becomes a unit test that feeds events and asserts resulting states
- Invariants from the matrix (INV-001 through INV-016) become assertion helpers
- These run in CI, on simulator, fast

### Event trace export + replay

- "Export Trace" button on the debug sheet captures the circular event log
- Exported traces can be replayed as new test scenarios
- Closes the loop: find bug manually → export trace → encode as regression test

### What the scenario matrix becomes

- `AWDL_USB_SCENARIO_MATRIX.md` stays as the human-readable spec
- Each scenario (S01-S24) maps to a Swift test case
- Invariants (INV-001 through INV-016) map to assertion functions that can be composed
- Spam/stress scenarios (S21-S24) run as parameterized tests with configurable iteration counts

## File Reference

| File | Role | 01-06 Action | 01-07 Action |
|------|------|-------------|-------------|
| `macOS/KeydAgent/Transport/TransportManager.swift` | macOS state management | **REWRITE** — explicit FSM | Test target |
| `KeydApp/KeydApp/Transport/TransportManager.swift` | iOS state management | **REWRITE** — explicit FSM | Test target |
| `KeydApp/KeydApp/Transport/AWDLTransport.swift` | iOS AWDL connection | **REFACTOR** — explicit connection state enum | Test target |
| `KeydApp/KeydApp/Transport/USBTransport.swift` | iOS USB connection | No change | Test target |
| `macOS/KeydAgent/Transport/USBListener.swift` | macOS USB connection | No change | Test target |
| `macOS/KeydAgent/Transport/AWDLListener.swift` | macOS AWDL listener | No change | Test target |
| `AWDL_USB_SCENARIO_MATRIX.md` | Test spec | Update if states/events change | Maps to test cases |

## Debug Sessions Reference

All in `.planning/debug/`:
- `multi-device-awdl-session-thrash.md` — 7 follow-up fixes, most relevant to 01-06
- `usb-state-shows-awdl-while-cabled.md` — transport direction + standby corruption
- `false-awdl-promotion-when-networking-unavailable.md` — stale AWDL socket lifecycle
- `ios-reinstall-retains-pairing-state.md` — keychain persistence (fixed, not transport)
- `keyboard-undo-and-predictive-text-not-disabled.md` — UI layer (fixed, not transport)
- `mac-log-info-level.md` — logging (fixed, not transport)
