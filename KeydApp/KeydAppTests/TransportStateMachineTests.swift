import XCTest
import SharedProtocol

/// iOS-specific transport FSM lifecycle tests.
///
/// These supplement the SharedProtocol tests by verifying iOS-specific behaviours:
/// background/foreground lifecycle, heartbeat management, and connection continuation.
/// All tests use iOSTransportTransition() directly from SharedProtocol.
final class TransportStateMachineTests: XCTestCase {

    // MARK: - Background Lifecycle

    func testBackgroundedFromUSBCreatesBackgroundTask() {
        let (newState, effects) = iOSTransportTransition(from: .usbConnected, on: .appBackgrounded)
        XCTAssertEqual(newState, .backgroundSuspended(previousTransport: .usb))
        XCTAssertTrue(effects.contains(.beginBackgroundTask), "Must start background task when backgrounded from USB")
    }

    func testBackgroundedFromAWDLCreatesBackgroundTask() {
        let (newState, effects) = iOSTransportTransition(
            from: .awdlConnected(awaitingHeartbeatAck: false),
            on: .appBackgrounded
        )
        XCTAssertEqual(newState, .backgroundSuspended(previousTransport: .awdl))
        XCTAssertTrue(effects.contains(.beginBackgroundTask), "Must start background task when backgrounded from AWDL")
    }

