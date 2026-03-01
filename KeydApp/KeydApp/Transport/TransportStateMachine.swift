import Foundation

// MARK: - Shared Type

/// Transport connection kind for the iOS FSM.
enum iOSConnectionKind: CustomStringConvertible, Equatable {
    case usb, awdl
    var description: String { self == .usb ? "USB" : "AWDL" }
}

// MARK: - State

/// Explicit transport state for the iOS Keyd app.
///
/// Absorbs the boolean flags that previously shadowed the State enum:
/// - `awdlEnabledForCurrentSession` → part of `.disconnected` and `.connecting` associated values
/// - `awaitingAWDLHeartbeatAck` → part of `.awdlConnected`
/// - `suppressAWDLStatusUntilPaired` → handled by transition logic (suppress until pairingCompleted)
/// - App lifecycle → `backgroundSuspended` state
enum iOSTransportState: Equatable, CustomStringConvertible {
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

    var description: String {
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
    var isConnected: Bool {
        switch self {
        case .usbConnected, .awdlConnected: return true
        default: return false
        }
    }

    /// Whether AWDL is enabled for this session (for states that carry this flag).
    var awdlEnabled: Bool {
        switch self {
        case .disconnected(let a): return a
        case .connecting(_, let a): return a
        default: return true // Connected states implicitly have AWDL available
        }
    }
}

// MARK: - Event

/// Events that trigger state transitions in the iOS transport.
enum iOSTransportEvent: CustomStringConvertible {
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

    var description: String {
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

// MARK: - SideEffect

/// Side effects returned by the iOS transition function.
///
/// TransportManager executes these after updating its FSM state.
enum iOSTransportSideEffect: CustomStringConvertible {
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

    var description: String {
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

// MARK: - Pure Transition Function

/// Pure state transition function for the iOS transport.
///
/// Free function (not a method) — testable without any TransportManager instance.
/// Returns the next state and side effects to execute. For illegal or no-op transitions,
/// returns the current state unchanged with an empty side-effect list.
func iOSTransportTransition(
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
