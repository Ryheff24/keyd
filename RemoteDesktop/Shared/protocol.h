#pragma once

#include <stdint.h>

/* ---- Service Constants ---- */
#define KEYDRD_MAGIC       0x4B44
#define KEYDRD_SERVICE     "_keydrd._tcp"
#define KEYDRD_MEDIA_PORT  14567  /* UDP */
#define KEYDRD_INPUT_PORT  14568  /* TCP */

/* ---- MediaFrameHeader flags (bit layout) ---- */
#define KEYDRD_FLAG_HEVC       (1 << 0)   /* bit 0: HEVC-encoded frame */
#define KEYDRD_FLAG_KEYFRAME   (1 << 1)   /* bit 1: keyframe / IDR */
#define KEYDRD_FLAG_LAST_CHUNK (1 << 2)   /* bit 2: last chunk of frame */
#define KEYDRD_FLAG_DELTA      (1 << 6)   /* bit 6: XOR delta frame */

/* ---- MediaFrameHeader (24 bytes, packed) ----
 * Field sizes chosen to fit 24 bytes exactly:
 *   seq is u16 (wraps at 65535 -- adequate for streaming with wrap-around comparison)
 *   chunk_idx/chunk_total are u8 (max 255 chunks per frame -- sufficient for MTU chunking)
 *   1 byte reserved for future use / alignment
 */
typedef struct __attribute__((packed)) {
    uint16_t magic;          /* KEYDRD_MAGIC */
    uint8_t  flags;          /* see KEYDRD_FLAG_* */
    uint16_t seq;            /* frame sequence number (wrapping) */
    uint8_t  chunk_idx;      /* chunk index within frame */
    uint8_t  chunk_total;    /* total chunks in frame */
    uint8_t  reserved;       /* reserved, set to 0 */
    uint32_t payload_size;   /* compressed payload bytes */
    uint64_t ts_us;          /* capture timestamp (microseconds) */
    uint32_t crc32;          /* CRC-32 of payload */
} MediaFrameHeader;

_Static_assert(sizeof(MediaFrameHeader) == 24,
               "MediaFrameHeader must be exactly 24 bytes");

/* ---- InputEventHeader type values ---- */
#define KEYDRD_INPUT_MOUSE_MOVE    0x01
#define KEYDRD_INPUT_CLICK         0x02
#define KEYDRD_INPUT_SCROLL        0x03
#define KEYDRD_INPUT_KEY           0x10
#define KEYDRD_INPUT_MODE_CHANGE   0x20
#define KEYDRD_INPUT_KEEPALIVE     0x30
#define KEYDRD_INPUT_LATENCY_PROBE 0xFF

/* ---- InputEventHeader (9 bytes, packed) ---- */
typedef struct __attribute__((packed)) {
    uint8_t  type;           /* KEYDRD_INPUT_* */
    uint64_t ts_us;          /* event timestamp (microseconds) */
} InputEventHeader;

_Static_assert(sizeof(InputEventHeader) == 9,
               "InputEventHeader must be exactly 9 bytes");

/* ---- SessionHandshakeMessage (packed) ---- */
#define KEYDRD_MSG_SESSION_HANDSHAKE 0x01

/* Session capabilities flags */
#define KEYDRD_CAP_LZ4           (1 << 0)   /* bit 0: LZ4 compression */
#define KEYDRD_CAP_HEVC          (1 << 1)   /* bit 1: HEVC encoding */
#define KEYDRD_CAP_ECO_AVAILABLE (1 << 2)   /* bit 2: eco mode available */

typedef struct __attribute__((packed)) {
    uint16_t magic;          /* KEYDRD_MAGIC */
    uint8_t  msg_type;       /* KEYDRD_MSG_SESSION_HANDSHAKE */
    uint32_t display_width;  /* capture width in pixels */
    uint32_t display_height; /* capture height in pixels */
    float    scale_factor;   /* display scale (e.g. 2.0 for Retina) */
    float    aspect_ratio;   /* width / height */
    uint8_t  capabilities;   /* KEYDRD_CAP_* */
    uint8_t  max_fps;        /* maximum frames per second */
    uint8_t  agent_version;  /* protocol version for compatibility */
    uint32_t reserved;       /* future use, set to 0 */
} SessionHandshakeMessage;
