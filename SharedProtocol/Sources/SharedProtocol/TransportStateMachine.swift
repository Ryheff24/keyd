import Foundation

// MARK: - Shared Transport Connection Kind

/// Transport connection kind. Used by both macOS agent and iOS FSMs.
public enum ConnectionKind: CustomStringConvertible, Equatable, Sendable {
    case usb, awdl
    public var description: String { self == .usb ? "USB" : "AWDL" }
}

/// Typealias so iOS FSM code that references iOSConnectionKind compiles without changes.
public typealias iOSConnectionKind = ConnectionKind

// MARK: - macOS Agent FSM

/// Explicit transport state for the macOS agent.
///
/// Every legal state is an enum case — no boolean flags or optional-as-state patterns.
/// Connection references (NWConnection, decoder, encoder) are NOT part of this enum;
/// they live in TransportManager's ConnectionResources alongside the FSM state.
public enum AgentTransportState: Equatable, CustomStringConvertible, Sendable {
    /// No active or pending connection.
    case disconnected

    /// USB connection established; waiting for the iOS device to identify itself
    /// via a sessionResume or pairingRequest message.
    case pendingUSBIdentity(deviceID: String?)

    /// USB session confirmed for a specific paired device.
    case usbConnected(deviceID: String)

    /// One or more AWDL connections are in the pending pool, each waiting for
    /// identity verification. `slotCount` tracks how many slots are active.
    case pendingAWDLPool(slotCount: Int)

    /// Unpaired: a single AWDL channel is open for pairing handshake.
    case pairingAWDL

    /// AWDL session confirmed for a specific paired device.
    case awdlConnected(deviceID: String)

    public var description: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .pendingUSBIdentity(let id):
            return "pendingUSBIdentity(\(id ?? "unknown"))"
        case .usbConnected(let id):
            return "usbConnected(\(id))"
        case .pendingAWDLPool(let count):
            return "pendingAWDLPool(\(count) slots)"
        case .pairingAWDL:
            return "pairingAWDL"
        case .awdlConnected(let id):
            return "awdlConnected(\(id))"
        }
    }

    /// The current active device ID, if any confirmed session is active.
    public var activeDeviceID: String? {
        switch self {
        case .usbConnected(let id): return id
        case .awdlConnected(let id): return id
        default: return nil
        }
    }
}

/// Events that can trigger a state transition in the macOS agent.
public enum AgentTransportEvent: CustomStringConvertible, Sendable {
    /// A USB socket became ready (before identity is known).
    case usbConnectionArrived(deviceID: String?)
    /// The pending USB connection identified itself as a known paired device.
    case usbIdentityConfirmed(deviceID: String)
    /// The pending USB connection timed out without identifying.
    case usbIdentityTimeout
    /// The active or pending USB connection dropped.
    case usbDisconnected
    /// An AWDL connection arrived. `isPaired` reflects whether the Mac currently
    /// has a paired device identity stored.
    case awdlCandidateArrived(isPaired: Bool)
    /// A pending AWDL slot identified itself as a known paired device.
    case awdlIdentityConfirmed(deviceID: String, remainingSlots: Int)
    /// A pending AWDL slot timed out. `remainingSlots` = pool count after removal.
    case awdlIdentityTimeout(remainingSlots: Int)
    /// The active AWDL connection dropped.
    case awdlDisconnected
    /// An AWDL pairing handshake completed successfully.
    case pairingCompleted(deviceID: String)
    /// An AWDL pairing handshake failed or was rejected.
    case pairingFailed
    /// The system secure input state changed.
    case secureInputChanged(active: Bool)
    /// The heartbeat keep-alive timed out without a response.
    case heartbeatTimeout
    /// A heartbeat acknowledgement was received.
    case heartbeatAck

    public var description: String {
        switch self {
        case .usbConnectionArrived(let id): return "usbConnectionArrived(\(id ?? "unknown"))"
        case .usbIdentityConfirmed(let id): return "usbIdentityConfirmed(\(id))"
        case .usbIdentityTimeout:          return "usbIdentityTimeout"
        case .usbDisconnected:             return "usbDisconnected"
        case .awdlCandidateArrived(let p): return "awdlCandidateArrived(isPaired:\(p))"
        case .awdlIdentityConfirmed(let id, let n): return "awdlIdentityConfirmed(\(id), remaining:\(n))"
        case .awdlIdentityTimeout(let n):  return "awdlIdentityTimeout(remaining:\(n))"
        case .awdlDisconnected:            return "awdlDisconnected"
        case .pairingCompleted(let id):    return "pairingCompleted(\(id))"
        case .pairingFailed:               return "pairingFailed"
        case .secureInputChanged(let a):   return "secureInputChanged(\(a))"
        case .heartbeatTimeout:            return "heartbeatTimeout"
        case .heartbeatAck:                return "heartbeatAck"
        }
    }
}

