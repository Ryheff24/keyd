import Foundation
import SharedProtocol

// MARK: - TransportManager Testing Extensions
// These methods are used only by KeydIntegrationTests and IntegrationHarness.
// They are compiled into the main KeydApp target (not a test target) so that
// @testable import KeydApp can access them from XCTest.
// None of these are called in the production code paths.

extension TransportManager {

    // MARK: - One-Shot Message Listener

    /// Registers a one-shot message handler that fires once for the first incoming
    /// message matching the predicate, then removes itself.
    /// The handler is called on the MainActor.
    ///
    /// Implementation: uses NotificationCenter so the test harness does not need
    /// to modify the production handleIncomingMessage dispatch path.
    func registerTestMessageObserver(
        predicate: @escaping @MainActor (KeydMessage) -> Bool,
        handler: @escaping @MainActor (KeydMessage) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .keydTestIncomingMessage,
            object: self,
            queue: nil
        ) { [weak self] notification in
            guard self != nil,
                  let message = notification.userInfo?[TransportManager.testMessageKey] as? KeydMessage
            else { return }
            Task { @MainActor in
                if predicate(message) {
                    handler(message)
                }
            }
        }
    }

    /// Posts an incoming message to any registered test observers.
    /// Call this from handleIncomingMessage (or the test-specific hook below)
    /// so the harness can observe wire messages without modifying production dispatch.
    func notifyTestObservers(_ message: KeydMessage) {
        NotificationCenter.default.post(
            name: .keydTestIncomingMessage,
            object: self,
            userInfo: [TransportManager.testMessageKey: message]
        )
    }

    /// Sends a message using the production sendMessage path.
    /// Used by IntegrationHarness.reset() and sendAndAwait().
    func sendTestMessage(_ message: KeydMessage) {
        Task { @MainActor [weak self] in
            do {
                try await self?.sendMessage(message)
            } catch {
                // Test message send failure is non-fatal — harness will time out naturally
            }
        }
    }

    // MARK: - Pairing Token Injection

    /// Injects a pairing token for automated testing, bypassing QR scan.
    /// Constructs a PairingManager.QRPayload equivalent and initiates the pairing
    /// handshake using the existing completeQRPairing path.
    func injectTestPairingToken(_ payload: TestPairingPayload, pairingManager: PairingManager) async {
        // Encode payload as JSON (matching QRPayload format)
        let qrPayload = PairingManager.QRPayload(
            publicKeyBase64: payload.publicKeyBase64,
            port: payload.port,
            agentID: payload.agentID,
            version: payload.version
        )
        guard let qrData = try? JSONEncoder().encode(qrPayload),
              let qrString = String(data: qrData, encoding: .utf8)
        else { return }
        await pairingManager.completeQRPairing(qrString: qrString, transportManager: self)
    }

    // MARK: - Internal Keys

    static let testMessageKey = "message"
}

extension Notification.Name {
    static let keydTestIncomingMessage = Notification.Name("keyd.test.incomingMessage")
}
