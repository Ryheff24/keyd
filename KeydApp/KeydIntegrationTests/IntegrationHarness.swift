import Foundation
import XCTest
import SharedProtocol
@testable import KeydApp

// MARK: - IntegrationHarness (XCTest target)

/// Async harness wrapping the app's live TransportManager for XCTest integration tests.
/// Reads TransportManager and PairingManager from TransportManagerRegistry.shared,
/// which KeydApp populates on startup.
///
/// The app must be running and connected to a --test-mode Mac agent before tests run.
@MainActor
final class IntegrationHarness: IntegrationHarnessProtocol {
    private weak var transportManager: TransportManager?
    private weak var pairingManager: PairingManager?

    // Track registered observers for cleanup
    private var observers: [NSObjectProtocol] = []

    init() {
        self.transportManager = TransportManagerRegistry.shared.transportManager
        self.pairingManager = TransportManagerRegistry.shared.pairingManager
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Connection

    /// True when the active connection to the Mac agent is established (USB or AWDL).
    var isConnectedToAgent: Bool {
        transportManager?.isConnected ?? false
    }

    /// Current transport kind (USB or AWDL). Used by IntegrationTestCase.runUSBAWDLFallback.
    var currentTransport: ConnectionKind? {
        guard let tm = transportManager else { return nil }
        switch tm.connectionState {
        case .usbConnected: return .usb
        case .awdlConnected: return .awdl
        default: return nil
        }
    }

    /// Wait for the active USB/AWDL connection to the Mac agent.
    func connect(timeout: TimeInterval = 10.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transportManager?.isConnected == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)  // 200ms poll
        }
        throw IntegrationError.connectionTimeout
    }

    // MARK: - Reset

    /// Send TestReset and await TestResetAck. Synchronization barrier between test cases.
    func reset(timeout: TimeInterval = 5.0) async throws {
        guard let tm = transportManager else { throw IntegrationError.noTransportManager }
        _ = try await awaitMessage(
            matching: { msg in
                if case .testResetAck = msg { return true }
                return false
            },
            beforeSend: {
                tm.sendTestMessage(.testReset)
            },
            timeout: timeout
        )
    }

    // MARK: - Message Observation

    /// Await a specific message type from the Mac agent, with timeout.
    /// Protocol-required method — forwards to the beforeSend variant.
    func awaitMessage(
        matching predicate: @escaping @MainActor (KeydMessage) -> Bool,
        timeout: TimeInterval
    ) async throws -> KeydMessage {
        try await awaitMessage(matching: predicate, beforeSend: nil, timeout: timeout)
    }

    /// Await a specific message type from the Mac agent, with timeout and optional pre-send hook.
    /// The `beforeSend` closure is called after the observer is registered
    /// but before waiting begins — prevents missed-message races.
    func awaitMessage(
        matching predicate: @escaping @MainActor (KeydMessage) -> Bool,
        beforeSend: (() -> Void)? = nil,
        timeout: TimeInterval = 10.0
    ) async throws -> KeydMessage {
        guard let tm = transportManager else { throw IntegrationError.noTransportManager }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KeydMessage, Error>) in
            // Atomic flag so we only resume once (timeout vs message race)
            var resumed = false

            // Register observer BEFORE sending to avoid the race where the reply arrives
            // before we start listening
            let observer = tm.registerTestMessageObserver(predicate: predicate) { [weak self] message in
                guard !resumed else { return }
                resumed = true
                if let self {
                    for obs in self.observers {
                        NotificationCenter.default.removeObserver(obs)
                    }
                    self.observers.removeAll()
                }
                continuation.resume(returning: message)
            }
            observers.append(observer)

            // Trigger the send now that observer is registered
            beforeSend?()

            // Timeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                if let self {
                    for obs in self.observers {
                        NotificationCenter.default.removeObserver(obs)
                    }
                    self.observers.removeAll()
                }
                continuation.resume(throwing: IntegrationError.messageTimeout("predicate"))
            }
        }
    }

    // MARK: - Send + Await

    /// Send a message and await a specific reply, with timeout.
    func sendAndAwait(
        _ message: KeydMessage,
        expecting replyPredicate: @escaping @MainActor (KeydMessage) -> Bool,
        timeout: TimeInterval = 5.0
    ) async throws {
        guard let tm = transportManager else { throw IntegrationError.noTransportManager }
        _ = try await awaitMessage(matching: replyPredicate, beforeSend: {
            tm.sendTestMessage(message)
        }, timeout: timeout)
    }

    // MARK: - Pairing Token Injection

    /// Inject a pairing token directly (bypasses QR scan).
    func injectPairingToken(_ payload: TestPairingPayload) {
        guard let tm = transportManager, let pm = pairingManager else { return }
        Task { @MainActor in
            await tm.injectTestPairingToken(payload, pairingManager: pm)
        }
    }

    // MARK: - Wire Log Attachment

    /// Attach a diagnostic wire log as XCTest attachment on failure.
    func attachWireLog(to testCase: XCTestCase) {
        // Wire log is collected from the notification stream — provide basic diagnostic info
        let info = "Integration test wire log: TransportManager registered=\(transportManager != nil), connected=\(transportManager?.isConnected ?? false)"
        let data = info.data(using: .utf8) ?? Data()
        let attachment = XCTAttachment(data: data)
        attachment.name = "integration-wire-log.txt"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    // MARK: - Error

    enum IntegrationError: Error, LocalizedError {
        case connectionTimeout
        case noTransportManager
        case messageTimeout(String)

        var errorDescription: String? {
            switch self {
            case .connectionTimeout:
                return "Timed out waiting for connection to Mac agent"
            case .noTransportManager:
                return "TransportManager not registered in TransportManagerRegistry — ensure app is running"
            case .messageTimeout(let detail):
                return "Timed out waiting for message: \(detail)"
            }
        }
    }
}
