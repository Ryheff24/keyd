import Foundation

/// Encodes a KeydMessage into a length-prefixed binary frame.
///
/// Frame format: [4-byte big-endian UInt32 length][JSON payload bytes]
/// The receiver reads 4 bytes to get the length, then exactly that many payload bytes.
public final class MessageEncoder: Sendable {
    private let jsonEncoder = JSONEncoder()

    public init() {}

    /// Encode a message into a transport frame.
    /// - Returns: 4-byte length prefix + JSON payload
    public func encode(_ message: KeydMessage) throws -> Data {
        let payload = try jsonEncoder.encode(message)
        let length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: length) { Data($0) }
        frame.append(payload)
        return frame
    }
}
