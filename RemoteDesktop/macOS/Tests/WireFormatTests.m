/*
 * WireFormatTests.m
 * XCTest suite verifying exact wire format compatibility between C packed structs
 * and Swift manual byte-offset parsing.
 *
 * Every packed struct in protocol.h is tested for:
 *   1. Exact sizeof (packed size)
 *   2. Exact field offsets via offsetof()
 *   3. Byte-level roundtrip (C serialize -> byte verify -> manual offset parse)
 *   4. Cross-format C-to-Swift simulation (parse at manual offsets, not memcpy)
 *   5. Magic bytes, type codes, and flag bit verification
 *
 * Context: A SessionHandshakeMessage mismatch (26 packed vs 28 via MemoryLayout)
 * caused a blocker bug. These tests prevent regressions.
 */

#import <XCTest/XCTest.h>
#include "protocol.h"
#include <string.h>
#include <stddef.h>

@interface WireFormatTests : XCTestCase
@end

@implementation WireFormatTests

#pragma mark - 1. Struct size verification (exact packed sizes)

- (void)testMediaFrameHeaderPackedSize {
    XCTAssertEqual(sizeof(MediaFrameHeader), (size_t)24,
                   @"MediaFrameHeader must be exactly 24 bytes packed");
}

- (void)testInputEventHeaderPackedSize {
    XCTAssertEqual(sizeof(InputEventHeader), (size_t)9,
                   @"InputEventHeader must be exactly 9 bytes packed");
}

- (void)testSessionHandshakePackedSize {
    XCTAssertEqual(sizeof(SessionHandshakeMessage), (size_t)26,
                   @"SessionHandshakeMessage must be exactly 26 bytes packed (NOT 28 with alignment)");
}

- (void)testResolutionMatchPayloadPackedSize {
    XCTAssertEqual(sizeof(ResolutionMatchPayload), (size_t)8,
                   @"ResolutionMatchPayload must be exactly 8 bytes packed");
}

- (void)testResolutionMatchResponsePackedSize {
    XCTAssertEqual(sizeof(ResolutionMatchResponse), (size_t)13,
                   @"ResolutionMatchResponse must be exactly 13 bytes packed");
}

- (void)testGeometryUpdatePayloadPackedSize {
    XCTAssertEqual(sizeof(GeometryUpdatePayload), (size_t)16,
                   @"GeometryUpdatePayload must be exactly 16 bytes packed");
}

#pragma mark - 2. Field offset verification (exact byte positions)

- (void)testMediaFrameHeaderFieldOffsets {
    XCTAssertEqual(offsetof(MediaFrameHeader, magic),        (size_t)0);
    XCTAssertEqual(offsetof(MediaFrameHeader, flags),        (size_t)2);
    XCTAssertEqual(offsetof(MediaFrameHeader, seq),          (size_t)3);
    XCTAssertEqual(offsetof(MediaFrameHeader, chunk_idx),    (size_t)5);
    XCTAssertEqual(offsetof(MediaFrameHeader, chunk_total),  (size_t)6);
    XCTAssertEqual(offsetof(MediaFrameHeader, reserved),     (size_t)7);
    XCTAssertEqual(offsetof(MediaFrameHeader, payload_size), (size_t)8);
    XCTAssertEqual(offsetof(MediaFrameHeader, ts_us),        (size_t)12);
    XCTAssertEqual(offsetof(MediaFrameHeader, crc32),        (size_t)20);
}

- (void)testInputEventHeaderFieldOffsets {
    XCTAssertEqual(offsetof(InputEventHeader, type),  (size_t)0);
    XCTAssertEqual(offsetof(InputEventHeader, ts_us), (size_t)1);
}

- (void)testSessionHandshakeFieldOffsets {
    XCTAssertEqual(offsetof(SessionHandshakeMessage, magic),          (size_t)0);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, msg_type),       (size_t)2);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, display_width),  (size_t)3);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, display_height), (size_t)7);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, scale_factor),   (size_t)11);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, aspect_ratio),   (size_t)15);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, capabilities),   (size_t)19);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, max_fps),        (size_t)20);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, agent_version),  (size_t)21);
    XCTAssertEqual(offsetof(SessionHandshakeMessage, reserved),       (size_t)22);
}

- (void)testResolutionMatchPayloadFieldOffsets {
    XCTAssertEqual(offsetof(ResolutionMatchPayload, ipad_width),  (size_t)0);
    XCTAssertEqual(offsetof(ResolutionMatchPayload, ipad_height), (size_t)4);
}

