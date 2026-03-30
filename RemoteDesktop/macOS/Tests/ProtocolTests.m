/*
 * ProtocolTests.m
 * XCTest suite for the keyd-rd binary protocol layer.
 *
 * Tests all message types defined in protocol.h:
 *   - MediaFrameHeader (25 bytes packed)
 *   - InputEventHeader (9 bytes packed)
 *   - SessionHandshakeMessage
 *   - ResolutionMatchPayload / ResolutionMatchResponse
 *   - GeometryUpdatePayload
 */

#import <XCTest/XCTest.h>
#include "protocol.h"
#include <zlib.h>
#include <string.h>
#include <stdlib.h>

@interface ProtocolTests : XCTestCase
@end

@implementation ProtocolTests

#pragma mark - Struct sizes

- (void)testMediaFrameHeaderSize {
    XCTAssertEqual(sizeof(MediaFrameHeader), 25,
                   @"MediaFrameHeader must be exactly 25 bytes");
}

- (void)testInputEventHeaderSize {
    XCTAssertEqual(sizeof(InputEventHeader), 9,
                   @"InputEventHeader must be exactly 9 bytes");
}

#pragma mark - MediaFrameHeader

- (void)testMediaFrameHeaderSerializeAndParse {
    MediaFrameHeader original;
    memset(&original, 0, sizeof(original));

    original.magic        = KEYDRD_MAGIC;
    original.flags        = KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
    original.seq          = 42;
    original.chunk_idx    = 3;
    original.chunk_total  = 7;
    original.payload_size = 123456;
    original.ts_us        = 9876543210ULL;
    original.crc32        = 0xDEADBEEF;

    /* Serialize to raw bytes */
    uint8_t wire[25];
    memcpy(wire, &original, sizeof(MediaFrameHeader));

    /* Parse back */
    MediaFrameHeader parsed;
    memcpy(&parsed, wire, sizeof(MediaFrameHeader));

    XCTAssertEqual(parsed.magic, KEYDRD_MAGIC);
    XCTAssertEqual(parsed.flags, (KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK));
    XCTAssertEqual(parsed.seq, 42);
    XCTAssertEqual(parsed.chunk_idx, 3);
    XCTAssertEqual(parsed.chunk_total, 7);
    XCTAssertEqual(parsed.payload_size, 123456u);
    XCTAssertEqual(parsed.ts_us, 9876543210ULL);
    XCTAssertEqual(parsed.crc32, 0xDEADBEEF);
}

- (void)testMediaFrameHeaderCRC {
    /* Create a payload and compute its CRC-32 */
    const size_t payload_len = 512;
    uint8_t payload[payload_len];
    for (size_t i = 0; i < payload_len; i++) {
        payload[i] = (uint8_t)(i & 0xFF);
    }

    uint32_t expected_crc = (uint32_t)crc32(0L, payload, (uInt)payload_len);
    XCTAssertNotEqual(expected_crc, 0u, @"CRC of non-trivial data should not be 0");

    MediaFrameHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic        = KEYDRD_MAGIC;
    hdr.flags        = KEYDRD_FLAG_KEYFRAME;
    hdr.payload_size = (uint32_t)payload_len;
    hdr.crc32        = expected_crc;

    /* Verify the stored CRC matches a fresh computation */
    uint32_t recomputed = (uint32_t)crc32(0L, payload, (uInt)payload_len);
    XCTAssertEqual(hdr.crc32, recomputed,
                   @"Header CRC must match payload CRC-32");
}

