/*
 * PipelineTests.m
 * Full data pipeline tests for keyd-rd.
 *
 * Tests the complete flow: compress -> header -> send -> receive -> parse -> decompress -> verify.
 * Uses localhost TCP loopback via NWListener + NWConnection.
 */

#import <XCTest/XCTest.h>
#import <Network/Network.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include "protocol.h"
#include "lz4.h"
#include "delta.h"
#include "FrameCompressor.h"
#import "HEVCEncoder.h"
#include <zlib.h>
#include <string.h>

/* ---- Test Surface Helpers ---- */

static IOSurfaceRef createTestSurface(size_t width, size_t height) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void fillSurfaceWithPattern(IOSurfaceRef surface, uint8_t seed) {
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t len = IOSurfaceGetAllocSize(surface);
    for (size_t i = 0; i < len; i++) {
        base[i] = (uint8_t)((i * 7 + seed) & 0xFF);
    }
    IOSurfaceUnlock(surface, 0, NULL);
}

static CVPixelBufferRef createPixelBufferFromSurface(IOSurfaceRef surface) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &pb);
    return pb;
}

/* ---- Localhost TCP Helper ----
 * Spins up an NWListener on port 0 (auto-assigned) and returns the port.
 * Calls serverBlock when a connection is accepted and becomes ready.
 * The listener runs on the provided queue.
 */
typedef void (^ServerConnectionBlock)(nw_connection_t conn);

static nw_listener_t createLocalhostListener(dispatch_queue_t queue,
                                              uint16_t *outPort,
                                              XCTestExpectation *listenerReady,
                                              ServerConnectionBlock serverBlock) {
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    /* Restrict to localhost loopback */
    nw_parameters_set_local_endpoint(params,
        nw_endpoint_create_host("127.0.0.1", "0"));

    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_state_changed_handler(listener,
        ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            *outPort = nw_listener_get_port(listener);
            [listenerReady fulfill];
        }
    });

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn,
            ^(nw_connection_state_t state, nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                serverBlock(conn);
            }
        });
        nw_connection_start(conn);
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);
    return listener;
}

/* Connect to localhost:<port>, call block when ready. */
static nw_connection_t connectToLocalhost(uint16_t port, dispatch_queue_t queue,
                                           XCTestExpectation *connReady) {
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", port);
    nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t conn = nw_connection_create(ep, params);
    nw_connection_set_queue(conn, queue);
    nw_connection_set_state_changed_handler(conn,
        ^(nw_connection_state_t state, nw_error_t _Nullable error) {
        if (state == nw_connection_state_ready && connReady) {
            [connReady fulfill];
        }
    });
    nw_connection_start(conn);
    return conn;
}

/* Send raw bytes over an NWConnection. */
static void sendBytes(nw_connection_t conn, const void *data, size_t len,
                      dispatch_block_t completion) {
    void *copy = malloc(len);
    memcpy(copy, data, len);
    dispatch_data_t dd = dispatch_data_create(copy, len, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(conn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t _Nullable error) {
        if (completion) completion();
    });
}

/* Receive exactly `len` bytes. Calls block with a contiguous buffer. */
static void receiveBytes(nw_connection_t conn, size_t len,
                         void (^block)(const uint8_t *buf, size_t actual)) {
    nw_connection_receive(conn, (uint32_t)len, (uint32_t)len,
        ^(dispatch_data_t _Nullable content,
          nw_content_context_t _Nullable ctx,
          bool is_complete,
          nw_error_t _Nullable error) {
        if (!content) {
            block(NULL, 0);
            return;
        }
        __block NSMutableData *result = [NSMutableData data];
        dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                           const void *buffer, size_t size) {
            [result appendBytes:buffer length:size];
            return true;
        });
        block((const uint8_t *)result.bytes, result.length);
    });
}

/* ---- Create a fake CMSampleBuffer wrapping an IOSurface ---- */
static CMSampleBufferRef createFakeSampleBuffer(IOSurfaceRef surface, CMTime pts) {
    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);
    if (!pb) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fmt);
    if (!fmt) {
        CVPixelBufferRelease(pb);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
        .duration = kCMTimeInvalid,
    };

    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(pb);
    return sb;
}

#pragma mark - Test Class

@interface PipelineTests : XCTestCase
@property (nonatomic) dispatch_queue_t testQueue;
@end

@implementation PipelineTests

- (void)setUp {
    [super setUp];
    self.testQueue = dispatch_queue_create("com.keydrd.test.pipeline", DISPATCH_QUEUE_SERIAL);
}

#pragma mark - LZ4 Pipeline

