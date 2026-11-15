#include "delta.h"
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) || defined(__arm64__)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif

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

int compute_delta_and_update(DeltaBuffer *db, const void *current, void *delta_out) {
    /*
     * Fused XOR-delta + reference-update in one pass.
     * For each byte: delta = current ^ ref, new_ref = current.
     * Returns 1 if any byte differs (frame dirty), 0 if identical.
     *
     * Called from serial compress_queue — no locking needed.
     */
    int pending = 1 - db->active;
    const uint8_t *src = (const uint8_t *)current;
    const uint8_t *ref = db->buf[db->active];
    uint8_t *delta = (uint8_t *)delta_out;
    uint8_t *new_ref = db->buf[pending];
    size_t n = db->frame_bytes;

#if HAVE_NEON
    /* ARM NEON: process 128 bytes per iteration (8x 16-byte vectors).
     * Fuses XOR + copy + dirty detection in a single pass over memory. */
    uint8x16_t acc0 = vdupq_n_u8(0);
    uint8x16_t acc1 = vdupq_n_u8(0);

    size_t i = 0;
    for (; i + 128 <= n; i += 128) {
        /* Load 128 bytes of current and reference */
        uint8x16_t c0 = vld1q_u8(src + i);
        uint8x16_t c1 = vld1q_u8(src + i + 16);
        uint8x16_t c2 = vld1q_u8(src + i + 32);
        uint8x16_t c3 = vld1q_u8(src + i + 48);
        uint8x16_t c4 = vld1q_u8(src + i + 64);
        uint8x16_t c5 = vld1q_u8(src + i + 80);
        uint8x16_t c6 = vld1q_u8(src + i + 96);
        uint8x16_t c7 = vld1q_u8(src + i + 112);

        uint8x16_t r0 = vld1q_u8(ref + i);
        uint8x16_t r1 = vld1q_u8(ref + i + 16);
        uint8x16_t r2 = vld1q_u8(ref + i + 32);
        uint8x16_t r3 = vld1q_u8(ref + i + 48);
        uint8x16_t r4 = vld1q_u8(ref + i + 64);
        uint8x16_t r5 = vld1q_u8(ref + i + 80);
        uint8x16_t r6 = vld1q_u8(ref + i + 96);
        uint8x16_t r7 = vld1q_u8(ref + i + 112);

        /* XOR: delta = current ^ reference */
        uint8x16_t d0 = veorq_u8(c0, r0);
        uint8x16_t d1 = veorq_u8(c1, r1);
        uint8x16_t d2 = veorq_u8(c2, r2);
        uint8x16_t d3 = veorq_u8(c3, r3);
        uint8x16_t d4 = veorq_u8(c4, r4);
        uint8x16_t d5 = veorq_u8(c5, r5);
        uint8x16_t d6 = veorq_u8(c6, r6);
        uint8x16_t d7 = veorq_u8(c7, r7);

        /* Store delta */
        vst1q_u8(delta + i, d0);
        vst1q_u8(delta + i + 16, d1);
        vst1q_u8(delta + i + 32, d2);
        vst1q_u8(delta + i + 48, d3);
        vst1q_u8(delta + i + 64, d4);
        vst1q_u8(delta + i + 80, d5);
        vst1q_u8(delta + i + 96, d6);
        vst1q_u8(delta + i + 112, d7);

        /* Copy current → new reference */
        vst1q_u8(new_ref + i, c0);
        vst1q_u8(new_ref + i + 16, c1);
        vst1q_u8(new_ref + i + 32, c2);
        vst1q_u8(new_ref + i + 48, c3);
        vst1q_u8(new_ref + i + 64, c4);
        vst1q_u8(new_ref + i + 80, c5);
        vst1q_u8(new_ref + i + 96, c6);
        vst1q_u8(new_ref + i + 112, c7);

        /* Accumulate dirty bits */
        acc0 = vorrq_u8(acc0, vorrq_u8(vorrq_u8(d0, d1), vorrq_u8(d2, d3)));
        acc1 = vorrq_u8(acc1, vorrq_u8(vorrq_u8(d4, d5), vorrq_u8(d6, d7)));
    }

    /* Handle remainder (< 128 bytes) */
    int dirty_tail = 0;
    for (; i < n; i++) {
        uint8_t d = src[i] ^ ref[i];
        delta[i] = d;
        new_ref[i] = src[i];
        dirty_tail |= d;
    }

    db->active = pending;

    /* Check if any dirty: reduce NEON accumulators */
    uint8x16_t acc = vorrq_u8(acc0, acc1);
    return (vmaxvq_u8(acc) != 0) || (dirty_tail != 0);

#else
    /* Scalar fallback for non-ARM64 */
    const uint64_t *src64 = (const uint64_t *)current;
    const uint64_t *ref64 = (const uint64_t *)ref;
    uint64_t *delta64 = (uint64_t *)delta_out;
    uint64_t *new_ref64 = (uint64_t *)new_ref;

    uint64_t dirty_acc = 0;
    size_t stride = n / sizeof(uint64_t);
    for (size_t i = 0; i < stride; i++) {
        uint64_t s = src64[i];
        uint64_t d = s ^ ref64[i];
        delta64[i] = d;
        new_ref64[i] = s;
        dirty_acc |= d;
    }

    size_t remainder = n % sizeof(uint64_t);
    if (remainder > 0) {
        size_t off = stride * sizeof(uint64_t);
        for (size_t i = 0; i < remainder; i++) {
            uint8_t d = src[off + i] ^ ref[off + i];
            delta[off + i] = d;
            new_ref[off + i] = src[off + i];
            dirty_acc |= d;
        }
    }

    db->active = pending;
    return dirty_acc != 0;
#endif
}

uint64_t frame_sample_hash(const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    uint64_t h = 1469598103934665603ULL;
    size_t words = len / 8;
    for (size_t i = 0; i < words; i += 512) {
        uint64_t w;
        memcpy(&w, p + i * 8, 8);
        h ^= w;
        h *= 1099511628211ULL;
    }
    if (words > 0) {
        uint64_t w;
        memcpy(&w, p + (words - 1) * 8, 8);
        h ^= w;
        h *= 1099511628211ULL;
    }
    h ^= (uint64_t)len;
    h *= 1099511628211ULL;
    return h;
}
