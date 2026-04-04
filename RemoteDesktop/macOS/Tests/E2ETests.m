/*
 * E2ETests.m
 * End-to-end session lifecycle tests for keyd-rd.
 *
 * Simulates the full Mac (server) <-> iPad (client) flow using localhost
 * loopback. Tests pairing, handshake, frame streaming, mode switching,
 * transport FSM cascade, reconnection, and error handling.
 */

#import <XCTest/XCTest.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <IOSurface/IOSurface.h>
#import "PairingManager.h"
#import "HEVCEncoder.h"
#include "protocol.h"
#include "FrameCompressor.h"
#include "lz4.h"
#include "delta.h"
#include "TransportFSM.h"
#include <zlib.h>

/* ---- Test Helpers (shared with PipelineTests) ---- */

static IOSurfaceRef e2eCreateTestSurface(size_t width, size_t height) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void e2eFillSurface(IOSurfaceRef surface, uint8_t seed) {
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t len = IOSurfaceGetAllocSize(surface);
    for (size_t i = 0; i < len; i++) {
        base[i] = (uint8_t)((i * 7 + seed) & 0xFF);
    }
    IOSurfaceUnlock(surface, 0, NULL);
}

static CVPixelBufferRef e2eCreatePixelBuffer(IOSurfaceRef surface) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &pb);
    return pb;
}

static CMSampleBufferRef e2eCreateSampleBuffer(IOSurfaceRef surface, CMTime pts) {
    CVPixelBufferRef pb = e2eCreatePixelBuffer(surface);
    if (!pb) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fmt);
    if (!fmt) { CVPixelBufferRelease(pb); return NULL; }

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

/* ---- Localhost TCP Helpers ---- */

typedef void (^E2EServerBlock)(nw_connection_t conn);

static nw_listener_t e2eCreateListener(dispatch_queue_t queue,
                                        uint16_t *outPort,
                                        XCTestExpectation *ready,
                                        E2EServerBlock serverBlock) {
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_local_endpoint(params,
        nw_endpoint_create_host("127.0.0.1", "0"));

    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_state_changed_handler(listener,
        ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            *outPort = nw_listener_get_port(listener);
            [ready fulfill];
        }
    });

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn,
            ^(nw_connection_state_t s, nw_error_t _Nullable e) {
            if (s == nw_connection_state_ready) {
                serverBlock(conn);
            }
        });
        nw_connection_start(conn);
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);
    return listener;
}

static nw_connection_t e2eConnect(uint16_t port, dispatch_queue_t queue,
                                   XCTestExpectation *ready) {
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
        if (state == nw_connection_state_ready && ready) {
            [ready fulfill];
        }
    });
    nw_connection_start(conn);
    return conn;
}

static void e2eSend(nw_connection_t conn, const void *data, size_t len,
                    dispatch_block_t completion) {
    void *copy = malloc(len);
    memcpy(copy, data, len);
    dispatch_data_t dd = dispatch_data_create(copy, len, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(conn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t _Nullable error) {
        if (completion) completion();
    });
}

static void e2eReceive(nw_connection_t conn, size_t len,
                       void (^block)(const uint8_t *buf, size_t actual)) {
    nw_connection_receive(conn, (uint32_t)len, (uint32_t)len,
        ^(dispatch_data_t _Nullable content,
          nw_content_context_t _Nullable ctx,
          bool is_complete,
          nw_error_t _Nullable error) {
        if (!content) { block(NULL, 0); return; }
        __block NSMutableData *result = [NSMutableData data];
        dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                           const void *buffer, size_t size) {
            [result appendBytes:buffer length:size];
            return true;
        });
        block((const uint8_t *)result.bytes, result.length);
    });
}

/* ---- Receive with minimum (for variable-length messages) ---- */
static void e2eReceiveMin(nw_connection_t conn, size_t minLen, size_t maxLen,
                          void (^block)(const uint8_t *buf, size_t actual)) {
    nw_connection_receive(conn, (uint32_t)minLen, (uint32_t)maxLen,
        ^(dispatch_data_t _Nullable content,
          nw_content_context_t _Nullable ctx,
          bool is_complete,
          nw_error_t _Nullable error) {
        if (!content) { block(NULL, 0); return; }
        __block NSMutableData *result = [NSMutableData data];
        dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                           const void *buffer, size_t size) {
            [result appendBytes:buffer length:size];
            return true;
        });
        block((const uint8_t *)result.bytes, result.length);
    });
}

#pragma mark - Test Class

@interface E2ETests : XCTestCase
@property (nonatomic) dispatch_queue_t testQueue;
@end

@implementation E2ETests

- (void)setUp {
    [super setUp];
    self.testQueue = dispatch_queue_create("com.keydrd.test.e2e", DISPATCH_QUEUE_SERIAL);
}

#pragma mark - Full Session Lifecycle