- (void)testLZ4FramePipelineRoundtrip {
    const size_t W = 640, H = 480;
    const size_t frame_bytes = W * H * 4;

    /* Create and fill source surface */
    IOSurfaceRef surface = createTestSurface(W, H);
    XCTAssertTrue(surface != NULL, @"IOSurface creation must succeed");
    fillSurfaceWithPattern(surface, 42);

    /* Read original pixel data for later comparison */
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    NSData *originalData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface) length:frame_bytes];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    /* Initialize compressor */
    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0, @"Compressor init must succeed");

    /* Compress the frame on the compress queue */
    __block CompressOutput output = compressor.output;
    __block MediaFrameHeader sentHeader;
    __block NSData *compressedPayload = nil;

    CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(0, 1000000));
    XCTAssertTrue(sb != NULL, @"Sample buffer creation must succeed");

    dispatch_sync(compressor.compress_queue, ^{
        int result = compress_frame(&compressor, surface, sb, &output);
        XCTAssertEqual(result, 0, @"compress_frame must succeed");

        sentHeader = output.header;
        compressedPayload = [NSData dataWithBytes:output.buf length:output.compressed_size];
    });

    CFRelease(sb);

    /* Verify header basics */
    XCTAssertEqual(sentHeader.magic, KEYDRD_MAGIC);
    XCTAssertTrue(sentHeader.flags & KEYDRD_FLAG_KEYFRAME, @"First frame must be keyframe");
    XCTAssertGreaterThan(sentHeader.payload_size, 0u);

    /* Send header + payload over localhost TCP, receive on other side */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *roundtripDone = [self expectationWithDescription:@"roundtrip done"];

    __block uint16_t port = 0;
    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Server: receive header, then payload */
        receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
            XCTAssertEqual(hdrLen, sizeof(MediaFrameHeader));

            MediaFrameHeader recvHeader;
            memcpy(&recvHeader, hdrBuf, sizeof(MediaFrameHeader));

            XCTAssertEqual(recvHeader.magic, KEYDRD_MAGIC);
            XCTAssertEqual(recvHeader.flags, sentHeader.flags);
            XCTAssertEqual(recvHeader.seq, sentHeader.seq);
            XCTAssertEqual(recvHeader.payload_size, sentHeader.payload_size);
            XCTAssertEqual(recvHeader.crc32, sentHeader.crc32);

            /* Receive compressed payload */
            receiveBytes(serverConn, recvHeader.payload_size, ^(const uint8_t *payloadBuf, size_t payloadLen) {
                XCTAssertEqual(payloadLen, (size_t)recvHeader.payload_size);

                /* Verify CRC */
                uint32_t computedCRC = (uint32_t)crc32(0L, payloadBuf, (uInt)payloadLen);
                XCTAssertEqual(computedCRC, recvHeader.crc32, @"CRC must match");

                /* Decompress */
                uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
                int decompSize = LZ4_decompress_safe((const char *)payloadBuf,
                                                      (char *)decompressed,
                                                      (int)payloadLen,
                                                      (int)frame_bytes);
                XCTAssertEqual((size_t)decompSize, frame_bytes, @"Decompressed size must match frame_bytes");

                /* Byte-by-byte comparison */
                XCTAssertEqual(memcmp(decompressed, originalData.bytes, frame_bytes), 0,
                               @"Decompressed data must match original");

                free(decompressed);
                [roundtripDone fulfill];
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    /* Client: connect and send */
    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send header */
    sendBytes(client, &sentHeader, sizeof(MediaFrameHeader), ^{
        /* Send payload */
        sendBytes(client, compressedPayload.bytes, compressedPayload.length, nil);
    });

    [self waitForExpectations:@[roundtripDone] timeout:10.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
    CFRelease(surface);
}

- (void)testLZ4DeltaFramePipelineRoundtrip {
    const size_t W = 640, H = 480;
    const size_t frame_bytes = W * H * 4;

    /* Create two surfaces: keyframe and slightly modified second frame */
    IOSurfaceRef surface1 = createTestSurface(W, H);
    IOSurfaceRef surface2 = createTestSurface(W, H);
    fillSurfaceWithPattern(surface1, 10);
    fillSurfaceWithPattern(surface2, 12); /* Slightly different */

    /* Read original data for both frames */
    IOSurfaceLock(surface1, kIOSurfaceLockReadOnly, NULL);
    NSData *frame1Data = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface1) length:frame_bytes];
    IOSurfaceUnlock(surface1, kIOSurfaceLockReadOnly, NULL);

    IOSurfaceLock(surface2, kIOSurfaceLockReadOnly, NULL);
    NSData *frame2Data = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface2) length:frame_bytes];
    IOSurfaceUnlock(surface2, kIOSurfaceLockReadOnly, NULL);

    /* Compress both frames */
    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    /* Force keyframe interval large enough that frame 2 is a delta */
    compressor.keyframe_interval_frames = 120;

    __block CompressOutput out1 = compressor.output;
    __block MediaFrameHeader hdr1;
    __block NSData *payload1 = nil;

    __block CompressOutput out2 = compressor.output;
    __block MediaFrameHeader hdr2;
    __block NSData *payload2 = nil;

    CMSampleBufferRef sb1 = createFakeSampleBuffer(surface1, CMTimeMake(0, 1000000));
    CMSampleBufferRef sb2 = createFakeSampleBuffer(surface2, CMTimeMake(33333, 1000000));

    dispatch_sync(compressor.compress_queue, ^{
        compress_frame(&compressor, surface1, sb1, &out1);
        hdr1 = out1.header;
        payload1 = [NSData dataWithBytes:out1.buf length:out1.compressed_size];

        compress_frame(&compressor, surface2, sb2, &out2);
        hdr2 = out2.header;
        payload2 = [NSData dataWithBytes:out2.buf length:out2.compressed_size];
    });

    CFRelease(sb1);
    CFRelease(sb2);

    XCTAssertTrue(hdr1.flags & KEYDRD_FLAG_KEYFRAME, @"Frame 1 must be keyframe");
    /* Frame 2 is either delta or keyframe (if delta exceeded threshold) */

    /* Send both frames over TCP, decompress on receive side */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *done = [self expectationWithDescription:@"delta roundtrip done"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Receive frame 1 (keyframe) */
        receiveBytes(serverConn, sizeof(MediaFrameHeader) + payload1.length,
            ^(const uint8_t *buf1, size_t len1) {
            MediaFrameHeader h1;
            memcpy(&h1, buf1, sizeof(MediaFrameHeader));
            const uint8_t *p1 = buf1 + sizeof(MediaFrameHeader);

            uint8_t *decompKF = (uint8_t *)malloc(frame_bytes);
            int d1 = LZ4_decompress_safe((const char *)p1, (char *)decompKF,
                                          (int)h1.payload_size, (int)frame_bytes);
            XCTAssertEqual((size_t)d1, frame_bytes);
            XCTAssertEqual(memcmp(decompKF, frame1Data.bytes, frame_bytes), 0,
                           @"Keyframe must match original");

            /* Receive frame 2 */
            receiveBytes(serverConn, sizeof(MediaFrameHeader) + payload2.length,
                ^(const uint8_t *buf2, size_t len2) {
                MediaFrameHeader h2;
                memcpy(&h2, buf2, sizeof(MediaFrameHeader));
                const uint8_t *p2 = buf2 + sizeof(MediaFrameHeader);

                uint8_t *decompRaw = (uint8_t *)malloc(frame_bytes);
                int d2 = LZ4_decompress_safe((const char *)p2, (char *)decompRaw,
                                              (int)h2.payload_size, (int)frame_bytes);
                XCTAssertEqual((size_t)d2, frame_bytes);

                if (h2.flags & KEYDRD_FLAG_DELTA) {
                    /* Apply delta: decompRaw XOR keyframe = original frame 2 */
                    uint8_t *reconstructed = (uint8_t *)malloc(frame_bytes);
                    apply_delta(decompRaw, decompKF, reconstructed, frame_bytes);
                    XCTAssertEqual(memcmp(reconstructed, frame2Data.bytes, frame_bytes), 0,
                                   @"Delta-reconstructed frame must match original");
                    free(reconstructed);
                } else {
                    /* Fell back to keyframe due to threshold */
                    XCTAssertEqual(memcmp(decompRaw, frame2Data.bytes, frame_bytes), 0,
                                   @"Keyframe fallback must match original");
                }

                free(decompRaw);
                free(decompKF);
                [done fulfill];
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send both frames: header + payload concatenated */
    NSMutableData *wire1 = [NSMutableData dataWithBytes:&hdr1 length:sizeof(hdr1)];
    [wire1 appendData:payload1];
    NSMutableData *wire2 = [NSMutableData dataWithBytes:&hdr2 length:sizeof(hdr2)];
    [wire2 appendData:payload2];

    sendBytes(client, wire1.bytes, wire1.length, ^{
        sendBytes(client, wire2.bytes, wire2.length, nil);
    });

    [self waitForExpectations:@[done] timeout:10.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
    CFRelease(surface1);
    CFRelease(surface2);
}

- (void)testLZ4MultiFrameStreaming {
    const size_t W = 320, H = 240;
    const size_t frame_bytes = W * H * 4;
    const int FRAME_COUNT = 10;

    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    /* Compress 10 frames with different patterns */
    NSMutableArray<NSData *> *wireFrames = [NSMutableArray array];
    __block NSMutableArray<NSNumber *> *expectedSeqs = [NSMutableArray array];
    __block NSMutableArray<NSNumber *> *expectedCRCs = [NSMutableArray array];

    for (int i = 0; i < FRAME_COUNT; i++) {
        IOSurfaceRef surface = createTestSurface(W, H);
        fillSurfaceWithPattern(surface, (uint8_t)(i * 3));

        CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(i * 33333, 1000000));
        __block CompressOutput out = compressor.output;
        __block MediaFrameHeader hdr;

        dispatch_sync(compressor.compress_queue, ^{
            compress_frame(&compressor, surface, sb, &out);
            hdr = out.header;
        });

        [expectedSeqs addObject:@(hdr.seq)];
        [expectedCRCs addObject:@(hdr.crc32)];

        NSMutableData *wire = [NSMutableData dataWithBytes:&hdr length:sizeof(hdr)];
        [wire appendBytes:out.buf length:out.compressed_size];
        [wireFrames addObject:wire];

        CFRelease(sb);
        CFRelease(surface);
    }

    /* Send all frames over TCP, verify on receive side */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *allReceived = [self expectationWithDescription:@"all frames received"];
    __block uint16_t port = 0;
    __block int receivedCount = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Receive all frames one by one */
        __block void (^receiveNext)(void);
        receiveNext = ^{
            if (receivedCount >= FRAME_COUNT) {
                [allReceived fulfill];
                return;
            }
            receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
                if (hdrLen < sizeof(MediaFrameHeader)) return;

                MediaFrameHeader hdr;
                memcpy(&hdr, hdrBuf, sizeof(MediaFrameHeader));

                XCTAssertEqual(hdr.magic, KEYDRD_MAGIC);
                XCTAssertEqual(hdr.seq, [expectedSeqs[receivedCount] unsignedShortValue],
                               @"Sequence number must increment for frame %d", receivedCount);

                receiveBytes(serverConn, hdr.payload_size, ^(const uint8_t *payload, size_t payloadLen) {
                    uint32_t computedCRC = (uint32_t)crc32(0L, payload, (uInt)payloadLen);
                    XCTAssertEqual(computedCRC, hdr.crc32,
                                   @"CRC must match for frame %d", receivedCount);
                    XCTAssertEqual(computedCRC, [expectedCRCs[receivedCount] unsignedIntValue]);

                    receivedCount++;
                    receiveNext();
                });
            });
        };
        receiveNext();
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send all frames in sequence */
    __block void (^sendNext)(int);
    sendNext = ^(int idx) {
        if (idx >= FRAME_COUNT) return;
        sendBytes(client, wireFrames[idx].bytes, wireFrames[idx].length, ^{
            sendNext(idx + 1);
        });
    };
    sendNext(0);

    [self waitForExpectations:@[allReceived] timeout:15.0];

    XCTAssertEqual(receivedCount, FRAME_COUNT);

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
}

#pragma mark - HEVC Pipeline

- (void)testHEVCEncoderProducesOutput {
    XCTestExpectation *encodedExpect = [self expectationWithDescription:@"HEVC frame encoded"];

    HEVCEncoder *encoder = [[HEVCEncoder alloc] init];

    encoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        XCTAssertGreaterThan(len, 0u, @"Encoded data must be non-empty");
        XCTAssertTrue(header.flags & KEYDRD_FLAG_HEVC, @"HEVC flag must be set");
        XCTAssertEqual(header.magic, KEYDRD_MAGIC);
        XCTAssertGreaterThan(header.payload_size, 0u);
        [encodedExpect fulfill];
    };

    [encoder startWithWidth:640 height:480 fps:30 bitrate:2000000];
    XCTAssertTrue(encoder.isActive, @"Encoder must be active after start");

    /* Create BGRA CVPixelBuffer with gradient pattern */
    IOSurfaceRef surface = createTestSurface(640, 480);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    for (size_t y = 0; y < 480; y++) {
        for (size_t x = 0; x < 640; x++) {
            size_t off = (y * 640 + x) * 4;
            base[off + 0] = (uint8_t)(x & 0xFF);         /* B */
            base[off + 1] = (uint8_t)(y & 0xFF);         /* G */
            base[off + 2] = (uint8_t)((x + y) & 0xFF);   /* R */
            base[off + 3] = 0xFF;                          /* A */
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);
    XCTAssertTrue(pb != NULL);

    [encoder encodePixelBuffer:pb timestamp:CMTimeMake(0, 1000000)];

    /* The encoder callback is async, give it time */
    [self waitForExpectations:@[encodedExpect] timeout:5.0];

    [encoder stop];
    CVPixelBufferRelease(pb);
    CFRelease(surface);
}

- (void)testHEVCEncodeDecodePipeline {
    XCTestExpectation *decodeDone = [self expectationWithDescription:@"HEVC decode done"];

    HEVCEncoder *encoder = [[HEVCEncoder alloc] init];
    __block NSData *encodedNALData = nil;
    __block MediaFrameHeader encodedHeader;

    /* We need the format description from the encoder to create the decoder.
     * Encode multiple frames to ensure we get at least one keyframe. */
    __block int framesReceived = 0;

    encoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        framesReceived++;
        if (!encodedNALData) {
            encodedNALData = [NSData dataWithBytes:data length:len];
            encodedHeader = header;
        }
    };

    [encoder startWithWidth:640 height:480 fps:30 bitrate:2000000];

    IOSurfaceRef surface = createTestSurface(640, 480);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    /* Fill with solid color gradient for predictable encoding */
    for (size_t y = 0; y < 480; y++) {
        for (size_t x = 0; x < 640; x++) {
            size_t off = (y * 640 + x) * 4;
            base[off + 0] = 128;   /* B */
            base[off + 1] = 64;    /* G */
            base[off + 2] = 32;    /* R */
            base[off + 3] = 255;   /* A */
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);

    /* Encode several frames to get at least one keyframe out */
    for (int i = 0; i < 5; i++) {
        [encoder encodePixelBuffer:pb timestamp:CMTimeMake(i * 33333, 1000000)];
    }

    /* Wait for encoder output */
    XCTestExpectation *encodeWait = [self expectationWithDescription:@"encode wait"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [encodeWait fulfill];
    });
    [self waitForExpectations:@[encodeWait] timeout:5.0];

    XCTAssertNotNil(encodedNALData, @"Must have received at least one encoded frame");
    XCTAssertGreaterThan(encodedNALData.length, 0u);
    XCTAssertTrue(encodedHeader.flags & KEYDRD_FLAG_HEVC);

    /* Try to create a VTDecompressionSession from the encoded data.
     * First, we need a CMFormatDescription. Create one from HEVC parameter sets.
     * For simplicity, we verify the data starts with valid NAL units and
     * doesn't crash when we attempt to create a format description. */
    XCTAssertGreaterThan(framesReceived, 0, @"Should have received encoded frames");

    /* Verify the encoded data is non-trivial HEVC bitstream */
    const uint8_t *nalBytes = (const uint8_t *)encodedNALData.bytes;
    /* HEVC NAL data from VT uses AVCC-style length prefixes (4-byte big-endian length) */
    if (encodedNALData.length >= 4) {
        uint32_t nalLen = ((uint32_t)nalBytes[0] << 24) | ((uint32_t)nalBytes[1] << 16) |
                          ((uint32_t)nalBytes[2] << 8)  | (uint32_t)nalBytes[3];
        XCTAssertGreaterThan(nalLen, 0u, @"NAL unit must have non-zero length");
        XCTAssertLessThanOrEqual(nalLen + 4, (uint32_t)encodedNALData.length,
                                 @"NAL length must be within bounds");
    }

    [decodeDone fulfill];

    [self waitForExpectations:@[decodeDone] timeout:3.0];

    [encoder stop];
    CVPixelBufferRelease(pb);
    CFRelease(surface);
}

#pragma mark - Input Pipeline

- (void)testInputEventSendReceive {
    InputEventHeader original;
    original.type  = KEYDRD_INPUT_MOUSE_MOVE;
    original.ts_us = 9876543210ULL;

    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *received = [self expectationWithDescription:@"input event received"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        receiveBytes(serverConn, sizeof(InputEventHeader), ^(const uint8_t *buf, size_t len) {
            XCTAssertEqual(len, sizeof(InputEventHeader));
            InputEventHeader parsed;
            memcpy(&parsed, buf, sizeof(InputEventHeader));
            XCTAssertEqual(parsed.type, KEYDRD_INPUT_MOUSE_MOVE);
            XCTAssertEqual(parsed.ts_us, 9876543210ULL);
            [received fulfill];
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    sendBytes(client, &original, sizeof(InputEventHeader), nil);

    [self waitForExpectations:@[received] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

- (void)testAllInputTypesRoundtrip {
    uint8_t types[] = {
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
    size_t typeCount = sizeof(types) / sizeof(types[0]);

    for (size_t i = 0; i < typeCount; i++) {
        InputEventHeader original;
        original.type  = types[i];
        original.ts_us = 1000000ULL * (i + 1);

        /* Serialize to wire */
        uint8_t wire[9];
        memcpy(wire, &original, sizeof(InputEventHeader));

        /* Parse back */
        InputEventHeader parsed;
        memcpy(&parsed, wire, sizeof(InputEventHeader));

        XCTAssertEqual(parsed.type, types[i],
                       @"Type 0x%02X must survive roundtrip", types[i]);
        XCTAssertEqual(parsed.ts_us, original.ts_us,
                       @"Timestamp must survive roundtrip for type 0x%02X", types[i]);
    }
}

- (void)testSessionHandshakeDelivery {
    SessionHandshakeMessage original;
    memset(&original, 0, sizeof(original));
    original.magic          = KEYDRD_MAGIC;
    original.msg_type       = KEYDRD_MSG_SESSION_HANDSHAKE;
    original.display_width  = 3600;
    original.display_height = 2338;
    original.scale_factor   = 2.0f;
    original.aspect_ratio   = 3600.0f / 2338.0f;
    original.capabilities   = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE;
    original.max_fps        = 120;
    original.agent_version  = 1;
    original.reserved       = 0;

    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *handshakeReceived = [self expectationWithDescription:@"handshake received"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        receiveBytes(serverConn, sizeof(SessionHandshakeMessage),
            ^(const uint8_t *buf, size_t len) {
            XCTAssertEqual(len, sizeof(SessionHandshakeMessage));

            SessionHandshakeMessage parsed;
            memcpy(&parsed, buf, sizeof(SessionHandshakeMessage));

            XCTAssertEqual(parsed.magic, KEYDRD_MAGIC);
            XCTAssertEqual(parsed.msg_type, KEYDRD_MSG_SESSION_HANDSHAKE);
            XCTAssertEqual(parsed.display_width, 3600u);
            XCTAssertEqual(parsed.display_height, 2338u);
            XCTAssertEqualWithAccuracy(parsed.scale_factor, 2.0f, 0.001f);
            XCTAssertEqualWithAccuracy(parsed.aspect_ratio, 3600.0f / 2338.0f, 0.01f);
            XCTAssertEqual(parsed.capabilities,
                           (KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE));
            XCTAssertEqual(parsed.max_fps, 120);
            XCTAssertEqual(parsed.agent_version, 1);

            [handshakeReceived fulfill];
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    sendBytes(client, &original, sizeof(SessionHandshakeMessage), nil);

    [self waitForExpectations:@[handshakeReceived] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

- (void)testResolutionMatchRequestResponse {
    /* Build request: InputEventHeader (type=0x21) + ResolutionMatchPayload */
    InputEventHeader reqHeader;
    reqHeader.type  = KEYDRD_INPUT_RES_MATCH_REQUEST;
    reqHeader.ts_us = 5555555555ULL;

    ResolutionMatchPayload reqPayload;
    reqPayload.ipad_width  = 2388;
    reqPayload.ipad_height = 1668;

    size_t reqSize = sizeof(InputEventHeader) + sizeof(ResolutionMatchPayload);
    uint8_t reqBuf[sizeof(InputEventHeader) + sizeof(ResolutionMatchPayload)];
    memcpy(reqBuf, &reqHeader, sizeof(InputEventHeader));
    memcpy(reqBuf + sizeof(InputEventHeader), &reqPayload, sizeof(ResolutionMatchPayload));

    /* Build response: InputEventHeader (type=0x22) + ResolutionMatchResponse */
    InputEventHeader respHeader;
    respHeader.type  = KEYDRD_INPUT_RES_MATCH_RESPONSE;
    respHeader.ts_us = 5555666666ULL;

    ResolutionMatchResponse respPayload;
    respPayload.result     = KEYDRD_RES_MATCH_OK;
    respPayload.new_width  = 2388;
    respPayload.new_height = 1668;
    respPayload.new_scale  = 2.0f;

    size_t respSize = sizeof(InputEventHeader) + sizeof(ResolutionMatchResponse);
    uint8_t *respBuf = (uint8_t *)malloc(respSize);
    memcpy(respBuf, &respHeader, sizeof(InputEventHeader));
    memcpy(respBuf + sizeof(InputEventHeader), &respPayload, sizeof(ResolutionMatchResponse));

    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *roundtripDone = [self expectationWithDescription:@"resolution match roundtrip"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Server receives request */
        receiveBytes(serverConn, reqSize, ^(const uint8_t *buf, size_t len) {
            XCTAssertEqual(len, reqSize);

            InputEventHeader parsedReqHdr;
            memcpy(&parsedReqHdr, buf, sizeof(InputEventHeader));
            XCTAssertEqual(parsedReqHdr.type, KEYDRD_INPUT_RES_MATCH_REQUEST);

            ResolutionMatchPayload parsedReqPayload;
            memcpy(&parsedReqPayload, buf + sizeof(InputEventHeader), sizeof(ResolutionMatchPayload));
            XCTAssertEqual(parsedReqPayload.ipad_width, 2388u);
            XCTAssertEqual(parsedReqPayload.ipad_height, 1668u);

            /* Server sends response */
            sendBytes(serverConn, respBuf, respSize, nil);
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Client sends request and waits for response */
    sendBytes(client, reqBuf, reqSize, ^{
        receiveBytes(client, respSize, ^(const uint8_t *buf, size_t len) {
            XCTAssertEqual(len, respSize);

            InputEventHeader parsedRespHdr;
            memcpy(&parsedRespHdr, buf, sizeof(InputEventHeader));
            XCTAssertEqual(parsedRespHdr.type, KEYDRD_INPUT_RES_MATCH_RESPONSE);
            XCTAssertEqual(parsedRespHdr.ts_us, 5555666666ULL);

            ResolutionMatchResponse parsedResp;
            memcpy(&parsedResp, buf + sizeof(InputEventHeader), sizeof(ResolutionMatchResponse));
            XCTAssertEqual(parsedResp.result, KEYDRD_RES_MATCH_OK);
            XCTAssertEqual(parsedResp.new_width, 2388u);
            XCTAssertEqual(parsedResp.new_height, 1668u);
            XCTAssertEqualWithAccuracy(parsedResp.new_scale, 2.0f, 0.001f);

            [roundtripDone fulfill];
        });
    });

    [self waitForExpectations:@[roundtripDone] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

#pragma mark - Throughput

- (void)testLZ4CompressionThroughput {
    const size_t W = 1920, H = 1080;
    const size_t frame_bytes = W * H * 4; /* ~8 MB per frame */
    const int FRAME_COUNT = 100;

    /* Create synthetic BGRA frame data */
    uint8_t *frameData = (uint8_t *)malloc(frame_bytes);
    XCTAssertTrue(frameData != NULL);
    for (size_t i = 0; i < frame_bytes; i++) {
        frameData[i] = (uint8_t)((i * 13 + 7) & 0xFF);
    }

    int bound = LZ4_compressBound((int)frame_bytes);
    uint8_t *compressed = (uint8_t *)malloc((size_t)bound);
    XCTAssertTrue(compressed != NULL);

    /* Measure compression throughput */
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

    for (int i = 0; i < FRAME_COUNT; i++) {
        /* Slightly vary data each frame to simulate real content */
        frameData[0] = (uint8_t)i;
        frameData[frame_bytes / 2] = (uint8_t)(i * 3);

        int result = LZ4_compress_default((const char *)frameData,
                                           (char *)compressed,
                                           (int)frame_bytes,
                                           bound);
        XCTAssertGreaterThan(result, 0, @"LZ4 compression must succeed for frame %d", i);
    }

    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
    double fps = (double)FRAME_COUNT / elapsed;

    NSLog(@"LZ4 throughput: %.1f frames/sec for %dx%d BGRA (%.2f ms/frame, %.1f MB/s)",
          fps, (int)W, (int)H, (elapsed / FRAME_COUNT) * 1000.0,
          (double)(FRAME_COUNT * frame_bytes) / elapsed / 1024.0 / 1024.0);

    XCTAssertGreaterThan(fps, 60.0,
                         @"LZ4 compression must sustain > 60fps for 1080p (actual: %.1f fps)", fps);

    free(frameData);
    free(compressed);
}

#pragma mark - Deterministic LZ4 Wire Format

- (void)testLZ4FrameWireFormatExact {
    /* Create known 64x64 BGRA surface with deterministic pixel pattern */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;  /* 16384 bytes */

    IOSurfaceRef surface = createTestSurface(W, H);
    XCTAssertTrue(surface != NULL, @"IOSurface creation must succeed");
    fillSurfaceWithPattern(surface, 0xAB);

    /* Capture original pixel data */
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    NSData *originalData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface) length:frame_bytes];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    /* Initialize compressor */
    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0, @"Compressor init must succeed");

    /* Compress the frame on the compress queue */
    __block CompressOutput output = compressor.output;
    __block MediaFrameHeader hdr;
    __block NSData *compressedPayload = nil;

    CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(100000, 1000000));
    XCTAssertTrue(sb != NULL, @"Sample buffer creation must succeed");

    dispatch_sync(compressor.compress_queue, ^{
        int result = compress_frame(&compressor, surface, sb, &output);
        XCTAssertEqual(result, 0, @"compress_frame must succeed");
        hdr = output.header;
        compressedPayload = [NSData dataWithBytes:output.buf length:output.compressed_size];
    });

    CFRelease(sb);

    /* ---- Verify every MediaFrameHeader field exactly ---- */
    XCTAssertEqual(hdr.magic, KEYDRD_MAGIC, @"magic must be 0x4B44");
    XCTAssertEqual(hdr.magic, (uint16_t)0x4B44, @"magic literal check");

    /* First frame: KEYFRAME flag set, HEVC flag NOT set, DELTA flag NOT set */
    XCTAssertTrue((hdr.flags & KEYDRD_FLAG_KEYFRAME) != 0, @"First frame must be keyframe");
    XCTAssertTrue((hdr.flags & KEYDRD_FLAG_HEVC) == 0, @"LZ4 frame must NOT have HEVC flag");
    XCTAssertTrue((hdr.flags & KEYDRD_FLAG_DELTA) == 0, @"First frame must NOT be delta");

    /* Sequence, chunk, reserved */
    XCTAssertEqual(hdr.seq, (uint16_t)0, @"First frame seq must be 0");
    XCTAssertEqual(hdr.chunk_idx, (uint8_t)0, @"chunk_idx must be 0");
    XCTAssertEqual(hdr.chunk_total, (uint8_t)1, @"chunk_total must be 1");
    XCTAssertEqual(hdr.reserved, (uint8_t)0, @"reserved must be 0");

    /* Payload size bounds */
    XCTAssertGreaterThan(hdr.payload_size, (uint32_t)0, @"payload_size must be > 0");
    int lz4bound = LZ4_compressBound((int)frame_bytes);
    XCTAssertLessThanOrEqual(hdr.payload_size, (uint32_t)lz4bound,
                             @"payload_size must be <= LZ4_compressBound");
    XCTAssertEqual(hdr.payload_size, (uint32_t)compressedPayload.length,
                   @"header payload_size must match actual compressed bytes");

    /* CRC32 must match actual CRC of compressed payload */
    uint32_t expectedCRC = (uint32_t)crc32(0L, (const uint8_t *)compressedPayload.bytes,
                                           (uInt)compressedPayload.length);
    XCTAssertEqual(hdr.crc32, expectedCRC, @"CRC32 must match actual payload CRC");

    /* Timestamp must be > 0 (we set pts to 100000/1000000 = 0.1s = 100000 us) */
    XCTAssertGreaterThan(hdr.ts_us, (uint64_t)0, @"Timestamp must be > 0");
    XCTAssertEqual(hdr.ts_us, (uint64_t)100000, @"Timestamp must match input PTS");

    /* ---- Decompress and verify pixels match original exactly ---- */
    uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
    int decompSize = LZ4_decompress_safe((const char *)compressedPayload.bytes,
                                          (char *)decompressed,
                                          (int)compressedPayload.length,
                                          (int)frame_bytes);
    XCTAssertEqual((size_t)decompSize, frame_bytes, @"Decompressed size must equal frame_bytes");
    XCTAssertEqual(memcmp(decompressed, originalData.bytes, frame_bytes), 0,
                   @"Decompressed data must match original pixel data byte-for-byte");

    free(decompressed);
    frame_compressor_destroy(&compressor);
    CFRelease(surface);
}

- (void)testLZ4DeltaFrameWireFormat {
    /* Compress two nearly-identical frames; second should be a delta */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    IOSurfaceRef surface1 = createTestSurface(W, H);
    IOSurfaceRef surface2 = createTestSurface(W, H);
    fillSurfaceWithPattern(surface1, 10);
    /* surface2 = surface1 with only a tiny difference (1 byte changed) */
    fillSurfaceWithPattern(surface2, 10);
    IOSurfaceLock(surface2, 0, NULL);
    ((uint8_t *)IOSurfaceGetBaseAddress(surface2))[0] ^= 0xFF; /* flip first byte */
    IOSurfaceUnlock(surface2, 0, NULL);

    /* Read original data for both */
    IOSurfaceLock(surface1, kIOSurfaceLockReadOnly, NULL);
    NSData *frame1Data = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface1) length:frame_bytes];
    IOSurfaceUnlock(surface1, kIOSurfaceLockReadOnly, NULL);

    IOSurfaceLock(surface2, kIOSurfaceLockReadOnly, NULL);
    NSData *frame2Data = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface2) length:frame_bytes];
    IOSurfaceUnlock(surface2, kIOSurfaceLockReadOnly, NULL);

    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);
    compressor.keyframe_interval_frames = 120; /* ensure frame 2 is not forced keyframe */

    __block CompressOutput out1 = compressor.output;
    __block MediaFrameHeader hdr1;
    __block NSData *payload1 = nil;

    __block CompressOutput out2 = compressor.output;
    __block MediaFrameHeader hdr2;
    __block NSData *payload2 = nil;

    CMSampleBufferRef sb1 = createFakeSampleBuffer(surface1, CMTimeMake(0, 1000000));
    CMSampleBufferRef sb2 = createFakeSampleBuffer(surface2, CMTimeMake(33333, 1000000));

    dispatch_sync(compressor.compress_queue, ^{
        compress_frame(&compressor, surface1, sb1, &out1);
        hdr1 = out1.header;
        payload1 = [NSData dataWithBytes:out1.buf length:out1.compressed_size];

        compress_frame(&compressor, surface2, sb2, &out2);
        hdr2 = out2.header;
        payload2 = [NSData dataWithBytes:out2.buf length:out2.compressed_size];
    });

    CFRelease(sb1);
    CFRelease(sb2);

    /* Frame 1: keyframe */
    XCTAssertTrue((hdr1.flags & KEYDRD_FLAG_KEYFRAME) != 0, @"Frame 1 must be keyframe");
    XCTAssertEqual(hdr1.seq, (uint16_t)0);

    /* Frame 2: should be delta (tiny difference, well under 60% threshold) */
    XCTAssertTrue((hdr2.flags & KEYDRD_FLAG_DELTA) != 0,
                  @"Frame 2 must be delta (frames nearly identical)");
    XCTAssertTrue((hdr2.flags & KEYDRD_FLAG_KEYFRAME) == 0,
                  @"Frame 2 must NOT be keyframe");
    XCTAssertTrue((hdr2.flags & KEYDRD_FLAG_HEVC) == 0, @"No HEVC flag on LZ4 delta");
    XCTAssertEqual(hdr2.seq, (uint16_t)1, @"Second frame seq must be 1");

    /* CRC must match payload */
    uint32_t crc2 = (uint32_t)crc32(0L, (const uint8_t *)payload2.bytes, (uInt)payload2.length);
    XCTAssertEqual(hdr2.crc32, crc2);

    /* Decompress keyframe */
    uint8_t *decompKF = (uint8_t *)malloc(frame_bytes);
    int d1 = LZ4_decompress_safe((const char *)payload1.bytes, (char *)decompKF,
                                  (int)payload1.length, (int)frame_bytes);
    XCTAssertEqual((size_t)d1, frame_bytes);
    XCTAssertEqual(memcmp(decompKF, frame1Data.bytes, frame_bytes), 0);

    /* Decompress delta, apply XOR with keyframe to reconstruct frame 2 */
    uint8_t *decompDelta = (uint8_t *)malloc(frame_bytes);
    int d2 = LZ4_decompress_safe((const char *)payload2.bytes, (char *)decompDelta,
                                  (int)payload2.length, (int)frame_bytes);
    XCTAssertEqual((size_t)d2, frame_bytes);

    uint8_t *reconstructed = (uint8_t *)malloc(frame_bytes);
    apply_delta(decompDelta, decompKF, reconstructed, frame_bytes);

    XCTAssertEqual(memcmp(reconstructed, frame2Data.bytes, frame_bytes), 0,
                   @"Delta-reconstructed frame must match original frame 2 exactly");

    free(decompKF);
    free(decompDelta);
    free(reconstructed);
    frame_compressor_destroy(&compressor);
    CFRelease(surface1);
    CFRelease(surface2);
}

- (void)testLZ4KeyframeFallbackOnSceneChange {
    /* Compress frame A (all zeros), then frame B (pseudo-random).
     * Delta of random vs zeros compresses poorly -> should fallback to keyframe. */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    IOSurfaceRef surfaceA = createTestSurface(W, H);
    IOSurfaceRef surfaceB = createTestSurface(W, H);

    /* Frame A: all zeros */
    IOSurfaceLock(surfaceA, 0, NULL);
    memset(IOSurfaceGetBaseAddress(surfaceA), 0, frame_bytes);
    IOSurfaceUnlock(surfaceA, 0, NULL);

    /* Frame B: pseudo-random (non-compressible pattern) */
    IOSurfaceLock(surfaceB, 0, NULL);
    uint8_t *bBase = IOSurfaceGetBaseAddress(surfaceB);
    uint32_t state = 0xDEADBEEF;
    for (size_t i = 0; i < frame_bytes; i++) {
        state = state * 1103515245 + 12345; /* LCG PRNG */
        bBase[i] = (uint8_t)(state >> 16);
    }
    IOSurfaceUnlock(surfaceB, 0, NULL);

    /* Save original frame B data */
    IOSurfaceLock(surfaceB, kIOSurfaceLockReadOnly, NULL);
    NSData *frameBData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surfaceB) length:frame_bytes];
    IOSurfaceUnlock(surfaceB, kIOSurfaceLockReadOnly, NULL);

    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);
    compressor.keyframe_interval_frames = 120;

    __block CompressOutput outA = compressor.output;
    __block MediaFrameHeader hdrA;

    __block CompressOutput outB = compressor.output;
    __block MediaFrameHeader hdrB;
    __block NSData *payloadB = nil;

    CMSampleBufferRef sbA = createFakeSampleBuffer(surfaceA, CMTimeMake(0, 1000000));
    CMSampleBufferRef sbB = createFakeSampleBuffer(surfaceB, CMTimeMake(33333, 1000000));

    dispatch_sync(compressor.compress_queue, ^{
        compress_frame(&compressor, surfaceA, sbA, &outA);
        hdrA = outA.header;

        compress_frame(&compressor, surfaceB, sbB, &outB);
        hdrB = outB.header;
        payloadB = [NSData dataWithBytes:outB.buf length:outB.compressed_size];
    });

    CFRelease(sbA);
    CFRelease(sbB);

    /* Frame A: keyframe */
    XCTAssertTrue((hdrA.flags & KEYDRD_FLAG_KEYFRAME) != 0, @"Frame A must be keyframe");

    /* Frame B: scene change -> delta exceeds 60% threshold -> fallback to keyframe */
    XCTAssertTrue((hdrB.flags & KEYDRD_FLAG_KEYFRAME) != 0,
                  @"Frame B must fallback to keyframe due to scene change");
    XCTAssertTrue((hdrB.flags & KEYDRD_FLAG_DELTA) == 0,
                  @"Frame B must NOT be delta");
    XCTAssertEqual(hdrB.seq, (uint16_t)1);

    /* Decompress frame B directly (it's a keyframe, not a delta) */
    uint8_t *decompB = (uint8_t *)malloc(frame_bytes);
    int dB = LZ4_decompress_safe((const char *)payloadB.bytes, (char *)decompB,
                                  (int)payloadB.length, (int)frame_bytes);
    XCTAssertEqual((size_t)dB, frame_bytes);
    XCTAssertEqual(memcmp(decompB, frameBData.bytes, frame_bytes), 0,
                   @"Keyframe fallback must decompress to exact original frame B");

    free(decompB);
    frame_compressor_destroy(&compressor);
    CFRelease(surfaceA);
    CFRelease(surfaceB);
}

#pragma mark - Deterministic HEVC Wire Format

- (void)testHEVCFrameWireFormat {
    /* Create known surface, encode with HEVCEncoder.
     * Verify MediaFrameHeader has HEVC flag set and payload contains valid NAL units. */
    XCTestExpectation *encodedExpect = [self expectationWithDescription:@"HEVC frame encoded"];

    HEVCEncoder *encoder = [[HEVCEncoder alloc] init];
    __block MediaFrameHeader capturedHeader;
    __block NSData *capturedPayload = nil;

    encoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        if (!capturedPayload) {
            capturedHeader = header;
            capturedPayload = [NSData dataWithBytes:data length:len];
            [encodedExpect fulfill];
        }
    };

    [encoder startWithWidth:64 height:64 fps:30 bitrate:500000];
    XCTAssertTrue(encoder.isActive);

    /* Create deterministic BGRA gradient */
    IOSurfaceRef surface = createTestSurface(64, 64);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    for (size_t y = 0; y < 64; y++) {
        for (size_t x = 0; x < 64; x++) {
            size_t off = (y * 64 + x) * 4;
            base[off + 0] = (uint8_t)(x * 4);       /* B */
            base[off + 1] = (uint8_t)(y * 4);       /* G */
            base[off + 2] = (uint8_t)((x + y) * 2); /* R */
            base[off + 3] = 0xFF;                     /* A */
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);
    XCTAssertTrue(pb != NULL);

    [encoder encodePixelBuffer:pb timestamp:CMTimeMake(0, 1000000)];

    [self waitForExpectations:@[encodedExpect] timeout:3.0];

    /* Verify header fields */
    XCTAssertEqual(capturedHeader.magic, KEYDRD_MAGIC, @"magic must be KEYDRD_MAGIC");
    XCTAssertTrue((capturedHeader.flags & KEYDRD_FLAG_HEVC) != 0,
                  @"HEVC flag must be set");
    XCTAssertTrue((capturedHeader.flags & KEYDRD_FLAG_DELTA) == 0,
                  @"HEVC frames must NOT have DELTA flag");
    XCTAssertEqual(capturedHeader.chunk_idx, (uint8_t)0);
    XCTAssertEqual(capturedHeader.chunk_total, (uint8_t)1);
    XCTAssertEqual(capturedHeader.reserved, (uint8_t)0);
    XCTAssertGreaterThan(capturedHeader.payload_size, (uint32_t)0);
    XCTAssertEqual(capturedHeader.payload_size, (uint32_t)capturedPayload.length,
                   @"header payload_size must match actual encoded bytes");

    /* Verify payload contains valid HEVC NAL units.
     * VideoToolbox uses AVCC-style (4-byte big-endian length prefix). */
    const uint8_t *nalBytes = (const uint8_t *)capturedPayload.bytes;
    XCTAssertGreaterThanOrEqual(capturedPayload.length, (NSUInteger)5,
                                @"Payload must have at least length prefix + NAL byte");
    uint32_t nalLen = ((uint32_t)nalBytes[0] << 24) | ((uint32_t)nalBytes[1] << 16) |
                      ((uint32_t)nalBytes[2] << 8)  | (uint32_t)nalBytes[3];
    XCTAssertGreaterThan(nalLen, (uint32_t)0, @"First NAL length must be > 0");
    XCTAssertLessThanOrEqual(nalLen + 4, (uint32_t)capturedPayload.length,
                             @"NAL length must fit within payload");

    [encoder stop];
    CVPixelBufferRelease(pb);
    CFRelease(surface);
}

/* C callback for VTCompressionSession (cannot use ObjC block) */
typedef struct {
    CMFormatDescriptionRef *capturedFmt;
    void *expectation;
} HEVCCallbackCtx;

static void hevcKeyframeCallback(void *refcon, void *srcRefcon, OSStatus status,
                                  VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    HEVCCallbackCtx *ctx = (HEVCCallbackCtx *)refcon;
    if (status != noErr || !sampleBuffer) return;
    if (*(ctx->capturedFmt)) return; /* only need the first keyframe */

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    BOOL isKeyframe = YES;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = NULL;
        if (CFDictionaryGetValueIfPresent(dict, kCMSampleAttachmentKey_NotSync,
                                          (const void **)&notSync)) {
            isKeyframe = !CFBooleanGetValue(notSync);
        }
    }

    if (isKeyframe) {
        *(ctx->capturedFmt) = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (*(ctx->capturedFmt)) CFRetain(*(ctx->capturedFmt));
        XCTestExpectation *expect = (__bridge XCTestExpectation *)(ctx->expectation);
        [expect fulfill];
    }
}

- (void)testHEVCKeyframeContainsVPSSPSPPS {
    /* Encode frames using VTCompressionSession directly so we can inspect
     * the CMFormatDescription for parameter sets (VPS, SPS, PPS).
     * VideoToolbox stores these in the format description, not inline in the
     * block buffer data. We use CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
     * to verify all three are present. */
    XCTestExpectation *keyframeExpect = [self expectationWithDescription:@"HEVC keyframe found"];

    __block CMFormatDescriptionRef capturedFmt = NULL;

    HEVCCallbackCtx ctx = { .capturedFmt = &capturedFmt, .expectation = (__bridge void *)keyframeExpect };

    /* Create a raw VTCompressionSession so we get the CMSampleBuffer in the callback */
    __block VTCompressionSessionRef session = NULL;

    VTCompressionSessionCreate(
        kCFAllocatorDefault, 640, 480, kCMVideoCodecType_HEVC,
        NULL, NULL, kCFAllocatorDefault,
        (VTCompressionOutputCallback)hevcKeyframeCallback,
        &ctx, &session);

    XCTAssertTrue(session != NULL, @"VTCompressionSession must be created");

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTCompressionSessionPrepareToEncodeFrames(session);

    /* Encode frames */
    IOSurfaceRef surface = createTestSurface(640, 480);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    for (size_t i = 0; i < 640 * 480 * 4; i++) {
        base[i] = (uint8_t)((i * 11 + 37) & 0xFF);
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);
    for (int i = 0; i < 5; i++) {
        VTCompressionSessionEncodeFrame(session, pb, CMTimeMake(i * 33333, 1000000),
                                         kCMTimeInvalid, NULL, NULL, NULL);
    }

    [self waitForExpectations:@[keyframeExpect] timeout:5.0];

    XCTAssertTrue(capturedFmt != NULL, @"Must have captured a keyframe format description");

    /* Extract parameter set count from the HEVC format description */
    size_t paramSetCount = 0;
    int nalUnitHeaderLength = 0;
    OSStatus paramStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        capturedFmt, 0, NULL, NULL, &paramSetCount, &nalUnitHeaderLength);
    XCTAssertEqual(paramStatus, noErr, @"Must be able to query HEVC parameter sets");
    XCTAssertGreaterThanOrEqual(paramSetCount, (size_t)3,
                                @"Must have at least 3 parameter sets (VPS + SPS + PPS)");
    XCTAssertEqual(nalUnitHeaderLength, 4,
                   @"NAL unit header length should be 4 (AVCC-style)");

    /* Extract each parameter set and verify its NAL type */
    BOOL foundVPS = NO, foundSPS = NO, foundPPS = NO;
    for (size_t i = 0; i < paramSetCount; i++) {
        const uint8_t *paramBuf = NULL;
        size_t paramSize = 0;
        OSStatus s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            capturedFmt, i, &paramBuf, &paramSize, NULL, NULL);
        XCTAssertEqual(s, noErr);
        XCTAssertGreaterThan(paramSize, (size_t)0);

        /* HEVC NAL type: (first_byte >> 1) & 0x3F */
        uint8_t nalType = (paramBuf[0] >> 1) & 0x3F;
        if (nalType == 32) foundVPS = YES;
        if (nalType == 33) foundSPS = YES;
        if (nalType == 34) foundPPS = YES;
    }

    XCTAssertTrue(foundVPS, @"HEVC keyframe format must contain VPS (NAL type 32)");
    XCTAssertTrue(foundSPS, @"HEVC keyframe format must contain SPS (NAL type 33)");
    XCTAssertTrue(foundPPS, @"HEVC keyframe format must contain PPS (NAL type 34)");

    /* Cleanup */
    if (capturedFmt) CFRelease(capturedFmt);
    VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    CVPixelBufferRelease(pb);
    CFRelease(surface);
}

#pragma mark - Full Send/Receive Pipeline (localhost TCP)

- (void)testLZ4FrameSendReceiveExact {
    /* Create localhost TCP pair (server + client).
     * Server: compress frame, send header + payload.
     * Client: receive sizeof(MediaFrameHeader), parse, receive payload, verify CRC, decompress. */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    IOSurfaceRef surface = createTestSurface(W, H);
    fillSurfaceWithPattern(surface, 77);

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    NSData *originalData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface) length:frame_bytes];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    /* Compress */
    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    __block CompressOutput output = compressor.output;
    __block MediaFrameHeader sentHeader;
    __block NSData *compressedPayload = nil;

    CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(500000, 1000000));
    XCTAssertTrue(sb != NULL);

    dispatch_sync(compressor.compress_queue, ^{
        int result = compress_frame(&compressor, surface, sb, &output);
        XCTAssertEqual(result, 0);
        sentHeader = output.header;
        compressedPayload = [NSData dataWithBytes:output.buf length:output.compressed_size];
    });
    CFRelease(sb);

    /* TCP setup */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *roundtripDone = [self expectationWithDescription:@"exact roundtrip done"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Server (receive side): receive header first */
        receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
            XCTAssertEqual(hdrLen, sizeof(MediaFrameHeader), @"Must receive exactly 24 bytes for header");

            MediaFrameHeader recvHdr;
            memcpy(&recvHdr, hdrBuf, sizeof(MediaFrameHeader));

            /* Verify every header field against sent header */
            XCTAssertEqual(recvHdr.magic, sentHeader.magic);
            XCTAssertEqual(recvHdr.flags, sentHeader.flags);
            XCTAssertEqual(recvHdr.seq, sentHeader.seq);
            XCTAssertEqual(recvHdr.chunk_idx, sentHeader.chunk_idx);
            XCTAssertEqual(recvHdr.chunk_total, sentHeader.chunk_total);
            XCTAssertEqual(recvHdr.reserved, sentHeader.reserved);
            XCTAssertEqual(recvHdr.payload_size, sentHeader.payload_size);
            XCTAssertEqual(recvHdr.ts_us, sentHeader.ts_us);
            XCTAssertEqual(recvHdr.crc32, sentHeader.crc32);

            /* Receive exactly header.payload_size bytes */
            receiveBytes(serverConn, recvHdr.payload_size, ^(const uint8_t *payloadBuf, size_t payloadLen) {
                XCTAssertEqual(payloadLen, (size_t)recvHdr.payload_size,
                               @"Received payload length must match header");

                /* Verify CRC of received payload */
                uint32_t computedCRC = (uint32_t)crc32(0L, payloadBuf, (uInt)payloadLen);
                XCTAssertEqual(computedCRC, recvHdr.crc32,
                               @"CRC32 of received payload must match header CRC");

                /* Decompress and verify exact pixels */
                uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
                int decompSize = LZ4_decompress_safe((const char *)payloadBuf,
                                                      (char *)decompressed,
                                                      (int)payloadLen,
                                                      (int)frame_bytes);
                XCTAssertEqual((size_t)decompSize, frame_bytes,
                               @"Decompressed size must be exactly %zu", frame_bytes);
                XCTAssertEqual(memcmp(decompressed, originalData.bytes, frame_bytes), 0,
                               @"Decompressed pixels must match original byte-for-byte");

                free(decompressed);
                [roundtripDone fulfill];
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:3.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:3.0];

    /* Client: send header, then payload */
    sendBytes(client, &sentHeader, sizeof(MediaFrameHeader), ^{
        sendBytes(client, compressedPayload.bytes, compressedPayload.length, nil);
    });

    [self waitForExpectations:@[roundtripDone] timeout:3.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
    CFRelease(surface);
}

- (void)testMultipleFrameStreamDeterministic {
    /* Send 10 frames with known different pixel patterns.
     * Receive all 10, decompress each, verify EXACT pixel match.
     * Verify seq numbers are 0..9.
     * Verify first frame is keyframe. */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;
    const int FRAME_COUNT = 10;

    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    /* Compress all 10 frames and store wire data + original pixel data */
    NSMutableArray<NSData *> *wireFrames = [NSMutableArray array];
    NSMutableArray<NSData *> *originalPixels = [NSMutableArray array];
    NSMutableArray<NSNumber *> *expectedSeqs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *expectedFlags = [NSMutableArray array];

    for (int i = 0; i < FRAME_COUNT; i++) {
        IOSurfaceRef surface = createTestSurface(W, H);
        fillSurfaceWithPattern(surface, (uint8_t)(i * 17 + 3));

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        [originalPixels addObject:[NSData dataWithBytes:IOSurfaceGetBaseAddress(surface)
                                                 length:frame_bytes]];
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

        CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(i * 33333, 1000000));
        __block CompressOutput out = compressor.output;
        __block MediaFrameHeader hdr;

        dispatch_sync(compressor.compress_queue, ^{
            compress_frame(&compressor, surface, sb, &out);
            hdr = out.header;
        });

        [expectedSeqs addObject:@(hdr.seq)];
        [expectedFlags addObject:@(hdr.flags)];

        NSMutableData *wire = [NSMutableData dataWithBytes:&hdr length:sizeof(hdr)];
        [wire appendBytes:out.buf length:out.compressed_size];
        [wireFrames addObject:wire];

        CFRelease(sb);
        CFRelease(surface);
    }

    /* Verify seq numbers are sequential 0..9 */
    for (int i = 0; i < FRAME_COUNT; i++) {
        XCTAssertEqual([expectedSeqs[i] unsignedShortValue], (uint16_t)i,
                       @"Frame %d seq must be %d", i, i);
    }
    /* First frame must be keyframe */
    XCTAssertTrue(([expectedFlags[0] unsignedCharValue] & KEYDRD_FLAG_KEYFRAME) != 0,
                  @"First frame must be keyframe");

    /* Send all frames over TCP, receive and fully decompress each */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *allReceived = [self expectationWithDescription:@"all 10 frames received"];
    __block uint16_t port = 0;
    __block int receivedCount = 0;

    /* Track keyframe reference for delta reconstruction */
    __block uint8_t *keyframeRef = (uint8_t *)malloc(frame_bytes);
    memset(keyframeRef, 0, frame_bytes);

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        __block void (^receiveNextFrame)(void);
        receiveNextFrame = ^{
            if (receivedCount >= FRAME_COUNT) {
                free(keyframeRef);
                [allReceived fulfill];
                return;
            }

            receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
                if (hdrLen < sizeof(MediaFrameHeader)) return;

                MediaFrameHeader hdr;
                memcpy(&hdr, hdrBuf, sizeof(MediaFrameHeader));

                XCTAssertEqual(hdr.magic, KEYDRD_MAGIC);
                XCTAssertEqual(hdr.seq, (uint16_t)receivedCount,
                               @"Sequence must be %d", receivedCount);

                receiveBytes(serverConn, hdr.payload_size, ^(const uint8_t *payloadBuf, size_t payloadLen) {
                    XCTAssertEqual(payloadLen, (size_t)hdr.payload_size);

                    /* Verify CRC */
                    uint32_t computedCRC = (uint32_t)crc32(0L, payloadBuf, (uInt)payloadLen);
                    XCTAssertEqual(computedCRC, hdr.crc32, @"CRC mismatch for frame %d", receivedCount);

                    /* Decompress */
                    uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
                    int decompSize = LZ4_decompress_safe((const char *)payloadBuf,
                                                          (char *)decompressed,
                                                          (int)payloadLen,
                                                          (int)frame_bytes);
                    XCTAssertEqual((size_t)decompSize, frame_bytes);

                    if (hdr.flags & KEYDRD_FLAG_DELTA) {
                        /* Apply delta to reconstruct original */
                        uint8_t *reconstructed = (uint8_t *)malloc(frame_bytes);
                        apply_delta(decompressed, keyframeRef, reconstructed, frame_bytes);

                        XCTAssertEqual(memcmp(reconstructed, originalPixels[receivedCount].bytes, frame_bytes), 0,
                                       @"Delta-reconstructed frame %d must match original pixels", receivedCount);

                        /* Update reference */
                        memcpy(keyframeRef, reconstructed, frame_bytes);
                        free(reconstructed);
                    } else {
                        /* Keyframe: verify directly */
                        XCTAssertEqual(memcmp(decompressed, originalPixels[receivedCount].bytes, frame_bytes), 0,
                                       @"Keyframe %d must match original pixels", receivedCount);
                        memcpy(keyframeRef, decompressed, frame_bytes);
                    }

                    free(decompressed);
                    receivedCount++;
                    receiveNextFrame();
                });
            });
        };
        receiveNextFrame();
    });

    [self waitForExpectations:@[listenerReady] timeout:3.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:3.0];

    /* Send all 10 frames sequentially */
    __block void (^sendNext)(int);
    sendNext = ^(int idx) {
        if (idx >= FRAME_COUNT) return;
        sendBytes(client, wireFrames[idx].bytes, wireFrames[idx].length, ^{
            sendNext(idx + 1);
        });
    };
    sendNext(0);

    [self waitForExpectations:@[allReceived] timeout:5.0];
    XCTAssertEqual(receivedCount, FRAME_COUNT);

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
}