- (void)testResolutionMatchResponseFieldOffsets {
    XCTAssertEqual(offsetof(ResolutionMatchResponse, result),     (size_t)0);
    XCTAssertEqual(offsetof(ResolutionMatchResponse, new_width),  (size_t)1);
    XCTAssertEqual(offsetof(ResolutionMatchResponse, new_height), (size_t)5);
    XCTAssertEqual(offsetof(ResolutionMatchResponse, new_scale),  (size_t)9);
}

- (void)testGeometryUpdatePayloadFieldOffsets {
    XCTAssertEqual(offsetof(GeometryUpdatePayload, display_width),  (size_t)0);
    XCTAssertEqual(offsetof(GeometryUpdatePayload, display_height), (size_t)4);
    XCTAssertEqual(offsetof(GeometryUpdatePayload, scale_factor),   (size_t)8);
    XCTAssertEqual(offsetof(GeometryUpdatePayload, aspect_ratio),   (size_t)12);
}

#pragma mark - 3. Byte-level roundtrip (C serialize -> byte verify -> manual parse)

- (void)testMediaFrameHeaderByteLayout {
    MediaFrameHeader msg;
    memset(&msg, 0, sizeof(msg));
    msg.magic        = 0x4B44;
    msg.flags        = 0x06;  /* KEYFRAME | LAST_CHUNK */
    msg.seq          = 1000;
    msg.chunk_idx    = 3;
    msg.chunk_total  = 7;
    msg.reserved     = 0;
    msg.payload_size = 0x00012345;
    msg.ts_us        = 0x00000002540BE400ULL; /* 10,000,000,000 */
    msg.crc32        = 0xDEADBEEF;

    uint8_t wire[24];
    memcpy(wire, &msg, 24);

    /* Verify magic at offset 0 (little-endian u16) */
    XCTAssertEqual(wire[0], 0x44);
    XCTAssertEqual(wire[1], 0x4B);

    /* Verify flags at offset 2 */
    XCTAssertEqual(wire[2], 0x06);

    /* Verify seq at offset 3 (little-endian u16) */
    uint16_t seq;
    memcpy(&seq, wire + 3, 2);
    XCTAssertEqual(seq, 1000);

    /* Verify chunk_idx at offset 5 */
    XCTAssertEqual(wire[5], 3);

    /* Verify chunk_total at offset 6 */
    XCTAssertEqual(wire[6], 7);

    /* Verify reserved at offset 7 */
    XCTAssertEqual(wire[7], 0);

    /* Verify payload_size at offset 8 (little-endian u32) */
    uint32_t payload_size;
    memcpy(&payload_size, wire + 8, 4);
    XCTAssertEqual(payload_size, 0x00012345u);

    /* Verify ts_us at offset 12 (little-endian u64) */
    uint64_t ts_us;
    memcpy(&ts_us, wire + 12, 8);
    XCTAssertEqual(ts_us, 0x00000002540BE400ULL);

    /* Verify crc32 at offset 20 (little-endian u32) */
    uint32_t crc32_val;
    memcpy(&crc32_val, wire + 20, 4);
    XCTAssertEqual(crc32_val, 0xDEADBEEFu);

    /* Parse back from manual offsets (NOT memcpy-to-struct) and verify */
    uint16_t parsed_magic;
    memcpy(&parsed_magic, wire + 0, 2);
    XCTAssertEqual(parsed_magic, msg.magic);

    uint8_t parsed_flags = wire[2];
    XCTAssertEqual(parsed_flags, msg.flags);

    uint16_t parsed_seq;
    memcpy(&parsed_seq, wire + 3, 2);
    XCTAssertEqual(parsed_seq, msg.seq);

    uint8_t parsed_chunk_idx = wire[5];
    XCTAssertEqual(parsed_chunk_idx, msg.chunk_idx);

    uint8_t parsed_chunk_total = wire[6];
    XCTAssertEqual(parsed_chunk_total, msg.chunk_total);

    uint8_t parsed_reserved = wire[7];
    XCTAssertEqual(parsed_reserved, msg.reserved);

    uint32_t parsed_payload;
    memcpy(&parsed_payload, wire + 8, 4);
    XCTAssertEqual(parsed_payload, msg.payload_size);

    uint64_t parsed_ts;
    memcpy(&parsed_ts, wire + 12, 8);
    XCTAssertEqual(parsed_ts, msg.ts_us);

    uint32_t parsed_crc;
    memcpy(&parsed_crc, wire + 20, 4);
    XCTAssertEqual(parsed_crc, msg.crc32);
}

