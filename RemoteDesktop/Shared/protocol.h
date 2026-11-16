#pragma once

#include <stdint.h>

/* ---- Service Constants ---- */
#define KEYDRD_MAGIC       0x4B44
#define KEYDRD_SERVICE     "_keydrd._tcp"
#define KEYDRD_MEDIA_PORT    14567  /* UDP */
#define KEYDRD_INPUT_PORT    14568  /* TCP */
#define KEYDRD_PAIRING_PORT  14569  /* TCP -- dedicated pairing listener */

/* ---- MediaFrameHeader flags (bit layout) ---- */
#define KEYDRD_FLAG_HEVC       (1 << 0)   /* bit 0: HEVC-encoded frame */
#define KEYDRD_FLAG_KEYFRAME   (1 << 1)   /* bit 1: keyframe / IDR */
#define KEYDRD_FLAG_LAST_CHUNK (1 << 2)   /* bit 2: last chunk of frame */
#define KEYDRD_FLAG_STRIPED    (1 << 3)   /* bit 3: LZ4 payload is a stripe table + K blocks
                                           * (delta.h striped_decode; tla/StripeSync.tla) */
#define KEYDRD_FLAG_DELTA      (1 << 6)   /* bit 6: XOR delta frame */

/* ---- MediaFrameHeader (25 bytes, packed) ----
 * Field sizes chosen to fit 25 bytes exactly:
 *   seq is u16 (wraps at 65535 -- adequate for streaming with wrap-around comparison)
 *   chunk_idx/chunk_total are u16 (max 65535 chunks per frame -- sufficient for large keyframes)
 */
typedef struct __attribute__((packed)) {
    uint16_t magic;          /* KEYDRD_MAGIC */
    uint8_t  flags;          /* see KEYDRD_FLAG_* */
    uint16_t seq;            /* frame sequence number (wrapping) */
    uint16_t chunk_idx;      /* chunk index within frame (u16 for large keyframes) */
    uint16_t chunk_total;    /* total chunks in frame (u16: up to 65535 chunks) */
    uint32_t payload_size;   /* compressed payload bytes */
    uint64_t ts_us;          /* capture host-time timestamp (microseconds) */
    uint32_t crc32;          /* CRC-32 of payload */
} MediaFrameHeader;

_Static_assert(sizeof(MediaFrameHeader) == 25,
               "MediaFrameHeader must be exactly 25 bytes");

/* ---- InputEventHeader type values ---- */
#define KEYDRD_INPUT_MOUSE_MOVE           0x01
#define KEYDRD_INPUT_CLICK                0x02
#define KEYDRD_INPUT_SCROLL               0x03
#define KEYDRD_INPUT_KEY                  0x10
#define KEYDRD_INPUT_HELD                 0x11  /* iPad -> Mac: what the iPad holds now (release-only resync) */
#define KEYDRD_INPUT_TEXT                 0x12  /* iPad -> Mac: on-screen keyboard text (UTF-16) */
#define KEYDRD_INPUT_MODE_CHANGE          0x20
#define KEYDRD_INPUT_RES_MATCH_REQUEST    0x21  /* iPad -> Mac: match iPad resolution */
#define KEYDRD_INPUT_RES_MATCH_RESPONSE   0x22  /* Mac -> iPad: resolution match result */
#define KEYDRD_INPUT_GEOMETRY_UPDATE      0x23  /* Mac -> iPad: new display geometry */
#define KEYDRD_INPUT_VIEWPORT_REPORT     0x24  /* iPad -> Mac: viewport pixel dimensions */
#define KEYDRD_INPUT_PEER_ADDRESS_UPDATE 0x25  /* Mac -> iPad: new USB NCM IP before transport switch */
#define KEYDRD_INPUT_TEST_CONTROL        0x26  /* iPad -> Mac, test mode only: UTF-8 JSON command */
#define KEYDRD_INPUT_TEST_REPORT         0x27  /* Mac -> iPad, test mode only: UTF-8 JSON reply */
#define KEYDRD_INPUT_TEST_FILLER         0x28  /* Mac -> iPad, test mode only: bandwidth-probe filler */
#define KEYDRD_INPUT_KEEPALIVE            0x30
#define KEYDRD_LINK_HEARTBEAT             0x31  /* both ways on the wireless control connection, every 1 s:
                                                 * link liveness; consumed by the transport, never
                                                 * delivered (tla/TransportConnections.tla SilenceDetect) */