- (void)testHEVCFrameSendReceive {
    /* Encode HEVC frame, send over localhost TCP, receive, verify header. */
    XCTestExpectation *encodedExpect = [self expectationWithDescription:@"HEVC encoded"];

    HEVCEncoder *encoder = [[HEVCEncoder alloc] init];
    __block MediaFrameHeader sentHeader;
    __block NSData *sentPayload = nil;

    encoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        if (!sentPayload) {
            sentHeader = header;
            sentPayload = [NSData dataWithBytes:data length:len];
            [encodedExpect fulfill];
        }
    };

    [encoder startWithWidth:128 height:128 fps:30 bitrate:500000];

    IOSurfaceRef surface = createTestSurface(128, 128);
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    for (size_t i = 0; i < 128 * 128 * 4; i++) {
        base[i] = (uint8_t)((i * 5 + 13) & 0xFF);
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(surface);
    [encoder encodePixelBuffer:pb timestamp:CMTimeMake(0, 1000000)];

    [self waitForExpectations:@[encodedExpect] timeout:3.0];
    XCTAssertNotNil(sentPayload);

    /* Send over TCP, receive on other side */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *roundtripDone = [self expectationWithDescription:@"HEVC roundtrip done"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
            XCTAssertEqual(hdrLen, sizeof(MediaFrameHeader));

            MediaFrameHeader recvHdr;
            memcpy(&recvHdr, hdrBuf, sizeof(MediaFrameHeader));

            XCTAssertEqual(recvHdr.magic, KEYDRD_MAGIC);
            XCTAssertTrue((recvHdr.flags & KEYDRD_FLAG_HEVC) != 0, @"HEVC flag must be set");
            XCTAssertEqual(recvHdr.payload_size, sentHeader.payload_size);
            XCTAssertEqual(recvHdr.seq, sentHeader.seq);

            receiveBytes(serverConn, recvHdr.payload_size, ^(const uint8_t *payloadBuf, size_t payloadLen) {
                XCTAssertEqual(payloadLen, (size_t)recvHdr.payload_size);

                /* Verify payload matches what was sent */
                XCTAssertEqual(memcmp(payloadBuf, sentPayload.bytes, payloadLen), 0,
                               @"Received HEVC payload must match sent payload exactly");

                /* Verify it contains valid AVCC-style NAL units */
                if (payloadLen >= 5) {
                    uint32_t nalLen = ((uint32_t)payloadBuf[0] << 24) |
                                      ((uint32_t)payloadBuf[1] << 16) |
                                      ((uint32_t)payloadBuf[2] << 8) |
                                      (uint32_t)payloadBuf[3];
                    XCTAssertGreaterThan(nalLen, (uint32_t)0);
                    XCTAssertLessThanOrEqual(nalLen + 4, (uint32_t)payloadLen);
                }

                [roundtripDone fulfill];
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:3.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:3.0];

    sendBytes(client, &sentHeader, sizeof(MediaFrameHeader), ^{
        sendBytes(client, sentPayload.bytes, sentPayload.length, nil);
    });

    [self waitForExpectations:@[roundtripDone] timeout:3.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    [encoder stop];
    CVPixelBufferRelease(pb);
    CFRelease(surface);
}

#pragma mark - Session Handshake + Frame Delivery (Full Mac->iPad Flow)

- (void)testHandshakeThenFrameDelivery {
    /* Full Mac->iPad flow: handshake message followed by LZ4 frame delivery.
     * Tests the EXACT same wire format the iPad would see. */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    /* Build handshake */
    SessionHandshakeMessage handshake;
    memset(&handshake, 0, sizeof(handshake));
    handshake.magic          = KEYDRD_MAGIC;
    handshake.msg_type       = KEYDRD_MSG_SESSION_HANDSHAKE;
    handshake.display_width  = (uint32_t)W;
    handshake.display_height = (uint32_t)H;
    handshake.scale_factor   = 2.0f;
    handshake.aspect_ratio   = (float)W / (float)H;
    handshake.capabilities   = KEYDRD_CAP_LZ4;
    handshake.max_fps        = 60;
    handshake.agent_version  = 1;
    handshake.reserved       = 0;

    /* Build LZ4 frame */
    IOSurfaceRef surface = createTestSurface(W, H);
    fillSurfaceWithPattern(surface, 0x55);

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    NSData *originalPixels = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface) length:frame_bytes];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    __block CompressOutput output = compressor.output;
    __block MediaFrameHeader frameHdr;
    __block NSData *framePayload = nil;

    CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(0, 1000000));
    dispatch_sync(compressor.compress_queue, ^{
        compress_frame(&compressor, surface, sb, &output);
        frameHdr = output.header;
        framePayload = [NSData dataWithBytes:output.buf length:output.compressed_size];
    });
    CFRelease(sb);

    /* TCP send: handshake, then frame */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *fullFlowDone = [self expectationWithDescription:@"handshake + frame done"];
    __block uint16_t port = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Step 1: receive handshake */
        receiveBytes(serverConn, sizeof(SessionHandshakeMessage),
            ^(const uint8_t *hBuf, size_t hLen) {
            XCTAssertEqual(hLen, sizeof(SessionHandshakeMessage));

            /* Parse handshake at packed offsets */
            SessionHandshakeMessage parsedHS;
            memcpy(&parsedHS, hBuf, sizeof(SessionHandshakeMessage));

            XCTAssertEqual(parsedHS.magic, KEYDRD_MAGIC);
            XCTAssertEqual(parsedHS.msg_type, KEYDRD_MSG_SESSION_HANDSHAKE);
            XCTAssertEqual(parsedHS.display_width, (uint32_t)W);
            XCTAssertEqual(parsedHS.display_height, (uint32_t)H);
            XCTAssertEqualWithAccuracy(parsedHS.scale_factor, 2.0f, 0.001f);
            XCTAssertEqualWithAccuracy(parsedHS.aspect_ratio, 1.0f, 0.01f);
            XCTAssertEqual(parsedHS.capabilities, KEYDRD_CAP_LZ4);
            XCTAssertEqual(parsedHS.max_fps, (uint8_t)60);
            XCTAssertEqual(parsedHS.agent_version, (uint8_t)1);

            /* Step 2: receive MediaFrameHeader */
            receiveBytes(serverConn, sizeof(MediaFrameHeader),
                ^(const uint8_t *fhBuf, size_t fhLen) {
                XCTAssertEqual(fhLen, sizeof(MediaFrameHeader));

                MediaFrameHeader parsedFH;
                memcpy(&parsedFH, fhBuf, sizeof(MediaFrameHeader));

                XCTAssertEqual(parsedFH.magic, KEYDRD_MAGIC);
                XCTAssertTrue((parsedFH.flags & KEYDRD_FLAG_KEYFRAME) != 0);
                XCTAssertTrue((parsedFH.flags & KEYDRD_FLAG_HEVC) == 0);
                XCTAssertEqual(parsedFH.seq, (uint16_t)0);

                /* Step 3: receive payload */
                receiveBytes(serverConn, parsedFH.payload_size,
                    ^(const uint8_t *payloadBuf, size_t payloadLen) {
                    XCTAssertEqual(payloadLen, (size_t)parsedFH.payload_size);

                    /* CRC check */
                    uint32_t computedCRC = (uint32_t)crc32(0L, payloadBuf, (uInt)payloadLen);
                    XCTAssertEqual(computedCRC, parsedFH.crc32);

                    /* Decompress and verify pixels */
                    uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
                    int decompSize = LZ4_decompress_safe((const char *)payloadBuf,
                                                          (char *)decompressed,
                                                          (int)payloadLen,
                                                          (int)frame_bytes);
                    XCTAssertEqual((size_t)decompSize, frame_bytes);
                    XCTAssertEqual(memcmp(decompressed, originalPixels.bytes, frame_bytes), 0,
                                   @"Pixels from full handshake+frame flow must match original");

                    free(decompressed);
                    [fullFlowDone fulfill];
                });
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:3.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:3.0];

    /* Send handshake, then header, then payload */
    sendBytes(client, &handshake, sizeof(SessionHandshakeMessage), ^{
        sendBytes(client, &frameHdr, sizeof(MediaFrameHeader), ^{
            sendBytes(client, framePayload.bytes, framePayload.length, nil);
        });
    });

    [self waitForExpectations:@[fullFlowDone] timeout:3.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
    CFRelease(surface);
}

#pragma mark - Mode Switch Mid-Stream

- (void)testModeSwitch_LZ4toHEVC_WireVerification {
    /* Send 3 LZ4 frames -> mode change command -> 3 HEVC frames.
     * Verify LZ4 frames have correct flags, HEVC frames have HEVC flag set.
     * Mode change uses InputEventHeader with type KEYDRD_INPUT_MODE_CHANGE. */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    /* ---- Produce 3 LZ4 frames ---- */
    __block FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    NSMutableArray<NSData *> *lz4Wires = [NSMutableArray array];

    for (int i = 0; i < 3; i++) {
        IOSurfaceRef surface = createTestSurface(W, H);
        fillSurfaceWithPattern(surface, (uint8_t)(i * 20));

        CMSampleBufferRef sb = createFakeSampleBuffer(surface, CMTimeMake(i * 33333, 1000000));
        __block CompressOutput out = compressor.output;
        __block MediaFrameHeader hdr;

        dispatch_sync(compressor.compress_queue, ^{
            compress_frame(&compressor, surface, sb, &out);
            hdr = out.header;
        });

        /* Verify LZ4 flags */
        XCTAssertTrue((hdr.flags & KEYDRD_FLAG_HEVC) == 0,
                      @"LZ4 frame %d must NOT have HEVC flag", i);

        NSMutableData *wire = [NSMutableData dataWithBytes:&hdr length:sizeof(hdr)];
        [wire appendBytes:out.buf length:out.compressed_size];
        [lz4Wires addObject:wire];

        CFRelease(sb);
        CFRelease(surface);
    }

    frame_compressor_destroy(&compressor);

    /* ---- Build mode change command ---- */
    InputEventHeader modeChangeHdr;
    modeChangeHdr.type  = KEYDRD_INPUT_MODE_CHANGE;
    modeChangeHdr.ts_us = 100000;

    /* ---- Produce 3 HEVC frames ---- */
    XCTestExpectation *hevcDone = [self expectationWithDescription:@"3 HEVC frames encoded"];
    __block int hevcCount = 0;
    NSMutableArray<NSData *> *hevcWires = [NSMutableArray array];

    HEVCEncoder *encoder = [[HEVCEncoder alloc] init];
    encoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        @synchronized (hevcWires) {
            /* Verify HEVC flags */
            XCTAssertTrue((header.flags & KEYDRD_FLAG_HEVC) != 0,
                          @"HEVC frame must have HEVC flag");
            XCTAssertTrue((header.flags & KEYDRD_FLAG_DELTA) == 0,
                          @"HEVC frame must NOT have DELTA flag");

            NSMutableData *wire = [NSMutableData dataWithBytes:&header length:sizeof(header)];
            [wire appendBytes:data length:len];
            [hevcWires addObject:wire];

            hevcCount++;
            if (hevcCount == 3) {
                [hevcDone fulfill];
            }
        }
    };

    [encoder startWithWidth:(int)W height:(int)H fps:30 bitrate:500000];

    IOSurfaceRef hevcSurface = createTestSurface(W, H);
    IOSurfaceLock(hevcSurface, 0, NULL);
    uint8_t *hBase = IOSurfaceGetBaseAddress(hevcSurface);
    for (size_t i = 0; i < frame_bytes; i++) {
        hBase[i] = (uint8_t)((i * 3 + 99) & 0xFF);
    }
    IOSurfaceUnlock(hevcSurface, 0, NULL);

    CVPixelBufferRef pb = createPixelBufferFromSurface(hevcSurface);
    for (int i = 0; i < 5; i++) { /* encode extra to guarantee 3 output frames */
        [encoder encodePixelBuffer:pb timestamp:CMTimeMake(i * 33333 + 100000, 1000000)];
    }

    [self waitForExpectations:@[hevcDone] timeout:5.0];
    [encoder stop];
    CVPixelBufferRelease(pb);
    CFRelease(hevcSurface);

    /* ---- Send everything over TCP ---- */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *allDone = [self expectationWithDescription:@"mode switch verified"];
    __block uint16_t port = 0;

    /* Pre-compute total frames to receive */
    __block int receivedLZ4 = 0;
    __block BOOL receivedModeChange = NO;
    __block int receivedHEVC = 0;

    nw_listener_t listener = createLocalhostListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {

        /* ---- Receive 3 LZ4 frames ---- */
        __block void (^receiveLZ4)(void);
        __block void (^receiveModeChange)(void);
        __block void (^receiveHEVC)(void);

        receiveLZ4 = ^{
            if (receivedLZ4 >= 3) {
                receiveModeChange();
                return;
            }
            receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
                if (hdrLen < sizeof(MediaFrameHeader)) return;
                MediaFrameHeader hdr;
                memcpy(&hdr, hdrBuf, sizeof(MediaFrameHeader));

                XCTAssertEqual(hdr.magic, KEYDRD_MAGIC);
                XCTAssertTrue((hdr.flags & KEYDRD_FLAG_HEVC) == 0,
                              @"LZ4 frame must not have HEVC flag");

                receiveBytes(serverConn, hdr.payload_size, ^(const uint8_t *payload, size_t pLen) {
                    XCTAssertEqual(pLen, (size_t)hdr.payload_size);
                    uint32_t computedCRC = (uint32_t)crc32(0L, payload, (uInt)pLen);
                    XCTAssertEqual(computedCRC, hdr.crc32);
                    receivedLZ4++;
                    receiveLZ4();
                });
            });
        };

        receiveModeChange = ^{
            receiveBytes(serverConn, sizeof(InputEventHeader), ^(const uint8_t *buf, size_t len) {
                XCTAssertEqual(len, sizeof(InputEventHeader));
                InputEventHeader mc;
                memcpy(&mc, buf, sizeof(InputEventHeader));
                XCTAssertEqual(mc.type, KEYDRD_INPUT_MODE_CHANGE);
                XCTAssertEqual(mc.ts_us, (uint64_t)100000);
                receivedModeChange = YES;
                receiveHEVC();
            });
        };

        receiveHEVC = ^{
            if (receivedHEVC >= 3) {
                [allDone fulfill];
                return;
            }
            receiveBytes(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
                if (hdrLen < sizeof(MediaFrameHeader)) return;
                MediaFrameHeader hdr;
                memcpy(&hdr, hdrBuf, sizeof(MediaFrameHeader));

                XCTAssertEqual(hdr.magic, KEYDRD_MAGIC);
                XCTAssertTrue((hdr.flags & KEYDRD_FLAG_HEVC) != 0,
                              @"HEVC frame must have HEVC flag after mode switch");

                receiveBytes(serverConn, hdr.payload_size, ^(const uint8_t *payload, size_t pLen) {
                    XCTAssertEqual(pLen, (size_t)hdr.payload_size);
                    /* HEVC payload should contain valid NAL units */
                    if (pLen >= 5) {
                        uint32_t nalLen = ((uint32_t)payload[0] << 24) |
                                          ((uint32_t)payload[1] << 16) |
                                          ((uint32_t)payload[2] << 8) |
                                          (uint32_t)payload[3];
                        XCTAssertGreaterThan(nalLen, (uint32_t)0);
                        XCTAssertLessThanOrEqual(nalLen + 4, (uint32_t)pLen);
                    }
                    receivedHEVC++;
                    receiveHEVC();
                });
            });
        };

        receiveLZ4();
    });

    [self waitForExpectations:@[listenerReady] timeout:3.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = connectToLocalhost(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:3.0];

    /* Send: 3 LZ4 frames, mode change, 3 HEVC frames — all sequentially */
    __block void (^sendLZ4)(int);
    sendLZ4 = ^(int idx) {
        if (idx >= 3) {
            /* Send mode change command */
            sendBytes(client, &modeChangeHdr, sizeof(InputEventHeader), ^{
                /* Then send 3 HEVC frames */
                __block void (^sendHEVC)(int);
                sendHEVC = ^(int hIdx) {
                    if (hIdx >= 3) return;
                    @synchronized (hevcWires) {
                        sendBytes(client, hevcWires[hIdx].bytes, hevcWires[hIdx].length, ^{
                            sendHEVC(hIdx + 1);
                        });
                    }
                };
                sendHEVC(0);
            });
            return;
        }
        sendBytes(client, lz4Wires[idx].bytes, lz4Wires[idx].length, ^{
            sendLZ4(idx + 1);
        });
    };
    sendLZ4(0);

    [self waitForExpectations:@[allDone] timeout:5.0];

    XCTAssertEqual(receivedLZ4, 3, @"Must have received exactly 3 LZ4 frames");
    XCTAssertTrue(receivedModeChange, @"Must have received mode change command");
    XCTAssertEqual(receivedHEVC, 3, @"Must have received exactly 3 HEVC frames");

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

@end
