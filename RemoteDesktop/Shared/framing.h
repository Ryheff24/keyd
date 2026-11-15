#pragma once
/*
 * iPad -> Mac message framing on the TCP input/control connection (tla/Framing.tla).
 *
 * Wire: every message is a 4-byte big-endian payload length followed by the payload
 * (InputEventHeader + body). The Mac appends each received TCP region to a per-connection
 * buffer and dispatches whole payloads only, keeping any partial tail for the next region.
 * The Mac -> iPad direction already uses the same 4-byte big-endian prefix.
 */
#include <stddef.h>
#include <stdint.h>

#define KEYDRD_FRAME_PREFIX_BYTES 4
/* Control and input messages are small; anything larger is a protocol error. */
#define KEYDRD_CONTROL_FRAME_MAX  (64u * 1024u)

/*
 * Look for one whole frame at the start of buf[0..avail).
 * Returns  1: a frame; payload and payload_len point into buf, consumed = prefix + payload.
 *          0: need more bytes (keep buf as is).
 *         -1: invalid length (0 or > KEYDRD_CONTROL_FRAME_MAX); drop the connection.
 */
static inline int keydrd_frame_next(const uint8_t *buf, size_t avail,
                                    size_t *consumed,
                                    const uint8_t **payload, size_t *payload_len) {
    if (avail < KEYDRD_FRAME_PREFIX_BYTES) return 0;
    uint32_t n = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) |
                 ((uint32_t)buf[2] << 8) | (uint32_t)buf[3];
    if (n == 0 || n > KEYDRD_CONTROL_FRAME_MAX) return -1;
    if (avail - KEYDRD_FRAME_PREFIX_BYTES < n) return 0;
    *payload = buf + KEYDRD_FRAME_PREFIX_BYTES;
    *payload_len = n;
    *consumed = KEYDRD_FRAME_PREFIX_BYTES + (size_t)n;
    return 1;
}