- (void)testInputEventHeaderByteLayout {
    InputEventHeader msg;
    msg.type  = 0x10; /* KEY */
    msg.ts_us = 1234567890123456ULL;

    uint8_t wire[9];
    memcpy(wire, &msg, 9);

    /* Verify type at offset 0 */
    XCTAssertEqual(wire[0], 0x10);

    /* Verify ts_us at offset 1 (little-endian u64) */
    uint64_t ts_us;
    memcpy(&ts_us, wire + 1, 8);
    XCTAssertEqual(ts_us, 1234567890123456ULL);

    /* Parse back from manual offsets */
    uint8_t parsed_type = wire[0];
    XCTAssertEqual(parsed_type, msg.type);

    uint64_t parsed_ts;
    memcpy(&parsed_ts, wire + 1, 8);
    XCTAssertEqual(parsed_ts, msg.ts_us);
}

- (void)testSessionHandshakeByteLayout {
    SessionHandshakeMessage msg;
    memset(&msg, 0, sizeof(msg));
    msg.magic          = 0x4B44;
    msg.msg_type       = 0x01;
    msg.display_width  = 3600;
    msg.display_height = 2338;
    msg.scale_factor   = 2.0f;
    msg.aspect_ratio   = 3600.0f / 2338.0f;
    msg.capabilities   = 0x07;
    msg.max_fps        = 120;
    msg.agent_version  = 1;
    msg.reserved       = 0;

    uint8_t wire[26];
    memcpy(wire, &msg, 26);

    /* Verify magic at offset 0 (little-endian u16) */
    XCTAssertEqual(wire[0], 0x44);
    XCTAssertEqual(wire[1], 0x4B);

    /* Verify msg_type at offset 2 */
    XCTAssertEqual(wire[2], 0x01);

    /* Verify display_width at offset 3 (little-endian u32) */
    uint32_t width;
    memcpy(&width, wire + 3, 4);
    XCTAssertEqual(width, 3600u);

    /* Verify display_height at offset 7 (little-endian u32) */
    uint32_t height;
    memcpy(&height, wire + 7, 4);
    XCTAssertEqual(height, 2338u);

    /* Verify scale_factor at offset 11 (IEEE 754 float) */
    float scale;
    memcpy(&scale, wire + 11, 4);
    XCTAssertEqualWithAccuracy(scale, 2.0f, 0.001f);

    /* Verify aspect_ratio at offset 15 (IEEE 754 float) */
    float aspect;
    memcpy(&aspect, wire + 15, 4);
    XCTAssertEqualWithAccuracy(aspect, 3600.0f / 2338.0f, 0.001f);

    /* Verify capabilities at offset 19 */
    XCTAssertEqual(wire[19], 0x07);

    /* Verify max_fps at offset 20 */
    XCTAssertEqual(wire[20], 120);

    /* Verify agent_version at offset 21 */
    XCTAssertEqual(wire[21], 1);

    /* Verify reserved at offset 22 (little-endian u32, should be 0) */
    uint32_t reserved;
    memcpy(&reserved, wire + 22, 4);
    XCTAssertEqual(reserved, 0u);

    /* Parse back from manual offsets */
    uint16_t parsed_magic;
    memcpy(&parsed_magic, wire + 0, 2);
    XCTAssertEqual(parsed_magic, msg.magic);

    uint8_t parsed_msgType = wire[2];
    XCTAssertEqual(parsed_msgType, msg.msg_type);

    uint32_t parsed_width;
    memcpy(&parsed_width, wire + 3, 4);
    XCTAssertEqual(parsed_width, msg.display_width);

    uint32_t parsed_height;
    memcpy(&parsed_height, wire + 7, 4);
    XCTAssertEqual(parsed_height, msg.display_height);

    float parsed_scale;
    memcpy(&parsed_scale, wire + 11, 4);
    XCTAssertEqualWithAccuracy(parsed_scale, msg.scale_factor, 0.001f);

    float parsed_aspect;
    memcpy(&parsed_aspect, wire + 15, 4);
    XCTAssertEqualWithAccuracy(parsed_aspect, msg.aspect_ratio, 0.001f);

    uint8_t parsed_caps = wire[19];
    XCTAssertEqual(parsed_caps, msg.capabilities);

    uint8_t parsed_fps = wire[20];
    XCTAssertEqual(parsed_fps, msg.max_fps);

    uint8_t parsed_version = wire[21];
    XCTAssertEqual(parsed_version, msg.agent_version);

    uint32_t parsed_reserved;
    memcpy(&parsed_reserved, wire + 22, 4);
    XCTAssertEqual(parsed_reserved, msg.reserved);
}

