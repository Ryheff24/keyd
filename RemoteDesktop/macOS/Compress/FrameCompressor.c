#include "FrameCompressor.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>  /* crc32() — always available on macOS */
#include <os/log.h>
#include <QuartzCore/QuartzCore.h>  /* CACurrentMediaTime */

static os_log_t fc_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.keydrd.compress", "frame");
    });
    return log;
}

/* ---- Initialization ---- */

int frame_compressor_init(FrameCompressorState *state, size_t frame_bytes) {
    memset(state, 0, sizeof(*state));

    state->frame_bytes = frame_bytes;
    state->seq = 0;
    state->keyframe_interval_frames = 600; /* ~5s at 120fps — fewer keyframes = less bandwidth spikes.
                                              * USB TCP is reliable so delta-only is safe for longer. */
    state->last_keyframe_compressed = 0;

    /* Initialize delta double-buffer */
    if (delta_buffer_init(&state->delta_buf, frame_bytes) != 0) {
        return -1;
    }

    /* Pre-allocate LZ4 output buffer (worst-case compressed size) */
    int bound = LZ4_compressBound((int)frame_bytes);
    if (bound <= 0) {
        delta_buffer_destroy(&state->delta_buf);
        return -1;
    }

    state->output.buf = (uint8_t *)malloc((size_t)bound);
    if (!state->output.buf) {
        delta_buffer_destroy(&state->delta_buf);
        return -1;
    }
    state->output.buf_capacity = (size_t)bound;
    state->output.compressed_size = 0;

    /* Pre-allocate delta scratch buffer (same size as frame — no malloc in hot path) */
    state->delta_scratch = (uint8_t *)malloc(frame_bytes);
    if (!state->delta_scratch) {
        free(state->output.buf);
        state->output.buf = NULL;
        delta_buffer_destroy(&state->delta_buf);
        return -1;
    }

    /* Pre-allocate stride-packing buffer (avoids 20MB malloc/free per frame
     * when IOSurface bytesPerRow > packed width*4) */
    state->packed_buf = (uint8_t *)malloc(frame_bytes);
    if (!state->packed_buf) {
        free(state->delta_scratch);
        state->delta_scratch = NULL;
        free(state->output.buf);
        state->output.buf = NULL;
        delta_buffer_destroy(&state->delta_buf);
        return -1;
    }

    /* Create high-priority serial dispatch queue for compression */
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    state->compress_queue = dispatch_queue_create("com.keydrd.compress", attr);
    if (!state->compress_queue) {
        free(state->delta_scratch);
        state->delta_scratch = NULL;
        free(state->output.buf);
        state->output.buf = NULL;
        delta_buffer_destroy(&state->delta_buf);
        return -1;
    }

    return 0;
}

/* ---- Teardown ---- */

void frame_compressor_destroy(FrameCompressorState *state) {
    if (state->output.buf) {
        free(state->output.buf);
        state->output.buf = NULL;
    }
    if (state->delta_scratch) {
        free(state->delta_scratch);
        state->delta_scratch = NULL;
    }
    if (state->packed_buf) {
        free(state->packed_buf);
        state->packed_buf = NULL;
    }
    if (state->compress_queue) {
        /* dispatch_release not needed under ARC / non-ObjC,
         * but state->compress_queue is a C dispatch object.
         * Under GCD, created queues need no explicit release
         * in modern runtimes (macOS 10.8+), but we NULL it. */
        state->compress_queue = NULL;
    }
    delta_buffer_destroy(&state->delta_buf);
    state->seq = 0;
    state->frame_bytes = 0;
    state->last_keyframe_compressed = 0;
}

/* ---- Compression ---- */

