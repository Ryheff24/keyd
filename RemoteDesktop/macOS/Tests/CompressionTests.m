/*
 * CompressionTests.m
 * XCTest suite for the keyd-rd compression layer.
 *
 * Tests LZ4 block compression, XOR delta encoding (DeltaBuffer),
 * and the FrameCompressor hot-path compressor.
 */

#import <XCTest/XCTest.h>
#include "lz4.h"
#include "delta.h"
#include "FrameCompressor.h"
#include <string.h>
#include <stdlib.h>
#include <IOSurface/IOSurface.h>

/* Helper: create a test IOSurface with BGRA pixel format */
static IOSurfaceRef createTestSurface(size_t width, size_t height) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

/*
 * Helper: create a CMSampleBuffer wrapping an IOSurface.
 * Caller must CFRelease the returned sampleBuf, formatDesc, and CVPixelBufferRelease pb.
 */
static CMSampleBufferRef createSampleBuffer(IOSurfaceRef surface,
                                             int64_t frameIndex,
                                             CVPixelBufferRef *outPB,
                                             CMVideoFormatDescriptionRef *outFD) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pb);
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(frameIndex, 60), kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true,
                                        NULL, NULL, fd, &timing, &sb);
    *outPB = pb;
    *outFD = fd;
    return sb;
}

@interface CompressionTests : XCTestCase
@end

@implementation CompressionTests

#pragma mark - LZ4 block compression

- (void)testLZ4CompressDecompressSmall {
    /* 1 KB of known repeating data */
    const int srcSize = 1024;
    char src[srcSize];
    for (int i = 0; i < srcSize; i++) {
        src[i] = (char)(i % 127);
    }

    int bound = LZ4_compressBound(srcSize);
    XCTAssertGreaterThan(bound, 0);

    char *compressed = (char *)malloc((size_t)bound);
    XCTAssertNotEqual(compressed, NULL);

    int compressedSize = LZ4_compress_default(src, compressed, srcSize, bound);
    XCTAssertGreaterThan(compressedSize, 0,
                         @"LZ4 compression must succeed for valid input");

    /* Decompress and verify */
    char decompressed[srcSize];
    int decompressedSize = LZ4_decompress_safe(compressed, decompressed,
                                                compressedSize, srcSize);
    XCTAssertEqual(decompressedSize, srcSize);
    XCTAssertEqual(memcmp(src, decompressed, (size_t)srcSize), 0,
                   @"Decompressed data must match original");

    free(compressed);
}

- (void)testLZ4CompressDecompressLargeFrame {
    /* Simulate a 1920x1080 BGRA frame = 8,294,400 bytes */
    const int width  = 1920;
    const int height = 1080;
    const int bpp    = 4;
    const int srcSize = width * height * bpp;

    char *src = (char *)malloc((size_t)srcSize);
    XCTAssertNotEqual(src, NULL);

    /* Fill with a gradient pattern */
    for (int i = 0; i < srcSize; i++) {
        src[i] = (char)((i * 7 + 13) & 0xFF);
    }

    int bound = LZ4_compressBound(srcSize);
    XCTAssertGreaterThan(bound, 0);

    char *compressed = (char *)malloc((size_t)bound);
    XCTAssertNotEqual(compressed, NULL);

    int compressedSize = LZ4_compress_default(src, compressed, srcSize, bound);
    XCTAssertGreaterThan(compressedSize, 0,
                         @"LZ4 must handle 8MB frame data");

    char *decompressed = (char *)malloc((size_t)srcSize);
    XCTAssertNotEqual(decompressed, NULL);

    int decompressedSize = LZ4_decompress_safe(compressed, decompressed,
                                                compressedSize, srcSize);
    XCTAssertEqual(decompressedSize, srcSize);
    XCTAssertEqual(memcmp(src, decompressed, (size_t)srcSize), 0,
                   @"Decompressed 8MB frame must match original");

    free(src);
    free(compressed);
    free(decompressed);
}