- (void)testMediaFrameHeaderFlagBits {
    /* Each flag sets exactly one bit */
    XCTAssertEqual(KEYDRD_FLAG_HEVC,       0x01);
    XCTAssertEqual(KEYDRD_FLAG_KEYFRAME,   0x02);
    XCTAssertEqual(KEYDRD_FLAG_LAST_CHUNK, 0x04);
    XCTAssertEqual(KEYDRD_FLAG_DELTA,      0x40);

    /* No overlap between any two flags */
    XCTAssertEqual(KEYDRD_FLAG_HEVC & KEYDRD_FLAG_KEYFRAME, 0);
    XCTAssertEqual(KEYDRD_FLAG_HEVC & KEYDRD_FLAG_LAST_CHUNK, 0);
    XCTAssertEqual(KEYDRD_FLAG_HEVC & KEYDRD_FLAG_DELTA, 0);
    XCTAssertEqual(KEYDRD_FLAG_KEYFRAME & KEYDRD_FLAG_LAST_CHUNK, 0);
    XCTAssertEqual(KEYDRD_FLAG_KEYFRAME & KEYDRD_FLAG_DELTA, 0);
    XCTAssertEqual(KEYDRD_FLAG_LAST_CHUNK & KEYDRD_FLAG_DELTA, 0);

    /* Combining flags works via OR */
    uint8_t combined = KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
    XCTAssertTrue(combined & KEYDRD_FLAG_KEYFRAME);
    XCTAssertTrue(combined & KEYDRD_FLAG_LAST_CHUNK);
    XCTAssertFalse(combined & KEYDRD_FLAG_HEVC);
    XCTAssertFalse(combined & KEYDRD_FLAG_DELTA);

    /* HEVC and DELTA are semantically mutually exclusive:
     * HEVC = hardware-encoded stream, DELTA = XOR delta of raw pixels.
     * Verify they don't share any bit. */
    XCTAssertEqual(KEYDRD_FLAG_HEVC & KEYDRD_FLAG_DELTA, 0,
                   @"HEVC and DELTA flags must not share bits");
}

- (void)testMediaFrameHeaderMaxSeqWraparound {
    MediaFrameHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = KEYDRD_MAGIC;
    hdr.seq   = UINT16_MAX; /* 65535 */

    uint8_t wire[24];
    memcpy(wire, &hdr, sizeof(hdr));

    MediaFrameHeader parsed;
    memcpy(&parsed, wire, sizeof(parsed));

    XCTAssertEqual(parsed.seq, 65535);

    /* Simulate wraparound */
    uint16_t next = (uint16_t)(parsed.seq + 1);
    XCTAssertEqual(next, 0, @"seq must wrap from 65535 to 0");
}

- (void)testMediaFrameHeaderMaxChunks {
    MediaFrameHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic       = KEYDRD_MAGIC;
    hdr.chunk_idx   = 254;
    hdr.chunk_total = 255;

    uint8_t wire[24];
    memcpy(wire, &hdr, sizeof(hdr));

    MediaFrameHeader parsed;
    memcpy(&parsed, wire, sizeof(parsed));

    XCTAssertEqual(parsed.chunk_idx, 254);
    XCTAssertEqual(parsed.chunk_total, 255);
}

#pragma mark - InputEventHeader

- (void)testInputEventHeaderRoundtrip {
    InputEventHeader original;
    original.type  = KEYDRD_INPUT_KEY;
    original.ts_us = 1234567890123456ULL;

    uint8_t wire[9];
    memcpy(wire, &original, sizeof(InputEventHeader));

    InputEventHeader parsed;
    memcpy(&parsed, wire, sizeof(InputEventHeader));

    XCTAssertEqual(parsed.type, KEYDRD_INPUT_KEY);
    XCTAssertEqual(parsed.ts_us, 1234567890123456ULL);
}

