#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FrameCompressor.h"

NS_ASSUME_NONNULL_BEGIN

/* Shared stress-scene renderer used by both synthetic capture and real-capture test windows.
 * Draws a full-frame moving-box pattern where every tile changes each frame. */
FOUNDATION_EXPORT void KeydRenderStressScene(CGContextRef ctx, CGSize size, uint64_t frameIndex);
FOUNDATION_EXPORT uint64_t KeydStressSceneSignature(CGSize size, uint64_t frameIndex);
FOUNDATION_EXPORT uint32_t KeydStressSceneCRC(size_t pixelWidth, size_t pixelHeight, uint64_t frameIndex);

/*
 * ScreenCapture.h
 * ScreenCaptureKit-based display capture with LZ4+delta compression.
 *
 * SCStream delegate that captures the primary display at Retina
 * resolution, 120fps, BGRA pixel format. Frames are compressed via
 * FrameCompressor (LZ4 keyframe or XOR delta) and delivered to the
 * onFrame callback ready for transport.
 *
 * Includes a 2-second watchdog timer that detects silent capture
 * stops (e.g. Sequoia re-authorization, display sleep).
 */

/* Callback block type — called on compress queue with compressed output (LZ4 mode). */
typedef void (^ScreenCaptureFrameCallback)(CompressOutput *output);

/* Callback block type — called with raw pixel buffer for HEVC encoding.
 * pixelBuffer + sampleBuffer are retained for the callback duration.
 * captureTimestampUs: host-time microseconds (CACurrentMediaTime/mach time) at capture arrival. */
typedef void (^ScreenCapturePixelBufferCallback)(CVPixelBufferRef pixelBuffer, CMTime timestamp, uint64_t captureTimestampUs);

/* Callback block type — called when watchdog detects no frames for >2s. */
typedef void (^ScreenCaptureReauthCallback)(void);

@interface ScreenCapture : NSObject <SCStreamOutput>

/* Whether capture is currently active. */
@property (nonatomic, assign, readonly) BOOL isCapturing;

/* Whether screen recording permission has been granted. */
@property (nonatomic, assign, readonly) BOOL hasPermission;

/* Called after compression with ready-to-send frame (LZ4 mode). */
@property (nonatomic, copy, nullable) ScreenCaptureFrameCallback onFrame;

/* LZ4 gate (tla/DeltaSync.tla GateBeforeCompress). Called on the serial compress queue
 * immediately before compress_frame. Returning NO skips this frame WITHOUT compressing it,
 * so the delta reference advances only on frames that will be sent. A compressed delta
 * must never be dropped afterwards: the iPad's XOR reference would desynchronize. */
@property (nonatomic, copy, nullable) BOOL (^shouldCompressFrame)(void);

/* Called with raw pixel buffer before compression (HEVC mode).
 * Set this when HEVC encoding is active. When set AND onFrame is set,
 * BOTH callbacks fire — onPixelBuffer first, then onFrame. */
@property (nonatomic, copy, nullable) ScreenCapturePixelBufferCallback onPixelBuffer;

/* Called when watchdog detects no frames for >2s and display is not asleep. */
@property (nonatomic, copy, nullable) ScreenCaptureReauthCallback onReauthorizationNeeded;

/* Override capture resolution. Set before startCapture.
 * If 0, uses the display's native pixel dimensions. */
@property (nonatomic, assign) uint32_t captureWidth;
@property (nonatomic, assign) uint32_t captureHeight;

/* Target capture cadence. Defaults to 120fps and can be lowered by the
 * transport so frames are produced evenly at the actual send rate. */
@property (nonatomic, assign) uint32_t captureFPS;

/* Optional file-backed synthetic source for test runs.
 * When set, startCapture generates frames from this file instead of live display capture.
 * Supported by common macOS still image formats plus video files readable by AVFoundation. */
@property (nonatomic, copy, nullable) NSString *testCaptureFilePath;

/* Optional procedural worst-case synthetic source for test runs.
 * When enabled, startCapture generates full-frame pixel patterns where every pixel changes
 * on every frame to stress the compression + encode path. */
@property (nonatomic, assign) BOOL testCaptureStressMode;

/*
 * Request screen recording permission.
 * On macOS Sequoia+, CGRequestScreenCaptureAccess triggers system prompt.
 */
- (void)requestPermission:(void (^)(BOOL granted))completion;

/*
 * Start capturing the primary display.
 * Asynchronous — calls SCShareableContent on background queue
 * (can block 3-10s on Sequoia per known pitfall).
 */
- (void)startCapture;

/*
 * Stop capture, invalidate watchdog, destroy compressor.
 */
- (void)stopCapture;

/*
 * Update capture resolution on a running stream (no stop/start needed).
 * Uses SCStream.updateConfiguration to avoid Sequoia re-authorization prompts.
 * Safe to call while capturing. No-op if not currently capturing.
 */
- (void)updateCaptureResolution:(uint32_t)width height:(uint32_t)height;

/*
 * Make the next LZ4 frame a keyframe (tla/DeltaSync.tla KeyOnConnect): called when a USB
 * connection (re)connects, since frames compressed before it never reach it in order.
 * Runs on the compress queue, ahead of any later compress.
 */
- (void)requestLZ4Keyframe;

@end

NS_ASSUME_NONNULL_END
