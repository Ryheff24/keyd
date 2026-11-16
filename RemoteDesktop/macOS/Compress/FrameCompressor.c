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

int frame_compressor_init_striped(FrameCompressorState *state, size_t frame_bytes, int stripes) {
    if (stripes < 1 || stripes > KEYDRD_STRIPE_MAX) return -1;
    if (frame_compressor_init(state, frame_bytes) != 0) return -1;
    state->stripe_count = 1;
    if (stripes == 1) return 0;

    stripe_layout(frame_bytes, stripes, state->stripe_off, state->stripe_len);
    size_t slot = 0;
    for (int k = 0; k < stripes; k++) {
        int bound = LZ4_compressBound((int)state->stripe_len[k]);
        if (bound <= 0) { frame_compressor_destroy(state); return -1; }
        state->stripe_slot[k] = slot;
        state->stripe_bound[k] = (size_t)bound;
        slot += (size_t)bound;
    }
    state->stripe_scratch = (uint8_t *)malloc(slot);
    if (!state->stripe_scratch) { frame_compressor_destroy(state); return -1; }

    /* Packed payload = table + all blocks; worst case is the sum of per-stripe bounds. */
    size_t need = stripe_table_bytes(stripes) + slot;
    if (need > state->output.buf_capacity) {
        uint8_t *bigger = (uint8_t *)realloc(state->output.buf, need);
        if (!bigger) { frame_compressor_destroy(state); return -1; }
        state->output.buf = bigger;
        state->output.buf_capacity = need;
    }
    state->stripe_count = stripes;
    os_log(fc_log(), "frame_compressor_init_striped: frameBytes=%zu stripes=%d stripeLen=%zu lastLen=%zu outCap=%zu",
           frame_bytes, stripes, state->stripe_len[0], state->stripe_len[stripes - 1], state->output.buf_capacity);
    return 0;
}

/* Striped compress (tla/StripeSync.tla MacJoin): every stripe worker reads its slice of the
 * active reference and writes its slice of the pending one; dispatch_apply returns only after
 * all workers finish, and only then is the reference flipped and the payload packed.
 * Returns the payload size, or -1 (reference not flipped, nothing emitted). */