#define KEYDRD_INPUT_FRAME_ACK            0x32  /* iPad -> Mac on the wireless input connection: u16 LE seq of
                                                 * the newest HEVC frame fully received (cumulative). The Mac
                                                 * encodes only while sent-but-unacked frames < limit
                                                 * (tla/WiFiSendLoop.tla AckGate). */
#define KEYDRD_INPUT_CLOCK_SYNC_REQ       0xFE  /* iPad -> Mac: Cristian's algorithm probe */
#define KEYDRD_INPUT_CLOCK_SYNC_RESP      0xFD  /* Mac -> iPad: clock sync response */
#define KEYDRD_INPUT_LATENCY_PROBE        0xFF

/* ---- Mode change subtypes (sent after InputEventHeader type=0x20) ---- */
#define KEYDRD_MODE_CHANGE_ECO               0x02
#define KEYDRD_MODE_CHANGE_REQUEST_KEYFRAME  0x03

/* ---- InputEventHeader (9 bytes, packed) ---- */
typedef struct __attribute__((packed)) {
    uint8_t  type;           /* KEYDRD_INPUT_* */
    uint64_t ts_us;          /* event host-time timestamp (microseconds) */
} InputEventHeader;

_Static_assert(sizeof(InputEventHeader) == 9,
               "InputEventHeader must be exactly 9 bytes");

/* ---- ClockSyncResponse (24 bytes, packed) ----
 * Sent after InputEventHeader (type=CLOCK_SYNC_RESP).
 * Carries three timestamps for Cristian's algorithm:
 *   t1 = iPad send time (echoed from request ts_us)
 *   t2 = Mac receive host time
 *   t3 = Mac send host time (just before send)
 * iPad records t4 on receipt, then:
 *   offset = ((t2-t1) + (t3-t4)) / 2   (Mac clock - iPad clock)
 */
typedef struct __attribute__((packed)) {
    uint64_t t1_ipad_us;     /* iPad send time, echoed */
    uint64_t t2_mac_us;      /* Mac receive time */
    uint64_t t3_mac_us;      /* Mac send time */
} ClockSyncResponse;

_Static_assert(sizeof(ClockSyncResponse) == 24,
               "ClockSyncResponse must be exactly 24 bytes");

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

/* ---- Resolution Match Request Payload (sent after InputEventHeader type=0x21) ---- */
typedef struct __attribute__((packed)) {
    uint32_t ipad_width;     /* iPad screen width in pixels */
    uint32_t ipad_height;    /* iPad screen height in pixels */
} ResolutionMatchPayload;

/* ---- Resolution Match Response Payload (sent after InputEventHeader type=0x22) ---- */
#define KEYDRD_RES_MATCH_OK      0x00
#define KEYDRD_RES_MATCH_FAILED  0x01
#define KEYDRD_RES_MATCH_NO_MODE 0x02

typedef struct __attribute__((packed)) {
    uint8_t  result;         /* KEYDRD_RES_MATCH_* */
    uint32_t new_width;      /* new display width (0 if failed) */
    uint32_t new_height;     /* new display height (0 if failed) */
    float    new_scale;      /* new display scale (0 if failed) */
} ResolutionMatchResponse;

/* ---- Geometry Update Payload (sent after InputEventHeader type=0x23) ---- */
typedef struct __attribute__((packed)) {
    uint32_t display_width;  /* new display width in pixels */
    uint32_t display_height; /* new display height in pixels */
    float    scale_factor;   /* new display scale */
    float    aspect_ratio;   /* width / height */
} GeometryUpdatePayload;

/* ---- Viewport Report Payload (sent after InputEventHeader type=0x24) ----
 * iPad sends this after receiving session handshake.
 * Contains the Metal viewport pixel dimensions (accounting for letterbox).
 * Mac uses this to set SCStream capture + HEVC encoder resolution. */
typedef struct __attribute__((packed)) {
    uint32_t viewport_width;   /* iPad viewport width in pixels */
    uint32_t viewport_height;  /* iPad viewport height in pixels */
} ViewportReportPayload;

_Static_assert(sizeof(ViewportReportPayload) == 8,
               "ViewportReportPayload must be exactly 8 bytes");