- (void)testResolutionMatchPayloadByteLayout {
    ResolutionMatchPayload msg;
    msg.ipad_width  = 2388;
    msg.ipad_height = 1668;

    uint8_t wire[8];
    memcpy(wire, &msg, 8);

    /* Verify ipad_width at offset 0 (little-endian u32) */
    uint32_t w;
    memcpy(&w, wire + 0, 4);
    XCTAssertEqual(w, 2388u);

    /* Verify ipad_height at offset 4 (little-endian u32) */
    uint32_t h;
    memcpy(&h, wire + 4, 4);
    XCTAssertEqual(h, 1668u);

    /* Parse back from manual offsets */
    uint32_t parsed_w;
    memcpy(&parsed_w, wire + 0, 4);
    XCTAssertEqual(parsed_w, msg.ipad_width);

    uint32_t parsed_h;
    memcpy(&parsed_h, wire + 4, 4);
    XCTAssertEqual(parsed_h, msg.ipad_height);
}

- (void)testResolutionMatchResponseByteLayout {
    ResolutionMatchResponse msg;
    memset(&msg, 0, sizeof(msg));
    msg.result     = KEYDRD_RES_MATCH_OK;
    msg.new_width  = 2388;
    msg.new_height = 1668;
    msg.new_scale  = 2.0f;

    uint8_t wire[13];
    memcpy(wire, &msg, 13);

    /* Verify result at offset 0 */
    XCTAssertEqual(wire[0], 0x00);

    /* Verify new_width at offset 1 (little-endian u32) */
    uint32_t nw;
    memcpy(&nw, wire + 1, 4);
    XCTAssertEqual(nw, 2388u);

    /* Verify new_height at offset 5 (little-endian u32) */
    uint32_t nh;
    memcpy(&nh, wire + 5, 4);
    XCTAssertEqual(nh, 1668u);

    /* Verify new_scale at offset 9 (IEEE 754 float) */
    float ns;
    memcpy(&ns, wire + 9, 4);
    XCTAssertEqualWithAccuracy(ns, 2.0f, 0.001f);

    /* Parse back from manual offsets */
    uint8_t parsed_result = wire[0];
    XCTAssertEqual(parsed_result, msg.result);

    uint32_t parsed_nw;
    memcpy(&parsed_nw, wire + 1, 4);
    XCTAssertEqual(parsed_nw, msg.new_width);

    uint32_t parsed_nh;
    memcpy(&parsed_nh, wire + 5, 4);
    XCTAssertEqual(parsed_nh, msg.new_height);

    float parsed_ns;
    memcpy(&parsed_ns, wire + 9, 4);
    XCTAssertEqualWithAccuracy(parsed_ns, msg.new_scale, 0.001f);
}

- (void)testGeometryUpdatePayloadByteLayout {
    GeometryUpdatePayload msg;
    msg.display_width  = 3024;
    msg.display_height = 1964;
    msg.scale_factor   = 2.0f;
    msg.aspect_ratio   = 3024.0f / 1964.0f;

    uint8_t wire[16];
    memcpy(wire, &msg, 16);

    /* Verify display_width at offset 0 (little-endian u32) */
    uint32_t dw;
    memcpy(&dw, wire + 0, 4);
    XCTAssertEqual(dw, 3024u);

    /* Verify display_height at offset 4 (little-endian u32) */
    uint32_t dh;
    memcpy(&dh, wire + 4, 4);
    XCTAssertEqual(dh, 1964u);

    /* Verify scale_factor at offset 8 (IEEE 754 float) */
    float sf;
    memcpy(&sf, wire + 8, 4);
    XCTAssertEqualWithAccuracy(sf, 2.0f, 0.001f);

    /* Verify aspect_ratio at offset 12 (IEEE 754 float) */
    float ar;
    memcpy(&ar, wire + 12, 4);
    XCTAssertEqualWithAccuracy(ar, 3024.0f / 1964.0f, 0.001f);

    /* Parse back from manual offsets */
    uint32_t parsed_dw;
    memcpy(&parsed_dw, wire + 0, 4);
    XCTAssertEqual(parsed_dw, msg.display_width);

    uint32_t parsed_dh;
    memcpy(&parsed_dh, wire + 4, 4);
    XCTAssertEqual(parsed_dh, msg.display_height);

    float parsed_sf;
    memcpy(&parsed_sf, wire + 8, 4);
    XCTAssertEqualWithAccuracy(parsed_sf, msg.scale_factor, 0.001f);

    float parsed_ar;
    memcpy(&parsed_ar, wire + 12, 4);
    XCTAssertEqualWithAccuracy(parsed_ar, msg.aspect_ratio, 0.001f);
}

