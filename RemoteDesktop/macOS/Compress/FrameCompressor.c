#include "FrameCompressor.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>  /* crc32() — always available on macOS */

/* ---- Initialization ---- */

int frame_compressor_init(FrameCompressorState *state, size_t frame_bytes) {
    memset(state, 0, sizeof(*state));

    state->frame_bytes = frame_bytes;
    state->seq = 0;
    state->keyframe_interval_frames = 120; /* ~1s at 120fps */
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

    /* Lock IOSurface for read access */
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);

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
        /* Stride mismatch — pack rows tightly */
        packed_buf = (uint8_t *)malloc(bytes);
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

    /* Determine keyframe vs delta */
    int is_keyframe = (state->seq == 0) ||
                      (state->seq % state->keyframe_interval_frames == 0);

    int compressed = 0;
    uint8_t flags = 0;

    if (is_keyframe) {
        /* ---- Keyframe path ---- */
        compressed = LZ4_compress_default(
            (const char *)base,
            (char *)out->buf,
            (int)bytes,
            (int)out->buf_capacity);

        if (compressed <= 0) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            free(packed_buf);
            return -1;
        }

        flags = KEYDRD_FLAG_KEYFRAME;
        state->last_keyframe_compressed = (size_t)compressed;

        /* Update double-buffer reference with this keyframe */
        update_keyframe_reference(&state->delta_buf, base);
    } else {
        /* ---- Delta path ---- */
        /* Compute XOR delta into pre-allocated scratch buffer */
        compute_delta(&state->delta_buf, base, state->delta_scratch);

        /* Compress the delta */
        compressed = LZ4_compress_default(
            (const char *)state->delta_scratch,
            (char *)out->buf,
            (int)bytes,
            (int)out->buf_capacity);

        if (compressed <= 0) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            free(packed_buf);
            return -1;
        }

        /*
         * RD-COMP-03: Delta threshold check.
         * If compressed delta > 60% of last keyframe compressed size,
         * the scene has changed too much — discard delta, send keyframe.
         */
        if (state->last_keyframe_compressed > 0 &&
            (size_t)compressed > (state->last_keyframe_compressed * 6 / 10)) {
            /* Fallback to keyframe */
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
            update_keyframe_reference(&state->delta_buf, base);
        } else {
            flags = KEYDRD_FLAG_DELTA;
            /* Update reference with current frame for next delta */
            update_keyframe_reference(&state->delta_buf, base);
        }
    }

    /* Unlock IOSurface — all pointer access complete */
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    /* Free stride-packing buffer if allocated */
    if (packed_buf) {
        free(packed_buf);
        packed_buf = NULL;
    }

    /* Fill output */
    out->compressed_size = (size_t)compressed;

    /* Use capture-time wall clock (CLOCK_REALTIME microseconds) stamped
     * in ScreenCapture.didOutputSampleBuffer — consistent with HEVC path
     * and comparable to iPad's clock_gettime(CLOCK_REALTIME). */
    uint64_t ts_us = capture_ts_us;

    /* Compute CRC-32 of compressed payload */
    uint32_t payload_crc = (uint32_t)crc32(0L, out->buf, (uInt)compressed);

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
