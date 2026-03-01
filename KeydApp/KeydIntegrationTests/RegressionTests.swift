import XCTest
@testable import KeydApp
import SharedProtocol
import CryptoKit

// MARK: - RegressionTests

/// Regression tests for the 4 interlocking bugs fixed in commit 9046927.
/// Each test has a descriptive name and directly verifies the fix on real hardware.
///
/// Requires: physical iOS device + Mac agent with --test-mode.
@MainActor
final class RegressionTests: XCTestCase {
    var harness: IntegrationHarness!

    override func setUp() async throws {
        harness = await IntegrationHarness()
        try await harness.connect(timeout: 15.0)
        try await harness.reset(timeout: 5.0)
    }

    override func tearDown() async throws {
        harness = nil
    }

    // MARK: - Bug 1

    /// Bug 1: Decoder missing for unpaired USB connection.
    ///
    /// Before fix: Mac had no MessageDecoder for an unpaired USB connection. The Mac
    /// never read the iOS data; the identity timer fired and disconnected the socket.
    ///
    /// After fix: Mac creates a decoder immediately on USB connection accept, before
    /// identity is known, so it can receive and decode any message including pairingRequest.
    ///
    /// Verification: After testReset clears pairing, send pairingRequest.
    /// If the decoder is present, Mac responds (accepted or rejected).
    /// If the decoder is missing, the connection times out with no reply.
    func testUnpairedUSBConnectionReceivesAndDecodesData() async throws {
        // testReset already cleared pairing state — both sides are unpaired now.
        // Inject a pairing token so iOS sends pairingRequest over the unpaired USB connection.
        harness.injectPairingToken(TestPairingPayload(
            publicKeyBase64: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            port: 12345,
            agentID: "regression-bug1-\(Int.random(in: 1000...9999))",
            version: 1
        ))
        // Await any pairing-related response — either accepted or rejected proves Mac decoded the message.
        // A timeout (IntegrationError.messageTimeout) would prove Bug 1 is still present.
        let response = try await harness.awaitMessage(matching: { msg in
            if case .pairingResponse = msg { return true }
            if case .pairingInvalidated = msg { return true }
            return false
        }, timeout: 10.0)

        // Either accepted or rejected is fine — what matters is that Mac responded at all.
        switch response {
        case .pairingResponse:
            break  // Mac responded — Bug 1 is fixed
        case .pairingInvalidated:
            break  // Also a valid response — Mac read the message
        default:
            XCTFail("Bug 1 regression: Mac did not respond to pairingRequest on unpaired USB connection (decoder missing?)")
        }
        _ = response
    }

    // MARK: - Bug 2

    /// Bug 2: pairingCompleted event ignored in pendingUSBIdentity state.
    ///
    /// Before fix: The Mac FSM received a pairingCompleted event while in pendingUSBIdentity
    /// (waiting for the first message from iOS). The FSM had no handler for this event in
    /// that state, so it did nothing — the pairing handshake stalled permanently.
    ///
    /// After fix: pendingUSBIdentity handles pairingCompleted and transitions to usbConnected,
    /// so the full pairing handshake can complete.
    ///
    /// Verification: Complete a full pairing handshake from scratch. If Bug 2 is present,
    /// the session never establishes and we time out on pairingResponse.
    func testPairingCompletedHandledInPendingUSBIdentityState() async throws {
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        harness.injectPairingToken(TestPairingPayload(
            publicKeyBase64: publicKey,
            port: 12345,
            agentID: "regression-bug2-\(Int.random(in: 1000...9999))",
            version: 1
        ))
        // If Bug 2 is present, pairingCompleted is ignored → no pairingResponse → timeout.
        let response = try await harness.awaitMessage(matching: { msg in
            if case .pairingResponse(let r) = msg, r.accepted { return true }
            return false
        }, timeout: 10.0)
        if case .pairingResponse(let r) = response {
            XCTAssertTrue(
                r.accepted,
                "Bug 2 regression: pairingCompleted not handled in pendingUSBIdentity — pairing not accepted"
            )
        } else {
            XCTFail("Bug 2 regression: no accepted pairingResponse received")
        }
    }

    // MARK: - Bug 3

    /// Bug 3: Pairing response silently dropped.
    ///
    /// Before fix: The Mac completed pairing internally but the encoder was not yet
    /// attached to the USB connection when it tried to send the PairingResponse.
    /// The send was silently dropped — iOS never received the response and hung waiting.
    ///
    /// After fix: Mac attaches the encoder before completing pairing so the
    /// PairingResponse is actually delivered over the wire.
    ///
    /// Verification: iOS must receive the pairingResponse within the timeout.
    /// If Bug 3 is present, this test times out (the response was dropped).
    func testPairingResponseIsDeliveredToiOS() async throws {
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        harness.injectPairingToken(TestPairingPayload(
            publicKeyBase64: publicKey,
            port: 12345,
            agentID: "regression-bug3-\(Int.random(in: 1000...9999))",
            version: 1
        ))
        let response = try await harness.awaitMessage(matching: { msg in
            if case .pairingResponse = msg { return true }
            return false
        }, timeout: 10.0)
        if case .pairingResponse(let r) = response {
            XCTAssertTrue(r.accepted, "Bug 3 regression: pairingResponse received but not accepted")
        } else {
            XCTFail("Bug 3 regression: pairingResponse not received — silently dropped?")
        }
    }

    // MARK: - Bug 4

    /// Bug 4: iOS sending sessionResume before pairing completes.
    ///
    /// Before fix: After USB connected, iOS immediately sent sessionResume.
    /// On a fresh (unpaired) connection, the Mac had no record of this device ID and
    /// responded with pairingInvalidated — tearing down the transport before the
    /// pairing handshake could even begin.
    ///
    /// After fix: iOS checks whether pairing is complete before sending sessionResume.
    /// On an unpaired connection, iOS sends pairingRequest instead.
    ///
    /// Verification: After testReset, inject a pairing token. The next Mac response must
    /// be pairingResponse (not pairingInvalidated). Receiving pairingInvalidated proves
    /// Bug 4 is still present (Mac rejected the spurious sessionResume).
    func testSessionResumeNotSentBeforePairingCompletes() async throws {
        // testReset cleared state — both sides are unpaired.
        // Inject token so iOS initiates pairing (not session resume).
        harness.injectPairingToken(TestPairingPayload(
            publicKeyBase64: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            port: 12345,
            agentID: "regression-bug4-\(Int.random(in: 1000...9999))",
            version: 1
        ))
        let response = try await harness.awaitMessage(matching: { msg in
            if case .pairingResponse = msg { return true }
            if case .pairingInvalidated = msg { return true }
            return false
        }, timeout: 10.0)
        // pairingInvalidated means Mac got sessionResume (unknown device) and rejected it — Bug 4 present.
        if case .pairingInvalidated = response {
            XCTFail(
                "Bug 4 regression: Mac sent pairingInvalidated — iOS likely sent sessionResume before pairing was established"
            )
        }
        // pairingResponse (any) = Bug 4 is fixed; iOS correctly sent pairingRequest first.
    }
}