#pragma mark - 4. Cross-format C-to-Swift compatibility (manual offset parse)

- (void)testMediaFrameHeaderCToSwiftCompatibility {
    MediaFrameHeader msg;
    memset(&msg, 0, sizeof(msg));
    msg.magic        = KEYDRD_MAGIC;
    msg.flags        = KEYDRD_FLAG_HEVC | KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
    msg.seq          = 42;
    msg.chunk_idx    = 3;
    msg.chunk_total  = 7;
    msg.reserved     = 0;
    msg.payload_size = 123456;
    msg.ts_us        = 9876543210ULL;
    msg.crc32        = 0xDEADBEEF;

    uint8_t wire[24];
    memcpy(wire, &msg, 24);

    /* Parse like Swift does: manual offsets with memcpy (safe for unaligned) */
    uint16_t swift_magic;        memcpy(&swift_magic, wire + 0, 2);
    uint8_t  swift_flags       = wire[2];
    uint16_t swift_seq;          memcpy(&swift_seq, wire + 3, 2);
    uint8_t  swift_chunkIdx    = wire[5];
    uint8_t  swift_chunkTotal  = wire[6];
    uint8_t  swift_reserved    = wire[7];
    uint32_t swift_payloadSize;  memcpy(&swift_payloadSize, wire + 8, 4);
    uint64_t swift_tsUs;         memcpy(&swift_tsUs, wire + 12, 8);
    uint32_t swift_crc32;        memcpy(&swift_crc32, wire + 20, 4);

    XCTAssertEqual(swift_magic,       msg.magic);
    XCTAssertEqual(swift_flags,       msg.flags);
    XCTAssertEqual(swift_seq,         msg.seq);
    XCTAssertEqual(swift_chunkIdx,    msg.chunk_idx);
    XCTAssertEqual(swift_chunkTotal,  msg.chunk_total);
    XCTAssertEqual(swift_reserved,    msg.reserved);
    XCTAssertEqual(swift_payloadSize, msg.payload_size);
    XCTAssertEqual(swift_tsUs,        msg.ts_us);
    XCTAssertEqual(swift_crc32,       msg.crc32);
}

- (void)testInputEventHeaderCToSwiftCompatibility {
    InputEventHeader msg;
    msg.type  = KEYDRD_INPUT_MOUSE_MOVE;
    msg.ts_us = 0xFEDCBA9876543210ULL;

    uint8_t wire[9];
    memcpy(wire, &msg, 9);

    /* Parse like Swift does */
    uint8_t  swift_type  = wire[0];
    uint64_t swift_tsUs; memcpy(&swift_tsUs, wire + 1, 8);

    XCTAssertEqual(swift_type,  msg.type);
    XCTAssertEqual(swift_tsUs,  msg.ts_us);
}

- (void)testSessionHandshakeCToSwiftCompatibility {
    SessionHandshakeMessage msg;
    memset(&msg, 0, sizeof(msg));
    msg.magic          = KEYDRD_MAGIC;
    msg.msg_type       = KEYDRD_MSG_SESSION_HANDSHAKE;
    msg.display_width  = 3600;
    msg.display_height = 2338;
    msg.scale_factor   = 2.0f;
    msg.aspect_ratio   = 3600.0f / 2338.0f;
    msg.capabilities   = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE;
    msg.max_fps        = 120;
    msg.agent_version  = 1;
    msg.reserved       = 0;

    uint8_t wire[26];
    memcpy(wire, &msg, 26);

    /* Parse like Swift does: manual offsets */
    uint16_t swift_magic;         memcpy(&swift_magic, wire + 0, 2);
    uint8_t  swift_msgType      = wire[2];
    uint32_t swift_dispW;         memcpy(&swift_dispW, wire + 3, 4);
    uint32_t swift_dispH;         memcpy(&swift_dispH, wire + 7, 4);
    float    swift_scale;         memcpy(&swift_scale, wire + 11, 4);
    float    swift_aspect;        memcpy(&swift_aspect, wire + 15, 4);
    uint8_t  swift_caps         = wire[19];
    uint8_t  swift_fps          = wire[20];
    uint8_t  swift_version      = wire[21];
    uint32_t swift_reserved;      memcpy(&swift_reserved, wire + 22, 4);

    XCTAssertEqual(swift_magic,    msg.magic);
    XCTAssertEqual(swift_msgType,  msg.msg_type);
    XCTAssertEqual(swift_dispW,    msg.display_width);
    XCTAssertEqual(swift_dispH,    msg.display_height);
    XCTAssertEqualWithAccuracy(swift_scale, msg.scale_factor, 0.001f);
    XCTAssertEqualWithAccuracy(swift_aspect, msg.aspect_ratio, 0.001f);
    XCTAssertEqual(swift_caps,     msg.capabilities);
    XCTAssertEqual(swift_fps,      msg.max_fps);
    XCTAssertEqual(swift_version,  msg.agent_version);
    XCTAssertEqual(swift_reserved, msg.reserved);
}