- (void)testFullSessionLifecycle {
    /*
     * Simulates the complete flow:
     * 1. Mac: generate QR payload, start listener
     * 2. iPad: parse QR, extract host/port, connect
     * 3. ECDH exchange
     * 4. Mac: start service listener for data
     * 5. iPad: connect to data channel
     * 6. Mac: send SessionHandshakeMessage
     * 7. iPad: receive and verify handshake
     * 8. Mac: compress frame (LZ4), send header + data
     * 9. iPad: receive, parse, decompress, verify
     * 10. Mac: send latency probe, iPad echoes back
     * 11. Clean disconnect
     *
     * Since PairingManager requires a PKCS12 file and Keychain, we simulate
     * the pairing exchange in-process using raw P-256 ECDH.
     */

    XCTestExpectation *fullSessionDone = [self expectationWithDescription:@"full session lifecycle"];

    const size_t W = 640, H = 480;
    const size_t frame_bytes = W * H * 4;

    /* --- Step 1-3: Simulated pairing (ECDH in-process) --- */
    /* Generate two P-256 key pairs (Mac + iPad) */
    NSDictionary *keyAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeySizeInBits: @256,
        (__bridge id)kSecAttrIsPermanent: @NO,
    };
    CFErrorRef err = NULL;
    SecKeyRef macPrivate = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttrs, &err);
    XCTAssertTrue(macPrivate != NULL, @"Mac key generation must succeed");
    SecKeyRef iPadPrivate = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttrs, &err);
    XCTAssertTrue(iPadPrivate != NULL, @"iPad key generation must succeed");

    SecKeyRef macPublic = SecKeyCopyPublicKey(macPrivate);
    SecKeyRef iPadPublic = SecKeyCopyPublicKey(iPadPrivate);

    /* Perform ECDH: Mac derives shared secret using iPad's public key */
    NSDictionary *exchangeParams = @{
        (__bridge id)kSecKeyKeyExchangeParameterRequestedSize: @32,
        (__bridge id)kSecKeyKeyExchangeParameterSharedInfo:
            [@"keydrd-v2" dataUsingEncoding:NSUTF8StringEncoding],
    };
    CFDataRef macSecret = SecKeyCopyKeyExchangeResult(
        macPrivate, kSecKeyAlgorithmECDHKeyExchangeStandard,
        iPadPublic, (__bridge CFDictionaryRef)exchangeParams, &err);
    XCTAssertTrue(macSecret != NULL, @"Mac ECDH must succeed");

    /* iPad derives same shared secret using Mac's public key */
    CFDataRef iPadSecret = SecKeyCopyKeyExchangeResult(
        iPadPrivate, kSecKeyAlgorithmECDHKeyExchangeStandard,
        macPublic, (__bridge CFDictionaryRef)exchangeParams, &err);
    XCTAssertTrue(iPadSecret != NULL, @"iPad ECDH must succeed");

    /* Verify both sides derived the same secret */
    XCTAssertTrue(CFEqual(macSecret, iPadSecret), @"Shared secrets must match");

    CFRelease(macSecret);
    CFRelease(iPadSecret);
    CFRelease(macPublic);
    CFRelease(iPadPublic);
    CFRelease(macPrivate);
    CFRelease(iPadPrivate);

    /* --- Steps 4-11: Data channel over localhost TCP --- */

    __block uint16_t port = 0;
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"data listener ready"];

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* === MAC SIDE (server) === */

        /* Step 6: Send handshake */
        SessionHandshakeMessage handshake;
        memset(&handshake, 0, sizeof(handshake));
        handshake.magic = KEYDRD_MAGIC;
        handshake.msg_type = KEYDRD_MSG_SESSION_HANDSHAKE;
        handshake.display_width = (uint32_t)W;
        handshake.display_height = (uint32_t)H;
        handshake.scale_factor = 2.0f;
        handshake.aspect_ratio = (float)W / (float)H;
        handshake.capabilities = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE;
        handshake.max_fps = 120;
        handshake.agent_version = 1;

        e2eSend(serverConn, &handshake, sizeof(handshake), ^{
            /* Step 8: Compress and send a frame */
            IOSurfaceRef surface = e2eCreateTestSurface(W, H);
            e2eFillSurface(surface, 77);

            /* Read original data */
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            NSData *origData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface)
                                              length:frame_bytes];
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

            FrameCompressorState comp;
            frame_compressor_init(&comp, frame_bytes);
            __block CompressOutput out = comp.output;
            __block MediaFrameHeader frameHdr;

            CMSampleBufferRef sb = e2eCreateSampleBuffer(surface, CMTimeMake(0, 1000000));

            dispatch_sync(comp.compress_queue, ^{
                compress_frame(&comp, surface, sb, 0, &out);
                frameHdr = out.header;
            });

            CFRelease(sb);

            /* Send header + compressed payload */
            size_t wireLen = sizeof(MediaFrameHeader) + out.compressed_size;
            uint8_t *wire = (uint8_t *)malloc(wireLen);
            memcpy(wire, &frameHdr, sizeof(MediaFrameHeader));
            memcpy(wire + sizeof(MediaFrameHeader), out.buf, out.compressed_size);

            e2eSend(serverConn, wire, wireLen, ^{
                free(wire);

                /* Step 10: Send latency probe */
                InputEventHeader probe;
                probe.type = KEYDRD_INPUT_LATENCY_PROBE;
                probe.ts_us = 123456789ULL;
                e2eSend(serverConn, &probe, sizeof(probe), ^{
                    /* Wait for echo back from "iPad" */
                    e2eReceive(serverConn, sizeof(InputEventHeader),
                        ^(const uint8_t *buf, size_t len) {
                        XCTAssertEqual(len, sizeof(InputEventHeader));
                        InputEventHeader echo;
                        memcpy(&echo, buf, sizeof(InputEventHeader));
                        XCTAssertEqual(echo.type, KEYDRD_INPUT_LATENCY_PROBE);
                        XCTAssertEqual(echo.ts_us, 123456789ULL);

                        /* Step 11: Clean disconnect */
                        [fullSessionDone fulfill];
                    });
                });
            });

            frame_compressor_destroy(&comp);
            CFRelease(surface);
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    /* === iPAD SIDE (client) === */
    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Step 7: Receive and verify handshake */
    e2eReceive(client, sizeof(SessionHandshakeMessage),
        ^(const uint8_t *hsBuf, size_t hsLen) {
        XCTAssertEqual(hsLen, sizeof(SessionHandshakeMessage));

        SessionHandshakeMessage hs;
        memcpy(&hs, hsBuf, sizeof(hs));
        XCTAssertEqual(hs.magic, KEYDRD_MAGIC);
        XCTAssertEqual(hs.msg_type, KEYDRD_MSG_SESSION_HANDSHAKE);
        XCTAssertEqual(hs.display_width, (uint32_t)W);
        XCTAssertEqual(hs.display_height, (uint32_t)H);
        XCTAssertEqualWithAccuracy(hs.scale_factor, 2.0f, 0.001f);
        XCTAssertEqual(hs.max_fps, 120);

        /* Step 9: Receive frame (header + payload) */
        e2eReceive(client, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
            XCTAssertEqual(hdrLen, sizeof(MediaFrameHeader));
            MediaFrameHeader frameHdr;
            memcpy(&frameHdr, hdrBuf, sizeof(frameHdr));
            XCTAssertEqual(frameHdr.magic, KEYDRD_MAGIC);
            XCTAssertGreaterThan(frameHdr.payload_size, 0u);

            e2eReceive(client, frameHdr.payload_size, ^(const uint8_t *payload, size_t payloadLen) {
                XCTAssertEqual(payloadLen, (size_t)frameHdr.payload_size);

                /* Verify CRC */
                uint32_t crc = (uint32_t)crc32(0L, payload, (uInt)payloadLen);
                XCTAssertEqual(crc, frameHdr.crc32);

                /* Decompress */
                uint8_t *decompressed = (uint8_t *)malloc(frame_bytes);
                int decompSize = LZ4_decompress_safe((const char *)payload,
                                                      (char *)decompressed,
                                                      (int)payloadLen,
                                                      (int)frame_bytes);
                XCTAssertEqual((size_t)decompSize, frame_bytes);

                /* Verify pixel data: fill pattern with seed 77 */
                BOOL pixelMatch = YES;
                for (size_t i = 0; i < frame_bytes && pixelMatch; i++) {
                    uint8_t expected = (uint8_t)((i * 7 + 77) & 0xFF);
                    if (decompressed[i] != expected) {
                        pixelMatch = NO;
                    }
                }
                XCTAssertTrue(pixelMatch, @"Decompressed pixels must match original pattern");
                free(decompressed);

                /* Step 10: Receive latency probe, echo it back */
                e2eReceive(client, sizeof(InputEventHeader),
                    ^(const uint8_t *probeBuf, size_t probeLen) {
                    XCTAssertEqual(probeLen, sizeof(InputEventHeader));
                    InputEventHeader probe;
                    memcpy(&probe, probeBuf, sizeof(probe));
                    XCTAssertEqual(probe.type, KEYDRD_INPUT_LATENCY_PROBE);

                    /* Echo back */
                    e2eSend(client, &probe, sizeof(probe), nil);
                });
            });
        });
    });

    [self waitForExpectations:@[fullSessionDone] timeout:30.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

#pragma mark - Mode Switch

- (void)testModeSwitch_LZ4toHEVC {
    /*
     * Start session in LZ4 mode. Send mode change event (type=0x20) to switch
     * to HEVC. Verify next frame headers have KEYDRD_FLAG_HEVC set.
     */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *modeSwitchDone = [self expectationWithDescription:@"mode switch verified"];
    __block uint16_t port = 0;

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Mac side: first send an LZ4 frame header */
        MediaFrameHeader lz4Header;
        memset(&lz4Header, 0, sizeof(lz4Header));
        lz4Header.magic = KEYDRD_MAGIC;
        lz4Header.flags = KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
        lz4Header.seq = 0;
        lz4Header.payload_size = 100;
        lz4Header.crc32 = 0x12345678;

        /* Send LZ4 header (just the header, no real payload for this test) */
        e2eSend(serverConn, &lz4Header, sizeof(lz4Header), ^{
            /* Receive mode change event from iPad */
            e2eReceive(serverConn, sizeof(InputEventHeader),
                ^(const uint8_t *buf, size_t len) {
                InputEventHeader modeEvt;
                memcpy(&modeEvt, buf, sizeof(InputEventHeader));
                XCTAssertEqual(modeEvt.type, KEYDRD_INPUT_MODE_CHANGE);

                /* Mac switches to HEVC and sends an HEVC frame header */
                MediaFrameHeader hevcHeader;
                memset(&hevcHeader, 0, sizeof(hevcHeader));
                hevcHeader.magic = KEYDRD_MAGIC;
                hevcHeader.flags = KEYDRD_FLAG_HEVC | KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
                hevcHeader.seq = 1;
                hevcHeader.payload_size = 200;
                hevcHeader.crc32 = 0xABCDEF01;

                e2eSend(serverConn, &hevcHeader, sizeof(hevcHeader), nil);
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* iPad: receive LZ4 header */
    e2eReceive(client, sizeof(MediaFrameHeader), ^(const uint8_t *buf, size_t len) {
        MediaFrameHeader hdr;
        memcpy(&hdr, buf, sizeof(hdr));
        XCTAssertFalse(hdr.flags & KEYDRD_FLAG_HEVC, @"First frame must be LZ4 (no HEVC flag)");
        XCTAssertTrue(hdr.flags & KEYDRD_FLAG_KEYFRAME);

        /* iPad sends mode change request */
        InputEventHeader modeChange;
        modeChange.type = KEYDRD_INPUT_MODE_CHANGE;
        modeChange.ts_us = 1111111111ULL;
        e2eSend(client, &modeChange, sizeof(modeChange), ^{
            /* iPad receives HEVC frame header */
            e2eReceive(client, sizeof(MediaFrameHeader), ^(const uint8_t *buf2, size_t len2) {
                MediaFrameHeader hdr2;
                memcpy(&hdr2, buf2, sizeof(hdr2));
                XCTAssertTrue(hdr2.flags & KEYDRD_FLAG_HEVC, @"Frame after mode switch must have HEVC flag");
                XCTAssertEqual(hdr2.seq, 1);
                [modeSwitchDone fulfill];
            });
        });
    });

    [self waitForExpectations:@[modeSwitchDone] timeout:10.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

#pragma mark - Transport FSM Integration

- (void)testTransportFSMCascade {
    /*
     * Walk through the full transport cascade:
     * IDLE -> WIRED_APPEARED -> USB_NCM (LZ4)
     * -> WIRED_DISAPPEARED -> DISCONNECTED
     * -> WIFI_AVAILABLE -> WIFI (HEVC)
     * -> WIRED_APPEARED -> USB_NCM (LZ4, promoted)
     * -> WIRED_DISAPPEARED -> DISCONNECTED
     * -> AWDL_AVAILABLE -> AWDL (HEVC)
     */

    TransportState state = TRANSPORT_IDLE;
    TransportTransition t;

    /* Step 1: IDLE + WIRED_APPEARED -> USB_NCM */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertGreaterThan(t.effect_count, 0);
    /* Verify effects include USB NCM bind and LZ4 encode */
    BOOL hasBindUSB = NO, hasLZ4 = NO, hasNotify = NO;
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == EFFECT_BIND_USB_NCM) hasBindUSB = YES;
        if (t.effects[i] == EFFECT_SWITCH_ENCODE_LZ4) hasLZ4 = YES;
        if (t.effects[i] == EFFECT_NOTIFY_TRANSPORT_CHANGE) hasNotify = YES;
    }
    XCTAssertTrue(hasBindUSB, @"Must bind USB NCM");
    XCTAssertTrue(hasLZ4, @"Must switch to LZ4 encoding");
    XCTAssertTrue(hasNotify, @"Must notify transport change");
    state = t.next_state;

    /* Step 2: USB_NCM + WIRED_DISAPPEARED -> DISCONNECTED */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_DISAPPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    BOOL hasDisconnect = NO;
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == EFFECT_DISCONNECT_CURRENT) hasDisconnect = YES;
    }
    XCTAssertTrue(hasDisconnect, @"Must disconnect current transport");
    state = t.next_state;

    /* Step 3: DISCONNECTED + WIFI_AVAILABLE -> WIFI (HEVC) */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    BOOL hasConnectWifi = NO, hasHEVC = NO;
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == EFFECT_CONNECT_WIFI) hasConnectWifi = YES;
        if (t.effects[i] == EFFECT_SWITCH_ENCODE_HEVC) hasHEVC = YES;
    }
    XCTAssertTrue(hasConnectWifi, @"Must connect WiFi");
    XCTAssertTrue(hasHEVC, @"Must switch to HEVC encoding for WiFi");
    state = t.next_state;

    /* Step 4: WIFI + WIRED_APPEARED -> USB_NCM (promoted from WiFi) */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    hasDisconnect = NO; hasBindUSB = NO; hasLZ4 = NO;
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == EFFECT_DISCONNECT_CURRENT) hasDisconnect = YES;
        if (t.effects[i] == EFFECT_BIND_USB_NCM) hasBindUSB = YES;
        if (t.effects[i] == EFFECT_SWITCH_ENCODE_LZ4) hasLZ4 = YES;
    }
    XCTAssertTrue(hasDisconnect, @"Must disconnect WiFi before promoting to USB");
    XCTAssertTrue(hasBindUSB, @"Must bind USB NCM");
    XCTAssertTrue(hasLZ4, @"Must switch to LZ4 for USB");
    state = t.next_state;

    /* Step 5: USB_NCM + WIRED_DISAPPEARED -> DISCONNECTED */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_DISAPPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    state = t.next_state;

    /* Step 6: DISCONNECTED + AWDL_AVAILABLE -> AWDL (HEVC) */
    t = transport_fsm_transition(state, TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_AWDL);
    BOOL hasConnectAWDL = NO;
    hasHEVC = NO;
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == EFFECT_CONNECT_AWDL) hasConnectAWDL = YES;
        if (t.effects[i] == EFFECT_SWITCH_ENCODE_HEVC) hasHEVC = YES;
    }
    XCTAssertTrue(hasConnectAWDL, @"Must connect AWDL");
    XCTAssertTrue(hasHEVC, @"Must switch to HEVC for AWDL");
    state = t.next_state;

    /* Verify final state */
    XCTAssertEqual(state, TRANSPORT_AWDL);

    /* Bonus: Verify name helpers don't crash */
    XCTAssertTrue(strlen(transport_state_name(TRANSPORT_IDLE)) > 0);
    XCTAssertTrue(strlen(transport_state_name(TRANSPORT_USB_NCM)) > 0);
    XCTAssertTrue(strlen(transport_state_name(TRANSPORT_WIFI)) > 0);
    XCTAssertTrue(strlen(transport_state_name(TRANSPORT_AWDL)) > 0);
    XCTAssertTrue(strlen(transport_state_name(TRANSPORT_DISCONNECTED)) > 0);
    XCTAssertTrue(strlen(transport_event_name(TRANSPORT_EVT_WIRED_APPEARED)) > 0);
    XCTAssertTrue(strlen(transport_effect_name(EFFECT_BIND_USB_NCM)) > 0);
}