- (void)testLZ4CompressEmptyData {
    char dst[64];
    /*
     * LZ4_compress_default with srcSize=0 produces a minimal valid
     * LZ4 block (1 byte). Verify it produces a tiny output and that
     * decompressing it yields 0 bytes.
     */
    int result = LZ4_compress_default("", dst, 0, sizeof(dst));
    XCTAssertGreaterThan(result, 0,
                         @"LZ4 produces a minimal block even for 0-byte input");
    XCTAssertLessThanOrEqual(result, 4,
                              @"0-byte input should compress to at most a few bytes");

    /* Decompress back and verify 0 bytes */
    char decompressed[1];
    int decompSize = LZ4_decompress_safe(dst, decompressed, result, 0);
    XCTAssertEqual(decompSize, 0,
                   @"Decompressing empty LZ4 block must yield 0 bytes");
}

- (void)testLZ4CompressBound {
    XCTAssertGreaterThan(LZ4_compressBound(1), 0);
    XCTAssertGreaterThan(LZ4_compressBound(1024), 0);
    XCTAssertGreaterThan(LZ4_compressBound(1920 * 1080 * 4), 0);
}

#pragma mark - DeltaBuffer / XOR delta

- (void)testDeltaBufferInitDestroy {
    DeltaBuffer db;
    int ret = delta_buffer_init(&db, 4096);
    XCTAssertEqual(ret, 0, @"delta_buffer_init must succeed");
    XCTAssertNotEqual(db.buf[0], NULL);
    XCTAssertNotEqual(db.buf[1], NULL);
    XCTAssertEqual(db.frame_bytes, 4096u);

    delta_buffer_destroy(&db);
    /* After destroy, buffers should be NULL (no crash) */
    XCTAssertEqual(db.buf[0], NULL);
    XCTAssertEqual(db.buf[1], NULL);
}

- (void)testDeltaXORComputeApplyRoundtrip {
    const size_t frame_bytes = 4096;
    DeltaBuffer db;
    XCTAssertEqual(delta_buffer_init(&db, frame_bytes), 0);

    /* Create frame A (keyframe reference) */
    uint8_t *frameA = (uint8_t *)malloc(frame_bytes);
    for (size_t i = 0; i < frame_bytes; i++) {
        frameA[i] = (uint8_t)(i & 0xFF);
    }

    /* Install frame A as the reference */
    update_keyframe_reference(&db, frameA);

    /* Create frame B (different data) */
    uint8_t *frameB = (uint8_t *)malloc(frame_bytes);
    for (size_t i = 0; i < frame_bytes; i++) {
        frameB[i] = (uint8_t)((i * 3 + 17) & 0xFF);
    }

    /* Compute delta: B vs reference(A) */
    uint8_t *delta = (uint8_t *)malloc(frame_bytes);
    compute_delta(&db, frameB, delta);

    /* Apply delta to A, should reconstruct B */
    uint8_t *reconstructed = (uint8_t *)malloc(frame_bytes);
    apply_delta(delta, frameA, reconstructed, frame_bytes);

    XCTAssertEqual(memcmp(frameB, reconstructed, frame_bytes), 0,
                   @"apply_delta(compute_delta(B, ref=A), A) must reconstruct B");

    free(frameA);
    free(frameB);
    free(delta);
    free(reconstructed);
    delta_buffer_destroy(&db);
}