/// Side effects returned by the macOS agent transition function.
///
/// TransportManager executes these after updating its state — the FSM itself
/// never touches network connections, timers, or UI directly.
public enum AgentTransportSideEffect: CustomStringConvertible, Sendable {
    /// Start the 2-second identity timer for the pending USB connection.
    case startUSBIdentityTimer
    /// Cancel the pending USB identity timer (if active).
    case cancelUSBIdentityTimer
    /// Start the 3-second identity timer for the AWDL slot at `slotIndex`.
    case startAWDLIdentityTimer(slotIndex: Int)
    /// Cancel the AWDL identity timer for the slot at `slotIndex`.
    case cancelAWDLIdentityTimer(slotIndex: Int)
    /// Promote the given transport to the active session (assign decoder/encoder, start receive loop).
    case promoteToActive(transport: ConnectionKind)
    /// Close the connection for the given transport.
    case closeConnection(transport: ConnectionKind)
    /// Close and remove all pending AWDL slots from the pool.
    case clearPendingAWDLPool
    /// Update the menu bar status indicator to reflect the new state.
    case updateStatusBar(state: AgentTransportState)
    /// Append a human-readable description to the event log.
    case logEvent(description: String)
    /// Send a pairingInvalidated message on the active connection.
    case sendPairingInvalidated
    /// Start polling IsSecureEventInputEnabled at 0.5s intervals.
    case startSecureInputPolling
    /// Stop the secure input polling timer.
    case stopSecureInputPolling
    /// Release all held modifier keys via CGEvent.
    case releaseModifiers

    public var description: String {
        switch self {
        case .startUSBIdentityTimer:         return "startUSBIdentityTimer"
        case .cancelUSBIdentityTimer:        return "cancelUSBIdentityTimer"
        case .startAWDLIdentityTimer(let i): return "startAWDLIdentityTimer(\(i))"
        case .cancelAWDLIdentityTimer(let i):return "cancelAWDLIdentityTimer(\(i))"
        case .promoteToActive(let t):        return "promoteToActive(\(t))"
        case .closeConnection(let t):        return "closeConnection(\(t))"
        case .clearPendingAWDLPool:          return "clearPendingAWDLPool"
        case .updateStatusBar(let s):        return "updateStatusBar(\(s))"
        case .logEvent(let d):               return "logEvent(\(d))"
        case .sendPairingInvalidated:        return "sendPairingInvalidated"
        case .startSecureInputPolling:       return "startSecureInputPolling"
        case .stopSecureInputPolling:        return "stopSecureInputPolling"
        case .releaseModifiers:              return "releaseModifiers"
        }
    }
}

// MARK: - macOS Agent Pure Transition Function

