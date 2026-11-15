#include "delta.h"
#include "lz4.h"
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>

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

int delta_xor_update_range(const uint8_t *src, const uint8_t *ref,
                           uint8_t *delta, uint8_t *new_ref, size_t n) {
    /* delta = src ^ ref, new_ref = src, in one pass. Returns 1 if any byte differs. */
#if HAVE_NEON
    uint8x16_t acc0 = vdupq_n_u8(0);
    uint8x16_t acc1 = vdupq_n_u8(0);
    size_t i = 0;
    for (; i + 128 <= n; i += 128) {
        uint8x16_t c0 = vld1q_u8(src + i);
        uint8x16_t c1 = vld1q_u8(src + i + 16);
        uint8x16_t c2 = vld1q_u8(src + i + 32);
        uint8x16_t c3 = vld1q_u8(src + i + 48);
        uint8x16_t c4 = vld1q_u8(src + i + 64);
        uint8x16_t c5 = vld1q_u8(src + i + 80);
        uint8x16_t c6 = vld1q_u8(src + i + 96);
        uint8x16_t c7 = vld1q_u8(src + i + 112);

        uint8x16_t d0 = veorq_u8(c0, vld1q_u8(ref + i));
        uint8x16_t d1 = veorq_u8(c1, vld1q_u8(ref + i + 16));
        uint8x16_t d2 = veorq_u8(c2, vld1q_u8(ref + i + 32));
        uint8x16_t d3 = veorq_u8(c3, vld1q_u8(ref + i + 48));
        uint8x16_t d4 = veorq_u8(c4, vld1q_u8(ref + i + 64));
        uint8x16_t d5 = veorq_u8(c5, vld1q_u8(ref + i + 80));
        uint8x16_t d6 = veorq_u8(c6, vld1q_u8(ref + i + 96));
        uint8x16_t d7 = veorq_u8(c7, vld1q_u8(ref + i + 112));

        vst1q_u8(delta + i, d0);
        vst1q_u8(delta + i + 16, d1);
        vst1q_u8(delta + i + 32, d2);
        vst1q_u8(delta + i + 48, d3);
        vst1q_u8(delta + i + 64, d4);
        vst1q_u8(delta + i + 80, d5);
        vst1q_u8(delta + i + 96, d6);
        vst1q_u8(delta + i + 112, d7);

        vst1q_u8(new_ref + i, c0);
        vst1q_u8(new_ref + i + 16, c1);
        vst1q_u8(new_ref + i + 32, c2);
        vst1q_u8(new_ref + i + 48, c3);
        vst1q_u8(new_ref + i + 64, c4);
        vst1q_u8(new_ref + i + 80, c5);
        vst1q_u8(new_ref + i + 96, c6);
        vst1q_u8(new_ref + i + 112, c7);

        acc0 = vorrq_u8(acc0, vorrq_u8(vorrq_u8(d0, d1), vorrq_u8(d2, d3)));
        acc1 = vorrq_u8(acc1, vorrq_u8(vorrq_u8(d4, d5), vorrq_u8(d6, d7)));
    }
    int dirty_tail = 0;
    for (; i < n; i++) {
        uint8_t d = src[i] ^ ref[i];
        delta[i] = d;
        new_ref[i] = src[i];
        dirty_tail |= d;
    }
    return (vmaxvq_u8(vorrq_u8(acc0, acc1)) != 0) || (dirty_tail != 0);
#else
    uint8_t acc = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t d = src[i] ^ ref[i];
        delta[i] = d;
        new_ref[i] = src[i];
        acc |= d;
    }
    return acc != 0;
#endif
}

void delta_buffer_flip(DeltaBuffer *db) {
    db->active = 1 - db->active;
}

int compute_delta_and_update(DeltaBuffer *db, const void *current, void *delta_out) {
    /*
     * Fused XOR-delta + reference-update in one pass over the whole frame.
     * Called from serial compress_queue — no locking needed.
     */
    int pending = 1 - db->active;
    int dirty = delta_xor_update_range((const uint8_t *)current, db->buf[db->active],
                                       (uint8_t *)delta_out, db->buf[pending], db->frame_bytes);
    db->active = pending;
    return dirty;
}

