import Foundation
import QuartzCore

// MARK: - Protocol Constants

/// Binary protocol magic number (0x4B44 = "KD")
let keydrdMagic: UInt16 = 0x4B44

/// Bonjour service type for remote desktop
let keydrdService = "_keydrd._tcp"

/// UDP port for media frame transport
let keydrdMediaPort: UInt16 = 14567

/// TCP port for input event transport
let keydrdInputPort: UInt16 = 14568

/// Monotonic host time in microseconds.
/// QuartzCore documents `CACurrentMediaTime()` as `mach_absolute_time()`
/// converted to seconds, so it is safe to compare with Metal/CoreAnimation
/// presentation timestamps and to exchange across devices via Cristian's algorithm.
@inline(__always)
func keydrdHostTimeUs() -> UInt64 {
    UInt64(CACurrentMediaTime() * 1_000_000)
}

// MARK: - MediaFrameHeader Flags

struct MediaFrameFlags: OptionSet {
    let rawValue: UInt8

    static let hevc      = MediaFrameFlags(rawValue: 1 << 0)
    static let keyframe  = MediaFrameFlags(rawValue: 1 << 1)
    static let lastChunk = MediaFrameFlags(rawValue: 1 << 2)
    static let delta     = MediaFrameFlags(rawValue: 1 << 6)
}

// MARK: - MediaFrameHeader (25 bytes, mirrors protocol.h)

/// Swift mirror of the C MediaFrameHeader struct (25 bytes packed).
/// Use `parse(from:)` for safe deserialization from network data.
struct MediaFrameHeader {
    let magic: UInt16       // KEYDRD_MAGIC
    let flags: UInt8        // MediaFrameFlags
    let seq: UInt16         // frame sequence number (wrapping)
    let chunkIdx: UInt16    // chunk index within frame (u16 for large keyframes)
    let chunkTotal: UInt16  // total chunks in frame (u16: up to 65535)
    let payloadSize: UInt32 // compressed payload bytes
    let tsUs: UInt64        // capture host-time timestamp (microseconds)
    let crc32: UInt32       // CRC-32 of payload

    var isHEVC: Bool { flags & 0x01 != 0 }
    var isKeyframe: Bool { flags & 0x02 != 0 }
    var isLastChunk: Bool { flags & 0x04 != 0 }
    var isDelta: Bool { flags & 0x40 != 0 }

    static let size = 25

    /// Parse a MediaFrameHeader from raw bytes using manual byte offsets.
    /// C packed offsets: magic(0,2), flags(2,1), seq(3,2), chunkIdx(5,2),
    /// chunkTotal(7,2), payloadSize(9,4), tsUs(13,8), crc32(21,4) = 25 bytes
    static func parse(from data: Data) -> MediaFrameHeader? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buf -> MediaFrameHeader? in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }

            var magic: UInt16 = 0;       memcpy(&magic,       p + 0,  2)
            guard magic == keydrdMagic else { return nil }

            let flags = p[2]
            var seq: UInt16 = 0;         memcpy(&seq,         p + 3,  2)
            var chunkIdx: UInt16 = 0;    memcpy(&chunkIdx,    p + 5,  2)
            var chunkTotal: UInt16 = 0;  memcpy(&chunkTotal,  p + 7,  2)
            var payloadSize: UInt32 = 0; memcpy(&payloadSize, p + 9,  4)
            var tsUs: UInt64 = 0;        memcpy(&tsUs,        p + 13, 8)
            var crc32Val: UInt32 = 0;    memcpy(&crc32Val,    p + 21, 4)

            return MediaFrameHeader(
                magic: magic, flags: flags, seq: seq,
                chunkIdx: chunkIdx, chunkTotal: chunkTotal,
                payloadSize: payloadSize, tsUs: tsUs, crc32: crc32Val
            )
        }
    }

    /// Serialize this header to packed bytes matching C layout (25 bytes).
    func serialize() -> Data {
        var buf = Data(count: Self.size)
        buf.withUnsafeMutableBytes { p in
            let base = p.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var m = magic;           memcpy(base + 0,  &m, 2)
            base[2] = flags
            var s = seq;             memcpy(base + 3,  &s, 2)
            var ci = chunkIdx;       memcpy(base + 5,  &ci, 2)
            var ct = chunkTotal;     memcpy(base + 7,  &ct, 2)
            var ps = payloadSize;    memcpy(base + 9,  &ps, 4)
            var ts = tsUs;           memcpy(base + 13, &ts, 8)
            var c = crc32;           memcpy(base + 21, &c, 4)
        }
        return buf
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
    case clockSyncReq       = 0xFE  // iPad -> Mac: Cristian's algorithm probe
    case clockSyncResp      = 0xFD  // Mac -> iPad: clock sync response
    case latencyProbe       = 0xFF
}

