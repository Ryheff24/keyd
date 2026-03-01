import XCTest
@testable import SharedProtocol

final class MessageRoundTripTests: XCTestCase {
    let encoder = MessageEncoder()
    var decoder: MessageDecoder!
    var received: [KeydMessage] = []

    override func setUp() {
        decoder = MessageDecoder()
        received = []
        decoder.onMessage = { [weak self] msg in self?.received.append(msg) }
    }

    // MARK: - Single message round-trips

    func testKeyEventRoundTrip() throws {
        let original = KeydMessage.keyEvent(KeyEvent(unicodeScalar: 97, keyDown: true, modifiers: []))
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .keyEvent(let ev) = received[0] {
            XCTAssertEqual(ev.unicodeScalar, 97)
            XCTAssertTrue(ev.keyDown)
        } else {
            XCTFail("Wrong message type")
        }
    }

    func testHotkeyEventRoundTrip() throws {
        let original = KeydMessage.hotkeyEvent(HotkeyEvent(virtualKeyCode: VirtualKey.c, keyDown: true, modifiers: .command))
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .hotkeyEvent(let ev) = received[0] {
            XCTAssertEqual(ev.virtualKeyCode, VirtualKey.c)
            XCTAssertEqual(ev.modifiers, .command)
        } else {
            XCTFail("Wrong message type")
        }
    }

    func testSecureInputChangedRoundTrip() throws {
        let original = KeydMessage.secureInputChanged(SecureInputChanged(isActive: true))
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .secureInputChanged(let ev) = received[0] {
            XCTAssertTrue(ev.isActive)
        } else {
            XCTFail("Wrong message type")
        }
    }

    func testPairingRequestRoundTrip() throws {
        let pubKey = Data(repeating: 0xAB, count: 32)
        let original = KeydMessage.pairingRequest(PairingRequest(publicKeyData: pubKey, deviceID: "test-device-id"))
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .pairingRequest(let req) = received[0] {
            XCTAssertEqual(req.publicKeyData, pubKey)
            XCTAssertEqual(req.deviceID, "test-device-id")
        } else {
            XCTFail("Wrong message type")
        }
    }

    func testReflectStateRoundTrip() throws {
        let original = KeydMessage.reflectState(ReflectState(text: "hello world", cursorOffset: 5, selectionStart: 2, selectionLength: 3))
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .reflectState(let state) = received[0] {
            XCTAssertEqual(state.text, "hello world")
            XCTAssertEqual(state.cursorOffset, 5)
            XCTAssertEqual(state.selectionStart, 2)
            XCTAssertEqual(state.selectionLength, 3)
        } else {
            XCTFail("Wrong message type")
        }
    }

    func testTransportHeartbeatRoundTrip() throws {
        let original = KeydMessage.transportHeartbeat
        let frame = try encoder.encode(original)
        decoder.receive(frame)
        XCTAssertEqual(received.count, 1)
        if case .transportHeartbeat = received[0] {
            XCTAssertTrue(true)
        } else {
            XCTFail("Wrong message type")
        }
    }

    // MARK: - Streaming / fragmentation

    func testFragmentedDelivery() throws {
        let msg = KeydMessage.keyEvent(KeyEvent(unicodeScalar: 65, keyDown: false, modifiers: .shift))
        let frame = try encoder.encode(msg)

        // Split the frame in half
        let mid = frame.count / 2
        decoder.receive(frame.prefix(mid))
        XCTAssertEqual(received.count, 0, "Should not emit until full frame received")
        decoder.receive(frame.dropFirst(mid))
        XCTAssertEqual(received.count, 1, "Should emit after receiving remaining bytes")
    }

    func testMultipleCoalescedMessages() throws {
        let msgs: [KeydMessage] = [
            .keyEvent(KeyEvent(unicodeScalar: 104, keyDown: true)),
            .keyEvent(KeyEvent(unicodeScalar: 105, keyDown: true)),
            .keyEvent(KeyEvent(unicodeScalar: 106, keyDown: true)),
        ]
        var combined = Data()
        for msg in msgs {
            combined.append(try encoder.encode(msg))
        }
        decoder.receive(combined)
        XCTAssertEqual(received.count, 3)
    }

    func testByteByByteDelivery() throws {
        let msg = KeydMessage.hotkeyEvent(HotkeyEvent(virtualKeyCode: VirtualKey.escape, keyDown: true))
        let frame = try encoder.encode(msg)
        for byte in frame {
            decoder.receive(Data([byte]))
        }
        XCTAssertEqual(received.count, 1)
    }

    func testDecoderResetClearsBuffer() throws {
        let frame = try encoder.encode(.keyEvent(KeyEvent(unicodeScalar: 97, keyDown: true)))
        decoder.receive(frame.prefix(2))  // Only partial frame
        decoder.reset()
        decoder.receive(frame)  // Full fresh frame after reset
        XCTAssertEqual(received.count, 1)
    }

    // MARK: - Modifier flags

    func testModifierFlagsComposition() {
        let combined: ModifierFlags = [.command, .shift]
        XCTAssertTrue(combined.contains(.command))
        XCTAssertTrue(combined.contains(.shift))
        XCTAssertFalse(combined.contains(.option))
    }

    func testModifierFlagsCodable() throws {
        let flags: ModifierFlags = [.command, .option]
        let data = try JSONEncoder().encode(flags)
        let decoded = try JSONDecoder().decode(ModifierFlags.self, from: data)
        XCTAssertEqual(flags, decoded)
    }

    // MARK: - VirtualKey constants

    func testVirtualKeyConstants() {
        // Verify key constants are non-zero and distinct
        let keys: [UInt16] = [
            VirtualKey.returnKey, VirtualKey.tab, VirtualKey.space,
            VirtualKey.delete, VirtualKey.escape, VirtualKey.forwardDelete,
            VirtualKey.a, VirtualKey.c, VirtualKey.q, VirtualKey.v,
            VirtualKey.x, VirtualKey.y, VirtualKey.z, VirtualKey.four
        ]
        let unique = Set(keys)
        XCTAssertEqual(unique.count, keys.count, "All VirtualKey constants should be unique")
    }
}
