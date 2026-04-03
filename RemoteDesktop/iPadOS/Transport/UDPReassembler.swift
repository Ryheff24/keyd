import Foundation
import os.log

/// Reassembles chunked UDP media frames into complete frames.
///
/// Incoming chunks are keyed by `seq` number. When all chunks for a sequence
/// arrive (`chunk_total` pieces), the complete frame is reassembled and
/// delivered via callback. Handles out-of-order arrival, stale frame timeout,
/// and max-concurrent-sequence eviction.
final class UDPReassembler {
    private static let maxForwardGapBeforeSkip: UInt16 = 32
    private static let maxOutOfOrderFrames = 32

    struct StatsSnapshot {
        let framesDelivered: Int
        let framesEvicted: Int
        let framesPurged: Int
        let chunksReceived: Int
        let pendingFrames: Int
        let outOfOrderBuffered: Int
        let hasDeliveredFirstFrame: Bool
        let lastDeliveredSeq: UInt16
    }

    // MARK: - Configuration

    /// Maximum number of concurrent sequences being reassembled.
    /// If exceeded, the oldest incomplete sequence is dropped.
    /// Must be large enough to handle multiple in-flight chunked HEVC frames
    /// (a 100KB keyframe at 1400B MTU = 71 chunks, takes ~50ms over WiFi).
    /// Raised from 32 to 128 to tolerate WiFi jitter without false evictions.
    static let maxConcurrentSequences = 128

    /// Timeout for incomplete frames (seconds). Stale partial frames are dropped.
    /// WiFi jitter can delay individual chunks by 100-300ms; 2s is generous enough
    /// to avoid false purges while still bounding memory usage.
    static let frameTimeoutInterval: TimeInterval = 2.0  // 2000ms (was 500ms)

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
    var onRecoveryNeeded: (() -> Void)?

    /// Pending frames keyed by sequence number.
    private var pendingFrames: [UInt16: PendingFrame] = [:]

    /// Insertion order tracking for eviction (oldest first).
    private var insertionOrder: [UInt16] = []

    /// Timer that periodically purges stale incomplete frames.
    private var purgeTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.ryheff.keyd.remote.app.udpreassembler")
    private let callbackQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.udpreassembler.callback")

