#include "delta.h"
#include <stdlib.h>
#include <string.h>

int delta_buffer_init(DeltaBuffer *db, size_t frame_bytes) {
    db->frame_bytes = frame_bytes;
    db->active = 0;

    db->buf[0] = (uint8_t *)malloc(frame_bytes);
    if (!db->buf[0]) return -1;

    db->buf[1] = (uint8_t *)malloc(frame_bytes);
    if (!db->buf[1]) {
        free(db->buf[0]);
        db->buf[0] = NULL;
        return -1;
    }

    memset(db->buf[0], 0, frame_bytes);
    memset(db->buf[1], 0, frame_bytes);

    if (pthread_rwlock_init(&db->lock, NULL) != 0) {
        free(db->buf[0]);
        free(db->buf[1]);
        db->buf[0] = NULL;
        db->buf[1] = NULL;
        return -1;
    }

    return 0;
}

void delta_buffer_destroy(DeltaBuffer *db) {
    if (db->buf[0]) { free(db->buf[0]); db->buf[0] = NULL; }
    if (db->buf[1]) { free(db->buf[1]); db->buf[1] = NULL; }
    pthread_rwlock_destroy(&db->lock);
}

void compute_delta(DeltaBuffer *db, const void *current, void *delta_out) {
    pthread_rwlock_rdlock(&db->lock);

    const uint64_t *src = (const uint64_t *)current;
    const uint64_t *ref = (const uint64_t *)db->buf[db->active];
    uint64_t       *dst = (uint64_t *)delta_out;

    size_t stride = db->frame_bytes / sizeof(uint64_t);
    size_t remainder = db->frame_bytes % sizeof(uint64_t);

    for (size_t i = 0; i < stride; i++) {
        dst[i] = src[i] ^ ref[i];
    }

    /* Handle remaining bytes that don't fill a full uint64_t */
    if (remainder > 0) {
        const uint8_t *src_tail = (const uint8_t *)current + stride * sizeof(uint64_t);
        const uint8_t *ref_tail = (const uint8_t *)db->buf[db->active] + stride * sizeof(uint64_t);
        uint8_t       *dst_tail = (uint8_t *)delta_out + stride * sizeof(uint64_t);
        for (size_t i = 0; i < remainder; i++) {
            dst_tail[i] = src_tail[i] ^ ref_tail[i];
        }
    }

    pthread_rwlock_unlock(&db->lock);
}

void apply_delta(const void *delta, const void *prev_keyframe,
                 void *output, size_t frame_bytes) {
    const uint64_t *d = (const uint64_t *)delta;
    const uint64_t *p = (const uint64_t *)prev_keyframe;
    uint64_t       *o = (uint64_t *)output;

    size_t stride = frame_bytes / sizeof(uint64_t);
    size_t remainder = frame_bytes % sizeof(uint64_t);

    for (size_t i = 0; i < stride; i++) {
        o[i] = d[i] ^ p[i];
    }

    if (remainder > 0) {
        const uint8_t *d_tail = (const uint8_t *)delta + stride * sizeof(uint64_t);
        const uint8_t *p_tail = (const uint8_t *)prev_keyframe + stride * sizeof(uint64_t);
        uint8_t       *o_tail = (uint8_t *)output + stride * sizeof(uint64_t);
        for (size_t i = 0; i < remainder; i++) {
            o_tail[i] = d_tail[i] ^ p_tail[i];
        }
    }
}

void update_keyframe_reference(DeltaBuffer *db, const void *keyframe) {
    /* Copy into the pending (inactive) buffer first */
    int pending = 1 - db->active;
    memcpy(db->buf[pending], keyframe, db->frame_bytes);

    /* Take write lock, swap active index, unlock */
    pthread_rwlock_wrlock(&db->lock);
    db->active = pending;
    pthread_rwlock_unlock(&db->lock);
}