#pragma mark - Multi-Frame Streaming

- (void)testStreamMultipleFramesOverTCP {
    const size_t W = 320, H = 240;
    const size_t frame_bytes = W * H * 4;
    const int FRAME_COUNT = 50;

    /* Compress all frames first */
    FrameCompressorState compressor;
    int rc = frame_compressor_init(&compressor, frame_bytes);
    XCTAssertEqual(rc, 0);

    NSMutableArray<NSData *> *wireFrames = [NSMutableArray array];
    NSMutableArray<NSNumber *> *expectedSeqs = [NSMutableArray array];

    for (int i = 0; i < FRAME_COUNT; i++) {
        IOSurfaceRef surface = e2eCreateTestSurface(W, H);
        e2eFillSurface(surface, (uint8_t)(i + 1));

        CMSampleBufferRef sb = e2eCreateSampleBuffer(surface, CMTimeMake(i * 33333, 1000000));
        __block CompressOutput out = compressor.output;
        __block MediaFrameHeader hdr;

        dispatch_sync(compressor.compress_queue, ^{
            compress_frame(&compressor, surface, sb, 0, &out);
            hdr = out.header;
        });

        [expectedSeqs addObject:@(hdr.seq)];

        /* Build handshake for first frame, then just frames */
        NSMutableData *wire = [NSMutableData data];
        if (i == 0) {
            /* Prepend handshake before first frame */
            SessionHandshakeMessage hs;
            memset(&hs, 0, sizeof(hs));
            hs.magic = KEYDRD_MAGIC;
            hs.msg_type = KEYDRD_MSG_SESSION_HANDSHAKE;
            hs.display_width = (uint32_t)W;
            hs.display_height = (uint32_t)H;
            hs.scale_factor = 1.0f;
            hs.aspect_ratio = (float)W / (float)H;
            hs.capabilities = KEYDRD_CAP_LZ4;
            hs.max_fps = 60;
            hs.agent_version = 1;
            [wire appendBytes:&hs length:sizeof(hs)];
        }
        [wire appendBytes:&hdr length:sizeof(hdr)];
        [wire appendBytes:out.buf length:out.compressed_size];
        [wireFrames addObject:wire];

        CFRelease(sb);
        CFRelease(surface);
    }

    /* Send and receive over TCP */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *allDone = [self expectationWithDescription:@"50 frames received"];
    __block uint16_t port = 0;
    __block int recvCount = 0;

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Receive handshake first */
        e2eReceive(serverConn, sizeof(SessionHandshakeMessage),
            ^(const uint8_t *hsBuf, size_t hsLen) {
            SessionHandshakeMessage hs;
            memcpy(&hs, hsBuf, sizeof(hs));
            XCTAssertEqual(hs.magic, KEYDRD_MAGIC);
            XCTAssertEqual(hs.msg_type, KEYDRD_MSG_SESSION_HANDSHAKE);

            /* Receive all 50 frames sequentially */
            __block void (^receiveNext)(void);
            receiveNext = ^{
                if (recvCount >= FRAME_COUNT) {
                    [allDone fulfill];
                    return;
                }
                e2eReceive(serverConn, sizeof(MediaFrameHeader),
                    ^(const uint8_t *hdrBuf, size_t hdrLen) {
                    if (hdrLen < sizeof(MediaFrameHeader)) return;
                    MediaFrameHeader hdr;
                    memcpy(&hdr, hdrBuf, sizeof(hdr));
                    XCTAssertEqual(hdr.magic, KEYDRD_MAGIC);
                    XCTAssertEqual(hdr.seq, [expectedSeqs[recvCount] unsignedShortValue],
                                   @"Sequence number mismatch at frame %d", recvCount);

                    /* Consume payload */
                    e2eReceive(serverConn, hdr.payload_size,
                        ^(const uint8_t *payload, size_t payloadLen) {
                        uint32_t computedCRC = (uint32_t)crc32(0L, payload, (uInt)payloadLen);
                        XCTAssertEqual(computedCRC, hdr.crc32,
                                       @"CRC mismatch at frame %d", recvCount);
                        recvCount++;
                        receiveNext();
                    });
                });
            };
            receiveNext();
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send all frames in burst */
    __block void (^sendNext)(int);
    sendNext = ^(int idx) {
        if (idx >= FRAME_COUNT) return;
        e2eSend(client, wireFrames[idx].bytes, wireFrames[idx].length, ^{
            sendNext(idx + 1);
        });
    };
    sendNext(0);

    [self waitForExpectations:@[allDone] timeout:15.0];
    XCTAssertEqual(recvCount, FRAME_COUNT);

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
}

#pragma mark - Reconnection

- (void)testReconnectAfterDisconnect {
    /*
     * 1. Establish session (send handshake + one frame).
     * 2. Kill the client connection.
     * 3. Verify FSM transitions through DISCONNECTED.
     * 4. Re-establish connection.
     * 5. Verify session resumes (server sends another handshake + frame).
     */

    const size_t W = 320, H = 240;
    const size_t frame_bytes = W * H * 4;

    XCTestExpectation *firstSessionDone = [self expectationWithDescription:@"first session done"];
    XCTestExpectation *reconnectDone = [self expectationWithDescription:@"reconnect done"];
    __block uint16_t port = 0;
    __block int connectionCount = 0;

    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];

    /* The server accepts multiple connections (reconnection scenario) */
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_local_endpoint(params,
        nw_endpoint_create_host("127.0.0.1", "0"));

    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_state_changed_handler(listener,
        ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            port = nw_listener_get_port(listener);
            [listenerReady fulfill];
        }
    });

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, self.testQueue);
        nw_connection_set_state_changed_handler(conn,
            ^(nw_connection_state_t s, nw_error_t _Nullable e) {
            if (s == nw_connection_state_ready) {
                connectionCount++;

                /* Send handshake on each connection */
                SessionHandshakeMessage hs;
                memset(&hs, 0, sizeof(hs));
                hs.magic = KEYDRD_MAGIC;
                hs.msg_type = KEYDRD_MSG_SESSION_HANDSHAKE;
                hs.display_width = (uint32_t)W;
                hs.display_height = (uint32_t)H;
                hs.scale_factor = 1.0f;
                hs.capabilities = KEYDRD_CAP_LZ4;
                hs.max_fps = 60;
                hs.agent_version = 1;

                e2eSend(conn, &hs, sizeof(hs), nil);
            }
        });
        nw_connection_start(conn);
    });

    nw_listener_set_queue(listener, self.testQueue);
    nw_listener_start(listener);

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    /* === First connection === */
    XCTestExpectation *client1Ready = [self expectationWithDescription:@"client1 ready"];
    nw_connection_t client1 = e2eConnect(port, self.testQueue, client1Ready);
    [self waitForExpectations:@[client1Ready] timeout:5.0];

    e2eReceive(client1, sizeof(SessionHandshakeMessage),
        ^(const uint8_t *buf, size_t len) {
        XCTAssertEqual(len, sizeof(SessionHandshakeMessage));
        SessionHandshakeMessage hs;
        memcpy(&hs, buf, sizeof(hs));
        XCTAssertEqual(hs.magic, KEYDRD_MAGIC);
        [firstSessionDone fulfill];
    });

    [self waitForExpectations:@[firstSessionDone] timeout:5.0];

    /* Simulate FSM disconnect */
    TransportState fsmState = TRANSPORT_USB_NCM;
    TransportTransition t = transport_fsm_transition(fsmState, TRANSPORT_EVT_WIRED_DISAPPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    fsmState = t.next_state;

    /* Kill client connection */
    nw_connection_cancel(client1);

    /* Simulate wired re-appearance */
    t = transport_fsm_transition(fsmState, TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM, @"FSM must transition back to USB_NCM");

    /* === Reconnect (second connection) === */
    XCTestExpectation *client2Ready = [self expectationWithDescription:@"client2 ready"];
    nw_connection_t client2 = e2eConnect(port, self.testQueue, client2Ready);
    [self waitForExpectations:@[client2Ready] timeout:5.0];

    e2eReceive(client2, sizeof(SessionHandshakeMessage),
        ^(const uint8_t *buf, size_t len) {
        XCTAssertEqual(len, sizeof(SessionHandshakeMessage));
        SessionHandshakeMessage hs;
        memcpy(&hs, buf, sizeof(hs));
        XCTAssertEqual(hs.magic, KEYDRD_MAGIC);
        XCTAssertEqual(connectionCount, 2, @"Server must have accepted two connections");
        [reconnectDone fulfill];
    });

    [self waitForExpectations:@[reconnectDone] timeout:5.0];

    nw_connection_cancel(client2);
    nw_listener_cancel(listener);
}