/* ==== Pointer and keyboard input (iPad -> Mac), tla/InputPath.tla ====
 * Wire: InputEventHeader (type, ts_us = iPad host time at the UIKit event) + InputSeq + body,
 * framed by the 4-byte length prefix (framing.h). Sent immediately, one event per message.
 *
 * Mac rules (InputPath design):
 *  - SeqGuard: a message of the current session is applied only if seq > last applied seq;
 *    a message of another session starts that session's count.
 *  - HELD: the Mac releases every key/button it holds that is not listed; it never presses.
 *    The iPad sends HELD first on every new connection, on every switch of link, and with an
 *    empty set when it loses its own held state (resign active, presses/touches cancelled).
 *  - Release-all when any input connection ends, after KEYDRD_INPUT_SILENCE_MS without a
 *    message while anything is held (the iPad sends KEEPALIVE every KEYDRD_INPUT_HEARTBEAT_MS
 *    while it holds anything), and when the agent stops.
 * Pointer coordinates are normalized over the streamed display: 0 = left/top edge,
 * 65535 = right/bottom edge. */
#define KEYDRD_INPUT_SILENCE_MS    1000u
#define KEYDRD_INPUT_HEARTBEAT_MS   250u

#define KEYDRD_BUTTON_LEFT   (1u << 0)
#define KEYDRD_BUTTON_RIGHT  (1u << 1)
#define KEYDRD_BUTTON_OTHER  (1u << 2)

typedef struct __attribute__((packed)) {
    uint64_t session;        /* random per iPad app launch */
    uint64_t seq;            /* 1, 2, 3, ... per message within the session */
} InputSeq;
_Static_assert(sizeof(InputSeq) == 16, "InputSeq must be exactly 16 bytes");

/* type = MOUSE_MOVE: the pointer moved (a drag if buttons != 0). */
typedef struct __attribute__((packed)) {
    uint16_t x, y;           /* normalized 0..65535 */
} PointerMovePayload;
_Static_assert(sizeof(PointerMovePayload) == 4, "PointerMovePayload must be exactly 4 bytes");

/* type = CLICK: one button goes down or up at (x, y). The Mac counts double clicks. */
typedef struct __attribute__((packed)) {
    uint16_t x, y;
    uint8_t  button;         /* KEYDRD_BUTTON_* (one bit) */
    uint8_t  down;           /* 1 = down, 0 = up */
} PointerButtonPayload;
_Static_assert(sizeof(PointerButtonPayload) == 6, "PointerButtonPayload must be exactly 6 bytes");

/* type = SCROLL: pixel deltas, content follows the fingers (+dy = content moves down). */
#define KEYDRD_SCROLL_PHASE_NONE     0
#define KEYDRD_SCROLL_PHASE_BEGAN    1
#define KEYDRD_SCROLL_PHASE_CHANGED  2
#define KEYDRD_SCROLL_PHASE_ENDED    3
#define KEYDRD_SCROLL_PHASE_CANCELLED 4
typedef struct __attribute__((packed)) {
    uint16_t x, y;           /* pointer position */
    int32_t  dx, dy;         /* pixels, in units of 1/16 px */
    uint8_t  phase;          /* KEYDRD_SCROLL_PHASE_* */
} ScrollPayload;
_Static_assert(sizeof(ScrollPayload) == 13, "ScrollPayload must be exactly 13 bytes");

/* type = KEY: a hardware key goes down or up. usage = USB HID usage, page 7 (UIKeyboardHIDUsage). */
typedef struct __attribute__((packed)) {
    uint16_t usage;
    uint8_t  down;
} KeyPayload;
_Static_assert(sizeof(KeyPayload) == 3, "KeyPayload must be exactly 3 bytes");

/* type = HELD: buttons + count, then count uint16 HID usages (little-endian). */
#define KEYDRD_HELD_MAX_KEYS 32
typedef struct __attribute__((packed)) {
    uint8_t  buttons;        /* KEYDRD_BUTTON_* held now */
    uint8_t  count;          /* number of usages that follow (<= KEYDRD_HELD_MAX_KEYS) */
} HeldPayload;
_Static_assert(sizeof(HeldPayload) == 2, "HeldPayload must be exactly 2 bytes");

/* type = TEXT: count UTF-16 code units follow (little-endian); typed as a unit, nothing held. */
typedef struct __attribute__((packed)) {
    uint16_t count;
} TextPayload;
_Static_assert(sizeof(TextPayload) == 2, "TextPayload must be exactly 2 bytes");
