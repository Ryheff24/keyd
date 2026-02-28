import Foundation

/// Decodes length-prefixed binary frames into KeydMessage values.
///
/// Maintains an internal streaming buffer. Feed received bytes via `receive(_:)`.
/// Complete messages are delivered via the `onMessage` callback.
///
/// Thread safety: Not thread-safe. Call from a single serial queue or actor.
public final class MessageDecoder {
    private let jsonDecoder = JSONDecoder()
    private var buffer = Data()

    /// Called with each fully decoded message.
    public var onMessage: ((KeydMessage) -> Void)?

    /// Called when a frame contains invalid data (decode error).
    public var onError: ((Error) -> Void)?

    public init() {}

    /// Feed received bytes into the decoder.
    /// Emits zero or more complete messages via `onMessage`.
    public func receive(_ data: Data) {
        buffer.append(data)
        processBuffer()
    }

    private func processBuffer() {
        // Process as many complete frames as are available
        while buffer.count >= 4 {
            // Read the 4-byte big-endian length prefix
            let lengthBytes = buffer.prefix(4)
            let length = lengthBytes.withUnsafeBytes { ptr in
                UInt32(bigEndian: ptr.load(as: UInt32.self))
            }
            let totalFrameSize = 4 + Int(length)

            // Wait for the full frame payload
            guard buffer.count >= totalFrameSize else { break }

            // Extract the payload
            let payload = buffer[4..<totalFrameSize]

            // Advance buffer past this frame
            buffer = Data(buffer.dropFirst(totalFrameSize))

            // Decode and emit
            do {
                let message = try jsonDecoder.decode(KeydMessage.self, from: payload)
                onMessage?(message)
            } catch {
                onError?(error)
                // Continue processing remaining frames (don't abort on one bad frame)
            }
        }
    }

    /// Reset internal buffer state (e.g., on reconnect).
    public func reset() {
        buffer = Data()
    }
}
