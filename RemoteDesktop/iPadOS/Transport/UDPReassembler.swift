import Foundation
import os.log

/// Reassembles chunked UDP media frames into complete frames.
///
/// Incoming chunks are keyed by `seq` number. When all chunks for a sequence
/// arrive (`chunk_total` pieces), the complete frame is reassembled and
/// delivered via callback. Handles out-of-order arrival, stale frame timeout,
/// and max-concurrent-sequence eviction.
final class UDPReassembler {

    // MARK: - Configuration

    /// Maximum number of concurrent sequences being reassembled.
    /// If exceeded, the oldest incomplete sequence is dropped.
    /// Must be large enough to handle multiple in-flight chunked HEVC frames
    /// (a 100KB keyframe at 1400B MTU = 71 chunks, takes ~50ms over WiFi).
    static let maxConcurrentSequences = 32

    /// Timeout for incomplete frames (seconds). Stale partial frames are dropped.
    /// WiFi jitter can delay individual chunks by 50-200ms; too short = false drops.
    static let frameTimeoutInterval: TimeInterval = 0.5  // 500ms

    // MARK: - Types

    /// State for a single frame being reassembled.
    private struct PendingFrame {
        let seq: UInt16
        let chunkTotal: UInt16
        /// Header from the first chunk (chunk_idx == 0), used to reconstruct the complete header.
        var firstChunkHeader: MediaFrameHeader?
        /// Received chunks indexed by chunk_idx. nil = not yet received.
        var chunks: [UInt16: Data]
        /// Timestamp when this pending frame was created.
        let createdAt: CFAbsoluteTime

        var isComplete: Bool {
            chunks.count == Int(chunkTotal)
        }
    }

    // MARK: - Properties

    /// Callback to deliver reassembled complete frames (header bytes + payload).
    var onFrameReassembled: ((Data) -> Void)?

    /// Pending frames keyed by sequence number.
    private var pendingFrames: [UInt16: PendingFrame] = [:]

    /// Insertion order tracking for eviction (oldest first).
    private var insertionOrder: [UInt16] = []

    /// Timer that periodically purges stale incomplete frames.
    private var purgeTimer: Timer?