/// Pure state transition function for the macOS agent transport.
///
/// This is a free function (not a method) so it can be tested in isolation without
/// any TransportManager instance. All side effects are returned as an array — the
/// caller (TransportManager) executes them after updating state.
///
/// For illegal or no-op transitions, returns the current state unchanged with an
/// empty side-effect list.
public func agentTransportTransition(
    from state: AgentTransportState,
    on event: AgentTransportEvent
) -> (AgentTransportState, [AgentTransportSideEffect]) {

    switch event {

    // MARK: - USB Arrived

    case .usbConnectionArrived(let deviceID):
        switch state {
        case .disconnected:
            let newState = AgentTransportState.pendingUSBIdentity(deviceID: deviceID)
            return (newState, [
                .startUSBIdentityTimer,
                .updateStatusBar(state: newState),
                .logEvent(description: "USB connected while disconnected; waiting for identity")
            ])

        case .awdlConnected:
            // USB arrived while AWDL is active — start identity check; do NOT disrupt AWDL yet.
            let newState = AgentTransportState.pendingUSBIdentity(deviceID: deviceID)
            return (newState, [
                .startUSBIdentityTimer,
                .logEvent(description: "USB connected while AWDL active; waiting for USB identity")
            ])

        case .pendingAWDLPool(let count):
            // USB arrived while AWDL pool is pending — clear pool and wait for USB identity.
            let newState = AgentTransportState.pendingUSBIdentity(deviceID: deviceID)
            return (newState, [
                .clearPendingAWDLPool,
                .startUSBIdentityTimer,
                .updateStatusBar(state: newState),
                .logEvent(description: "USB connected while AWDL pool pending (\(count) slots cleared); waiting for USB identity")
            ])

        case .pairingAWDL:
            // USB arrived while AWDL pairing channel open — close AWDL pairing and wait for USB identity.
            let newState = AgentTransportState.pendingUSBIdentity(deviceID: deviceID)
            return (newState, [
                .closeConnection(transport: .awdl),
                .startUSBIdentityTimer,
                .updateStatusBar(state: newState),
                .logEvent(description: "USB connected while AWDL pairing channel open; closed AWDL and waiting for USB identity")
            ])

        case .usbConnected:
            return (state, [.logEvent(description: "Ignoring duplicate USB connection")])

        case .pendingUSBIdentity:
            return (state, [.logEvent(description: "USB arrived while identity pending; ignoring duplicate")])
        }

    // MARK: - USB Identity Confirmed

    case .usbIdentityConfirmed(let deviceID):
        switch state {
        case .pendingUSBIdentity:
            let newState = AgentTransportState.usbConnected(deviceID: deviceID)
            return (newState, [
                .cancelUSBIdentityTimer,
                .clearPendingAWDLPool,
                .closeConnection(transport: .awdl),
                .promoteToActive(transport: .usb),
                .updateStatusBar(state: newState),
                .startSecureInputPolling,
                .logEvent(description: "USB identity confirmed for \(deviceID); USB session active")
            ])

        case .awdlConnected(let awdlID):
            // USB confirmed for paired device — check if it's the same device as AWDL.
            if awdlID == deviceID {
                // Same device: promote USB over AWDL.
                let newState = AgentTransportState.usbConnected(deviceID: deviceID)
                return (newState, [
                    .cancelUSBIdentityTimer,
                    .closeConnection(transport: .awdl),
                    .clearPendingAWDLPool,
                    .promoteToActive(transport: .usb),
                    .updateStatusBar(state: newState),
                    .logEvent(description: "USB identity confirmed for \(deviceID); promoted over AWDL")
                ])
            } else {
                // Different device: reject USB (INV-007).
                return (state, [
                    .cancelUSBIdentityTimer,
                    .closeConnection(transport: .usb),
                    .sendPairingInvalidated,
                    .logEvent(description: "USB identity from non-matching device \(deviceID) rejected; AWDL session preserved")
                ])
            }

        default:
            // Identity confirmed while not in a pending state — ignore.
            return (state, [
                .cancelUSBIdentityTimer,
                .logEvent(description: "USB identity confirmed in unexpected state \(state); ignored")
            ])
        }

    // MARK: - USB Identity Timeout

    case .usbIdentityTimeout:
        return (.disconnected, [
            .cancelUSBIdentityTimer,
            .closeConnection(transport: .usb),
            .updateStatusBar(state: .disconnected),
            .logEvent(description: "USB identity timeout; rotating to next device")
        ])

    // MARK: - USB Disconnected

    case .usbDisconnected:
        switch state {
        case .usbConnected:
            return (.disconnected, [
                .updateStatusBar(state: .disconnected),
                .stopSecureInputPolling,
                .releaseModifiers,
                .logEvent(description: "USB disconnected; session ended")
            ])
        case .pendingUSBIdentity:
            return (.disconnected, [
                .cancelUSBIdentityTimer,
                .updateStatusBar(state: .disconnected),
                .logEvent(description: "Pending USB connection dropped before identity")
            ])
        default:
            return (state, [.logEvent(description: "USB disconnected in state \(state); no action")])
        }

    // MARK: - AWDL Candidate Arrived

    case .awdlCandidateArrived(let isPaired):
        switch state {
        case .disconnected:
            if isPaired {
                return (.pendingAWDLPool(slotCount: 1), [
                    .logEvent(description: "AWDL candidate arrived while disconnected (paired); added to pending pool")
                ])
            } else {
                return (.pairingAWDL, [
                    .logEvent(description: "AWDL candidate arrived while disconnected (unpaired); pairing channel open")
                ])
            }

        case .pendingAWDLPool(let count):
            if isPaired {
                return (.pendingAWDLPool(slotCount: count + 1), [
                    .logEvent(description: "Additional AWDL candidate added to pool (\(count + 1) pending)")
                ])
            } else {
                return (state, [
                    .closeConnection(transport: .awdl),
                    .logEvent(description: "Unpaired AWDL candidate rejected while pending pool active")
                ])
            }

        case .pairingAWDL:
            // Replace stale pairing channel.
            return (.pairingAWDL, [
                .closeConnection(transport: .awdl),
                .logEvent(description: "Replaced stale AWDL pairing channel with new candidate")
            ])

        case .awdlConnected:
            if isPaired {
                // Probe new candidate in the pending pool while session stays active.
                return (state, [
                    .logEvent(description: "Additional AWDL candidate arrived while AWDL active; probing in pending pool")
                ])
            } else {
                return (state, [
                    .closeConnection(transport: .awdl),
                    .logEvent(description: "Unpaired AWDL candidate rejected while AWDL active")
                ])
            }

        case .usbConnected:
            return (state, [
                .closeConnection(transport: .awdl),
                .logEvent(description: "AWDL candidate rejected while USB is primary")
            ])

        case .pendingUSBIdentity:
            if isPaired {
                // Allow into pool even while USB identity is pending.
                return (state, [
                    .logEvent(description: "AWDL candidate arrived while USB identity pending; added to pool")
                ])
            } else {
                return (state, [
                    .closeConnection(transport: .awdl),
                    .logEvent(description: "Unpaired AWDL candidate rejected while USB identity pending")
                ])
            }
        }

    // MARK: - AWDL Identity Confirmed (from pending pool)

    case .awdlIdentityConfirmed(let deviceID, _):
        switch state {
        case .pendingAWDLPool:
            let newState = AgentTransportState.awdlConnected(deviceID: deviceID)
            return (newState, [
                .clearPendingAWDLPool,
                .promoteToActive(transport: .awdl),
                .updateStatusBar(state: newState),
                .startSecureInputPolling,
                .logEvent(description: "AWDL identity confirmed for \(deviceID); AWDL session active")
            ])

        case .awdlConnected:
            // New slot confirmed identity while another AWDL session is active — replace.
            let newState = AgentTransportState.awdlConnected(deviceID: deviceID)
            return (newState, [
                .clearPendingAWDLPool,
                .closeConnection(transport: .awdl),
                .promoteToActive(transport: .awdl),
                .updateStatusBar(state: newState),
                .logEvent(description: "AWDL session replaced by new confirmed slot for \(deviceID)")
            ])

        default:
            return (state, [.logEvent(description: "AWDL identity confirmed in unexpected state \(state); ignored")])
        }

    // MARK: - AWDL Identity Timeout

    case .awdlIdentityTimeout(let remaining):
        switch state {
        case .pendingAWDLPool:
            if remaining == 0 {
                return (.disconnected, [
                    .updateStatusBar(state: .disconnected),
                    .logEvent(description: "Last AWDL pending slot timed out; disconnected")
                ])
            } else {
                return (.pendingAWDLPool(slotCount: remaining), [
                    .logEvent(description: "AWDL slot timed out; \(remaining) slots remaining in pool")
                ])
            }
        case .awdlConnected:
            // Timeout on a probe slot while session active — ignore.
            return (state, [.logEvent(description: "AWDL probe slot timed out; active session unaffected")])
        default:
            return (state, [.logEvent(description: "AWDL identity timeout in state \(state); ignored")])
        }

    // MARK: - AWDL Disconnected

    case .awdlDisconnected:
        switch state {
        case .awdlConnected:
            return (.disconnected, [
                .updateStatusBar(state: .disconnected),
                .stopSecureInputPolling,
                .releaseModifiers,
                .logEvent(description: "AWDL disconnected; session ended")
            ])
        case .pairingAWDL:
            return (.disconnected, [
                .updateStatusBar(state: .disconnected),
                .logEvent(description: "AWDL pairing channel dropped")
            ])
        case .pendingAWDLPool(let count):
            let remaining = max(0, count - 1)
            if remaining == 0 {
                return (.disconnected, [
                    .updateStatusBar(state: .disconnected),
                    .logEvent(description: "Last pending AWDL slot dropped; disconnected")
                ])
            }
            return (.pendingAWDLPool(slotCount: remaining), [
                .logEvent(description: "Pending AWDL slot dropped; \(remaining) remaining")
            ])
        default:
            return (state, [.logEvent(description: "AWDL disconnected in state \(state); no action")])
        }

    // MARK: - Pairing Completed

    case .pairingCompleted(let deviceID):
        switch state {
        case .pairingAWDL:
            let newState = AgentTransportState.awdlConnected(deviceID: deviceID)
            return (newState, [
                .promoteToActive(transport: .awdl),
                .updateStatusBar(state: newState),
                .startSecureInputPolling,
                .logEvent(description: "AWDL pairing completed for \(deviceID); session active")
            ])
        default:
            return (state, [.logEvent(description: "Pairing completed in unexpected state \(state); ignored")])
        }

    // MARK: - Pairing Failed

    case .pairingFailed:
        switch state {
        case .pairingAWDL:
            return (.disconnected, [
                .closeConnection(transport: .awdl),
                .updateStatusBar(state: .disconnected),
                .logEvent(description: "AWDL pairing failed; disconnected")
            ])
        default:
            return (state, [.logEvent(description: "Pairing failed in state \(state); no action")])
        }

    // MARK: - Secure Input Changed

    case .secureInputChanged:
        // Secure input changes are handled by the caller as a send — no state change.
        return (state, [])

    // MARK: - Heartbeat

    case .heartbeatTimeout:
        switch state {
        case .usbConnected:
            return (.disconnected, [
                .updateStatusBar(state: .disconnected),
                .stopSecureInputPolling,
                .releaseModifiers,
                .logEvent(description: "USB heartbeat timed out; disconnected")
            ])
        case .awdlConnected:
            return (.disconnected, [
                .closeConnection(transport: .awdl),
                .updateStatusBar(state: .disconnected),
                .stopSecureInputPolling,
                .releaseModifiers,
                .logEvent(description: "AWDL heartbeat timed out; disconnected")
            ])
        default:
            return (state, [.logEvent(description: "Heartbeat timeout in state \(state); ignored")])
        }

    case .heartbeatAck:
        // Heartbeat ack is informational; no state change on macOS side.
        return (state, [])
    }
}