- (void)testAllInputTypeCodes {
    /* Collect all defined type codes and verify uniqueness */
    uint8_t codes[] = {
        KEYDRD_INPUT_MOUSE_MOVE,        /* 0x01 */
        KEYDRD_INPUT_CLICK,             /* 0x02 */
        KEYDRD_INPUT_SCROLL,            /* 0x03 */
        KEYDRD_INPUT_KEY,               /* 0x10 */
        KEYDRD_INPUT_MODE_CHANGE,       /* 0x20 */
        KEYDRD_INPUT_RES_MATCH_REQUEST, /* 0x21 */
        KEYDRD_INPUT_RES_MATCH_RESPONSE,/* 0x22 */
        KEYDRD_INPUT_GEOMETRY_UPDATE,   /* 0x23 */
        KEYDRD_INPUT_KEEPALIVE,         /* 0x30 */
        KEYDRD_INPUT_LATENCY_PROBE,     /* 0xFF */
    };
    size_t count = sizeof(codes) / sizeof(codes[0]);

    /* Brute-force uniqueness check */
    for (size_t i = 0; i < count; i++) {
        for (size_t j = i + 1; j < count; j++) {
            XCTAssertNotEqual(codes[i], codes[j],
                              @"Input type codes at index %zu and %zu must be unique (both 0x%02X)",
                              i, j, codes[i]);
        }
    }

    /* Verify expected values */
    XCTAssertEqual(KEYDRD_INPUT_MOUSE_MOVE,        0x01);
    XCTAssertEqual(KEYDRD_INPUT_CLICK,             0x02);
    XCTAssertEqual(KEYDRD_INPUT_SCROLL,            0x03);
    XCTAssertEqual(KEYDRD_INPUT_KEY,               0x10);
    XCTAssertEqual(KEYDRD_INPUT_MODE_CHANGE,       0x20);
    XCTAssertEqual(KEYDRD_INPUT_RES_MATCH_REQUEST, 0x21);
    XCTAssertEqual(KEYDRD_INPUT_RES_MATCH_RESPONSE,0x22);
    XCTAssertEqual(KEYDRD_INPUT_GEOMETRY_UPDATE,   0x23);
    XCTAssertEqual(KEYDRD_INPUT_KEEPALIVE,         0x30);
    XCTAssertEqual(KEYDRD_INPUT_LATENCY_PROBE,     0xFF);
}

#pragma mark - SessionHandshakeMessage

- (void)testSessionHandshakeRoundtrip {
    SessionHandshakeMessage original;
    memset(&original, 0, sizeof(original));

    original.magic         = KEYDRD_MAGIC;
    original.msg_type      = KEYDRD_MSG_SESSION_HANDSHAKE;
    original.display_width = 2560;
    original.display_height = 1600;
    original.scale_factor  = 2.0f;
    original.aspect_ratio  = 2560.0f / 1600.0f;
    original.capabilities  = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC;
    original.max_fps       = 120;
    original.agent_version = 1;
    original.reserved      = 0;

    /* Serialize */
    uint8_t wire[sizeof(SessionHandshakeMessage)];
    memcpy(wire, &original, sizeof(original));

    /* Parse */
    SessionHandshakeMessage parsed;
    memcpy(&parsed, wire, sizeof(parsed));

    XCTAssertEqual(parsed.magic, KEYDRD_MAGIC);
    XCTAssertEqual(parsed.msg_type, KEYDRD_MSG_SESSION_HANDSHAKE);
    XCTAssertEqual(parsed.display_width, 2560u);
    XCTAssertEqual(parsed.display_height, 1600u);
    XCTAssertEqualWithAccuracy(parsed.scale_factor, 2.0f, 0.001f);
    XCTAssertEqualWithAccuracy(parsed.aspect_ratio, 2560.0f / 1600.0f, 0.001f);
    XCTAssertEqual(parsed.capabilities, (KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC));
    XCTAssertEqual(parsed.max_fps, 120);
    XCTAssertEqual(parsed.agent_version, 1);
    XCTAssertEqual(parsed.reserved, 0u);
}

- (void)testSessionHandshakeCapabilityFlags {
    /* Each capability flag is independent */
    XCTAssertEqual(KEYDRD_CAP_LZ4,           0x01);
    XCTAssertEqual(KEYDRD_CAP_HEVC,          0x02);
    XCTAssertEqual(KEYDRD_CAP_ECO_AVAILABLE, 0x04);

    /* No overlap */
    XCTAssertEqual(KEYDRD_CAP_LZ4 & KEYDRD_CAP_HEVC, 0);
    XCTAssertEqual(KEYDRD_CAP_LZ4 & KEYDRD_CAP_ECO_AVAILABLE, 0);
    XCTAssertEqual(KEYDRD_CAP_HEVC & KEYDRD_CAP_ECO_AVAILABLE, 0);

    /* Individual flag testing */
    uint8_t caps = KEYDRD_CAP_LZ4;
    XCTAssertTrue(caps & KEYDRD_CAP_LZ4);
    XCTAssertFalse(caps & KEYDRD_CAP_HEVC);
    XCTAssertFalse(caps & KEYDRD_CAP_ECO_AVAILABLE);

    caps = KEYDRD_CAP_HEVC;
    XCTAssertFalse(caps & KEYDRD_CAP_LZ4);
    XCTAssertTrue(caps & KEYDRD_CAP_HEVC);
    XCTAssertFalse(caps & KEYDRD_CAP_ECO_AVAILABLE);

    caps = KEYDRD_CAP_ECO_AVAILABLE;
    XCTAssertFalse(caps & KEYDRD_CAP_LZ4);
    XCTAssertFalse(caps & KEYDRD_CAP_HEVC);
    XCTAssertTrue(caps & KEYDRD_CAP_ECO_AVAILABLE);

    /* All three combined */
    caps = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE;
    XCTAssertTrue(caps & KEYDRD_CAP_LZ4);
    XCTAssertTrue(caps & KEYDRD_CAP_HEVC);
    XCTAssertTrue(caps & KEYDRD_CAP_ECO_AVAILABLE);
    XCTAssertEqual(caps, 0x07);
}

