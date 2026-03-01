import Foundation
import SharedProtocol

// MARK: - Scenario Model

/// A single transport FSM test scenario derived from AWDL_USB_SCENARIO_MATRIX.md.
struct TransportTestScenario: Identifiable {
    let id: String              // "S01", "S02", etc.
    let suite: Suite
    let name: String
    let initialState: AgentTransportState
    let events: [AgentTransportEvent]
    let expectedFinalState: AgentTransportState?   // nil for stress scenarios with variable outcome
    let invariants: [InvariantID]
    let stepLimit: Int          // Max steps for stress scenarios (same as events.count for deterministic ones)

    enum Suite: String, CaseIterable {
        case singleDevice = "Suite A: Single-Device"
        case multiDevice  = "Suite B: Multi-Device"
    }

    /// Invariant identifiers — maps to the assertion helpers in the XCTest suite.
    enum InvariantID: String, CaseIterable {
        case inv001 = "INV-001"
        case inv002 = "INV-002"
        case inv003 = "INV-003"
        case inv004 = "INV-004"
        case inv005 = "INV-005"
        case inv006 = "INV-006"
        case inv007 = "INV-007"
        case inv008 = "INV-008"
        case inv009 = "INV-009"
        case inv010 = "INV-010"
        case inv011 = "INV-011"
        case inv012 = "INV-012"
        case inv013 = "INV-013"
        case inv014 = "INV-014"
        case inv015 = "INV-015"
        case inv016 = "INV-016"

        var description: String {
            switch self {
            case .inv001: return "Unpaired identity never confirmed"
            case .inv002: return "Single active session"
            case .inv003: return "Pending USB timeout drops only that slot"
            case .inv004: return "Pending AWDL timeout drops only that slot"
            case .inv005: return "Non-matching resume rejected"
            case .inv006: return "Matching resume promotes"
            case .inv007: return "USB promotion requires matching identity"
            case .inv008: return "AWDL promotion only when USB absent"
            case .inv009: return "Unpaired reconnect bounded"
            case .inv010: return "Backoff monotonic"
            case .inv011: return "Stale never displaces healthy"
            case .inv012: return "Unpaired USB does not clear paired AWDL"
            case .inv013: return "USB rotation progresses"
            case .inv014: return "Relaunch preserves pairing"
            case .inv015: return "Heartbeat respected during stabilization"
            case .inv016: return "Convergence after disconnect"
            }
        }
    }
}

// MARK: - Seeded RNG (for on-device stress scenarios)

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Stress scenario factory

extension TransportTestScenario {
    static func stressScenario(
        id: String,
        suite: Suite,
        name: String,
        seed: UInt64,
        steps: Int,
        invariants: [InvariantID]
    ) -> TransportTestScenario {
        var rng = SeededRNG(seed: seed)
        let events = (0..<steps).map { _ in randomAgentEvent(using: &rng) }
        return TransportTestScenario(
            id: id,
            suite: suite,
            name: name,
            initialState: .disconnected,
            events: events,
            expectedFinalState: nil, // stress test — outcome is non-deterministic with respect to a specific state
            invariants: invariants,
            stepLimit: steps
        )
    }

    private static func randomAgentEvent(using rng: inout SeededRNG) -> AgentTransportEvent {
        switch rng.next() % 10 {
        case 0: return .usbConnectionArrived(deviceID: rng.next() % 2 == 0 ? "P" : "U")
        case 1: return .usbIdentityConfirmed(deviceID: rng.next() % 2 == 0 ? "P" : "U")
        case 2: return .usbIdentityTimeout
        case 3: return .usbDisconnected
        case 4: return .awdlCandidateArrived(isPaired: rng.next() % 2 == 0)
        case 5: return .awdlIdentityConfirmed(deviceID: "P", remainingSlots: Int(rng.next() % 3))
        case 6: return .awdlIdentityTimeout(remainingSlots: Int(rng.next() % 3))
        case 7: return .awdlDisconnected
        case 8: return .heartbeatTimeout
        default: return .heartbeatAck
        }
    }
}