- (void)testResolutionMatchPayloadCToSwiftCompatibility {
    ResolutionMatchPayload msg;
    msg.ipad_width  = 2732;
    msg.ipad_height = 2048;

    uint8_t wire[8];
    memcpy(wire, &msg, 8);

    /* Parse like Swift does */
    uint32_t swift_w; memcpy(&swift_w, wire + 0, 4);
    uint32_t swift_h; memcpy(&swift_h, wire + 4, 4);

    XCTAssertEqual(swift_w, msg.ipad_width);
    XCTAssertEqual(swift_h, msg.ipad_height);
}

- (void)testResolutionMatchResponseCToSwiftCompatibility {
    ResolutionMatchResponse msg;
    memset(&msg, 0, sizeof(msg));
    msg.result     = KEYDRD_RES_MATCH_OK;
    msg.new_width  = 2732;
    msg.new_height = 2048;
    msg.new_scale  = 2.0f;

    uint8_t wire[13];
    memcpy(wire, &msg, 13);

    /* Parse like Swift does */
    uint8_t  swift_result    = wire[0];
    uint32_t swift_newW;      memcpy(&swift_newW, wire + 1, 4);
    uint32_t swift_newH;      memcpy(&swift_newH, wire + 5, 4);
    float    swift_newScale;  memcpy(&swift_newScale, wire + 9, 4);

    XCTAssertEqual(swift_result,   msg.result);
    XCTAssertEqual(swift_newW,     msg.new_width);
    XCTAssertEqual(swift_newH,     msg.new_height);
    XCTAssertEqualWithAccuracy(swift_newScale, msg.new_scale, 0.001f);
}

- (void)testGeometryUpdatePayloadCToSwiftCompatibility {
    GeometryUpdatePayload msg;
    msg.display_width  = 1920;
    msg.display_height = 1080;
    msg.scale_factor   = 1.0f;
    msg.aspect_ratio   = 1920.0f / 1080.0f;

    uint8_t wire[16];
    memcpy(wire, &msg, 16);

    /* Parse like Swift does */
    uint32_t swift_dw;     memcpy(&swift_dw, wire + 0, 4);
    uint32_t swift_dh;     memcpy(&swift_dh, wire + 4, 4);
    float    swift_sf;     memcpy(&swift_sf, wire + 8, 4);
    float    swift_ar;     memcpy(&swift_ar, wire + 12, 4);

    XCTAssertEqual(swift_dw, msg.display_width);
    XCTAssertEqual(swift_dh, msg.display_height);
    XCTAssertEqualWithAccuracy(swift_sf, msg.scale_factor, 0.001f);
    XCTAssertEqualWithAccuracy(swift_ar, msg.aspect_ratio, 0.001f);
}

#pragma mark - 5. Magic byte and type code verification

- (void)testMagicIsLittleEndian {
    /* KEYDRD_MAGIC (0x4B44) on little-endian wire must serialize as [0x44, 0x4B] */
    uint16_t magic = KEYDRD_MAGIC;
    uint8_t bytes[2];
    memcpy(bytes, &magic, 2);

    XCTAssertEqual(bytes[0], 0x44, @"KEYDRD_MAGIC low byte must be 0x44 ('D')");
    XCTAssertEqual(bytes[1], 0x4B, @"KEYDRD_MAGIC high byte must be 0x4B ('K')");

    /* Verify the constant itself */
    XCTAssertEqual(KEYDRD_MAGIC, (uint16_t)0x4B44);
}