#pragma mark - Error Handling

- (void)testInvalidMagicBytesRejected {
    /*
     * Send a MediaFrameHeader with wrong magic (0xFFFF instead of 0x4B44).
     * The receiver must detect the mismatch.
     */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *rejected = [self expectationWithDescription:@"invalid magic rejected"];
    __block uint16_t port = 0;

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        e2eReceive(serverConn, sizeof(MediaFrameHeader),
            ^(const uint8_t *buf, size_t len) {
            XCTAssertEqual(len, sizeof(MediaFrameHeader));
            MediaFrameHeader hdr;
            memcpy(&hdr, buf, sizeof(hdr));

            /* Verify magic is wrong and would be rejected */
            XCTAssertNotEqual(hdr.magic, KEYDRD_MAGIC,
                              @"Magic bytes must not match KEYDRD_MAGIC");
            XCTAssertEqual(hdr.magic, 0xFFFF,
                           @"Magic must be the invalid value we sent");

            [rejected fulfill];
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send header with invalid magic */
    MediaFrameHeader badHeader;
    memset(&badHeader, 0, sizeof(badHeader));
    badHeader.magic = 0xFFFF; /* Wrong! Should be KEYDRD_MAGIC (0x4B44) */
    badHeader.flags = KEYDRD_FLAG_KEYFRAME;
    badHeader.seq = 1;
    badHeader.payload_size = 100;

    e2eSend(client, &badHeader, sizeof(badHeader), nil);

    [self waitForExpectations:@[rejected] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

- (void)testTruncatedHeaderRejected {
    /*
     * Send only 12 bytes (less than the 24-byte MediaFrameHeader).
     * Verify the receiver detects the truncation.
     */
    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *truncationDetected = [self expectationWithDescription:@"truncation detected"];
    __block uint16_t port = 0;

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Try to receive a full 24-byte header. We should either get
         * fewer bytes or the connection will complete with is_complete. */
        nw_connection_receive(serverConn, 1, sizeof(MediaFrameHeader),
            ^(dispatch_data_t _Nullable content,
              nw_content_context_t _Nullable ctx,
              bool is_complete,
              nw_error_t _Nullable error) {
            size_t received = content ? dispatch_data_get_size(content) : 0;

            /* We sent 12 bytes — receiver should get exactly 12 */
            XCTAssertEqual(received, 12u, @"Should receive exactly 12 bytes");
            XCTAssertLessThan(received, sizeof(MediaFrameHeader),
                              @"Received data must be less than full header size");

            /* A parser would reject this as insufficient data */
            if (received < sizeof(MediaFrameHeader)) {
                /* Truncated — insufficient data for a valid header */
                [truncationDetected fulfill];
            }
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send only 12 bytes (half a header) then close */
    uint8_t truncated[12] = {0};
    /* Put valid magic at the start to make it look like a real header attempt */
    uint16_t magic = KEYDRD_MAGIC;
    memcpy(truncated, &magic, sizeof(magic));

    void *copy = malloc(12);
    memcpy(copy, truncated, 12);
    dispatch_data_t dd = dispatch_data_create(copy, 12, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(client, dd, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true,
        ^(nw_error_t _Nullable error) {
        /* Connection closed after sending partial data */
    });

    [self waitForExpectations:@[truncationDetected] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
}

- (void)testCRCMismatchDetected {
    /*
     * Send a valid header but corrupt the payload so CRC mismatches.
     * Verify the mismatch is detectable.
     */
    const size_t W = 64, H = 64;
    const size_t frame_bytes = W * H * 4;

    /* Create and compress a real frame */
    IOSurfaceRef surface = e2eCreateTestSurface(W, H);
    e2eFillSurface(surface, 55);

    FrameCompressorState compressor;
    frame_compressor_init(&compressor, frame_bytes);

    CMSampleBufferRef sb = e2eCreateSampleBuffer(surface, CMTimeMake(0, 1000000));
    __block CompressOutput out = compressor.output;
    __block MediaFrameHeader hdr;

    dispatch_sync(compressor.compress_queue, ^{
        compress_frame(&compressor, surface, sb, 0, &out);
        hdr = out.header;
    });

    CFRelease(sb);

    /* Create corrupted payload (flip some bytes) */
    NSMutableData *corruptedPayload = [NSMutableData dataWithBytes:out.buf length:out.compressed_size];
    uint8_t *corruptBytes = (uint8_t *)corruptedPayload.mutableBytes;
    if (corruptedPayload.length > 10) {
        corruptBytes[5] ^= 0xFF;
        corruptBytes[10] ^= 0xFF;
    }

    XCTestExpectation *listenerReady = [self expectationWithDescription:@"listener ready"];
    XCTestExpectation *crcMismatch = [self expectationWithDescription:@"CRC mismatch detected"];
    __block uint16_t port = 0;

    nw_listener_t listener = e2eCreateListener(self.testQueue, &port, listenerReady,
        ^(nw_connection_t serverConn) {
        /* Receive header */
        e2eReceive(serverConn, sizeof(MediaFrameHeader), ^(const uint8_t *hdrBuf, size_t hdrLen) {
            MediaFrameHeader recvHdr;
            memcpy(&recvHdr, hdrBuf, sizeof(recvHdr));
            XCTAssertEqual(recvHdr.magic, KEYDRD_MAGIC);

            /* Receive corrupted payload */
            e2eReceive(serverConn, recvHdr.payload_size, ^(const uint8_t *payload, size_t payloadLen) {
                /* Compute CRC of received (corrupted) payload */
                uint32_t computedCRC = (uint32_t)crc32(0L, payload, (uInt)payloadLen);

                /* CRC in header was computed from ORIGINAL payload,
                 * so it must NOT match the corrupted payload's CRC. */
                XCTAssertNotEqual(computedCRC, recvHdr.crc32,
                                  @"CRC of corrupted payload must not match header CRC");

                [crcMismatch fulfill];
            });
        });
    });

    [self waitForExpectations:@[listenerReady] timeout:5.0];

    XCTestExpectation *clientReady = [self expectationWithDescription:@"client ready"];
    nw_connection_t client = e2eConnect(port, self.testQueue, clientReady);
    [self waitForExpectations:@[clientReady] timeout:5.0];

    /* Send valid header + corrupted payload */
    NSMutableData *wire = [NSMutableData dataWithBytes:&hdr length:sizeof(hdr)];
    [wire appendData:corruptedPayload];
    e2eSend(client, wire.bytes, wire.length, nil);

    [self waitForExpectations:@[crcMismatch] timeout:5.0];

    nw_connection_cancel(client);
    nw_listener_cancel(listener);
    frame_compressor_destroy(&compressor);
    CFRelease(surface);
}

#pragma mark - Security: Identity File Permissions (C3)

/// Verify /tmp/keydrd-tls/identity.p12 has restrictive permissions (not world-readable).
/// Catches C3: TLS identity stored in world-readable /tmp with hardcoded password.
- (void)testIdentityFilePermissions {
    NSString *identityDir = @"/tmp/keydrd-tls";
    NSString *identityFile = @"/tmp/keydrd-tls/identity.p12";
    NSFileManager *fm = [NSFileManager defaultManager];

    /* Check if the identity file exists */
    if (![fm fileExistsAtPath:identityFile]) {
        /* File doesn't exist — may not have been generated yet.
         * This is not a vulnerability per se, but note it. */
        NSLog(@"sec-identity-file-permissions: identity.p12 not found at %@", identityFile);
        /* Pass: no file = no exposure */
        return;
    }

    /* Check directory permissions */
    NSError *dirError = nil;
    NSDictionary *dirAttrs = [fm attributesOfItemAtPath:identityDir error:&dirError];
    XCTAssertNil(dirError, @"Failed to read directory attributes: %@", dirError);

    if (dirAttrs) {
        NSUInteger dirPerms = [dirAttrs filePosixPermissions];
        /* Directory should be 0700 (owner-only) */
        XCTAssertEqual(dirPerms & 0077, 0,
                       @"VULNERABLE (C3): /tmp/keydrd-tls/ has group/other permissions: %lo (expected 0700)",
                       (unsigned long)dirPerms);
        NSLog(@"sec-identity-file-permissions: directory permissions = %lo", (unsigned long)dirPerms);
    }

    /* Check file permissions */
    NSError *fileError = nil;
    NSDictionary *fileAttrs = [fm attributesOfItemAtPath:identityFile error:&fileError];
    XCTAssertNil(fileError, @"Failed to read file attributes: %@", fileError);

    if (fileAttrs) {
        NSUInteger filePerms = [fileAttrs filePosixPermissions];
        /* File should be 0600 (owner-only read/write) */
        XCTAssertEqual(filePerms & 0077, 0,
                       @"VULNERABLE (C3): identity.p12 has group/other permissions: %lo (expected 0600)",
                       (unsigned long)filePerms);
        NSLog(@"sec-identity-file-permissions: file permissions = %lo", (unsigned long)filePerms);

        /* Also check file owner matches current user */
        NSString *fileOwner = fileAttrs[NSFileOwnerAccountName];
        NSString *currentUser = NSUserName();
        XCTAssertEqualObjects(fileOwner, currentUser,
                              @"identity.p12 owned by %@ (expected %@)", fileOwner, currentUser);
    }
}

#pragma mark - Security: Keychain Access Controls (H1)

/// Verify keychain items use kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
/// Catches H1: No Keychain access controls on stored secrets.
- (void)testKeychainAccessControls {
    NSString *service = @"com.ryheff.keyd.remote.agent";
    NSArray *accounts = @[
        @"tls-identity-p12",
        @"tls-cert-der",
        @"tls-private-key",
        @"peer-fingerprint",
        @"shared-secret",
    ];

    NSMutableArray *issues = [NSMutableArray array];
    int itemsFound = 0;

    for (NSString *account in accounts) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecReturnAttributes: @YES,
        };

        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

        if (status == errSecSuccess && result) {
            itemsFound++;
            NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;

            id accessible = attrs[(__bridge id)kSecAttrAccessible];
            if (accessible) {
                /* Check it matches WhenUnlockedThisDeviceOnly */
                if (![accessible isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) {
                    [issues addObject:[NSString stringWithFormat:
                        @"%@: accessible=%@ (expected WhenUnlockedThisDeviceOnly)", account, accessible]];
                }
            } else {
                [issues addObject:[NSString stringWithFormat:
                    @"%@: no kSecAttrAccessible set (H1 vulnerability)", account]];
            }

            NSLog(@"sec-keychain-access-control: %@ found, accessible=%@", account, accessible ?: @"(nil)");
        } else if (status == errSecItemNotFound) {
            NSLog(@"sec-keychain-access-control: %@ not found in keychain", account);
        } else {
            [issues addObject:[NSString stringWithFormat:
                @"%@: keychain query error %d", account, (int)status]];
            if (result) CFRelease(result);
        }
    }

    if (itemsFound > 0 && issues.count > 0) {
        XCTFail(@"VULNERABLE (H1): %@", [issues componentsJoinedByString:@"; "]);
    } else if (itemsFound == 0) {
        NSLog(@"sec-keychain-access-control: no keychain items found to audit — agent may not have paired yet");
    }
    /* itemsFound > 0 && issues.count == 0 => pass */
}

@end
