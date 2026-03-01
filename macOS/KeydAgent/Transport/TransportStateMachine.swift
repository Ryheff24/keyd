import Foundation

// MARK: - State

/// Explicit transport state for the macOS agent.
///
/// Every legal state is an enum case — no boolean flags or optional-as-state patterns.
/// Connection references (NWConnection, decoder, encoder) are NOT part of this enum;
/// they live in TransportManager's ConnectionResources alongside the FSM state.
enum AgentTransportState: Equatable, CustomStringConvertible {
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

    var description: String {
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
    var activeDeviceID: String? {
        switch self {
        case .usbConnected(let id): return id
        case .awdlConnected(let id): return id
        default: return nil
        }
    }
}

// MARK: - Event

/// Events that can trigger a state transition in the macOS agent.
enum AgentTransportEvent: CustomStringConvertible {
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

    var description: String {
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

// MARK: - SideEffect

/// Side effects returned by the transition function.
///
/// TransportManager executes these after updating its state — the FSM itself
/// never touches network connections, timers, or UI directly.
enum AgentTransportSideEffect: CustomStringConvertible {
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

    var description: String {
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

// MARK: - Pure Transition Function

/// Pure state transition function for the macOS agent transport.
///
/// This is a free function (not a method) so it can be tested in isolation without
/// any TransportManager instance. All side effects are returned as an array — the
/// caller (TransportManager) executes them after updating state.
///
/// For illegal or no-op transitions, returns the current state unchanged with an
/// empty side-effect list.
func agentTransportTransition(
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