- (void)testAllMessageTypeCodes {
    /* Verify expected value */
    XCTAssertEqual(KEYDRD_MSG_SESSION_HANDSHAKE, (uint8_t)0x01);

    /* All input type codes must be unique */
    uint8_t codes[] = {
        KEYDRD_INPUT_MOUSE_MOVE,
        KEYDRD_INPUT_CLICK,
        KEYDRD_INPUT_SCROLL,
        KEYDRD_INPUT_KEY,
        KEYDRD_INPUT_MODE_CHANGE,
        KEYDRD_INPUT_RES_MATCH_REQUEST,
        KEYDRD_INPUT_RES_MATCH_RESPONSE,
        KEYDRD_INPUT_GEOMETRY_UPDATE,
        KEYDRD_INPUT_KEEPALIVE,
        KEYDRD_INPUT_LATENCY_PROBE,
    };
    size_t count = sizeof(codes) / sizeof(codes[0]);

    for (size_t i = 0; i < count; i++) {
        for (size_t j = i + 1; j < count; j++) {
            XCTAssertNotEqual(codes[i], codes[j],
                              @"Input type codes at index %zu (0x%02X) and %zu (0x%02X) must be unique",
                              i, codes[i], j, codes[j]);
        }
    }

    /* Verify specific expected values */
    XCTAssertEqual(KEYDRD_INPUT_MOUSE_MOVE,         (uint8_t)0x01);
    XCTAssertEqual(KEYDRD_INPUT_CLICK,              (uint8_t)0x02);
    XCTAssertEqual(KEYDRD_INPUT_SCROLL,             (uint8_t)0x03);
    XCTAssertEqual(KEYDRD_INPUT_KEY,                (uint8_t)0x10);
    XCTAssertEqual(KEYDRD_INPUT_MODE_CHANGE,        (uint8_t)0x20);
    XCTAssertEqual(KEYDRD_INPUT_RES_MATCH_REQUEST,  (uint8_t)0x21);
    XCTAssertEqual(KEYDRD_INPUT_RES_MATCH_RESPONSE, (uint8_t)0x22);
    XCTAssertEqual(KEYDRD_INPUT_GEOMETRY_UPDATE,    (uint8_t)0x23);
    XCTAssertEqual(KEYDRD_INPUT_KEEPALIVE,          (uint8_t)0x30);
    XCTAssertEqual(KEYDRD_INPUT_LATENCY_PROBE,      (uint8_t)0xFF);

    /* Resolution match result codes must be unique and correct */
    XCTAssertEqual(KEYDRD_RES_MATCH_OK,      (uint8_t)0x00);
    XCTAssertEqual(KEYDRD_RES_MATCH_FAILED,  (uint8_t)0x01);
    XCTAssertEqual(KEYDRD_RES_MATCH_NO_MODE, (uint8_t)0x02);
    XCTAssertNotEqual(KEYDRD_RES_MATCH_OK,      KEYDRD_RES_MATCH_FAILED);
    XCTAssertNotEqual(KEYDRD_RES_MATCH_OK,      KEYDRD_RES_MATCH_NO_MODE);
    XCTAssertNotEqual(KEYDRD_RES_MATCH_FAILED,  KEYDRD_RES_MATCH_NO_MODE);
}

- (void)testAllFlagBits {
    /* Media frame flags: each must be a single bit, no overlaps */
    XCTAssertEqual(KEYDRD_FLAG_HEVC,       (uint8_t)(1 << 0));
    XCTAssertEqual(KEYDRD_FLAG_KEYFRAME,   (uint8_t)(1 << 1));
    XCTAssertEqual(KEYDRD_FLAG_LAST_CHUNK, (uint8_t)(1 << 2));
    XCTAssertEqual(KEYDRD_FLAG_DELTA,      (uint8_t)(1 << 6));

    /* Verify no overlap between ANY pair of flags */
    uint8_t all_flags[] = {
        KEYDRD_FLAG_HEVC,
        KEYDRD_FLAG_KEYFRAME,
        KEYDRD_FLAG_LAST_CHUNK,
        KEYDRD_FLAG_DELTA,
    };
    size_t count = sizeof(all_flags) / sizeof(all_flags[0]);

    for (size_t i = 0; i < count; i++) {
        for (size_t j = i + 1; j < count; j++) {
            XCTAssertEqual(all_flags[i] & all_flags[j], 0,
                           @"Flags at index %zu (0x%02X) and %zu (0x%02X) must not overlap",
                           i, all_flags[i], j, all_flags[j]);
        }
    }

    /* Capability flags: each must be a single bit, no overlaps */
    XCTAssertEqual(KEYDRD_CAP_LZ4,           (uint8_t)(1 << 0));
    XCTAssertEqual(KEYDRD_CAP_HEVC,          (uint8_t)(1 << 1));
    XCTAssertEqual(KEYDRD_CAP_ECO_AVAILABLE, (uint8_t)(1 << 2));

    uint8_t all_caps[] = {
        KEYDRD_CAP_LZ4,
        KEYDRD_CAP_HEVC,
        KEYDRD_CAP_ECO_AVAILABLE,
    };
    size_t cap_count = sizeof(all_caps) / sizeof(all_caps[0]);

    for (size_t i = 0; i < cap_count; i++) {
        for (size_t j = i + 1; j < cap_count; j++) {
            XCTAssertEqual(all_caps[i] & all_caps[j], 0,
                           @"Capability flags at index %zu (0x%02X) and %zu (0x%02X) must not overlap",
                           i, all_caps[i], j, all_caps[j]);
        }
    }
}