/// Swift mirror of the C InputEventHeader struct (9 bytes packed).
struct InputEventHeader {
    let type: UInt8    // InputEventType
    let tsUs: UInt64   // event host-time timestamp (microseconds)

    static let size = 9

    /// Parse an InputEventHeader from raw bytes (manual packed offsets).
    /// C packed: type(0), tsUs(1) = 9 bytes. Swift pads to 16.
    static func parse(from data: Data) -> InputEventHeader? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buf -> InputEventHeader? in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let type = p[0]
            var tsUs: UInt64 = 0; memcpy(&tsUs, p + 1, 8)
            return InputEventHeader(type: type, tsUs: tsUs)
        }
    }

    /// Serialize this header to packed bytes (9 bytes).
    func serialize() -> Data {
        var buf = Data(count: Self.size)
        buf.withUnsafeMutableBytes { p in
            let base = p.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = type
            var ts = tsUs; memcpy(base + 1, &ts, 8)
        }
        return buf
    }
}

// MARK: - ClockSyncResponse (24 bytes, mirrors protocol.h)

/// Cristian's algorithm response payload, sent after InputEventHeader.
/// Carries t1 (iPad send, echoed), t2 (Mac receive), t3 (Mac send).
struct ClockSyncResponse {
    let t1iPadUs: UInt64
    let t2MacUs: UInt64
    let t3MacUs: UInt64

    static let size = 24

    static func parse(from data: Data) -> ClockSyncResponse? {
        guard data.count >= Self.size else { return nil }
        return data.withUnsafeBytes { buf -> ClockSyncResponse? in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var t1: UInt64 = 0; memcpy(&t1, p + 0, 8)
            var t2: UInt64 = 0; memcpy(&t2, p + 8, 8)
            var t3: UInt64 = 0; memcpy(&t3, p + 16, 8)
            return ClockSyncResponse(t1iPadUs: t1, t2MacUs: t2, t3MacUs: t3)
        }
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

    /// Packed wire size matching C __attribute__((packed)) struct: 26 bytes.
    static let packedSize = 26

    static var size: Int { packedSize }

    /// Parse a SessionHandshakeMessage from raw packed bytes (C __attribute__((packed)) layout).
    /// Offsets match the C struct exactly: magic(2) + msgType(1) + width(4) + height(4)
    /// + scale(4) + aspect(4) + caps(1) + fps(1) + version(1) + reserved(4) = 26.
    static func parse(from data: Data) -> SessionHandshakeMessage? {
        guard data.count >= packedSize else { return nil }
        return data.withUnsafeBytes { buf -> SessionHandshakeMessage? in
            guard let base = buf.baseAddress else { return nil }
            let p = base.assumingMemoryBound(to: UInt8.self)

            let magic = UInt16(p[0]) | (UInt16(p[1]) << 8)  // little-endian
            let msgType = p[2]
            guard magic == keydrdMagic, msgType == Self.msgTypeValue else { return nil }

            var width: UInt32 = 0;  memcpy(&width,  p + 3,  4)
            var height: UInt32 = 0; memcpy(&height, p + 7,  4)
            var scale: Float = 0;   memcpy(&scale,  p + 11, 4)
            var aspect: Float = 0;  memcpy(&aspect, p + 15, 4)
            let caps = p[19]
            let fps = p[20]
            let ver = p[21]
            var res: UInt32 = 0;    memcpy(&res,    p + 22, 4)

            return SessionHandshakeMessage(
                magic: magic, msgType: msgType,
                displayWidth: width, displayHeight: height,
                scaleFactor: scale, aspectRatio: aspect,
                capabilities: caps, maxFps: fps, agentVersion: ver,
                reserved: res
            )
        }
    }

    /// Serialize this message to packed bytes matching C layout.
    func serialize() -> Data {
        var buf = Data(count: Self.packedSize)
        buf.withUnsafeMutableBytes { p in
            let base = p.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var m = magic;           memcpy(base + 0,  &m, 2)
            base[2] = msgType
            var w = displayWidth;    memcpy(base + 3,  &w, 4)
            var h = displayHeight;   memcpy(base + 7,  &h, 4)
            var s = scaleFactor;     memcpy(base + 11, &s, 4)
            var a = aspectRatio;     memcpy(base + 15, &a, 4)
            base[19] = capabilities
            base[20] = maxFps
            base[21] = agentVersion
            var r = reserved;        memcpy(base + 22, &r, 4)
        }
        return buf
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
