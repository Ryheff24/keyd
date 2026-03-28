#pragma once

/*
 * HEVCEncoder.h
 * VideoToolbox HEVC hardware encoder for wireless/eco mode.
 *
 * Uses VTCompressionSession with:
 *   - AverageBitRate (NOT ConstantBitRate -- conflicts with low-latency mode)
 *   - Low-latency rate control enabled
 *   - No B-frames (AllowFrameReordering = false)
 *   - RealTime priority
 *
 * Eco mode: tears down session, recreates at reduced resolution + 30fps.
 * The encoder adapts to whatever pixel buffers it receives -- resolution
 * changes happen at the capture layer (SCStreamConfiguration).
 */

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "protocol.h"

NS_ASSUME_NONNULL_BEGIN

/// Callback block invoked for each encoded HEVC frame.
/// @param data    Pointer to encoded H.265 NAL unit data (valid only during callback).
/// @param len     Length of encoded data in bytes.
/// @param header  Pre-filled MediaFrameHeader with HEVC flag set.
typedef void (^HEVCEncoderOutputBlock)(const void *data, size_t len, MediaFrameHeader header);

@interface HEVCEncoder : NSObject

/// Whether the encoder session is currently active.
@property (nonatomic, assign, readonly) BOOL isActive;

/// Whether the encoder is in eco mode (reduced resolution + 30fps).
@property (nonatomic, assign, readonly) BOOL isEcoMode;

/// Callback for encoded frames. Set before calling -start.
@property (nonatomic, copy, nullable) HEVCEncoderOutputBlock onEncodedFrame;

/// Start the encoder with the given parameters.
/// @param width   Frame width in pixels.
/// @param height  Frame height in pixels.
/// @param fps     Target frames per second.
/// @param bitrate Target average bitrate in bits per second.
- (void)startWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate;

/// Encode a single pixel buffer. Must be called on the compress queue.
/// @param pixelBuffer CVPixelBuffer in BGRA format.
/// @param timestamp   Capture timestamp for this frame.
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer timestamp:(CMTime)timestamp;

/// Stop the encoder and release the compression session.
- (void)stop;

/// Switch to eco mode: recreates session at reduced resolution + 30fps.
/// Eco mode uses HEVC at 1080p (or 720p if source is <= 1080p) at 30Hz.
- (void)switchToEcoMode;

/// Restore full quality: recreates session at original resolution and fps.
- (void)switchToFullQuality;

@end

NS_ASSUME_NONNULL_END
