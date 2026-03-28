import Foundation

// MARK: - Transport States

/// Transport connection state. Mirrors TransportFSM.h/TransportFSM.c exactly.
enum TransportState: String, CustomStringConvertible {
    case idle
    case usbNCM
    case wifi
    case awdl
    case disconnected

    var description: String { rawValue }
}

// MARK: - Transport Events

/// Events that trigger transport state transitions.
enum TransportEvent: String, CustomStringConvertible {
    case wiredAppeared
    case wiredDisappeared
    case wifiAvailable
    case wifiUnavailable
    case awdlAvailable
    case awdlUnavailable
    case connected
    case disconnected
    case error

    var description: String { rawValue }
}

// MARK: - Transport Effects

/// Side effects to execute after a state transition.
/// The FSM returns effects; the caller executes them.
enum TransportEffect: String, CustomStringConvertible {
    case bindUSBNCM
    case connectWiFi
    case connectAWDL
    case disconnectCurrent
    case switchEncodeLZ4
    case switchEncodeHEVC
    case notifyTransportChange

    var description: String { rawValue }
}

// MARK: - Transport FSM

/// Pure state machine for transport layer transitions.
///
/// Pattern-copied from keyd v1.0 TransportStateMachine.swift but adapted
/// for the USB NCM > Wi-Fi > AWDL cascade with encode mode switching.
///
/// This is a pure function with no side effects. The caller is responsible
/// for executing the returned effects.
enum TransportFSM {

    /// Compute the next state and side effects for a given state + event.
    /// This function is pure -- it performs no side effects.
    static func transition(from current: TransportState,
                           on event: TransportEvent) -> (state: TransportState,
                                                         effects: [TransportEffect]) {
        // Priority rule: WIRED_APPEARED from ANY state promotes to USB_NCM
        if event == .wiredAppeared {
            if current == .usbNCM {
                return (current, [])
            }
            if current == .idle || current == .disconnected {
                return (.usbNCM, [.bindUSBNCM, .switchEncodeLZ4, .notifyTransportChange])
            }
            // From WiFi or AWDL: disconnect current, then bind USB
            return (.usbNCM, [.disconnectCurrent, .bindUSBNCM, .switchEncodeLZ4, .notifyTransportChange])
        }

        // Per-state transitions
        switch current {
        case .idle:
            switch event {
            case .wifiAvailable:
                return (.wifi, [.connectWiFi, .switchEncodeHEVC, .notifyTransportChange])
            case .awdlAvailable:
                return (.awdl, [.connectAWDL, .switchEncodeHEVC, .notifyTransportChange])
            default:
                return (current, [])
            }

        case .usbNCM:
            switch event {
            case .wiredDisappeared, .error, .disconnected:
                return (.disconnected, [.disconnectCurrent, .notifyTransportChange])
            default:
                return (current, [])
            }

        case .wifi:
            switch event {
            case .wifiUnavailable, .error, .disconnected:
                return (.disconnected, [.disconnectCurrent, .notifyTransportChange])
            case .awdlAvailable:
                // Stay on Wi-Fi -- Wi-Fi is preferred over AWDL
                return (current, [])
            default:
                return (current, [])
            }

        case .awdl:
            switch event {
            case .wifiAvailable:
                // Promote from AWDL to Wi-Fi
                return (.wifi, [.disconnectCurrent, .connectWiFi, .notifyTransportChange])
            case .awdlUnavailable, .error, .disconnected:
                return (.disconnected, [.disconnectCurrent, .notifyTransportChange])
            default:
                return (current, [])
            }

        case .disconnected:
            switch event {
            case .wifiAvailable:
                return (.wifi, [.connectWiFi, .switchEncodeHEVC, .notifyTransportChange])
            case .awdlAvailable:
                return (.awdl, [.connectAWDL, .switchEncodeHEVC, .notifyTransportChange])
            default:
                return (current, [])
            }
        }
    }
}