// MARK: - iOS FSM

/// Explicit transport state for the iOS Keyd app.
///
/// Absorbs the boolean flags that previously shadowed the State enum:
/// - `awdlEnabledForCurrentSession` → part of `.disconnected` and `.connecting` associated values
/// - `awaitingAWDLHeartbeatAck` → part of `.awdlConnected`
/// - `suppressAWDLStatusUntilPaired` → handled by transition logic (suppress until pairingCompleted)
/// - App lifecycle → `backgroundSuspended` state
public enum iOSTransportState: Equatable, CustomStringConvertible, Sendable {
    /// No active connection. `awdlEnabled` tracks whether AWDL is available for this session.
    case disconnected(awdlEnabled: Bool)

    /// Attempting to connect via the given transport.
    case connecting(transport: iOSConnectionKind, awdlEnabled: Bool)

    /// USB session confirmed and active.
    case usbConnected

    /// AWDL session confirmed and active.
    /// `awaitingHeartbeatAck` is true after sending a heartbeat, until the ack arrives.
    case awdlConnected(awaitingHeartbeatAck: Bool)

    /// App has entered background; background task is running.
    /// `previousTransport` indicates which transport was active before backgrounding.
    case backgroundSuspended(previousTransport: iOSConnectionKind?)

    public var description: String {
        switch self {
        case .disconnected(let awdl):
            return "disconnected(awdlEnabled:\(awdl))"
        case .connecting(let t, let awdl):
            return "connecting(\(t), awdlEnabled:\(awdl))"
        case .usbConnected:
            return "usbConnected"
        case .awdlConnected(let waiting):
            return "awdlConnected(awaitingHeartbeatAck:\(waiting))"
        case .backgroundSuspended(let t):
            return "backgroundSuspended(previousTransport:\(t.map { "\($0)" } ?? "nil"))"
        }
    }