    func testBackgroundedFromConnectingPreservesNilTransport() {
        let (newState, effects) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: true),
            on: .appBackgrounded
        )
        XCTAssertEqual(newState, .backgroundSuspended(previousTransport: nil))
        XCTAssertTrue(effects.contains(.beginBackgroundTask))
    }

    func testBackgroundedFromDisconnectedPreservesNilTransport() {
        let (newState, effects) = iOSTransportTransition(
            from: .disconnected(awdlEnabled: true),
            on: .appBackgrounded
        )
        XCTAssertEqual(newState, .backgroundSuspended(previousTransport: nil))
        XCTAssertTrue(effects.contains(.beginBackgroundTask))
    }

    func testDuplicateBackgroundEventIsNoOp() {
        let state = iOSTransportState.backgroundSuspended(previousTransport: .usb)
        let (newState, _) = iOSTransportTransition(from: state, on: .appBackgrounded)
        XCTAssertEqual(newState, state, "Duplicate background event must not change state")
    }

    // MARK: - Foreground Lifecycle

    func testForegroundedFromUSBPreviousDoesSkipBackoff() {
        // Had USB session before background → fast reconnect (skipBackoff: true)
        let (newState, effects) = iOSTransportTransition(
            from: .backgroundSuspended(previousTransport: .usb),
            on: .appForegrounded
        )
        XCTAssertTrue(effects.contains(.startReconnect(skipBackoff: true)),
            "Must skip backoff when returning from background with prior USB session")
        XCTAssertTrue(effects.contains(.endBackgroundTask))
        if case .connecting = newState { } else {
            XCTFail("Must be in connecting state after foregrounding, got \(newState)")
        }
    }

    func testForegroundedFromAWDLPreviousDoesSkipBackoff() {
        // Had AWDL session before background → fast reconnect
        let (newState, effects) = iOSTransportTransition(
            from: .backgroundSuspended(previousTransport: .awdl),
            on: .appForegrounded
        )
        XCTAssertTrue(effects.contains(.startReconnect(skipBackoff: true)))
        XCTAssertTrue(effects.contains(.endBackgroundTask))
        if case .connecting = newState { } else {
            XCTFail("Must be in connecting state after foregrounding, got \(newState)")
        }
    }

    func testForegroundedFromNoSessionDoesNotSkipBackoff() {
        // No prior session → normal reconnect (skipBackoff: false)
        let (newState, effects) = iOSTransportTransition(
            from: .backgroundSuspended(previousTransport: nil),
            on: .appForegrounded
        )
        XCTAssertTrue(effects.contains(.startReconnect(skipBackoff: false)),
            "Must NOT skip backoff when returning from background without prior session")
        XCTAssertTrue(effects.contains(.endBackgroundTask))
        if case .connecting = newState { } else {
            XCTFail("Must be in connecting state after foregrounding, got \(newState)")
        }
    }

    func testForegroundedWhenAlreadyConnectedIsNoOp() {
        let (usbState, _) = iOSTransportTransition(from: .usbConnected, on: .appForegrounded)
        XCTAssertEqual(usbState, .usbConnected, "Foreground while connected must not change state")

        let (awdlState, _) = iOSTransportTransition(
            from: .awdlConnected(awaitingHeartbeatAck: false),
            on: .appForegrounded
        )
        XCTAssertEqual(awdlState, .awdlConnected(awaitingHeartbeatAck: false))
    }

    // MARK: - Background Task Expiry

    func testBackgroundTaskExpiryClosesAllConnections() {
        let (newState, effects) = iOSTransportTransition(
            from: .backgroundSuspended(previousTransport: .awdl),
            on: .backgroundTaskExpiring
        )
        XCTAssertEqual(newState, .disconnected(awdlEnabled: true))
        XCTAssertTrue(effects.contains(.closeConnections))
        XCTAssertTrue(effects.contains(.endBackgroundTask))
        XCTAssertTrue(effects.contains(.stopHeartbeat))
        XCTAssertTrue(effects.contains(.enableIdleTimer))
    }

    // MARK: - Heartbeat Management

    func testHeartbeatStartedOnAWDLConnect() {
        let (_, effects) = iOSTransportTransition(
            from: .connecting(transport: .awdl, awdlEnabled: true),
            on: .awdlReady
        )
        XCTAssertTrue(effects.contains(.startHeartbeat), "Must start heartbeat on AWDL connection")
    }

    func testHeartbeatNotStartedOnUSBConnect() {
        let (_, effects) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: true),
            on: .usbReady
        )
        XCTAssertFalse(effects.contains(.startHeartbeat), "Must NOT start heartbeat on USB connection")
    }

    func testHeartbeatTimeoutDisconnectsAndReconnects() {
        let (newState, effects) = iOSTransportTransition(
            from: .awdlConnected(awaitingHeartbeatAck: false),
            on: .heartbeatTimeout
        )
        XCTAssertEqual(newState, .disconnected(awdlEnabled: true))
        XCTAssertTrue(effects.contains(.stopHeartbeat))
        XCTAssertTrue(effects.contains(.closeConnections))
        XCTAssertTrue(effects.contains(.startReconnect(skipBackoff: false)))
        XCTAssertTrue(effects.contains(.enableIdleTimer))
    }

    func testHeartbeatTimeoutIgnoredWhenNotAWDL() {
        // Heartbeat timeout when in USB session must be ignored
        let (usbState, usbEffects) = iOSTransportTransition(from: .usbConnected, on: .heartbeatTimeout)
        XCTAssertEqual(usbState, .usbConnected, "Heartbeat timeout must not affect USB session")
        XCTAssertTrue(usbEffects.contains(where: { if case .logEvent = $0 { return true }; return false }))

        // Heartbeat timeout when disconnected must be ignored
        let (discState, _) = iOSTransportTransition(from: .disconnected(awdlEnabled: true), on: .heartbeatTimeout)
        XCTAssertEqual(discState, .disconnected(awdlEnabled: true))
    }

    func testHeartbeatAckClearsAwaitingFlag() {
        // ack while awaiting → clears flag
        let (state1, _) = iOSTransportTransition(from: .awdlConnected(awaitingHeartbeatAck: true), on: .heartbeatAck)
        XCTAssertEqual(state1, .awdlConnected(awaitingHeartbeatAck: false))

        // ack while not awaiting → stays the same
        let (state2, _) = iOSTransportTransition(from: .awdlConnected(awaitingHeartbeatAck: false), on: .heartbeatAck)
        XCTAssertEqual(state2, .awdlConnected(awaitingHeartbeatAck: false))
    }

    // MARK: - Connection Continuations

    func testUSBReadyResolvesConnectionContinuation() {
        let (_, effects) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: true),
            on: .usbReady
        )
        XCTAssertTrue(effects.contains(.resolveConnectionContinuation))
    }

    func testAWDLReadyResolvesConnectionContinuation() {
        let (_, effects) = iOSTransportTransition(
            from: .connecting(transport: .awdl, awdlEnabled: true),
            on: .awdlReady
        )
        XCTAssertTrue(effects.contains(.resolveConnectionContinuation))
    }

    // MARK: - USB Fallback

    func testUSBDropFallsBackToAWDL() {
        let (newState, effects) = iOSTransportTransition(from: .usbConnected, on: .usbDisconnected)
        XCTAssertEqual(newState, .disconnected(awdlEnabled: true))
        XCTAssertTrue(effects.contains(.startReconnect(skipBackoff: false)))
    }

    func testUSBNotAvailableFallsBackToAWDLIfEnabled() {
        let (newState, _) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: true),
            on: .usbDisconnected
        )
        XCTAssertEqual(newState, .connecting(transport: .awdl, awdlEnabled: true))
    }

    func testUSBNotAvailableDisconnectsIfAWDLDisabled() {
        let (newState, _) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: false),
            on: .usbDisconnected
        )
        XCTAssertEqual(newState, .disconnected(awdlEnabled: false))
    }

    // MARK: - Idle Timer

    func testIdleTimerDisabledOnConnect() {
        let (_, effects) = iOSTransportTransition(
            from: .connecting(transport: .usb, awdlEnabled: true),
            on: .usbReady
        )
        XCTAssertTrue(effects.contains(.disableIdleTimer), "Must disable idle timer when connected")
    }

    func testIdleTimerEnabledOnDisconnect() {
        let (_, effects) = iOSTransportTransition(from: .usbConnected, on: .usbDisconnected)
        XCTAssertTrue(effects.contains(.enableIdleTimer), "Must re-enable idle timer when disconnected")
    }

    // MARK: - Full lifecycle integration scenario

    func testFullUSBToAWDLToBackgroundToForeground() {
        var state: iOSTransportState = .connecting(transport: .usb, awdlEnabled: true)

        // USB connects
        let (s1, _) = iOSTransportTransition(from: state, on: .usbReady)
        state = s1
        XCTAssertEqual(state, .usbConnected)

        // USB drops — fall back to AWDL reconnect
        let (s2, _) = iOSTransportTransition(from: state, on: .usbDisconnected)
        state = s2
        XCTAssertEqual(state, .disconnected(awdlEnabled: true))

        // Start AWDL reconnect
        let (s3, _) = iOSTransportTransition(from: state, on: .retryRequested)
        state = s3
        if case .connecting = state { } else {
            XCTFail("Expected connecting after retry, got \(state)")
        }

        // AWDL connects
        let (s4, _) = iOSTransportTransition(from: state, on: .awdlReady)
        state = s4
        XCTAssertEqual(state, .awdlConnected(awaitingHeartbeatAck: false))

        // App backgrounds
        let (s5, _) = iOSTransportTransition(from: state, on: .appBackgrounded)
        state = s5
        XCTAssertEqual(state, .backgroundSuspended(previousTransport: .awdl))

        // App foregrounds — fast reconnect
        let (s6, effects6) = iOSTransportTransition(from: state, on: .appForegrounded)
        state = s6
        XCTAssertTrue(effects6.contains(.startReconnect(skipBackoff: true)))
        if case .connecting = state { } else {
            XCTFail("Expected connecting after foregrounding, got \(state)")
        }
    }
}
