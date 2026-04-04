import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import os.log

/// VideoToolbox HEVC hardware decoder for wireless/eco mode frames.
///
/// Creates a VTDecompressionSession from SPS/PPS extracted from the first
/// keyframe. Decodes synchronously (low latency) and returns CVPixelBuffer
/// in BGRA format for Metal texture upload.
final class HEVCDecoder {

    private static let log = OSLog(subsystem: "com.keydrd.decode", category: "hevc")

    /// Callback invoked with each decoded pixel buffer and its timestamp (microseconds).
    var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    /// Output pixel buffer attributes: BGRA format for Metal texture upload.
    private let outputAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    // MARK: - Public API

    /// Decode an HEVC-encoded frame.
    ///
    /// For the first keyframe, extracts SPS/PPS to create the format description
    /// and decompression session. Subsequent frames use the existing session.
    ///
    /// - Parameters:
    ///   - data: Encoded H.265 NAL unit data.
    ///   - header: Parsed MediaFrameHeader for this frame.
    /// - Returns: Decoded CVPixelBuffer in BGRA format, or nil on error.
    private var decodeLogCount = 0

    func decode(data: Data, header: MediaFrameHeader) -> CVPixelBuffer? {
        return decode(frameData: data,
                      payloadOffset: 0,
                      payloadLength: data.count,
                      header: header)
    }

    func decode(frameData: Data,
                payloadOffset: Int,
                payloadLength: Int,
                header: MediaFrameHeader) -> CVPixelBuffer? {
        guard payloadOffset >= 0,
              payloadLength >= 0,
              payloadOffset + payloadLength <= frameData.count else {
            os_log(.error, log: Self.log,
                   "Invalid HEVC payload bounds: offset=%d length=%d frame=%d",
                   payloadOffset, payloadLength, frameData.count)
            return nil
        }

        // If this is a keyframe, extract SPS/PPS and ensure session exists
        if header.isKeyframe {
            if !ensureSession(from: frameData, payloadOffset: payloadOffset, payloadLength: payloadLength) {
                print("[CONSOLE] HEVCDecoder: ensureSession FAILED for keyframe (data=\(payloadLength) bytes)")
                return nil
            }
            if decodeLogCount < 3 {
                print("[CONSOLE] HEVCDecoder: session ready after keyframe")
            }
        }

        guard let session = decompressionSession,
              let fmtDesc = formatDescription else {
            if decodeLogCount < 3 {
                print("[CONSOLE] HEVCDecoder: no session (awaiting keyframe)")
            }
            decodeLogCount += 1
            return nil
        }

        // Create CMBlockBuffer from encoded data
        var blockBuffer: CMBlockBuffer?
        let dataCount = payloadLength
        var status = frameData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            let payloadBase = baseAddress.advanced(by: payloadOffset)
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: payloadBase),
                blockLength: dataCount,
                blockAllocator: kCFAllocatorNull, // data owns the memory
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let block = blockBuffer else {
            os_log(.error, log: Self.log, "CMBlockBufferCreate failed: %d", status)
            return nil
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataCount
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fmtDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            os_log(.error, log: Self.log, "CMSampleBufferCreate failed: %d", status)
            return nil
        }