    /// Whether the iOS device is currently in a confirmed connected session.
    public var isConnected: Bool {
        switch self {
        case .usbConnected, .awdlConnected: return true
        default: return false
        }
    }

    /// Whether AWDL is enabled for this session (for states that carry this flag).
    public var awdlEnabled: Bool {
        switch self {
        case .disconnected(let a): return a
        case .connecting(_, let a): return a
        default: return true // Connected states implicitly have AWDL available
        }
    }
}

/// Events that trigger state transitions in the iOS transport.
public enum iOSTransportEvent: CustomStringConvertible, Sendable {
    /// USB tunnel accepted and ready for communication.
    case usbReady
    /// USB tunnel closed or dropped.
    case usbDisconnected
    /// AWDL connection established and ready.
    case awdlReady
    /// AWDL connection closed or dropped.
    case awdlDisconnected
    /// Heartbeat acknowledgement received from Mac.
    case heartbeatAck
    /// Heartbeat timed out without ack — connection may be dead.
    case heartbeatTimeout
    /// Pairing handshake completed successfully.
    case pairingCompleted
    /// Pairing handshake failed or was rejected.
    case pairingFailed
    /// App entered background (scenePhase == .background).
    case appBackgrounded
    /// App returned to foreground (scenePhase == .active).
    case appForegrounded
    /// Background task expiration handler fired — must stop immediately.
    case backgroundTaskExpiring
    /// Secure input state changed on Mac.
    case secureInputChanged(active: Bool)
    /// User or system requested a reconnect attempt.
    case retryRequested