- (void)testDeltaXORIdenticalFramesCompressWell {
    const size_t frame_bytes = 65536; /* 64 KB */
    DeltaBuffer db;
    XCTAssertEqual(delta_buffer_init(&db, frame_bytes), 0);

    uint8_t *frame = (uint8_t *)malloc(frame_bytes);
    for (size_t i = 0; i < frame_bytes; i++) {
        frame[i] = (uint8_t)(i & 0xFF);
    }

    /* Set reference to same data */
    update_keyframe_reference(&db, frame);

    /* Compute delta of identical frames -- should be all zeros */
    uint8_t *delta = (uint8_t *)malloc(frame_bytes);
    compute_delta(&db, frame, delta);

    /* Verify delta is all zeros */
    int allZero = 1;
    for (size_t i = 0; i < frame_bytes; i++) {
        if (delta[i] != 0) { allZero = 0; break; }
    }
    XCTAssertTrue(allZero, @"Delta of identical frames must be all zeros");

    /* All-zero data should compress extremely well under LZ4 */
    int bound = LZ4_compressBound((int)frame_bytes);
    char *compressed = (char *)malloc((size_t)bound);
    int compressedSize = LZ4_compress_default((const char *)delta, compressed,
                                               (int)frame_bytes, bound);
    XCTAssertGreaterThan(compressedSize, 0);
    /* Compressed size of all-zeros should be tiny relative to input */
    XCTAssertLessThan((size_t)compressedSize, frame_bytes / 100,
                      @"All-zero delta must compress to <1%% of original");

    free(frame);
    free(delta);
    free(compressed);
    delta_buffer_destroy(&db);
}

- (void)testDeltaXORDifferentFramesProduceDelta {
    const size_t frame_bytes = 4096;
    DeltaBuffer db;
    XCTAssertEqual(delta_buffer_init(&db, frame_bytes), 0);

    /* Reference: all 0xAA */
    uint8_t *ref = (uint8_t *)malloc(frame_bytes);
    memset(ref, 0xAA, frame_bytes);
    update_keyframe_reference(&db, ref);

    /* Current: all 0x55 */
    uint8_t *current = (uint8_t *)malloc(frame_bytes);
    memset(current, 0x55, frame_bytes);

    uint8_t *delta = (uint8_t *)malloc(frame_bytes);
    compute_delta(&db, current, delta);

    /* 0xAA ^ 0x55 = 0xFF, so delta should be all 0xFF */
    int allFF = 1;
    for (size_t i = 0; i < frame_bytes; i++) {
        if (delta[i] != 0xFF) { allFF = 0; break; }
    }
    XCTAssertTrue(allFF, @"Delta of 0xAA vs 0x55 must be all 0xFF");

    free(ref);
    free(current);
    free(delta);
    delta_buffer_destroy(&db);
}

- (void)testDeltaBufferSwapsOnUpdate {
    const size_t frame_bytes = 256;
    DeltaBuffer db;
    XCTAssertEqual(delta_buffer_init(&db, frame_bytes), 0);

    int initial_active = db.active;
    XCTAssertEqual(initial_active, 0, @"Initial active index should be 0");

    /* First update: should swap active from 0 to 1 */
    uint8_t dummy[256];
    memset(dummy, 0x42, sizeof(dummy));
    update_keyframe_reference(&db, dummy);
    XCTAssertEqual(db.active, 1, @"After first update, active should be 1");

    /* Second update: should swap active from 1 to 0 */
    memset(dummy, 0x84, sizeof(dummy));
    update_keyframe_reference(&db, dummy);
    XCTAssertEqual(db.active, 0, @"After second update, active should toggle back to 0");

    delta_buffer_destroy(&db);
}

#pragma mark - FrameCompressor

- (void)testFrameCompressorInit {
    FrameCompressorState state;
    size_t frame_bytes = (size_t)(1920 * 1080 * 4);

    int ret = frame_compressor_init(&state, frame_bytes);
    XCTAssertEqual(ret, 0, @"frame_compressor_init must succeed");
    XCTAssertEqual(state.frame_bytes, frame_bytes);
    XCTAssertEqual(state.seq, 0u);
    XCTAssertNotEqual(state.output.buf, NULL);
    XCTAssertGreaterThan(state.output.buf_capacity, 0u);
    XCTAssertNotEqual(state.delta_scratch, NULL);
    XCTAssertNotEqual(state.compress_queue, NULL);

    frame_compressor_destroy(&state);
}