    private static let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "UDPReassembler")

    private var reassembledCount = 0

    /// Counters for frame loss tracking — exposed for test observability.
    private(set) var framesEvicted = 0   // dropped due to maxConcurrentSequences
    private(set) var framesPurged = 0    // dropped due to timeout
    private(set) var framesDelivered = 0 // successfully reassembled + delivered
    private(set) var chunksReceived = 0  // total chunks processed

    /// In-order delivery: track last delivered sequence to avoid visual glitches
    /// from out-of-order frame completion.
    private var lastDeliveredSeq: UInt16 = 0
    private var hasDeliveredFirstFrame = false
    private var outOfOrderBuffer: [UInt16: Data] = [:]
    private var awaitingKeyframeAfterLoss = false
    private var droppedUntilKeyframeCount = 0

    /// Stats logging interval counter (counts purge timer ticks).
    private var statsTickCount = 0
    /// Number of purge timer intervals between stats logs.
    /// purgeTimer fires every frameTimeoutInterval (2s), so 3 ticks = 6 seconds.
    private static let statsLogInterval = 3

    // MARK: - Init

    init() {
        startPurgeTimer()
    }

    deinit {
        purgeTimer?.cancel()
    }

    // MARK: - Public API

    /// Process an incoming chunk. If this completes a frame, delivers it via `onFrameReassembled`.
    ///
    /// - Parameter data: Raw packet data including the 24-byte MediaFrameHeader + chunk payload.
    func processChunk(_ data: Data) {
        queue.async {
            self.processChunkLocked(data)
        }
    }

    func statsSnapshot() -> StatsSnapshot {
        queue.sync {
            StatsSnapshot(
                framesDelivered: framesDelivered,
                framesEvicted: framesEvicted,
                framesPurged: framesPurged,
                chunksReceived: chunksReceived,
                pendingFrames: pendingFrames.count,
                outOfOrderBuffered: outOfOrderBuffer.count,
                hasDeliveredFirstFrame: hasDeliveredFirstFrame,
                lastDeliveredSeq: lastDeliveredSeq
            )
        }
    }

    /// Returns current loss rate (0.0 to 1.0) and resets counters for the next window.
    func consumeLossRate() -> Float {
        queue.sync {
            let total = framesDelivered + framesEvicted + framesPurged
            guard total > 0 else { return 0 }
            let lost = framesEvicted + framesPurged
            let rate = Float(lost) / Float(total)
            // Reset for next window
            framesDelivered = 0
            framesEvicted = 0
            framesPurged = 0
            return rate
        }
    }

    // MARK: - Private

    private func processChunkLocked(_ data: Data) {
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

        // Single-chunk frame (no chunking needed).
        // Still route through the in-order delivery path so TCP fallback,
        // one-chunk UDP frames, and multi-chunk UDP frames share the same
        // sequence continuity guarantees.
        if chunkTotal <= 1 {
            deliverFrameData(seq: seq, frameData: data)
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
    /// Reassemble a complete frame into deliverable data.
    private func buildFrameData(seq: UInt16, pending: PendingFrame) -> Data? {
        // Reassemble payload in chunk_idx order
        var fullPayload = Data()
        for i in 0..<pending.chunkTotal {
            guard let chunk = pending.chunks[i] else {
                // Should not happen if isComplete is true, but guard anyway
                print("[CONSOLE] UDPReassembler: missing chunk \(i) for seq=\(seq) during reassembly")
                return nil
            }
            fullPayload.append(chunk)
        }

        // Build complete frame: reconstruct header from first chunk
        guard let firstHeader = pending.firstChunkHeader else {
            // If we never received chunk 0's header, use a fallback
            // This shouldn't happen in practice since isComplete requires all chunks
            print("[CONSOLE] UDPReassembler: no first chunk header for seq=\(seq)")
            return nil
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
        return frameData
    }

    /// Reassemble and deliver a complete frame, respecting in-order delivery.
    private func deliverCompleteFrame(seq: UInt16, pending: PendingFrame) {
        // Remove from tracking
        pendingFrames.removeValue(forKey: seq)
        insertionOrder.removeAll { $0 == seq }

        reassembledCount += 1
        if reassembledCount <= 3 {
            print("[CONSOLE] UDPReassembler: reassembled seq=\(seq), \(pending.chunkTotal) chunks -> \(pending.chunks.values.reduce(0) { $0 + $1.count }) bytes")
        }

        guard let frameData = buildFrameData(seq: seq, pending: pending) else { return }
        deliverFrameData(seq: seq, frameData: frameData)
    }

    private func enqueueReassembledFrame(_ frameData: Data) {
        callbackQueue.async { [weak self] in
            self?.onFrameReassembled?(frameData)
        }
    }

    /// Deliver a complete frame while preserving sequence continuity across
    /// all media paths, including direct single-chunk and TCP-fallback frames.
    private func deliverFrameData(seq: UInt16, frameData: Data) {
        guard let header = MediaFrameHeader.parse(from: frameData) else {
            print("[CONSOLE] UDPReassembler: failed to parse complete frame for seq=\(seq)")
            return
        }

        if awaitingKeyframeAfterLoss {
            guard header.isKeyframe else {
                droppedUntilKeyframeCount += 1
                if droppedUntilKeyframeCount <= 10 || droppedUntilKeyframeCount % 25 == 0 {
                    print("[CONSOLE] UDPReassembler: dropping seq=\(seq) while waiting for keyframe (dropped=\(droppedUntilKeyframeCount))")
                }
                return
            }

            awaitingKeyframeAfterLoss = false
            droppedUntilKeyframeCount = 0
            outOfOrderBuffer.removeAll()
            hasDeliveredFirstFrame = true
            lastDeliveredSeq = seq
            framesDelivered += 1
            print("[CONSOLE] UDPReassembler: recovered on keyframe seq=\(seq)")
            enqueueReassembledFrame(frameData)
            return
        }

        if !hasDeliveredFirstFrame {
            guard header.isKeyframe else {
                enterRecoveryMode(reason: "first complete frame was not a keyframe", missingSeq: seq)
                return
            }

            // First frame ever — deliver immediately and set baseline
            hasDeliveredFirstFrame = true
            lastDeliveredSeq = seq
            framesDelivered += 1
            enqueueReassembledFrame(frameData)
            drainOutOfOrderBuffer()
            return
        }

        let distance = seqDistance(from: lastDeliveredSeq, to: seq)

        if distance == 0 || distance > 32768 {
            // distance == 0: duplicate of last delivered frame
            // distance > 32768: seq is BEHIND lastDeliveredSeq (wrapped backward), old/stale frame
        } else if distance == 1 {
            // Next in sequence — deliver immediately
            lastDeliveredSeq = seq
            framesDelivered += 1
            enqueueReassembledFrame(frameData)
            drainOutOfOrderBuffer()
        } else if distance <= Self.maxForwardGapBeforeSkip {
            // Slightly ahead — buffer and wait for the missing frames rather than
            // skipping forward and poisoning the HEVC reference chain.
            outOfOrderBuffer[seq] = frameData
            if outOfOrderBuffer.count > Self.maxOutOfOrderFrames {
                enterRecoveryMode(reason: "out-of-order buffer overflow", missingSeq: lastDeliveredSeq &+ 1)
            }
        } else {
            // A larger gap likely means the missing frames are gone for good.
            // Only skip ahead if the new frame is a keyframe that can restart
            // decoder state cleanly. Otherwise, freeze until the next keyframe.
            if header.isKeyframe {
                outOfOrderBuffer.removeAll()
                lastDeliveredSeq = seq
                framesDelivered += 1
                print("[CONSOLE] UDPReassembler: skipped forward to keyframe seq=\(seq) after gap")
                enqueueReassembledFrame(frameData)
            } else {
                enterRecoveryMode(reason: "gap exceeded \(Self.maxForwardGapBeforeSkip) frames", missingSeq: lastDeliveredSeq &+ 1)
            }
        }
    }

    /// Deliver consecutive frames from the out-of-order buffer.
    private func drainOutOfOrderBuffer() {
        while true {
            let nextSeq = lastDeliveredSeq &+ 1
            guard let frameData = outOfOrderBuffer.removeValue(forKey: nextSeq) else { break }
            lastDeliveredSeq = nextSeq
            framesDelivered += 1
            enqueueReassembledFrame(frameData)
        }
    }

    private func enterRecoveryMode(reason: String, missingSeq: UInt16) {
        let shouldNotifyRecovery = !awaitingKeyframeAfterLoss
        if shouldNotifyRecovery {
            print("[CONSOLE] UDPReassembler: entering recovery, waiting for keyframe (\(reason), missing seq=\(missingSeq), buffered=\(outOfOrderBuffer.count), pending=\(pendingFrames.count))")
        }
        awaitingKeyframeAfterLoss = true
        droppedUntilKeyframeCount = 0
        outOfOrderBuffer.removeAll()
        if shouldNotifyRecovery {
            callbackQueue.async { [weak self] in
                self?.onRecoveryNeeded?()
            }
        }
    }

    /// Compute forward distance between two wrapping UInt16 sequence numbers.
    /// Returns a value in [0, 65535]. A result > 32768 means `to` is behind `from`.
    private func seqDistance(from a: UInt16, to b: UInt16) -> UInt16 {
        return b &- a
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
        if hasDeliveredFirstFrame {
            let distance = seqDistance(from: lastDeliveredSeq, to: oldestSeq)
            if distance > 0 && distance <= 32768 {
                enterRecoveryMode(reason: "evicted incomplete frame", missingSeq: oldestSeq)
            }
        }
    }

    /// Start a timer that periodically purges stale incomplete frames.
    private func startPurgeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.frameTimeoutInterval,
                       repeating: Self.frameTimeoutInterval)
        timer.setEventHandler { [weak self] in
            self?.purgeStaleFrames()
        }
        timer.resume()
        purgeTimer = timer
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
            if hasDeliveredFirstFrame {
                let distance = seqDistance(from: lastDeliveredSeq, to: seq)
                if distance > 0 && distance <= 32768 {
                    enterRecoveryMode(reason: "purged incomplete frame", missingSeq: seq)
                }
            }
        }

        // Periodic stats logging (every statsLogInterval purge ticks)
        statsTickCount += 1
        if statsTickCount >= Self.statsLogInterval {
            statsTickCount = 0
            let total = framesDelivered + framesEvicted + framesPurged
            if total > 0 {
                let lossRate = Float(framesEvicted + framesPurged) / Float(total)
                print("[CONSOLE] UDPReassembler stats: delivered=\(framesDelivered) evicted=\(framesEvicted) purged=\(framesPurged) loss=\(String(format: "%.1f", lossRate * 100))% ooo_buffered=\(outOfOrderBuffer.count) pending=\(pendingFrames.count)")
            }
        }
    }
}
