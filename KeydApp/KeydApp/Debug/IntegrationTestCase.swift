import Foundation
import SharedProtocol
import CryptoKit

// MARK: - TestPairingPayload

/// Token injected directly into PairingManager to bypass QR scan in automated tests.
public struct TestPairingPayload {
    public let publicKeyBase64: String
    public let port: UInt16
    public let agentID: String
    public let version: Int

    public init(publicKeyBase64: String, port: UInt16, agentID: String, version: Int) {
        self.publicKeyBase64 = publicKeyBase64
        self.port = port
        self.agentID = agentID
        self.version = version
    }
}

// MARK: - IntegrationTestCase

/// Shared integration test case implementations.
/// Called by both KeydIntegrationTests XCTestCase subclasses and Suite C in TransportTestRunnerView.
///
/// This file is compiled into the main KeydApp target (no XCTest import).
/// It is also included in the KeydIntegrationTests target via project.yml sources.
@MainActor
public enum IntegrationTestCase {

    public struct Result {
        public let passed: Bool
        public let detail: String?
        public let durationMs: Double

        public init(passed: Bool, detail: String?, durationMs: Double) {
            self.passed = passed
            self.detail = detail
            self.durationMs = durationMs
        }
    }

    /// Test: Full pairing handshake over live USB connection.
    /// Injects a real Curve25519 key pair; awaits pairingResponse from the Mac agent.
    public static func runPairingTest(harness: IntegrationHarnessProtocol) async throws -> Result {
        let start = Date()
        try await harness.reset()
        let iOSPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let testPayload = TestPairingPayload(
            publicKeyBase64: iOSPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            port: 12345,
            agentID: "integration-test-\(Int.random(in: 1000...9999))",
            version: 1
        )
        harness.injectPairingToken(testPayload)
        let response = try await harness.awaitMessage(matching: { msg in
            if case .pairingResponse = msg { return true }
            return false
        }, timeout: 10.0)
        guard case .pairingResponse(let r) = response else {
            return Result(
                passed: false,
                detail: "Expected pairingResponse, got \(response)",
                durationMs: Date().timeIntervalSince(start) * 1000
            )
        }
        return Result(
            passed: r.accepted,
            detail: r.accepted ? nil : "Pairing rejected by Mac agent",
            durationMs: Date().timeIntervalSince(start) * 1000
        )
    }

    /// Test: Latency benchmark — 100-message burst over USB, assert p99 < 50ms.
    public static func runLatencyBenchmark(harness: IntegrationHarnessProtocol) async throws -> Result {
        let start = Date()
        try await harness.reset()
        var roundTrips: [Double] = []
        let burstSize = 100
        for _ in 0..<burstSize {
            let t0 = Date()
            try await harness.sendAndAwait(
                .transportHeartbeat,
                expecting: { msg in
                    if case .transportHeartbeatAck = msg { return true }
                    return false
                },
                timeout: 2.0
            )
            roundTrips.append(Date().timeIntervalSince(t0) * 1000)
        }
        let sorted = roundTrips.sorted()
        let p99Index = max(0, Int(Double(sorted.count) * 0.99) - 1)
        let p99 = sorted[p99Index]
        let p50 = sorted[sorted.count / 2]
        let threshold = 50.0  // ms
        let passed = p99 < threshold
        return Result(
            passed: passed,
            detail: passed
                ? nil
                : "p99=\(String(format: "%.1f", p99))ms exceeded \(threshold)ms threshold (p50=\(String(format: "%.1f", p50))ms)",
            durationMs: Date().timeIntervalSince(start) * 1000
        )
    }

    /// Semi-automated: USB→AWDL fallback (Suite C on-device UI only — never called from XCTest).
    /// Returns a Result after the user unplugs the cable and the test observes the switchover.
    public static func runUSBAWDLFallback(
        harness: IntegrationHarnessProtocol,
        onPrompt: @escaping () async -> Void
    ) async throws -> Result {
        let start = Date()
        try await harness.reset()
        guard harness.currentTransport == .usb else {
            return Result(
                passed: false,
                detail: "Must start on USB — plug in cable first",
                durationMs: 0
            )
        }
        // Prompt human to unplug
        await onPrompt()
        let switchStart = Date()
        // Await any message from Mac after switchover
        _ = try await harness.awaitMessage(matching: { msg in
            if case .transportHeartbeatAck = msg { return true }
            if case .pairingResponse = msg { return true }
            return false
        }, timeout: 15.0)
        let switchoverMs = Date().timeIntervalSince(switchStart) * 1000
        let passed = switchoverMs < 5000
        return Result(
            passed: passed,
            detail: passed
                ? nil
                : "Switchover took \(String(format: "%.0f", switchoverMs))ms (>5s threshold)",
            durationMs: Date().timeIntervalSince(start) * 1000
        )
    }
}

// MARK: - IntegrationHarnessProtocol

/// Protocol that both IntegrationHarness (XCTest target) and IntegrationSuiteCRunner (UI)
/// conform to, so IntegrationTestCase methods work in both contexts without importing XCTest.
@MainActor
public protocol IntegrationHarnessProtocol: AnyObject {
    var isConnectedToAgent: Bool { get }
    var currentTransport: ConnectionKind? { get }
    func connect(timeout: TimeInterval) async throws
    func reset(timeout: TimeInterval) async throws
    func awaitMessage(matching: @escaping @MainActor (KeydMessage) -> Bool, timeout: TimeInterval) async throws -> KeydMessage
    func sendAndAwait(_ message: KeydMessage, expecting: @escaping @MainActor (KeydMessage) -> Bool, timeout: TimeInterval) async throws
    func injectPairingToken(_ payload: TestPairingPayload)
}

/// Default timeout values for IntegrationHarnessProtocol methods.
public extension IntegrationHarnessProtocol {
    func connect() async throws { try await connect(timeout: 10.0) }
    func reset() async throws { try await reset(timeout: 5.0) }
    func awaitMessage(matching predicate: @escaping @MainActor (KeydMessage) -> Bool) async throws -> KeydMessage {
        try await awaitMessage(matching: predicate, timeout: 10.0)
    }
    func sendAndAwait(_ message: KeydMessage, expecting predicate: @escaping @MainActor (KeydMessage) -> Bool) async throws {
        try await sendAndAwait(message, expecting: predicate, timeout: 5.0)
    }
}
