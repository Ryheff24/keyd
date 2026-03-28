import Foundation

// MARK: - Protocol Constants

/// Binary protocol magic number (0x4B44 = "KD")
let keydrdMagic: UInt16 = 0x4B44

/// Bonjour service type for remote desktop
let keydrdService = "_keydrd._tcp"

/// UDP port for media frame transport
let keydrdMediaPort: UInt16 = 14567

/// TCP port for input event transport
let keydrdInputPort: UInt16 = 14568

// MARK: - MediaFrameHeader Flags

struct MediaFrameFlags: OptionSet {
    let rawValue: UInt8

    static let hevc      = MediaFrameFlags(rawValue: 1 << 0)
    static let keyframe  = MediaFrameFlags(rawValue: 1 << 1)
    static let lastChunk = MediaFrameFlags(rawValue: 1 << 2)
    static let delta     = MediaFrameFlags(rawValue: 1 << 6)
}

// MARK: - MediaFrameHeader (24 bytes, mirrors protocol.h)

/// Swift mirror of the C MediaFrameHeader struct (24 bytes packed).
/// Use `parse(from:)` for safe deserialization from network data.
struct MediaFrameHeader {
    let magic: UInt16       // KEYDRD_MAGIC
    let flags: UInt8        // MediaFrameFlags
    let seq: UInt16         // frame sequence number (wrapping)
    let chunkIdx: UInt8     // chunk index within frame
    let chunkTotal: UInt8   // total chunks in frame
    let reserved: UInt8     // reserved, set to 0
    let payloadSize: UInt32 // compressed payload bytes
    let tsUs: UInt64        // capture timestamp (microseconds)
    let crc32: UInt32       // CRC-32 of payload

    var isHEVC: Bool { flags & 0x01 != 0 }
    var isKeyframe: Bool { flags & 0x02 != 0 }
    var isLastChunk: Bool { flags & 0x04 != 0 }
    var isDelta: Bool { flags & 0x40 != 0 }

    static let size = 24

    /// Parse a MediaFrameHeader from raw bytes.
    /// Returns nil if data is too small or magic doesn't match.
    static func parse(from data: Data) -> MediaFrameHeader? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buffer -> MediaFrameHeader? in
            guard let base = buffer.baseAddress else { return nil }
            let header = base.assumingMemoryBound(to: MediaFrameHeader.self).pointee
            guard header.magic == keydrdMagic else { return nil }
            return header
        }
    }

    /// Serialize this header to raw bytes.
    func serialize() -> Data {
        var copy = self
        return Data(bytes: &copy, count: Self.size)
    }
}

// MARK: - InputEventHeader (9 bytes, mirrors protocol.h)

/// Input event type constants
enum InputEventType: UInt8 {
    case mouseMove          = 0x01
    case click              = 0x02
    case scroll             = 0x03
    case key                = 0x10
    case modeChange         = 0x20
    case resMatchRequest    = 0x21  // iPad -> Mac: request resolution match
    case resMatchResponse   = 0x22  // Mac -> iPad: resolution match result
    case geometryUpdate     = 0x23  // Mac -> iPad: new display geometry
    case keepalive          = 0x30
    case latencyProbe       = 0xFF
}

/// Swift mirror of the C InputEventHeader struct (9 bytes packed).
struct InputEventHeader {
    let type: UInt8    // InputEventType
    let tsUs: UInt64   // event timestamp (microseconds)

    static let size = 9

    /// Parse an InputEventHeader from raw bytes.
    static func parse(from data: Data) -> InputEventHeader? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buffer -> InputEventHeader? in
            guard let base = buffer.baseAddress else { return nil }
            return base.assumingMemoryBound(to: InputEventHeader.self).pointee
        }
    }

    /// Serialize this header to raw bytes.
    func serialize() -> Data {
        var copy = self
        return Data(bytes: &copy, count: Self.size)
    }
}

// MARK: - SessionHandshakeMessage (mirrors protocol.h)