void stripe_layout(size_t frame_bytes, int count, size_t *offs, size_t *lens) {
    if (count < 1) count = 1;
    size_t base = (frame_bytes / (size_t)count) & ~(size_t)127;
    size_t off = 0;
    for (int k = 0; k < count; k++) {
        size_t len = (k == count - 1) ? frame_bytes - off : base;
        offs[k] = off;
        lens[k] = len;
        off += len;
    }
}

static inline uint32_t rd_u32le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* out = v, ref = v where v = delta ^ ref, one pass. */
static void apply_delta_inplace(const uint8_t *delta, uint8_t *ref, uint8_t *out, size_t n) {
    size_t i = 0;
#if HAVE_NEON
    for (; i + 64 <= n; i += 64) {
        uint8x16_t v0 = veorq_u8(vld1q_u8(delta + i),      vld1q_u8(ref + i));
        uint8x16_t v1 = veorq_u8(vld1q_u8(delta + i + 16), vld1q_u8(ref + i + 16));
        uint8x16_t v2 = veorq_u8(vld1q_u8(delta + i + 32), vld1q_u8(ref + i + 32));
        uint8x16_t v3 = veorq_u8(vld1q_u8(delta + i + 48), vld1q_u8(ref + i + 48));
        vst1q_u8(out + i, v0);      vst1q_u8(ref + i, v0);
        vst1q_u8(out + i + 16, v1); vst1q_u8(ref + i + 16, v1);
        vst1q_u8(out + i + 32, v2); vst1q_u8(ref + i + 32, v2);
        vst1q_u8(out + i + 48, v3); vst1q_u8(ref + i + 48, v3);
    }
#endif
    for (; i < n; i++) {
        uint8_t v = delta[i] ^ ref[i];
        out[i] = v;
        ref[i] = v;
    }
}

int striped_decode(const uint8_t *payload, size_t payload_len, int is_keyframe,
                   uint8_t *out, uint8_t *ref, uint8_t *scratch, size_t frame_bytes) {
    if (payload_len < 1) return -1;
    int count = payload[0];
    if (count < 1 || count > KEYDRD_STRIPE_MAX) return -2;
    size_t table = stripe_table_bytes(count);
    if (payload_len < table) return -3;

    /* Parse and validate the whole table before any worker runs. */
    size_t raw_off_a[KEYDRD_STRIPE_MAX], raw_len_a[KEYDRD_STRIPE_MAX];
    size_t comp_off_a[KEYDRD_STRIPE_MAX], comp_len_a[KEYDRD_STRIPE_MAX];
    /* Blocks cannot capture arrays; workers read them through these pointers. */
    size_t *raw_off = raw_off_a, *raw_len = raw_len_a, *comp_off = comp_off_a, *comp_len = comp_len_a;
    size_t r = 0, c = table;
    for (int k = 0; k < count; k++) {
        size_t rl = rd_u32le(payload + 1 + (size_t)k * 8);
        size_t cl = rd_u32le(payload + 1 + (size_t)k * 8 + 4);
        if (rl == 0 || rl > frame_bytes - r) return -4;
        if (cl == 0 || cl > payload_len - c) return -5;
        raw_off[k] = r;  raw_len[k] = rl;  r += rl;
        comp_off[k] = c; comp_len[k] = cl; c += cl;
    }
    if (r != frame_bytes || c != payload_len) return -6;

    __block int failures = 0;
    /* dispatch_apply returns only after every stripe worker has finished (IpadJoin). */
    dispatch_apply((size_t)count, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t k) {
        const char *src = (const char *)payload + comp_off[k];
        uint8_t *dst = is_keyframe ? out + raw_off[k] : scratch + raw_off[k];
        int got = LZ4_decompress_safe(src, (char *)dst, (int)comp_len[k], (int)raw_len[k]);
        if (got != (int)raw_len[k]) {
            __atomic_fetch_add(&failures, 1, __ATOMIC_RELAXED);
            return;
        }
        if (is_keyframe) {
            memcpy(ref + raw_off[k], out + raw_off[k], raw_len[k]);
        } else {
            apply_delta_inplace(scratch + raw_off[k], ref + raw_off[k], out + raw_off[k], raw_len[k]);
        }
    });
    return failures == 0 ? 0 : -7;
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