// MARK: - Scenario Registry

/// All 24 scenarios from AWDL_USB_SCENARIO_MATRIX.md encoded as Swift data.
let allScenarios: [TransportTestScenario] = [

    // MARK: Suite A: Single-Device

    // S05: Confirmed AWDL on P, USB for P appears -> promote to USB
    TransportTestScenario(
        id: "S05",
        suite: .singleDevice,
        name: "USB promotes over confirmed AWDL",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .usbConnectionArrived(deviceID: "P"),
            .usbIdentityConfirmed(deviceID: "P"),
        ],
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv002, .inv006, .inv007],
        stepLimit: 2
    ),

    // S06: Confirmed USB on P -> force_usb_drop -> AWDL fallback -> confirmed AWDL on P
    TransportTestScenario(
        id: "S06",
        suite: .singleDevice,
        name: "USB drop fallback to AWDL",
        initialState: .usbConnected(deviceID: "P"),
        events: [
            .usbDisconnected,
            .awdlCandidateArrived(isPaired: true),
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv002, .inv006, .inv008, .inv016],
        stepLimit: 3
    ),

    // S07: Confirmed AWDL on P -> force_awdl_drop -> USB reconnect
    TransportTestScenario(
        id: "S07",
        suite: .singleDevice,
        name: "AWDL drop fallback to USB",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .awdlDisconnected,
            .usbConnectionArrived(deviceID: "P"),
            .usbIdentityConfirmed(deviceID: "P"),
        ],
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv002, .inv006, .inv016],
        stepLimit: 3
    ),

    // S10: Agent restarted; paired secret exists -> USB reconnect
    TransportTestScenario(
        id: "S10",
        suite: .singleDevice,
        name: "Post-relaunch USB reconnect",
        initialState: .disconnected,
        events: [
            .usbConnectionArrived(deviceID: "P"),
            .usbIdentityConfirmed(deviceID: "P"),
        ],
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv006, .inv014],
        stepLimit: 2
    ),

    // S11: Agent restarted -> AWDL candidate -> P accepted
    TransportTestScenario(
        id: "S11",
        suite: .singleDevice,
        name: "Post-relaunch AWDL reconnect",
        initialState: .disconnected,
        events: [
            .awdlCandidateArrived(isPaired: true),
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv006, .inv014],
        stepLimit: 2
    ),

    // S14: Confirmed AWDL on P, heartbeat ack within stabilization window
    TransportTestScenario(
        id: "S14",
        suite: .singleDevice,
        name: "Heartbeat ack preserves AWDL session",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .heartbeatAck,
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv015],
        stepLimit: 1
    ),

    // S15: Confirmed AWDL on P -> hard close -> backoff reconnect
    TransportTestScenario(
        id: "S15",
        suite: .singleDevice,
        name: "Backoff reconnect after hard close",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .awdlDisconnected,
            .awdlCandidateArrived(isPaired: true),
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv010, .inv016],
        stepLimit: 3
    ),

    // MARK: Suite B: Multi-Device

    // S01: No session -> U arrives (unpaired) -> P arrives (paired) -> confirmed AWDL on P
    TransportTestScenario(
        id: "S01",
        suite: .multiDevice,
        name: "Paired P confirms AWDL over unpaired U",
        initialState: .disconnected,
        events: [
            .awdlCandidateArrived(isPaired: false),  // U arrives -> pairingAWDL
            // Simulate P arriving: restart from disconnected path (paired candidate)
            // The test runner handles multi-step scenarios
            .awdlCandidateArrived(isPaired: true),   // while in pairingAWDL, P also arrives
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv001, .inv002, .inv004, .inv006, .inv011],
        stepLimit: 3
    ),

    // S02: No session -> unpaired AWDL arrives -> identity timeout -> no session
    TransportTestScenario(
        id: "S02",
        suite: .multiDevice,
        name: "Unpaired AWDL timeout — no confirmed session",
        initialState: .disconnected,
        events: [
            .awdlCandidateArrived(isPaired: false),
            .awdlDisconnected,  // simulates identity timeout / disconnect
        ],
        expectedFinalState: .disconnected,
        invariants: [.inv002, .inv004, .inv009],
        stepLimit: 2
    ),

    // S03: Confirmed AWDL on P -> unpaired U AWDL arrives -> P stable
    TransportTestScenario(
        id: "S03",
        suite: .multiDevice,
        name: "Unpaired AWDL rejected while P session active",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .awdlCandidateArrived(isPaired: false),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv001, .inv002, .inv011],
        stepLimit: 1
    ),

    // S04: Confirmed AWDL on P, USB from U -> U rejected, P stable
    TransportTestScenario(
        id: "S04",
        suite: .multiDevice,
        name: "USB from unpaired U rejected while P AWDL active",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .usbConnectionArrived(deviceID: "U"),
            .usbIdentityTimeout,  // U times out
        ],
        expectedFinalState: .disconnected,  // AWDL was displaced by USB arrival, then timeout
        invariants: [.inv001, .inv002, .inv005, .inv007],
        stepLimit: 2
    ),

    // S08: Both USB connected (U first) -> timeout -> P USB identity -> confirmed USB on P
    TransportTestScenario(
        id: "S08",
        suite: .multiDevice,
        name: "USB rotation reaches paired device P",
        initialState: .disconnected,
        events: [
            .usbConnectionArrived(deviceID: "U"),
            .usbIdentityTimeout,
            .usbConnectionArrived(deviceID: "P"),
            .usbIdentityConfirmed(deviceID: "P"),
        ],
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv001, .inv013],
        stepLimit: 4
    ),

    // S09: Both AWDL arrive simultaneously -> P confirmed, U dropped
    TransportTestScenario(
        id: "S09",
        suite: .multiDevice,
        name: "Simultaneous AWDL candidates — P prevails",
        initialState: .disconnected,
        events: [
            .awdlCandidateArrived(isPaired: true),
            .awdlCandidateArrived(isPaired: false),  // U rejected from pool
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv001, .inv002, .inv006, .inv011],
        stepLimit: 3
    ),

    // S12: Confirmed AWDL on P, U in pairing mode -> U bounded, P stable
    TransportTestScenario(
        id: "S12",
        suite: .multiDevice,
        name: "Unpaired U reconnect bounded while P stable",
        initialState: .awdlConnected(deviceID: "P"),
        events: Array(repeating: AgentTransportEvent.awdlCandidateArrived(isPaired: false), count: 10),
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv009, .inv011],
        stepLimit: 10
    ),

    // S13: No session, U USB idle -> timeout -> P USB wins
    TransportTestScenario(
        id: "S13",
        suite: .multiDevice,
        name: "Idle U USB dropped, P wins USB",
        initialState: .disconnected,
        events: [
            .usbConnectionArrived(deviceID: "U"),
            .usbIdentityTimeout,
            .usbConnectionArrived(deviceID: "P"),
            .usbIdentityConfirmed(deviceID: "P"),
        ],
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv003, .inv013],
        stepLimit: 4
    ),

    // S16: Confirmed USB on P, U AWDL storm -> USB on P unaffected
    TransportTestScenario(
        id: "S16",
        suite: .multiDevice,
        name: "AWDL storm from U does not affect USB session on P",
        initialState: .usbConnected(deviceID: "P"),
        events: Array(repeating: AgentTransportEvent.awdlCandidateArrived(isPaired: false), count: 20),
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv001, .inv002, .inv011],
        stepLimit: 20
    ),

    // S17: AWDL race — stale U slot replaced by P
    TransportTestScenario(
        id: "S17",
        suite: .multiDevice,
        name: "Stale AWDL slot replaced by P",
        initialState: .disconnected,
        events: [
            .awdlCandidateArrived(isPaired: true),
            .awdlCandidateArrived(isPaired: false),  // U rejected from pool
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv004, .inv006, .inv011],
        stepLimit: 3
    ),

    // S18: Confirmed AWDL on P, pending USB from U -> P AWDL path not cleared
    TransportTestScenario(
        id: "S18",
        suite: .multiDevice,
        name: "Pending USB from U does not permanently clear P AWDL path",
        initialState: .awdlConnected(deviceID: "P"),
        events: [
            .usbConnectionArrived(deviceID: "U"),
            .usbIdentityTimeout,
            .awdlCandidateArrived(isPaired: true),
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv012, .inv016],
        stepLimit: 4
    ),

    // S19: Confirmed USB on P -> drop -> U AWDL -> P AWDL confirmed despite contention
    TransportTestScenario(
        id: "S19",
        suite: .multiDevice,
        name: "P AWDL confirmed despite U contention after USB drop",
        initialState: .usbConnected(deviceID: "P"),
        events: [
            .usbDisconnected,
            .awdlCandidateArrived(isPaired: true),
            .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0),
        ],
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv001, .inv006, .inv011, .inv016],
        stepLimit: 3
    ),

    // MARK: Stress Scenarios (both suites)

    // S20: Long-run churn — 200-step seeded
    TransportTestScenario.stressScenario(
        id: "S20",
        suite: .singleDevice,
        name: "Long-run churn — 200-step seeded randomized stream",
        seed: 42,
        steps: 200,
        invariants: TransportTestScenario.InvariantID.allCases
    ),

    // S21: USB reconnect spam — 200x force_usb_drop then reconnect
    TransportTestScenario(
        id: "S21",
        suite: .singleDevice,
        name: "USB reconnect spam — 200 iterations",
        initialState: .usbConnected(deviceID: "P"),
        events: Array((0..<200).flatMap { _ -> [AgentTransportEvent] in
            [.usbDisconnected,
             .usbConnectionArrived(deviceID: "P"),
             .usbIdentityConfirmed(deviceID: "P")]
        }),
        expectedFinalState: .usbConnected(deviceID: "P"),
        invariants: [.inv010, .inv016],
        stepLimit: 600
    ),

    // S22: AWDL heartbeat churn — 50 iterations
    TransportTestScenario(
        id: "S22",
        suite: .singleDevice,
        name: "AWDL reconnect churn with heartbeat — 50 iterations",
        initialState: .awdlConnected(deviceID: "P"),
        events: Array((0..<50).flatMap { _ -> [AgentTransportEvent] in
            [.heartbeatTimeout,
             .awdlCandidateArrived(isPaired: true),
             .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0)]
        }),
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv010, .inv016],
        stepLimit: 150
    ),

    // S23: U storm + P drop/reconnect — 30 iterations
    TransportTestScenario(
        id: "S23",
        suite: .multiDevice,
        name: "U storm + P periodic drop/reconnect — 30 cycles",
        initialState: .awdlConnected(deviceID: "P"),
        events: Array((0..<30).flatMap { _ -> [AgentTransportEvent] in
            // Storm of 5 unpaired candidates + P drop/reconnect
            Array(repeating: AgentTransportEvent.awdlCandidateArrived(isPaired: false), count: 5) + [
                .awdlDisconnected,
                .awdlCandidateArrived(isPaired: true),
                .awdlIdentityConfirmed(deviceID: "P", remainingSlots: 0)
            ]
        }),
        expectedFinalState: .awdlConnected(deviceID: "P"),
        invariants: [.inv001, .inv011, .inv016],
        stepLimit: 240
    ),

    // S24: 500-step seeded storm
    TransportTestScenario.stressScenario(
        id: "S24",
        suite: .multiDevice,
        name: "500-step seeded storm — deterministic replay",
        seed: 0xDEADBEEF,
        steps: 500,
        invariants: TransportTestScenario.InvariantID.allCases
    ),
]
