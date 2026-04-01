#pragma once

/*
 * FrameCompressor.h
 * Pure C hot-path compressor for screen capture frames.
 *
 * Provides LZ4 block compression with XOR delta encoding.
 * Operates on IOSurface-backed frames delivered by ScreenCaptureKit.
 *
 * CALLER CONTRACT:
 *   - Caller MUST hold a CFRetain on the CMSampleBuffer that owns
 *     the IOSurface until compress_frame() returns. The compressor
 *     locks the IOSurface for read access and requires the backing
 *     memory to remain valid for the entire duration (RD-COMP-05).
 *   - compress_frame() MUST be called on state->compress_queue
 *     (enforced via dispatch_assert_queue at entry).
 */

#include "protocol.h"
#include "delta.h"
#include "lz4.h"

#include <IOSurface/IOSurface.h>
#include <CoreMedia/CoreMedia.h>
#include <dispatch/dispatch.h>

/* Compressed frame output — filled by compress_frame(). */
typedef struct {
    uint8_t         *buf;              /* pre-allocated output buffer */
    size_t           buf_capacity;     /* capacity in bytes */
    size_t           compressed_size;  /* actual compressed bytes after call */
    MediaFrameHeader header;           /* filled header, ready to prepend */
} CompressOutput;

/* Compressor state — one per capture session. */
typedef struct {
    DeltaBuffer      delta_buf;                 /* double-buffered XOR reference */
    uint32_t         seq;                       /* frame sequence counter */
    uint32_t         keyframe_interval_frames;  /* keyframes every N frames (default 120) */
    CompressOutput   output;                    /* pre-allocated output */
    uint8_t         *delta_scratch;             /* pre-allocated scratch for delta XOR */
    uint8_t         *packed_buf;               /* pre-allocated stride-packing buffer (avoids malloc/frame) */
    size_t           frame_bytes;               /* raw frame size in bytes */
    size_t           last_keyframe_compressed;  /* compressed size of last keyframe */
    dispatch_queue_t compress_queue;            /* high-priority serial queue */
} FrameCompressorState;

/*
 * Initialize compressor for frames of the given size.
 * Returns 0 on success, -1 on failure.
 */
int frame_compressor_init(FrameCompressorState *state, size_t frame_bytes);

/*
 * Free all compressor resources.
 */
void frame_compressor_destroy(FrameCompressorState *state);

/*
 * Compress a single frame from an IOSurface.
 *
 * Locks the IOSurface for read, compresses via LZ4 (keyframe or delta),
 * unlocks, and fills out->header + out->compressed_size.
 *
 * Returns 0 on success, -1 on error (LZ4 failure).
 */
int compress_frame(FrameCompressorState *state,
                   IOSurfaceRef surface,
                   CMSampleBufferRef sampleBuf,
                   uint64_t capture_ts_us,
                   CompressOutput *out);
