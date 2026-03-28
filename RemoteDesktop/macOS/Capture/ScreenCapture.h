#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FrameCompressor.h"

NS_ASSUME_NONNULL_BEGIN

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

/* Callback block type — called on compress queue with compressed output. */
typedef void (^ScreenCaptureFrameCallback)(CompressOutput *output);

/* Callback block type — called when watchdog detects no frames for >2s. */
typedef void (^ScreenCaptureReauthCallback)(void);

@interface ScreenCapture : NSObject <SCStreamOutput>

/* Whether capture is currently active. */
@property (nonatomic, assign, readonly) BOOL isCapturing;

/* Whether screen recording permission has been granted. */
@property (nonatomic, assign, readonly) BOOL hasPermission;

/* Called after compression with ready-to-send frame. */
@property (nonatomic, copy, nullable) ScreenCaptureFrameCallback onFrame;

/* Called when watchdog detects no frames for >2s and display is not asleep. */
@property (nonatomic, copy, nullable) ScreenCaptureReauthCallback onReauthorizationNeeded;

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

@end

NS_ASSUME_NONNULL_END