#pragma mark - ResolutionMatchPayload

- (void)testResolutionMatchPayloadRoundtrip {
    ResolutionMatchPayload original;
    original.ipad_width  = 2388;
    original.ipad_height = 1668;

    uint8_t wire[sizeof(ResolutionMatchPayload)];
    memcpy(wire, &original, sizeof(original));

    ResolutionMatchPayload parsed;
    memcpy(&parsed, wire, sizeof(parsed));

    XCTAssertEqual(parsed.ipad_width, 2388u);
    XCTAssertEqual(parsed.ipad_height, 1668u);
}

#pragma mark - ResolutionMatchResponse

- (void)testResolutionMatchResponseRoundtrip {
    /* Test all three result codes */
    uint8_t resultCodes[] = {
        KEYDRD_RES_MATCH_OK,
        KEYDRD_RES_MATCH_FAILED,
        KEYDRD_RES_MATCH_NO_MODE,
    };

    for (size_t i = 0; i < sizeof(resultCodes) / sizeof(resultCodes[0]); i++) {
        ResolutionMatchResponse original;
        memset(&original, 0, sizeof(original));
        original.result = resultCodes[i];

        if (resultCodes[i] == KEYDRD_RES_MATCH_OK) {
            original.new_width  = 2388;
            original.new_height = 1668;
            original.new_scale  = 2.0f;
        } else {
            original.new_width  = 0;
            original.new_height = 0;
            original.new_scale  = 0.0f;
        }

        uint8_t wire[sizeof(ResolutionMatchResponse)];
        memcpy(wire, &original, sizeof(original));

        ResolutionMatchResponse parsed;
        memcpy(&parsed, wire, sizeof(parsed));

        XCTAssertEqual(parsed.result, resultCodes[i]);
        XCTAssertEqual(parsed.new_width, original.new_width);
        XCTAssertEqual(parsed.new_height, original.new_height);
        XCTAssertEqualWithAccuracy(parsed.new_scale, original.new_scale, 0.001f);
    }

    /* Verify result code constants */
    XCTAssertEqual(KEYDRD_RES_MATCH_OK,      0x00);
    XCTAssertEqual(KEYDRD_RES_MATCH_FAILED,  0x01);
    XCTAssertEqual(KEYDRD_RES_MATCH_NO_MODE, 0x02);
}

#pragma mark - GeometryUpdatePayload

- (void)testGeometryUpdatePayloadRoundtrip {
    GeometryUpdatePayload original;
    original.display_width  = 3024;
    original.display_height = 1964;
    original.scale_factor   = 2.0f;
    original.aspect_ratio   = 3024.0f / 1964.0f;

    uint8_t wire[sizeof(GeometryUpdatePayload)];
    memcpy(wire, &original, sizeof(original));

    GeometryUpdatePayload parsed;
    memcpy(&parsed, wire, sizeof(parsed));

    XCTAssertEqual(parsed.display_width, 3024u);
    XCTAssertEqual(parsed.display_height, 1964u);
    XCTAssertEqualWithAccuracy(parsed.scale_factor, 2.0f, 0.001f);
    XCTAssertEqualWithAccuracy(parsed.aspect_ratio, 3024.0f / 1964.0f, 0.001f);
}

@end