    public var description: String {
        switch self {
        case .usbReady:                    return "usbReady"
        case .usbDisconnected:             return "usbDisconnected"
        case .awdlReady:                   return "awdlReady"
        case .awdlDisconnected:            return "awdlDisconnected"
        case .heartbeatAck:                return "heartbeatAck"
        case .heartbeatTimeout:            return "heartbeatTimeout"
        case .pairingCompleted:            return "pairingCompleted"
        case .pairingFailed:               return "pairingFailed"
        case .appBackgrounded:             return "appBackgrounded"
        case .appForegrounded:             return "appForegrounded"
        case .backgroundTaskExpiring:      return "backgroundTaskExpiring"
        case .secureInputChanged(let a):   return "secureInputChanged(\(a))"
        case .retryRequested:              return "retryRequested"
        }
    }
}

/// Side effects returned by the iOS transition function.
///
/// TransportManager executes these after updating its FSM state.
public enum iOSTransportSideEffect: CustomStringConvertible, Sendable {
    /// Start the AWDL heartbeat loop (send heartbeat every 4s, expect ack within 2s).
    case startHeartbeat
    /// Stop the heartbeat loop.
    case stopHeartbeat
    /// Update the Dynamic Island Live Activity to reflect the new state.
    case updateLiveActivity(state: iOSTransportState)
    /// Resume any pending `connectionReadyContinuation`.
    case resolveConnectionContinuation
    /// Resume any pending `pairingResponseContinuation` with success.
    case resolvePairingContinuation
    /// Call `UIApplication.shared.beginBackgroundTask`.
    case beginBackgroundTask
    /// Call `UIApplication.shared.endBackgroundTask`.
    case endBackgroundTask
    /// Close all active transport connections.
    case closeConnections
    /// Start a reconnect attempt (fast reconnect if `skipBackoff` is true).
    case startReconnect(skipBackoff: Bool)
    /// Send a sessionResume message to the Mac.
    case sendSessionResume
    /// Enable the idle timer disable flag (prevent screen sleep during active session).
    case disableIdleTimer
    /// Re-enable the idle timer (allow screen sleep when not in active session).
    case enableIdleTimer
    /// Log a human-readable event description.
    case logEvent(description: String)

    public var description: String {
        switch self {
        case .startHeartbeat:                  return "startHeartbeat"
        case .stopHeartbeat:                   return "stopHeartbeat"
        case .updateLiveActivity(let s):       return "updateLiveActivity(\(s))"
        case .resolveConnectionContinuation:   return "resolveConnectionContinuation"
        case .resolvePairingContinuation:      return "resolvePairingContinuation"
        case .beginBackgroundTask:             return "beginBackgroundTask"
        case .endBackgroundTask:               return "endBackgroundTask"
        case .closeConnections:                return "closeConnections"
        case .startReconnect(let skip):        return "startReconnect(skipBackoff:\(skip))"
        case .sendSessionResume:               return "sendSessionResume"
        case .disableIdleTimer:                return "disableIdleTimer"
        case .enableIdleTimer:                 return "enableIdleTimer"
        case .logEvent(let d):                 return "logEvent(\(d))"
        }
    }
}

// MARK: - iOS Pure Transition Function

