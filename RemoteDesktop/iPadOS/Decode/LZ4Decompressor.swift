import Foundation
import os.log

/// LZ4 decompressor with XOR delta apply for wired mode frame decode.
///
/// Wraps the C `LZ4_decompress_safe` (from lz4.h) and `apply_delta`
/// (from delta.h) functions via the Objective-C bridging header.
///
/// All buffers are pre-allocated at init time -- no per-frame malloc.
/// Target: <3ms decompress + delta apply per frame on iPad M4 (RD-REND-04).
final class LZ4Decompressor {

    private static let log = OSLog(subsystem: "com.keydrd.decode", category: "lz4")

    /// Pre-allocated buffer for decompressed frame output.
    private let decompressBuffer: UnsafeMutableRawPointer

    /// Pre-allocated buffer storing the last keyframe for delta reference.
    private let keyframeReference: UnsafeMutableRawPointer

    /// Pre-allocated temporary buffer for decompressed delta data.
    private let tempDeltaBuffer: UnsafeMutableRawPointer

    /// Size of each buffer in bytes (display_width * display_height * 4 for BGRA).
    let frameBytes: Int

    // MARK: - Lifecycle

    /// Initialize with the raw frame size in bytes.
    ///
    /// - Parameter frameBytes: Total bytes per uncompressed frame
    ///   (e.g., 2732 * 2048 * 4 = 22,380,544 bytes for iPad Pro 13" BGRA).
    init(frameBytes: Int) {
        self.frameBytes = frameBytes
        self.decompressBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: frameBytes, alignment: MemoryLayout<UInt64>.alignment
        )
        self.keyframeReference = UnsafeMutableRawPointer.allocate(
            byteCount: frameBytes, alignment: MemoryLayout<UInt64>.alignment
        )
        self.tempDeltaBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: frameBytes, alignment: MemoryLayout<UInt64>.alignment
        )

        // Zero-fill reference buffer so first delta has a clean base
        memset(keyframeReference, 0, frameBytes)

        os_log(.info, log: Self.log, "LZ4Decompressor initialized: frameBytes=%d", frameBytes)
    }

    deinit {
        decompressBuffer.deallocate()
        keyframeReference.deallocate()
        tempDeltaBuffer.deallocate()
        os_log(.info, log: Self.log, "LZ4Decompressor deallocated")
    }

    // MARK: - Decompress

    /// Decompress an LZ4-compressed frame (keyframe or delta).
    ///
    /// - Parameters:
    ///   - data: LZ4-compressed payload data.
    ///   - header: Parsed MediaFrameHeader indicating keyframe vs delta.
    ///   - frameBytes: Expected decompressed size (must match self.frameBytes).
    /// - Returns: Pointer to the decompressed BGRA pixel data, or nil on error.
    ///   The pointer is valid until the next call to `decompress` or until
    ///   this LZ4Decompressor is deallocated.
    func decompress(data: Data, header: MediaFrameHeader, frameBytes: Int) -> UnsafeRawPointer? {
        guard frameBytes == self.frameBytes else {
            os_log(.error, log: Self.log,
                   "Frame size mismatch: expected %d, got %d", self.frameBytes, frameBytes)
            return nil
        }

        if header.isKeyframe {
            return decompressKeyframe(data: data)
        } else if header.isDelta {
            return decompressDelta(data: data)
        } else {
            os_log(.error, log: Self.log, "Unknown frame type: flags=0x%02x", header.flags)
            return nil
        }
    }

    // MARK: - Private

    /// Decompress a keyframe: LZ4 decompress, update keyframe reference.
    private func decompressKeyframe(data: Data) -> UnsafeRawPointer? {
        let compressedSize = data.count
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let src = buffer.baseAddress else { return -1 }
            return LZ4_decompress_safe(
                src.assumingMemoryBound(to: CChar.self),
                decompressBuffer.assumingMemoryBound(to: CChar.self),
                Int32(compressedSize),
                Int32(frameBytes)
            )
        }

        guard result > 0 else {
            os_log(.error, log: Self.log,
                   "LZ4_decompress_safe failed for keyframe: result=%d, compressed=%d",
                   result, compressedSize)
            return nil
        }

        // Update keyframe reference for future delta frames
        memcpy(keyframeReference, decompressBuffer, frameBytes)

        return UnsafeRawPointer(decompressBuffer)
    }

    /// Decompress a delta frame: LZ4 decompress delta, apply XOR against reference.
    private func decompressDelta(data: Data) -> UnsafeRawPointer? {
        let compressedSize = data.count

        // Step 1: LZ4 decompress the delta data into tempDeltaBuffer
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let src = buffer.baseAddress else { return -1 }
            return LZ4_decompress_safe(
                src.assumingMemoryBound(to: CChar.self),
                tempDeltaBuffer.assumingMemoryBound(to: CChar.self),
                Int32(compressedSize),
                Int32(frameBytes)
            )
        }

        guard result > 0 else {
            os_log(.error, log: Self.log,
                   "LZ4_decompress_safe failed for delta: result=%d, compressed=%d",
                   result, compressedSize)
            return nil
        }

        // Step 2: Apply XOR delta: output = delta ^ keyframeReference
        apply_delta(tempDeltaBuffer, keyframeReference, decompressBuffer, frameBytes)

        // Step 3: Update keyframe reference with the reconstructed frame
        memcpy(keyframeReference, decompressBuffer, frameBytes)

        return UnsafeRawPointer(decompressBuffer)
    }
}