- (void)testFrameCompressorKeyframeCompress {
    const size_t width  = 64;
    const size_t height = 64;
    const size_t frame_bytes = width * height * 4;

    /*
     * __block is required so the block captures a reference to the
     * original state, not a copy. compress_frame modifies state->seq
     * and writes to the out parameter; without __block those changes
     * would be lost when the block's copy goes out of scope.
     */
    __block FrameCompressorState state;
    XCTAssertEqual(frame_compressor_init(&state, frame_bytes), 0);

    IOSurfaceRef surface = createTestSurface(width, height);
    XCTAssertNotEqual(surface, NULL, @"IOSurface creation must succeed");

    /* Fill surface with a known pattern */
    IOSurfaceLock(surface, 0, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    memset(base, 0x42, frame_bytes);
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = NULL;
    CMVideoFormatDescriptionRef fd = NULL;
    CMSampleBufferRef sampleBuf = createSampleBuffer(surface, 1, &pb, &fd);
    XCTAssertNotEqual(sampleBuf, NULL);

    /* Compress on the compressor's queue */
    __block int compressRet = -1;
    dispatch_sync(state.compress_queue, ^{
        compressRet = compress_frame(&state, surface, sampleBuf, &state.output);
    });

    XCTAssertEqual(compressRet, 0, @"First compress_frame must succeed");
    XCTAssertGreaterThan(state.output.compressed_size, 0u);
    XCTAssertTrue(state.output.header.flags & KEYDRD_FLAG_KEYFRAME,
                  @"First frame must be a keyframe");
    XCTAssertEqual(state.output.header.magic, KEYDRD_MAGIC);
    XCTAssertEqual(state.output.header.seq, 0);

    CFRelease(sampleBuf);
    CFRelease(fd);
    CVPixelBufferRelease(pb);
    CFRelease(surface);
    frame_compressor_destroy(&state);
}

- (void)testFrameCompressorDeltaCompress {
    const size_t width  = 64;
    const size_t height = 64;
    const size_t frame_bytes = width * height * 4;

    __block FrameCompressorState state;
    XCTAssertEqual(frame_compressor_init(&state, frame_bytes), 0);

    /* Compress first frame (keyframe).
     * Use varied data so the keyframe has a non-trivial compressed size.
     * If we used uniform data (all 0x42), LZ4 would compress it to ~30 bytes,
     * making even the tiniest delta exceed the 60% fallback threshold. */
    IOSurfaceRef surface1 = createTestSurface(width, height);
    XCTAssertNotEqual(surface1, NULL);

    IOSurfaceLock(surface1, 0, NULL);
    uint8_t *base1 = (uint8_t *)IOSurfaceGetBaseAddress(surface1);
    for (size_t i = 0; i < frame_bytes; i++) {
        base1[i] = (uint8_t)((i * 7 + 13) & 0xFF);
    }
    IOSurfaceUnlock(surface1, 0, NULL);

    CVPixelBufferRef pb1 = NULL;
    CMVideoFormatDescriptionRef fd1 = NULL;
    CMSampleBufferRef sb1 = createSampleBuffer(surface1, 1, &pb1, &fd1);

    dispatch_sync(state.compress_queue, ^{
        compress_frame(&state, surface1, sb1, &state.output);
    });
    XCTAssertTrue(state.output.header.flags & KEYDRD_FLAG_KEYFRAME,
                  @"First frame must be keyframe");

    /* Compress second frame: nearly identical to first, with only a few changed bytes.
     * The mostly-zero delta should compress much smaller than 60% of keyframe. */
    IOSurfaceRef surface2 = createTestSurface(width, height);
    XCTAssertNotEqual(surface2, NULL);

    IOSurfaceLock(surface2, 0, NULL);
    uint8_t *base2 = (uint8_t *)IOSurfaceGetBaseAddress(surface2);
    for (size_t i = 0; i < frame_bytes; i++) {
        base2[i] = (uint8_t)((i * 7 + 13) & 0xFF);
    }
    /* Change just a few pixels so delta stays small */
    base2[0] ^= 0x01;
    base2[100] ^= 0x02;
    IOSurfaceUnlock(surface2, 0, NULL);

    CVPixelBufferRef pb2 = NULL;
    CMVideoFormatDescriptionRef fd2 = NULL;
    CMSampleBufferRef sb2 = createSampleBuffer(surface2, 2, &pb2, &fd2);

    dispatch_sync(state.compress_queue, ^{
        compress_frame(&state, surface2, sb2, &state.output);
    });

    /* Second frame should be delta (not keyframe) since the change is tiny */
    XCTAssertTrue(state.output.header.flags & KEYDRD_FLAG_DELTA,
                  @"Second frame with minor changes should be a delta");
    XCTAssertFalse(state.output.header.flags & KEYDRD_FLAG_KEYFRAME,
                   @"Delta frame must not have keyframe flag");
    XCTAssertEqual(state.output.header.seq, 1);

    CFRelease(sb1); CFRelease(fd1); CVPixelBufferRelease(pb1); CFRelease(surface1);
    CFRelease(sb2); CFRelease(fd2); CVPixelBufferRelease(pb2); CFRelease(surface2);
    frame_compressor_destroy(&state);
}

- (void)testFrameCompressorDeltaFallback {
    const size_t width  = 64;
    const size_t height = 64;
    const size_t frame_bytes = width * height * 4;

    __block FrameCompressorState state;
    XCTAssertEqual(frame_compressor_init(&state, frame_bytes), 0);

    /* First frame: keyframe with uniform data (compresses very small) */
    IOSurfaceRef surface1 = createTestSurface(width, height);
    XCTAssertNotEqual(surface1, NULL);

    IOSurfaceLock(surface1, 0, NULL);
    memset(IOSurfaceGetBaseAddress(surface1), 0x00, frame_bytes);
    IOSurfaceUnlock(surface1, 0, NULL);

    CVPixelBufferRef pb1 = NULL;
    CMVideoFormatDescriptionRef fd1 = NULL;
    CMSampleBufferRef sb1 = createSampleBuffer(surface1, 1, &pb1, &fd1);

    dispatch_sync(state.compress_queue, ^{
        compress_frame(&state, surface1, sb1, &state.output);
    });
    XCTAssertTrue(state.output.header.flags & KEYDRD_FLAG_KEYFRAME);
    size_t keyframeSize = state.output.compressed_size;
    XCTAssertGreaterThan(keyframeSize, 0u);

    /* Second frame: completely different random-ish data.
     * The XOR delta will be very high entropy, exceeding 60% threshold
     * and triggering keyframe fallback. */
    IOSurfaceRef surface2 = createTestSurface(width, height);
    XCTAssertNotEqual(surface2, NULL);

    IOSurfaceLock(surface2, 0, NULL);
    uint8_t *base2 = (uint8_t *)IOSurfaceGetBaseAddress(surface2);
    /* Fill with pseudo-random data that compresses poorly */
    for (size_t i = 0; i < frame_bytes; i++) {
        base2[i] = (uint8_t)((i * 251 + 97) & 0xFF);
    }
    IOSurfaceUnlock(surface2, 0, NULL);

    CVPixelBufferRef pb2 = NULL;
    CMVideoFormatDescriptionRef fd2 = NULL;
    CMSampleBufferRef sb2 = createSampleBuffer(surface2, 2, &pb2, &fd2);

    dispatch_sync(state.compress_queue, ^{
        compress_frame(&state, surface2, sb2, &state.output);
    });

    /* The compressed delta of (random XOR zeros) = random, which is much larger
     * than the keyframe (all zeros compresses to almost nothing).
     * The 60% threshold check should have triggered keyframe fallback. */
    XCTAssertTrue(state.output.header.flags & KEYDRD_FLAG_KEYFRAME,
                  @"Massive scene change should trigger keyframe fallback (keyframe compressed=%zu, "
                  @"delta would exceed 60%% threshold)", keyframeSize);

    CFRelease(sb1); CFRelease(fd1); CVPixelBufferRelease(pb1); CFRelease(surface1);
    CFRelease(sb2); CFRelease(fd2); CVPixelBufferRelease(pb2); CFRelease(surface2);
    frame_compressor_destroy(&state);
}

- (void)testFrameCompressorBufferSizeUsesFrameBytes {
    /*
     * REGRESSION TEST (RD-COMP-05):
     * Verify that compress_frame uses state->frame_bytes, NOT
     * IOSurfaceGetAllocSize(). IOSurfaceGetAllocSize includes row
     * alignment padding and can exceed the delta buffer capacity,
     * causing buffer overreads.
     */
    const size_t width  = 63;  /* Non-power-of-2 to provoke alignment padding */
    const size_t height = 63;
    const size_t frame_bytes = width * height * 4; /* 15876 bytes */

    IOSurfaceRef surface = createTestSurface(width, height);
    XCTAssertNotEqual(surface, NULL);

    size_t allocSize = IOSurfaceGetAllocSize(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);

    /* IOSurface typically aligns rows to 16 or 32 bytes.
     * For width=63, bytesPerRow is likely > width*4 due to alignment. */
    NSLog(@"frame_bytes=%zu, IOSurfaceGetAllocSize=%zu, bytesPerRow=%zu, width*4=%zu",
          frame_bytes, allocSize, bytesPerRow, width * 4);

    /* The key invariant: allocSize may differ from frame_bytes */
    if (allocSize != frame_bytes) {
        NSLog(@"Good: allocSize (%zu) != frame_bytes (%zu) -- alignment padding present",
              allocSize, frame_bytes);
    }

    /* Initialize compressor with OUR frame_bytes (not allocSize) */
    __block FrameCompressorState state;
    XCTAssertEqual(frame_compressor_init(&state, frame_bytes), 0);
    XCTAssertEqual(state.frame_bytes, frame_bytes);

    /* Fill surface -- only touch frame_bytes worth within the actual pixel area */
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
    /* Fill row by row using actual bytesPerRow stride, but only width*4 pixels per row */
    for (size_t row = 0; row < height; row++) {
        memset(base + row * bytesPerRow, 0x42, width * 4);
    }
    IOSurfaceUnlock(surface, 0, NULL);

    CVPixelBufferRef pb = NULL;
    CMVideoFormatDescriptionRef fd = NULL;
    CMSampleBufferRef sb = createSampleBuffer(surface, 1, &pb, &fd);

    /* Compress must not crash even when allocSize > frame_bytes */
    __block int ret = -1;
    dispatch_sync(state.compress_queue, ^{
        ret = compress_frame(&state, surface, sb, &state.output);
    });
    XCTAssertEqual(ret, 0, @"compress_frame must succeed with mismatched allocSize");
    XCTAssertGreaterThan(state.output.compressed_size, 0u);

    CFRelease(sb);
    CFRelease(fd);
    CVPixelBufferRelease(pb);
    CFRelease(surface);
    frame_compressor_destroy(&state);
}

- (void)testFrameCompressorSequenceIncrement {
    const size_t width  = 32;
    const size_t height = 32;
    const size_t frame_bytes = width * height * 4;

    __block FrameCompressorState state;
    XCTAssertEqual(frame_compressor_init(&state, frame_bytes), 0);

    /* Compress 5 frames and verify seq increments */
    for (uint16_t i = 0; i < 5; i++) {
        IOSurfaceRef surface = createTestSurface(width, height);
        XCTAssertNotEqual(surface, NULL);

        IOSurfaceLock(surface, 0, NULL);
        memset(IOSurfaceGetBaseAddress(surface), (int)(0x10 + i), frame_bytes);
        IOSurfaceUnlock(surface, 0, NULL);

        CVPixelBufferRef pb = NULL;
        CMVideoFormatDescriptionRef fd = NULL;
        CMSampleBufferRef sb = createSampleBuffer(surface, i + 1, &pb, &fd);

        __block int ret = -1;
        dispatch_sync(state.compress_queue, ^{
            ret = compress_frame(&state, surface, sb, &state.output);
        });
        XCTAssertEqual(ret, 0);
        XCTAssertEqual(state.output.header.seq, i,
                       @"Frame %u must have seq=%u", i, i);

        CFRelease(sb);
        CFRelease(fd);
        CVPixelBufferRelease(pb);
        CFRelease(surface);
    }

    XCTAssertEqual(state.seq, 5u,
                   @"After 5 frames, internal seq counter must be 5");

    frame_compressor_destroy(&state);
}

@end