int compress_frame(FrameCompressorState *state,
                   IOSurfaceRef surface,
                   CMSampleBufferRef sampleBuf,
                   uint64_t capture_ts_us,
                   CompressOutput *out) {
    /* Enforce single-threaded access on compress queue */
    dispatch_assert_queue(state->compress_queue);

    double t0 = CACurrentMediaTime();

    /* Lock IOSurface for read access */
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    double t_lock = CACurrentMediaTime();

    void  *base  = IOSurfaceGetBaseAddress(surface);
    size_t bytes = state->frame_bytes;

    /* Handle IOSurface stride padding.
     * IOSurface rows are often aligned to 64/256 bytes, so bytesPerRow > width*4.
     * If stride differs, we must copy row-by-row into a packed buffer to avoid
     * the classic "horizontal banding" corruption on the receiver. */
    size_t surfaceBytesPerRow = IOSurfaceGetBytesPerRow(surface);
    size_t surfaceWidth  = IOSurfaceGetWidth(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    size_t packedBytesPerRow = surfaceWidth * 4;
    uint8_t *packed_buf = NULL;

    if (surfaceBytesPerRow != packedBytesPerRow && surfaceHeight > 0) {
        /* Stride mismatch — pack rows into pre-allocated buffer (no malloc in hot path) */
        packed_buf = state->packed_buf;
        if (packed_buf) {
            const uint8_t *src = (const uint8_t *)base;
            for (size_t row = 0; row < surfaceHeight; row++) {
                memcpy(packed_buf + row * packedBytesPerRow,
                       src + row * surfaceBytesPerRow,
                       packedBytesPerRow);
            }
            base = packed_buf;
        }
    }

    double t_pack = CACurrentMediaTime();

    /* Determine keyframe vs delta */
    int is_keyframe = (state->seq == 0) ||
                      (state->seq % state->keyframe_interval_frames == 0);

    int compressed = 0;
    uint8_t flags = 0;
    int should_log_frame_check = (state->seq < 10) || (state->seq % 120 == 0);

    if (is_keyframe) {
        /* ---- Keyframe path ---- */
        /* Use default compression (acceleration=1) for keyframes — slower but
         * ~30-40% smaller than acceleration=8. Keyframes are infrequent (every 600
         * frames) so the extra compress time is acceptable. Smaller keyframes
         * reduce the TCP stall that blocks all subsequent delta frames. */
        compressed = LZ4_compress_default(
            (const char *)base,
            (char *)out->buf,
            (int)bytes,
            (int)out->buf_capacity);

        if (compressed <= 0) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            return -1;
        }

        flags = KEYDRD_FLAG_KEYFRAME;
        state->last_keyframe_compressed = (size_t)compressed;

        /* Update double-buffer reference with this keyframe */
        update_keyframe_reference(&state->delta_buf, base);
    } else {
        /* ---- Delta path (fused XOR + reference update) ---- */
        int dirty = compute_delta_and_update(&state->delta_buf, base, state->delta_scratch);
        (void)dirty;  /* Zero-frame skip disabled: even identical frames must flow
                       * so the iPad always has fresh content. The _lz4CompressPending
                       * skip in ScreenCapture already rate-limits the queue. */

        double t_delta = CACurrentMediaTime();

        /* Compress the delta */
        compressed = LZ4_compress_fast(
            (const char *)state->delta_scratch,
            (char *)out->buf,
            (int)bytes,
            (int)out->buf_capacity,
            8);

        if (compressed <= 0) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            return -1;
        }

        /* Delta threshold fallback removed (was RD-COMP-03).
         * The 60% threshold caused double LZ4 compression on every frame
         * during active content (scrolling, video), halving throughput.
         * On reliable TCP, periodic keyframes (every keyframe_interval_frames)
         * are sufficient for error recovery. Deltas are always valid as long
         * as the reference stays in sync, which TCP guarantees. */
        flags = KEYDRD_FLAG_DELTA;

        /* Log delta-specific timing for first 10 frames and every 200th */
        {
            static int deltaProbeCount = 0;
            if (deltaProbeCount < 10 || deltaProbeCount % 200 == 0) {
                double deltaMs = (t_delta - t_pack) * 1000;
                double lz4Ms = (CACurrentMediaTime() - t_delta) * 1000;
                os_log(fc_log(), "delta_detail #%d: xor+copy=%.1fms lz4=%.1fms compressed=%d bytes",
                       deltaProbeCount, deltaMs, lz4Ms, compressed);
            }
            deltaProbeCount++;
        }
    }

    /* Unlock IOSurface — all pointer access complete */
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    double t_compress = CACurrentMediaTime();

    /* Timing probe — log first 10 frames and every 200th */
    {
        static int probeCount = 0;
        if (probeCount < 10 || probeCount % 200 == 0) {
            double lockMs = (t_lock - t0) * 1000;
            double packMs = (t_pack - t_lock) * 1000;
            double compMs = (t_compress - t_pack) * 1000;
            double totalMs = (t_compress - t0) * 1000;
            os_log(fc_log(), "compress_frame #%d: total=%.1fms (lock=%.1f pack=%.1f comp=%.1f) "
                   "stride=%zu packed=%zu %s compressed=%d bytes",
                   probeCount, totalMs, lockMs, packMs, compMs,
                   surfaceBytesPerRow, packedBytesPerRow,
                   is_keyframe ? "KEY" : "delta", compressed);
        }
        probeCount++;
    }

    /* Fill output */
    out->compressed_size = (size_t)compressed;

    /* Use capture-time host clock (microseconds) stamped
     * in ScreenCapture.didOutputSampleBuffer — consistent with HEVC path
     * and comparable to iPad host-time timestamps. */
    uint64_t ts_us = capture_ts_us;

    /* Compute CRC-32 of compressed payload */
    uint32_t payload_crc = (uint32_t)crc32(0L, out->buf, (uInt)compressed);
    if (should_log_frame_check) {
        uint32_t raw_crc = (uint32_t)crc32(0L, (const Bytef *)base, (uInt)bytes);
        os_log(fc_log(), "FRAME-CHECK converge seq=%u raw_crc=%08x payload_crc=%08x compressed=%d flags=0x%02x dims=%zux%zu stride=%zu",
               state->seq, raw_crc, payload_crc, compressed, flags,
               surfaceWidth, surfaceHeight, surfaceBytesPerRow);
    }

    /* Fill MediaFrameHeader */
    out->header.magic        = KEYDRD_MAGIC;
    out->header.flags        = flags;
    out->header.seq          = (uint16_t)(state->seq & 0xFFFF);
    out->header.chunk_idx    = 0;     /* chunking deferred to transport layer */
    out->header.chunk_total  = 1;
    out->header.payload_size = (uint32_t)compressed;
    out->header.ts_us        = ts_us;
    out->header.crc32        = payload_crc;

    state->seq++;

    return 0;
}