/// Pure state transition function for the iOS transport.
///
/// Free function (not a method) — testable without any TransportManager instance.
/// Returns the next state and side effects to execute. For illegal or no-op transitions,
/// returns the current state unchanged with an empty side-effect list.
public func iOSTransportTransition(
    from state: iOSTransportState,
    on event: iOSTransportEvent
) -> (iOSTransportState, [iOSTransportSideEffect]) {

    switch event {

    // MARK: - USB Ready

    case .usbReady:
        switch state {
        case .connecting:
            return (.usbConnected, [
                .disableIdleTimer,
                .resolveConnectionContinuation,
                .sendSessionResume,
                .updateLiveActivity(state: .usbConnected),
                .logEvent(description: "USB connected")
            ])
        case .disconnected:
            // USB tunnel arrived while disconnected (late arrival after connect timeout).
            return (.usbConnected, [
                .disableIdleTimer,
                .resolveConnectionContinuation,
                .sendSessionResume,
                .updateLiveActivity(state: .usbConnected),
                .logEvent(description: "USB tunnel arrived (was disconnected)")
            ])
        case .awdlConnected:
            // USB arrived while AWDL is active — promote to USB.
            return (.usbConnected, [
                .stopHeartbeat,
                .sendSessionResume,
                .updateLiveActivity(state: .usbConnected),
                .logEvent(description: "USB reconnected; AWDL session replaced")
            ])
        case .usbConnected:
            return (state, [.logEvent(description: "Duplicate USB ready event; ignored")])
        default:
            return (state, [.logEvent(description: "USB ready in state \(state); ignored")])
        }

    // MARK: - USB Disconnected

    case .usbDisconnected:
        switch state {
        case .usbConnected:
            // On USB drop, attempt fresh AWDL connection.
            return (.disconnected(awdlEnabled: true), [
                .enableIdleTimer,
                .updateLiveActivity(state: .disconnected(awdlEnabled: true)),
                .startReconnect(skipBackoff: false),
                .logEvent(description: "USB disconnected; attempting AWDL handoff")
            ])
        case .connecting(let t, let awdl) where t == .usb:
            if awdl {
                return (.connecting(transport: .awdl, awdlEnabled: true), [
                    .logEvent(description: "USB unavailable; falling back to AWDL")
                ])
            } else {
                return (.disconnected(awdlEnabled: false), [
                    .enableIdleTimer,
                    .updateLiveActivity(state: .disconnected(awdlEnabled: false)),
                    .logEvent(description: "USB unavailable (AWDL disabled); disconnected")
                ])
            }
        default:
            return (state, [.logEvent(description: "USB disconnected in state \(state); ignored")])
        }

    // MARK: - AWDL Ready

    case .awdlReady:
        switch state {
        case .connecting(_, let awdl) where awdl:
            return (.awdlConnected(awaitingHeartbeatAck: false), [
                .disableIdleTimer,
                .resolveConnectionContinuation,
                .sendSessionResume,
                .startHeartbeat,
                .updateLiveActivity(state: .awdlConnected(awaitingHeartbeatAck: false)),
                .logEvent(description: "AWDL connected")
            ])
        case .disconnected(let awdl) where awdl:
            return (.awdlConnected(awaitingHeartbeatAck: false), [
                .disableIdleTimer,
                .resolveConnectionContinuation,
                .sendSessionResume,
                .startHeartbeat,
                .updateLiveActivity(state: .awdlConnected(awaitingHeartbeatAck: false)),
                .logEvent(description: "AWDL connected (was disconnected)")
            ])
        case .awdlConnected:
            return (state, [.logEvent(description: "Duplicate AWDL ready event; ignored")])
        case .usbConnected:
            return (state, [.logEvent(description: "AWDL ready while USB is primary; AWDL discarded")])
        default:
            return (state, [.logEvent(description: "AWDL ready in state \(state); ignored (AWDL disabled or unexpected)")])
        }

    // MARK: - AWDL Disconnected

    case .awdlDisconnected:
        switch state {
        case .awdlConnected:
            return (.disconnected(awdlEnabled: true), [
                .stopHeartbeat,
                .enableIdleTimer,
                .updateLiveActivity(state: .disconnected(awdlEnabled: true)),
                .startReconnect(skipBackoff: false),
                .logEvent(description: "AWDL disconnected")
            ])
        case .connecting(let t, let awdl) where t == .awdl:
            if awdl {
                return (.disconnected(awdlEnabled: true), [
                    .enableIdleTimer,
                    .updateLiveActivity(state: .disconnected(awdlEnabled: true)),
                    .startReconnect(skipBackoff: false),
                    .logEvent(description: "AWDL disconnected during connect; will retry")
                ])
            } else {
                return (.disconnected(awdlEnabled: false), [
                    .enableIdleTimer,
                    .updateLiveActivity(state: .disconnected(awdlEnabled: false)),
                    .logEvent(description: "AWDL disconnected (disabled for session)")
                ])
            }
        default:
            return (state, [.logEvent(description: "AWDL disconnected in state \(state); ignored")])
        }

    // MARK: - Heartbeat

    case .heartbeatAck:
        switch state {
        case .awdlConnected:
            // Successful ack — clear the awaiting flag.
            return (.awdlConnected(awaitingHeartbeatAck: false), [
                .logEvent(description: "AWDL heartbeat ack received")
            ])
        default:
            return (state, [.logEvent(description: "Heartbeat ack in state \(state); ignored")])
        }

    case .heartbeatTimeout:
        switch state {
        case .awdlConnected:
            return (.disconnected(awdlEnabled: true), [
                .stopHeartbeat,
                .enableIdleTimer,
                .closeConnections,
                .updateLiveActivity(state: .disconnected(awdlEnabled: true)),
                .startReconnect(skipBackoff: false),
                .logEvent(description: "AWDL heartbeat timed out; reconnecting")
            ])
        default:
            return (state, [.logEvent(description: "Heartbeat timeout in state \(state); ignored")])
        }

    // MARK: - Pairing

    case .pairingCompleted:
        switch state {
        case .connecting:
            return (.usbConnected, [
                .disableIdleTimer,
                .resolveConnectionContinuation,
                .resolvePairingContinuation,
                .sendSessionResume,
                .updateLiveActivity(state: .usbConnected),
                .logEvent(description: "Pairing completed; session active")
            ])
        case .awdlConnected:
            return (.awdlConnected(awaitingHeartbeatAck: false), [
                .resolvePairingContinuation,
                .sendSessionResume,
                .logEvent(description: "Pairing completed while AWDL active")
            ])
        case .disconnected:
            return (.connecting(transport: .awdl, awdlEnabled: true), [
                .resolvePairingContinuation,
                .logEvent(description: "Pairing completed; reconnecting")
            ])
        default:
            return (state, [.logEvent(description: "Pairing completed in state \(state); ignored")])
        }

    case .pairingFailed:
        return (state, [.logEvent(description: "Pairing failed in state \(state)")])

    // MARK: - App Lifecycle

    case .appBackgrounded:
        switch state {
        case .usbConnected:
            return (.backgroundSuspended(previousTransport: .usb), [
                .beginBackgroundTask,
                .logEvent(description: "App backgrounded while USB connected; background task started")
            ])
        case .awdlConnected:
            return (.backgroundSuspended(previousTransport: .awdl), [
                .beginBackgroundTask,
                .logEvent(description: "App backgrounded while AWDL connected; background task started")
            ])
        case .connecting:
            return (.backgroundSuspended(previousTransport: nil), [
                .beginBackgroundTask,
                .logEvent(description: "App backgrounded while connecting; background task started")
            ])
        case .disconnected:
            return (.backgroundSuspended(previousTransport: nil), [
                .beginBackgroundTask,
                .logEvent(description: "App backgrounded while disconnected; background task started")
            ])
        case .backgroundSuspended:
            return (state, [.logEvent(description: "Duplicate background event; ignored")])
        }

    case .appForegrounded:
        switch state {
        case .backgroundSuspended(let prev):
            let hadSession = prev != nil
            let awdl = prev != .usb
            let connectingState = iOSTransportState.connecting(transport: prev ?? .usb, awdlEnabled: awdl)
            return (connectingState, [
                .endBackgroundTask,
                .startReconnect(skipBackoff: hadSession),
                .logEvent(description: "App foregrounded; fast reconnect (skipBackoff:\(hadSession))")
            ])
        default:
            return (state, [.logEvent(description: "Foregrounded in state \(state); no action needed")])
        }

    case .backgroundTaskExpiring:
        switch state {
        case .backgroundSuspended:
            return (.disconnected(awdlEnabled: true), [
                .closeConnections,
                .stopHeartbeat,
                .endBackgroundTask,
                .enableIdleTimer,
                .updateLiveActivity(state: .disconnected(awdlEnabled: true)),
                .logEvent(description: "Background task expiring; connections closed gracefully")
            ])
        default:
            return (state, [.logEvent(description: "Background task expiring in state \(state); ignored")])
        }

    // MARK: - Secure Input

    case .secureInputChanged:
        // Secure input change is purely informational — no transport state change.
        return (state, [])

    // MARK: - Retry Requested

    case .retryRequested:
        switch state {
        case .disconnected(let awdl):
            return (.connecting(transport: awdl ? .awdl : .usb, awdlEnabled: awdl), [
                .startReconnect(skipBackoff: true),
                .logEvent(description: "Retry requested; reconnecting")
            ])
        case .usbConnected:
            return (state, [.logEvent(description: "Retry requested while already connected; ignored")])
        case .awdlConnected:
            return (state, [.logEvent(description: "Retry requested while already connected; ignored")])
        default:
            return (state, [.logEvent(description: "Retry requested in state \(state); ignored")])
        }
    }
}
