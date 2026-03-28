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
