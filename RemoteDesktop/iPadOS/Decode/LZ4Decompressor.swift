import Foundation
import QuartzCore
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
        return decompress(frameData: data,
                          payloadOffset: 0,
                          payloadLength: data.count,
                          header: header,
                          frameBytes: frameBytes)
    }

    func decompress(frameData: Data,
                    payloadOffset: Int,
                    payloadLength: Int,
                    header: MediaFrameHeader,
                    frameBytes: Int) -> UnsafeRawPointer? {
        guard payloadOffset >= 0,
              payloadLength >= 0,
              payloadOffset + payloadLength <= frameData.count else {
            os_log(.error, log: Self.log,
                   "Invalid payload bounds: offset=%d length=%d frame=%d",
                   payloadOffset, payloadLength, frameData.count)
            return nil
        }

        guard frameBytes <= self.frameBytes else {
            os_log(.error, log: Self.log,
                   "Frame too large for buffer: capacity %d, requested %d", self.frameBytes, frameBytes)
            return nil
        }

        if header.isStriped {
            return decompressStriped(frameData: frameData,
                                     payloadOffset: payloadOffset,
                                     payloadLength: payloadLength,
                                     header: header,
                                     expectedBytes: frameBytes)
        } else if header.isKeyframe {
            return decompressKeyframe(frameData: frameData,
                                      payloadOffset: payloadOffset,
                                      payloadLength: payloadLength,
                                      expectedBytes: frameBytes)
        } else if header.isDelta {
            return decompressDelta(frameData: frameData,
                                   payloadOffset: payloadOffset,
                                   payloadLength: payloadLength,
                                   expectedBytes: frameBytes)
        } else {
            os_log(.error, log: Self.log, "Unknown frame type: flags=0x%02x", header.flags)
            return nil
        }
    }

    // MARK: - Private

    private var stripedLogCount = 0

    /// Striped frame (KEYDRD_FLAG_STRIPED, tla/StripeSync.tla): the C `striped_decode` runs one
    /// worker per stripe and returns only after all of them finish (IpadJoin), so the renderer
    /// never sees a half-written frame. Keyframe and delta both update `keyframeReference`.
    private func decompressStriped(frameData: Data,
                                   payloadOffset: Int,
                                   payloadLength: Int,
                                   header: MediaFrameHeader,
                                   expectedBytes: Int) -> UnsafeRawPointer? {
        guard header.isKeyframe || header.isDelta else {
            print("[CONSOLE] LZ4 striped: frame is neither keyframe nor delta, flags=0x\(String(header.flags, radix: 16)) seq=\(header.seq)")
            return nil
        }
        let t0 = CACurrentMediaTime()
        var stripes = -1
        let rc = frameData.withUnsafeBytes { buffer -> Int32 in
            guard let src = buffer.baseAddress else { return -100 }
            if payloadLength > 0 { stripes = Int(buffer[payloadOffset]) }
            return striped_decode(src.advanced(by: payloadOffset).assumingMemoryBound(to: UInt8.self),
                                  payloadLength,
                                  header.isKeyframe ? 1 : 0,
                                  decompressBuffer.assumingMemoryBound(to: UInt8.self),
                                  keyframeReference.assumingMemoryBound(to: UInt8.self),
                                  tempDeltaBuffer.assumingMemoryBound(to: UInt8.self),
                                  expectedBytes)
        }
        let ms = (CACurrentMediaTime() - t0) * 1000.0
        stripedLogCount += 1
        guard rc == 0 else {
            print("[CONSOLE] LZ4 striped: decode FAILED rc=\(rc) seq=\(header.seq) key=\(header.isKeyframe) payload=\(payloadLength) expected=\(expectedBytes) stripes=\(stripes)")
            return nil
        }
        if stripedLogCount <= 10 || stripedLogCount % 240 == 0 || ms > 6.0 {
            print("[CONSOLE] LZ4 striped: decoded seq=\(header.seq) key=\(header.isKeyframe) stripes=\(stripes) payload=\(payloadLength) decodeMs=\(String(format: "%.2f", ms))")
        }
        return UnsafeRawPointer(decompressBuffer)
    }

    /// Decompress a keyframe: LZ4 decompress, update keyframe reference.
    private func decompressKeyframe(frameData: Data,
                                    payloadOffset: Int,
                                    payloadLength: Int,
                                    expectedBytes: Int) -> UnsafeRawPointer? {
        let compressedSize = payloadLength
        let result = frameData.withUnsafeBytes { buffer -> Int32 in
            guard let src = buffer.baseAddress else { return -1 }
            let payloadBase = src.advanced(by: payloadOffset)
            return LZ4_decompress_safe(
                payloadBase.assumingMemoryBound(to: CChar.self),
                decompressBuffer.assumingMemoryBound(to: CChar.self),
                Int32(compressedSize),
                Int32(expectedBytes)
            )
        }

        guard result > 0 else {
            os_log(.error, log: Self.log,
                   "LZ4_decompress_safe failed for keyframe: result=%d, compressed=%d, expected=%d",
                    result, compressedSize, expectedBytes)
            return nil
        }
        guard Int(result) == expectedBytes else {
            os_log(.error, log: Self.log,
                   "LZ4 keyframe size mismatch: decoded=%d compressed=%d expected=%d",
                   result, compressedSize, expectedBytes)
            return nil
        }

        // Update keyframe reference for future delta frames
        memcpy(keyframeReference, decompressBuffer, expectedBytes)

        return UnsafeRawPointer(decompressBuffer)
    }

    /// Decompress a delta frame: LZ4 decompress delta, apply XOR against reference.
    private func decompressDelta(frameData: Data,
                                 payloadOffset: Int,
                                 payloadLength: Int,
                                 expectedBytes: Int) -> UnsafeRawPointer? {
        let compressedSize = payloadLength

        // Step 1: LZ4 decompress the delta data into tempDeltaBuffer
        let result = frameData.withUnsafeBytes { buffer -> Int32 in
            guard let src = buffer.baseAddress else { return -1 }
            let payloadBase = src.advanced(by: payloadOffset)
            return LZ4_decompress_safe(
                payloadBase.assumingMemoryBound(to: CChar.self),
                tempDeltaBuffer.assumingMemoryBound(to: CChar.self),
                Int32(compressedSize),
                Int32(expectedBytes)
            )
        }

        guard result > 0 else {
            os_log(.error, log: Self.log,
                   "LZ4_decompress_safe failed for delta: result=%d, compressed=%d, expected=%d",
                    result, compressedSize, expectedBytes)
            return nil
        }
        guard Int(result) == expectedBytes else {
            os_log(.error, log: Self.log,
                   "LZ4 delta size mismatch: decoded=%d compressed=%d expected=%d",
                   result, compressedSize, expectedBytes)
            return nil
        }

        // Step 2: Apply XOR delta: output = delta ^ keyframeReference
        apply_delta(tempDeltaBuffer, keyframeReference, decompressBuffer, expectedBytes)

        // Step 3: Update keyframe reference with the reconstructed frame
        memcpy(keyframeReference, decompressBuffer, expectedBytes)

        return UnsafeRawPointer(decompressBuffer)
    }
}