#pragma mark - Edge cases: boundary values across wire format

- (void)testSessionHandshakeZeroPayload {
    /* All-zero message must still serialize to exactly 26 bytes with zeros */
    SessionHandshakeMessage msg;
    memset(&msg, 0, sizeof(msg));

    uint8_t wire[26];
    memcpy(wire, &msg, 26);

    /* Every byte should be 0 */
    for (size_t i = 0; i < 26; i++) {
        XCTAssertEqual(wire[i], 0, @"Byte %zu of zero-init SessionHandshakeMessage must be 0", i);
    }
}

- (void)testMediaFrameHeaderMaxValues {
    /* Test boundary values that could trigger alignment issues */
    MediaFrameHeader msg;
    memset(&msg, 0xFF, sizeof(msg)); /* Fill with all-ones */
    msg.magic        = 0xFFFF;
    msg.flags        = 0xFF;
    msg.seq          = 0xFFFF;
    msg.chunk_idx    = 0xFF;
    msg.chunk_total  = 0xFF;
    msg.reserved     = 0xFF;
    msg.payload_size = 0xFFFFFFFF;
    msg.ts_us        = 0xFFFFFFFFFFFFFFFFULL;
    msg.crc32        = 0xFFFFFFFF;

    uint8_t wire[24];
    memcpy(wire, &msg, 24);

    /* Every byte should be 0xFF */
    for (size_t i = 0; i < 24; i++) {
        XCTAssertEqual(wire[i], 0xFF, @"Byte %zu of all-max MediaFrameHeader must be 0xFF", i);
    }

    /* Parse back via manual offsets */
    uint16_t swift_magic;        memcpy(&swift_magic, wire + 0, 2);
    uint16_t swift_seq;          memcpy(&swift_seq, wire + 3, 2);
    uint32_t swift_payloadSize;  memcpy(&swift_payloadSize, wire + 8, 4);
    uint64_t swift_tsUs;         memcpy(&swift_tsUs, wire + 12, 8);
    uint32_t swift_crc32;        memcpy(&swift_crc32, wire + 20, 4);

    XCTAssertEqual(swift_magic,       (uint16_t)0xFFFF);
    XCTAssertEqual(swift_seq,         (uint16_t)0xFFFF);
    XCTAssertEqual(swift_payloadSize, (uint32_t)0xFFFFFFFF);
    XCTAssertEqual(swift_tsUs,        (uint64_t)0xFFFFFFFFFFFFFFFFULL);
    XCTAssertEqual(swift_crc32,       (uint32_t)0xFFFFFFFF);
}

- (void)testResolutionMatchResponseFailedResult {
    /* Ensure failed result codes serialize correctly with zero dimensions */
    ResolutionMatchResponse msg;
    memset(&msg, 0, sizeof(msg));
    msg.result     = KEYDRD_RES_MATCH_NO_MODE;
    msg.new_width  = 0;
    msg.new_height = 0;
    msg.new_scale  = 0.0f;

    uint8_t wire[13];
    memcpy(wire, &msg, 13);

    /* Parse like Swift */
    uint8_t  swift_result = wire[0];
    uint32_t swift_w;     memcpy(&swift_w, wire + 1, 4);
    uint32_t swift_h;     memcpy(&swift_h, wire + 5, 4);
    float    swift_s;     memcpy(&swift_s, wire + 9, 4);

    XCTAssertEqual(swift_result, KEYDRD_RES_MATCH_NO_MODE);
    XCTAssertEqual(swift_w, 0u);
    XCTAssertEqual(swift_h, 0u);
    XCTAssertEqualWithAccuracy(swift_s, 0.0f, 0.001f);
}

@end