    private static let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "UDPReassembler")

    private var reassembledCount = 0

    /// Counters for frame loss tracking — exposed for test observability.
    private(set) var framesEvicted = 0   // dropped due to maxConcurrentSequences
    private(set) var framesPurged = 0    // dropped due to timeout
    private(set) var framesDelivered = 0 // successfully reassembled + delivered
    private(set) var chunksReceived = 0  // total chunks processed

    // MARK: - Init

    init() {
        startPurgeTimer()
    }

    deinit {
        purgeTimer?.invalidate()
    }

    // MARK: - Public API

    /// Process an incoming chunk. If this completes a frame, delivers it via `onFrameReassembled`.
    ///
    /// - Parameter data: Raw packet data including the 24-byte MediaFrameHeader + chunk payload.
    func processChunk(_ data: Data) {
        guard data.count >= MediaFrameHeader.size else {
            print("[CONSOLE] UDPReassembler: chunk too small (\(data.count) bytes)")
            return
        }

        guard let header = MediaFrameHeader.parse(from: data) else {
            print("[CONSOLE] UDPReassembler: invalid header (magic mismatch)")
            return
        }

        let seq = header.seq
        let chunkIdx = header.chunkIdx
        let chunkTotal = header.chunkTotal

        chunksReceived += 1

        // Single-chunk frame (no chunking needed) -- pass through directly
        if chunkTotal <= 1 {
            framesDelivered += 1
            onFrameReassembled?(data)
            return
        }

        // Extract payload (after header)
        let payload = data.subdata(in: MediaFrameHeader.size..<data.count)

        // Get or create pending frame
        if pendingFrames[seq] == nil {
            // Evict oldest if at capacity
            if pendingFrames.count >= Self.maxConcurrentSequences {
                evictOldest()
            }

            pendingFrames[seq] = PendingFrame(
                seq: seq,
                chunkTotal: chunkTotal,
                firstChunkHeader: nil,
                chunks: [:],
                createdAt: CFAbsoluteTimeGetCurrent()
            )
            insertionOrder.append(seq)
        }

        guard var pending = pendingFrames[seq] else { return }

        // Validate chunk_total consistency
        guard pending.chunkTotal == chunkTotal else {
            print("[CONSOLE] UDPReassembler: chunk_total mismatch for seq=\(seq) (expected \(pending.chunkTotal), got \(chunkTotal))")
            return
        }

        // Store chunk (idempotent -- duplicate chunks are silently ignored)
        if pending.chunks[chunkIdx] == nil {
            pending.chunks[chunkIdx] = payload
        }

        // Store first chunk's header for reconstruction
        if chunkIdx == 0 {
            pending.firstChunkHeader = header
        }

        pendingFrames[seq] = pending

        // Check if frame is complete
        if pending.isComplete {
            deliverCompleteFrame(seq: seq, pending: pending)
        }
    }

    // MARK: - Private

    /// Reassemble and deliver a complete frame.
    private func deliverCompleteFrame(seq: UInt16, pending: PendingFrame) {
        // Remove from tracking
        pendingFrames.removeValue(forKey: seq)
        insertionOrder.removeAll { $0 == seq }

        // Reassemble payload in chunk_idx order
        var fullPayload = Data()
        for i in 0..<pending.chunkTotal {
            guard let chunk = pending.chunks[i] else {
                // Should not happen if isComplete is true, but guard anyway
                print("[CONSOLE] UDPReassembler: missing chunk \(i) for seq=\(seq) during reassembly")
                return
            }
            fullPayload.append(chunk)
        }

        // Build complete frame: reconstruct header from first chunk
        guard let firstHeader = pending.firstChunkHeader else {
            // If we never received chunk 0's header, use a fallback
            // This shouldn't happen in practice since isComplete requires all chunks
            print("[CONSOLE] UDPReassembler: no first chunk header for seq=\(seq)")
            return
        }

        // Create a new header with chunk_idx=0, chunk_total=1, full payload size, LAST_CHUNK flag
        let reconstructedHeader = MediaFrameHeader(
            magic: firstHeader.magic,
            flags: firstHeader.flags | MediaFrameFlags.lastChunk.rawValue,
            seq: firstHeader.seq,
            chunkIdx: 0,
            chunkTotal: 1,
            payloadSize: UInt32(fullPayload.count),
            tsUs: firstHeader.tsUs,
            crc32: firstHeader.crc32
        )

        var frameData = reconstructedHeader.serialize()
        frameData.append(fullPayload)

        reassembledCount += 1
        framesDelivered += 1
        if reassembledCount <= 3 {
            print("[CONSOLE] UDPReassembler: reassembled seq=\(seq), \(pending.chunkTotal) chunks -> \(fullPayload.count) bytes")
        }

        onFrameReassembled?(frameData)
    }

    /// Evict the oldest pending frame to make room for a new one.
    private func evictOldest() {
        guard let oldestSeq = insertionOrder.first else { return }
        let pending = pendingFrames[oldestSeq]
        let received = pending?.chunks.count ?? 0
        let total = pending?.chunkTotal ?? 0
        pendingFrames.removeValue(forKey: oldestSeq)
        insertionOrder.removeFirst()
        framesEvicted += 1
        print("[CONSOLE] UDPReassembler: EVICTED seq=\(oldestSeq) (\(received)/\(total) chunks, total evicted=\(framesEvicted))")
    }

    /// Start a timer that periodically purges stale incomplete frames.
    private func startPurgeTimer() {
        purgeTimer = Timer.scheduledTimer(withTimeInterval: Self.frameTimeoutInterval, repeats: true) {
            [weak self] _ in
            self?.purgeStaleFrames()
        }
    }

    /// Remove any pending frames older than the timeout interval.
    private func purgeStaleFrames() {
        let now = CFAbsoluteTimeGetCurrent()
        let cutoff = now - Self.frameTimeoutInterval

        let staleSeqs = pendingFrames.filter { $0.value.createdAt < cutoff }.map { $0.key }
        for seq in staleSeqs {
            let pending = pendingFrames[seq]
            let received = pending?.chunks.count ?? 0
            let total = pending?.chunkTotal ?? 0
            framesPurged += 1
            print("[CONSOLE] UDPReassembler: PURGED seq=\(seq) (\(received)/\(total) chunks, age=\(String(format: "%.0f", (now - (pending?.createdAt ?? now)) * 1000))ms, total purged=\(framesPurged))")
            pendingFrames.removeValue(forKey: seq)
            insertionOrder.removeAll { $0 == seq }
        }
    }
}