        // Real-time decode path.
        var pixelBuffer: CVPixelBuffer?
        var flagsOut: VTDecodeInfoFlags = []

        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: &flagsOut,
            outputHandler: { decodeStatus, _, imageBuffer, _, _ in
                if decodeStatus == noErr, let buf = imageBuffer {
                    pixelBuffer = buf
                } else {
                    os_log(.error, log: Self.log, "Decode frame error: %d", decodeStatus)
                }
            }
        )

        if status != noErr {
            os_log(.error, log: Self.log, "VTDecompressionSessionDecodeFrame failed: %d", status)
            handleSessionError(status)
            return nil
        }

        // Avoid unconditional decoder drains. Only wait when this call actually
        // returned asynchronously and we still need the output for this frame.
        if flagsOut.contains(.asynchronous) && pixelBuffer == nil {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }

        if let pb = pixelBuffer {
            onDecodedFrame?(pb, header.tsUs)
        }

        return pixelBuffer
    }

    /// Invalidate and release the decompression session.
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
    }

    deinit {
        invalidate()
    }

    // MARK: - Session Setup

    /// Extract SPS/PPS from keyframe data and create/recreate the decompression session.
    /// Returns true if session is ready for decoding.
    private func ensureSession(from data: Data, payloadOffset: Int, payloadLength: Int) -> Bool {
        // Extract parameter sets (SPS, PPS) from HEVC keyframe
        guard let fmtDesc = createFormatDescription(from: data, payloadOffset: payloadOffset, payloadLength: payloadLength) else {
            // Log first few bytes for debugging NAL unit format
            let safeStart = payloadOffset
            let safeEnd = min(data.count, payloadOffset + min(payloadLength, 20))
            let preview = data[safeStart..<safeEnd].map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[CONSOLE] HEVCDecoder: createFormatDescription FAILED, payload[\(payloadLength)]= \(preview)...")
            return false
        }

        // Check if format description changed (resolution change, etc.)
        let newDims = CMVideoFormatDescriptionGetDimensions(fmtDesc)
        if let existing = formatDescription {
            let oldDims = CMVideoFormatDescriptionGetDimensions(existing)
            if oldDims.width == newDims.width && oldDims.height == newDims.height {
                // Same format -- keep existing session
                formatDescription = fmtDesc
                return true
            }
        }

        // New or changed format -- recreate session
        invalidate()
        formatDescription = fmtDesc

        let destAttributes = outputAttributes as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmtDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destAttributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let newSession = session else {
            os_log(.error, log: Self.log, "VTDecompressionSessionCreate failed: %d", status)
            return false
        }

        decompressionSession = newSession
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        os_log(.info, log: Self.log, "Decompression session created")
        return true
    }

    /// Create a CMVideoFormatDescription from HEVC parameter set NAL units.
    ///
    /// Scans encoded data for VPS (type 32), SPS (type 33), PPS (type 34)
    /// NAL units using 4-byte Annex-B start codes (00 00 00 01).
    private func createFormatDescription(from data: Data, payloadOffset: Int, payloadLength: Int) -> CMVideoFormatDescription? {
        // Find NAL units with Annex-B start codes
        let nalRanges = extractNALRanges(from: data, payloadOffset: payloadOffset, payloadLength: payloadLength)

        var vps: Data?
        var sps: Data?
        var pps: Data?

        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for range in nalRanges where range.count > 2 {
                // HEVC NAL unit type is in bits 1-6 of the first byte
                let nalType = (bytes[range.lowerBound] >> 1) & 0x3F
                switch nalType {
                case 32: vps = Data(data[range])  // VPS
                case 33: sps = Data(data[range])  // SPS
                case 34: pps = Data(data[range])  // PPS
                default: break
                }
            }
        }

        guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
            // Not all parameter sets found -- this may be a non-keyframe or
            // the data uses length-prefix format rather than start codes
            return createFormatDescriptionFromLengthPrefixed(data,
                                                             payloadOffset: payloadOffset,
                                                             payloadLength: payloadLength)
        }

        // Build parameter set pointers for CMVideoFormatDescriptionCreateFromHEVCParameterSets
        var fmtDesc: CMVideoFormatDescription?
        let paramSets: [Data] = [vpsData, spsData, ppsData]
        let status = paramSets.withContiguousStorageIfAvailable { _ -> OSStatus in
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []

            return vpsData.withUnsafeBytes { vpsPtr -> OSStatus in
                pointers.append(vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                sizes.append(vpsData.count)

                return spsData.withUnsafeBytes { spsPtr -> OSStatus in
                    pointers.append(spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    sizes.append(spsData.count)

                    return ppsData.withUnsafeBytes { ppsPtr -> OSStatus in
                        pointers.append(ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                        sizes.append(ppsData.count)

                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &fmtDesc
                        )
                    }
                }
            }
        }

        // Fallback: if withContiguousStorageIfAvailable returned nil (not contiguous)
        if status == nil {
            let result = createFormatDescriptionDirect(vps: vpsData, sps: spsData, pps: ppsData, out: &fmtDesc)
            if result != noErr {
                os_log(.error, log: Self.log, "Format description create failed: %d", result)
                return nil
            }
        } else if let s = status, s != noErr {
            os_log(.error, log: Self.log, "Format description create failed: %d", s)
            return nil
        }

        return fmtDesc
    }

    /// Direct creation without withContiguousStorageIfAvailable.
    private func createFormatDescriptionDirect(vps: Data, sps: Data, pps: Data,
                                                out: inout CMVideoFormatDescription?) -> OSStatus {
        return vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]

                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &out
                    )
                }
            }
        }
    }

    /// Extract NAL ranges from Annex-B formatted payload data (00 00 00 01 prefix).
    /// Returned ranges are absolute indices into `data`.
    private func extractNALRanges(from data: Data,
                                  payloadOffset: Int,
                                  payloadLength: Int) -> [Range<Int>] {
        var nalRanges: [Range<Int>] = []
        var searchOffset = payloadOffset
        let payloadEnd = payloadOffset + payloadLength
        var startCodePositions: [Int] = []

        // Find all start code positions
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while searchOffset + 3 < payloadEnd {
                if bytes[searchOffset] == 0x00 &&
                   bytes[searchOffset + 1] == 0x00 &&
                   bytes[searchOffset + 2] == 0x00 &&
                   bytes[searchOffset + 3] == 0x01 {
                    startCodePositions.append(searchOffset)
                    searchOffset += 4
                } else {
                    searchOffset += 1
                }
            }
        }

        // Extract NAL unit data between start codes
        for i in 0..<startCodePositions.count {
            let nalStart = startCodePositions[i] + 4
            let nalEnd = (i + 1 < startCodePositions.count) ? startCodePositions[i + 1] : payloadEnd
            if nalStart < nalEnd {
                nalRanges.append(nalStart..<nalEnd)
            }
        }

        return nalRanges
    }

    /// Attempt to create format description from length-prefixed NAL units.
    /// VideoToolbox output uses 4-byte length prefix format.
    private func createFormatDescriptionFromLengthPrefixed(_ data: Data,
                                                           payloadOffset: Int,
                                                           payloadLength: Int) -> CMVideoFormatDescription? {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var offset = payloadOffset
        let payloadEnd = payloadOffset + payloadLength

        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while offset + 4 <= payloadEnd {
                let nalLength = Int(bytes[offset]) << 24 |
                                Int(bytes[offset + 1]) << 16 |
                                Int(bytes[offset + 2]) << 8 |
                                Int(bytes[offset + 3])
                offset += 4
                guard nalLength > 0, offset + nalLength <= payloadEnd else { break }

                let nalType = (bytes[offset] >> 1) & 0x3F
                let nalStart = offset
                let nalEnd = offset + nalLength
                let nalData = Data(data[nalStart..<nalEnd])
                switch nalType {
                case 32: vps = nalData
                case 33: sps = nalData
                case 34: pps = nalData
                default: break
                }
                offset += nalLength
            }
        }

        guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
            return nil
        }

        var fmtDesc: CMVideoFormatDescription?
        let result = createFormatDescriptionDirect(vps: vpsData, sps: spsData, pps: ppsData, out: &fmtDesc)
        if result != noErr {
            os_log(.error, log: Self.log, "Format description from length-prefixed failed: %d", result)
            return nil
        }
        return fmtDesc
    }

    // MARK: - Error Handling

    /// Handle session errors by invalidating for recreation on next keyframe.
    private func handleSessionError(_ status: OSStatus) {
        os_log(.error, log: Self.log, "Session error %d -- will recreate on next keyframe", status)
        invalidate()
    }
}
