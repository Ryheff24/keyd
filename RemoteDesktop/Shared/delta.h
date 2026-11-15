#pragma once

#include <stddef.h>
#include <stdint.h>
#include <pthread.h>

/* Double-buffered XOR delta encoder/decoder.
 *
 * macOS (encode side): compute_delta + update_keyframe_reference
 *   - Requires pthread_rwlock_t because capture thread and update thread
 *     may race on the reference buffer.
 *
 * iPadOS (decode side): apply_delta
 *   - Single-threaded, no locking needed.
 */

typedef struct {
    uint8_t         *buf[2];       /* two reference buffers */
    int              active;       /* index of current reference (0 or 1) */
    pthread_rwlock_t lock;         /* protects buf/active swap */
    size_t           frame_bytes;  /* size of each buffer in bytes */
} DeltaBuffer;

/* Initialize double-buffer. Returns 0 on success, -1 on failure. */
int delta_buffer_init(DeltaBuffer *db, size_t frame_bytes);

/* Free buffers and destroy lock. */
void delta_buffer_destroy(DeltaBuffer *db);

/* Compute XOR delta: current vs active reference -> delta_out.
 * delta_out must be at least frame_bytes. Takes read lock. */
void compute_delta(DeltaBuffer *db, const void *current, void *delta_out);

/* Apply XOR delta on decode side (no locking). */
void apply_delta(const void *delta, const void *prev_keyframe,
                 void *output, size_t frame_bytes);

/* Update reference buffer with new keyframe. Takes write lock, swaps active. */
void update_keyframe_reference(DeltaBuffer *db, const void *keyframe);

/* Fused: compute XOR delta AND update reference in one pass.
 * Eliminates the separate update_keyframe_reference memcpy.
 * Returns 1 if any pixel changed (dirty), 0 if frame identical.
 * Uses NEON SIMD on ARM64 for maximum throughput.
 * MUST be called from a serial queue (no locking). */
int compute_delta_and_update(DeltaBuffer *db, const void *current, void *delta_out);

/* ---- Striped frames (KEYDRD_FLAG_STRIPED, tla/StripeSync.tla) ----
 * A frame is split into `count` contiguous byte ranges (stripes), each XOR-delta'd against
 * its own slice of the reference and LZ4-compressed as an independent block, so both ends
 * can work on stripes in parallel. Each end joins all stripe workers before the frame leaves
 * it (Mac: before flipping the reference and emitting; iPad: before the renderer copies).
 *
 * Wire payload: u8 count, then count x {u32 raw_len, u32 comp_len} little-endian, then the
 * count LZ4 blocks back to back. Raw ranges are contiguous and sum to frame_bytes. */
#define KEYDRD_STRIPE_MAX 16

static inline size_t stripe_table_bytes(int count) { return 1 + (size_t)count * 8; }

/* Split frame_bytes into `count` ranges; every range but the last is a multiple of 128 bytes. */
void stripe_layout(size_t frame_bytes, int count, size_t *offs, size_t *lens);

/* Fused XOR + reference copy over one byte range: delta = src ^ ref, new_ref = src.
 * Returns 1 if any byte differs. Ranges of different stripes may run concurrently. */
int delta_xor_update_range(const uint8_t *src, const uint8_t *ref,
                           uint8_t *delta, uint8_t *new_ref, size_t n);

/* Make the pending reference buffer active (call once per frame, after all ranges). */
void delta_buffer_flip(DeltaBuffer *db);

/* iPad: decode a striped payload in parallel and join before returning.
 * Keyframe: out = block, ref = out. Delta: v = block ^ ref, out = v, ref = v.
 * scratch must hold frame_bytes. Returns 0 on success, negative on a malformed payload or
 * LZ4 error (out/ref may then hold a partly decoded frame: the caller must not render it). */
int striped_decode(const uint8_t *payload, size_t payload_len, int is_keyframe,
                   uint8_t *out, uint8_t *ref, uint8_t *scratch, size_t frame_bytes);

/* Sampled 64-bit FNV-1a over every 512th 8-byte word plus the last word of the frame.
 * Cheap (~5k words for a 2752x1786 BGRA frame) and identical on both ends, so the Mac
 * (pre-compress, packed pixels) and the iPad (post-decompress) can log it for the same seq
 * and an E2E check can count mismatches. A desynchronized XOR reference garbles the whole
 * frame, which sparse sampling detects. Not a cryptographic or exhaustive check. */
uint64_t frame_sample_hash(const void *buf, size_t len);
