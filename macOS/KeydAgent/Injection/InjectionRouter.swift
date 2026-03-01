import Foundation
import SharedProtocol

private let logger = KeydLogger(category: "InjectionRouter")

/// Routes decoded KeydMessages to the appropriate injector.
/// In Phase 1: KeyEvent and HotkeyEvent → CGEventInjector
/// In Phase 2: will also route to AXInjector for cursor/selection ops
final class InjectionRouter {
    private let cgInjector = CGEventInjector()
    private let axInjector = AXInjector()

    func route(_ message: KeydMessage) {
        switch message {
        case .keyEvent(let ev):
            cgInjector.injectCharacter(
                scalar: ev.unicodeScalar,
                keyDown: ev.keyDown,
                modifiers: ev.modifiers
            )

        case .hotkeyEvent(let ev):
            cgInjector.injectVirtualKey(
                virtualKeyCode: ev.virtualKeyCode,
                keyDown: ev.keyDown,
                modifiers: ev.modifiers
            )

        case .pairingRequest(let req):
            // Phase 1: Pairing handled in TransportManager/PairingManager (Plan 04)
            logger.warning("Received pairing request from device: \(req.deviceID)")

        case .sessionResume(let resume):
            logger.warning("Received session resume from device: \(resume.deviceID)")

        case .pairingResponse, .pairingInvalidated, .reflectState, .appStateChanged, .transportHeartbeat, .transportHeartbeatAck:
            // Mac→iOS messages — should not arrive at macOS side
            logger.warning("Unexpected Mac→iOS message received: \(message)")

        case .secureInputChanged:
            // Mac→iOS message — should not arrive at macOS side
            break

        case .testReset, .testResetAck:
            // Test harness control messages — handled by TransportManager, not routed to injection
            logger.warning("Test control message reached InjectionRouter (should be handled upstream): \(message)")
        }
    }

    /// Called on transport disconnect to release any stuck modifier keys (SHORT-11).
    func releaseModifiers() {
        cgInjector.releaseAllModifiers()
    }
}