static int compress_striped(FrameCompressorState *state, const uint8_t *base, int is_keyframe,
                            uint8_t *out_buf, size_t out_cap, double *t_work_out) {
    const int count = state->stripe_count;
    DeltaBuffer *db = &state->delta_buf;
    const uint8_t *ref = db->buf[db->active];
    uint8_t *pending = db->buf[1 - db->active];
    uint8_t *scratch = state->stripe_scratch;
    uint8_t *delta = state->delta_scratch;
    int comp_arr[KEYDRD_STRIPE_MAX];
    int *comp = comp_arr;
    dispatch_queue_t workers = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);

    dispatch_apply((size_t)count, workers, ^(size_t k) {
        size_t off = state->stripe_off[k];
        size_t len = state->stripe_len[k];
        char *dst = (char *)scratch + state->stripe_slot[k];
        int bound = (int)state->stripe_bound[k];
        if (is_keyframe) {
            memcpy(pending + off, base + off, len);
            comp[k] = LZ4_compress_default((const char *)base + off, dst, (int)len, bound);
        } else {
            (void)delta_xor_update_range(base + off, ref + off, delta + off, pending + off, len);
            comp[k] = LZ4_compress_fast((const char *)delta + off, dst, (int)len, bound, 32);
        }
    });
    *t_work_out = CACurrentMediaTime();

    size_t table = stripe_table_bytes(count);
    size_t total = table;
    size_t dst_off_arr[KEYDRD_STRIPE_MAX];
    size_t *dst_off = dst_off_arr;
    for (int k = 0; k < count; k++) {
        if (comp[k] <= 0) {
            os_log_error(fc_log(), "compress_striped: stripe %d failed (%d), frame not emitted", k, comp[k]);
            return -1;
        }
        dst_off[k] = total;
        total += (size_t)comp[k];
    }
    if (total > out_cap) {
        os_log_error(fc_log(), "compress_striped: payload %zu exceeds capacity %zu", total, out_cap);
        return -1;
    }

    delta_buffer_flip(db);   /* once per frame, after the join */

    out_buf[0] = (uint8_t)count;
    for (int k = 0; k < count; k++) {
        uint8_t *e = out_buf + 1 + (size_t)k * 8;
        uint32_t rl = (uint32_t)state->stripe_len[k];
        uint32_t cl = (uint32_t)comp[k];
        e[0] = rl & 0xFF; e[1] = (rl >> 8) & 0xFF; e[2] = (rl >> 16) & 0xFF; e[3] = (rl >> 24) & 0xFF;
        e[4] = cl & 0xFF; e[5] = (cl >> 8) & 0xFF; e[6] = (cl >> 16) & 0xFF; e[7] = (cl >> 24) & 0xFF;
    }
    dispatch_apply((size_t)count, workers, ^(size_t k) {
        memcpy(out_buf + dst_off[k], scratch + state->stripe_slot[k], (size_t)comp[k]);
    });
    return (int)total;
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
    if (state->stripe_scratch) {
        free(state->stripe_scratch);
        state->stripe_scratch = NULL;
    }
    state->stripe_count = 1;
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

    /* Every buffer here (reference, delta, packed rows, stripes) is sized for frame_bytes.
     * A capture surface of any other size (live SCStream reconfigure on a transport switch,
     * crash 2026-11-15 22:35 in delta_xor_update_range) would be read or packed out of
     * bounds. Refuse it: nothing compressed, reference not flipped (same as any failure). */
    if (packedBytesPerRow * surfaceHeight != bytes || surfaceBytesPerRow < packedBytesPerRow) {
        static int sizeMismatchCount = 0;
        sizeMismatchCount++;
        if (sizeMismatchCount <= 10 || sizeMismatchCount % 120 == 0) {
            os_log_error(fc_log(), "compress_frame: surface %zux%zu stride=%zu does not match compressor frameBytes=%zu, frame skipped count=%d",
                         surfaceWidth, surfaceHeight, surfaceBytesPerRow, bytes, sizeMismatchCount);
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        return -2;
    }

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

    /* End-to-end picture check: sampled hash of the exact pixels being compressed, keyed by
     * the 16-bit wire seq. The iPad logs the same hash after decompress (FRAME-HASH ipad). */
    if ((state->seq % 30) == 0) {
        os_log(fc_log(), "FRAME-HASH mac seq=%u hash=%016llx",
               (unsigned)(state->seq & 0xFFFF),
               (unsigned long long)frame_sample_hash(base, bytes));
    }

    /* Determine keyframe vs delta */
    int is_keyframe = (state->seq == 0) ||
                      (state->seq % state->keyframe_interval_frames == 0);

    int compressed = 0;
    uint8_t flags = 0;
    int should_log_frame_check = (state->seq < 10) || (state->seq % 120 == 0);

    if (state->stripe_count > 1) {
        /* ---- Striped parallel path (keyframe or delta) ---- */
        double t_work = 0;
        compressed = compress_striped(state, (const uint8_t *)base, is_keyframe,
                                      out->buf, out->buf_capacity, &t_work);
        if (compressed <= 0) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            return -1;
        }
        flags = (uint8_t)((is_keyframe ? KEYDRD_FLAG_KEYFRAME : KEYDRD_FLAG_DELTA) | KEYDRD_FLAG_STRIPED);
        if (is_keyframe) state->last_keyframe_compressed = (size_t)compressed;
        {
            static int stripeProbeCount = 0;
            double workMs = (t_work - t_pack) * 1000;
            double packMs = (CACurrentMediaTime() - t_work) * 1000;
            if (stripeProbeCount < 10 || stripeProbeCount % 200 == 0 || workMs > 8.0) {
                os_log(fc_log(), "stripe_detail #%d: %s stripes=%d xor+lz4=%.1fms pack=%.1fms compressed=%d bytes",
                       stripeProbeCount, is_keyframe ? "KEY" : "delta", state->stripe_count,
                       workMs, packMs, compressed);
            }
            stripeProbeCount++;
        }
    } else if (is_keyframe) {
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

        /* Compress the delta.
         * Acceleration 32: ~2x faster than acc=8 at cost of ~20% worse ratio.
         * For 2752x1786 delta frames, this keeps compress under 2ms even for
         * noisy content with 1-5MB deltas. The ratio tradeoff is acceptable
         * because USB NCM has ample bandwidth (300Mbps). */
        compressed = LZ4_compress_fast(
            (const char *)state->delta_scratch,
            (char *)out->buf,
            (int)bytes,
            (int)out->buf_capacity,
            32);

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
