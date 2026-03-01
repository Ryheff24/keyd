import XCTest
@testable import KeydApp

// MARK: - PairingIntegrationTests

/// XCTestCase: fully-automated integration tests for pairing and latency.
/// Requires: physical iOS device, Mac agent running with --test-mode on port 12345.
/// Run via: xcodebuild test -scheme KeydIntegrationTests -destination "platform=iOS,id=<UDID>"
@MainActor
final class PairingIntegrationTests: XCTestCase {
    var harness: IntegrationHarness!

    override func setUp() async throws {
        harness = await IntegrationHarness()
        try await harness.connect(timeout: 15.0)
        try await harness.reset(timeout: 5.0)
    }

    override func tearDown() async throws {
        harness = nil
    }

    /// Full pairing handshake over live USB connection.
    /// Verifies: iOS sends pairingRequest, Mac responds with pairingResponse(accepted: true).
    func testUSBPairingHandshakeCompletesSuccessfully() async throws {
        let result = try await IntegrationTestCase.runPairingTest(harness: harness)
        if !result.passed { harness.attachWireLog(to: self) }
        XCTAssertTrue(result.passed, result.detail ?? "Pairing test failed")
    }

    /// Latency benchmark: 100-message heartbeat burst over USB.
    /// Asserts p99 round-trip time < 50ms.
    func testLatencyBenchmarkUSBP99Under50ms() async throws {
        let result = try await IntegrationTestCase.runLatencyBenchmark(harness: harness)
        if !result.passed { harness.attachWireLog(to: self) }
        XCTAssertTrue(result.passed, result.detail ?? "Latency benchmark failed")
    }
}