/// Session capability flags
struct SessionCapabilities: OptionSet {
    let rawValue: UInt8

    static let lz4          = SessionCapabilities(rawValue: 1 << 0)
    static let hevc         = SessionCapabilities(rawValue: 1 << 1)
    static let ecoAvailable = SessionCapabilities(rawValue: 1 << 2)
}

/// Swift mirror of the C SessionHandshakeMessage struct.
struct SessionHandshakeMessage {
    let magic: UInt16          // KEYDRD_MAGIC
    let msgType: UInt8         // KEYDRD_MSG_SESSION_HANDSHAKE (0x01)
    let displayWidth: UInt32   // capture width in pixels
    let displayHeight: UInt32  // capture height in pixels
    let scaleFactor: Float     // display scale (e.g. 2.0 for Retina)
    let aspectRatio: Float     // width / height
    let capabilities: UInt8    // SessionCapabilities
    let maxFps: UInt8          // maximum frames per second
    let agentVersion: UInt8    // protocol version for compatibility
    let reserved: UInt32       // future use, set to 0

    static let msgTypeValue: UInt8 = 0x01

    static var size: Int {
        MemoryLayout<SessionHandshakeMessage>.size
    }

    /// Parse a SessionHandshakeMessage from raw bytes.
    static func parse(from data: Data) -> SessionHandshakeMessage? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buffer -> SessionHandshakeMessage? in
            guard let base = buffer.baseAddress else { return nil }
            let msg = base.assumingMemoryBound(to: SessionHandshakeMessage.self).pointee
            guard msg.magic == keydrdMagic,
                  msg.msgType == Self.msgTypeValue else { return nil }
            return msg
        }
    }

    /// Serialize this message to raw bytes.
    func serialize() -> Data {
        var copy = self
        return Data(bytes: &copy, count: Self.size)
    }
}

// MARK: - Resolution Match Payload (sent after InputEventHeader type=0x21)

/// Payload for resolution match request (iPad -> Mac).
struct ResolutionMatchPayload {
    let iPadWidth: UInt32
    let iPadHeight: UInt32

    static var size: Int {
        MemoryLayout<ResolutionMatchPayload>.size
    }

    func serialize() -> Data {
        var copy = self
        return Data(bytes: &copy, count: Self.size)
    }
}

// MARK: - Resolution Match Response (parsed after InputEventHeader type=0x22)

/// Result codes for resolution match response.
enum ResolutionMatchResult: UInt8 {
    case ok       = 0x00
    case failed   = 0x01
    case noMode   = 0x02
}

/// Payload for resolution match response (Mac -> iPad).
struct ResolutionMatchResponse {
    let result: UInt8
    let newWidth: UInt32
    let newHeight: UInt32
    let newScale: Float

    static var size: Int {
        MemoryLayout<ResolutionMatchResponse>.size
    }

    static func parse(from data: Data, offset: Int) -> ResolutionMatchResponse? {
        guard data.count >= offset + Self.size else { return nil }
        return data.withUnsafeBytes { buffer -> ResolutionMatchResponse? in
            guard let base = buffer.baseAddress else { return nil }
            return (base + offset).assumingMemoryBound(to: ResolutionMatchResponse.self).pointee
        }
    }
}

// MARK: - Geometry Update Payload (parsed after InputEventHeader type=0x23)

/// Payload for geometry update notification (Mac -> iPad).
struct GeometryUpdatePayload {
    let displayWidth: UInt32
    let displayHeight: UInt32
    let scaleFactor: Float
    let aspectRatio: Float

    static var size: Int {
        MemoryLayout<GeometryUpdatePayload>.size
    }

    static func parse(from data: Data, offset: Int) -> GeometryUpdatePayload? {
        guard data.count >= offset + Self.size else { return nil }
        return data.withUnsafeBytes { buffer -> GeometryUpdatePayload? in
            guard let base = buffer.baseAddress else { return nil }
            return (base + offset).assumingMemoryBound(to: GeometryUpdatePayload.self).pointee
        }
    }
}
