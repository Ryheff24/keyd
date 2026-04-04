#import "HEVCEncoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <stdatomic.h>

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
}

static os_log_t hevc_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.keydrd.encode", "hevc");
    });
    return log;
}

/* ---- Bitrate presets ---- */
static const int kBitrate4K   __attribute__((unused)) = 50000000;  /* 50 Mbps */
static const int kBitrate1080 = 15000000;  /* 15 Mbps */
static const int kBitrate720  =  8000000;  /*  8 Mbps */

/* ---- Eco mode constants ---- */
static const int kEcoFPS = 30;
static const int kEcoMaxWidth1080 = 1920;
static const int kEcoMaxHeight1080 = 1080;
static const int kEcoMaxWidth720 = 1280;
static const int kEcoMaxHeight720 = 720;

@implementation HEVCEncoder {
    VTCompressionSessionRef _session;
    int _originalWidth;
    int _originalHeight;
    int _originalFPS;
    int _originalBitrate;
    float _originalQuality;
    int _currentWidth;
    int _currentHeight;
    int _currentFPS;
    int _currentBitrate;
    float _currentQuality;
    uint16_t _seq;
    atomic_int _pendingFrameCount;
    atomic_bool _forceNextKeyframe;
    int _skipLogCount;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = NULL;
        _seq = 0;
        _pendingFrameCount = 0;
        _forceNextKeyframe = false;
        _skipLogCount = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Session Management

- (void)startWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate quality:(float)quality {
    if (_isActive) {
        [self stop];
    }

    _originalWidth = width;
    _originalHeight = height;
    _originalFPS = fps;
    _originalBitrate = bitrate;
    _originalQuality = quality;
    _pendingFrameCount = 0;
    _forceNextKeyframe = false;

    [self _createSessionWithWidth:width height:height fps:fps bitrate:bitrate quality:quality];
}

- (void)_createSessionWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate quality:(float)quality {
    _currentWidth = width;
    _currentHeight = height;
    _currentFPS = fps;
    _currentBitrate = bitrate;
    _currentQuality = quality;
    _quality = quality;

    /* Encoder specification: enable low-latency rate control */
    NSDictionary *encoderSpec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
    };

    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCMVideoCodecType_HEVC,
        (__bridge CFDictionaryRef)encoderSpec,
        NULL,  /* source pixel buffer attributes -- NULL to accept any format */
        kCFAllocatorDefault,
        _hevcOutputCallback,
        (__bridge void *)self,
        &_session
    );

    if (status != noErr) {
        os_log_error(hevc_log(), "Failed to create VTCompressionSession: %d", (int)status);
        return;
    }

    /* Session properties for low-latency HEVC encoding */
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);

    /* Force zero-frame encoder delay — output each frame immediately.
     * Without this, the encoder may buffer 1-2 frames for rate control,
     * adding ~16ms to the pipeline latency. */
    int maxDelay = 0;
    CFNumberRef delayRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxDelay);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxFrameDelayCount, delayRef);
    CFRelease(delayRef);

    if (quality > 0) {
        /* Quality-based encoding (CRF-like): let the encoder decide bitrate.
         * Fixes bitrate undershoot on low-complexity desktop content where
         * AverageBitRate=150Mbps but actual output is only 6Mbps.
         * Quality 0.85 gives excellent text clarity at ~20-40Mbps actual. */
        Float32 qualityVal = (Float32)quality;
        CFNumberRef qualityRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &qualityVal);
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_Quality, qualityRef);
        CFRelease(qualityRef);
        os_log_info(hevc_log(), "Using quality-based encoding: quality=%.2f", quality);
    } else {
        /* AverageBitRate -- NOT ConstantBitRate (conflicts with low-latency mode per research) */
        CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrate);
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
        CFRelease(bitrateRef);
        os_log_info(hevc_log(), "Using bitrate-based encoding: bitrate=%d", bitrate);
    }

    /* Max keyframe interval (seconds).
     * Recovery now requests an IDR immediately when the iPad loses decoder
     * continuity, so the steady-state stream does not need frequent periodic
     * keyframes. Longer spacing avoids repeated 100KB+ DTLS bursts that were
     * knocking the Wi-Fi path into backlog and fallback. */
    float maxKeyframeInterval = 300.0f;
    CFNumberRef keyframeRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &maxKeyframeInterval);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeRef);
    CFRelease(keyframeRef);

    /* Expected frame rate hint */
    CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fps);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    /* No DataRateLimits — AverageBitRate/Quality handles rate control.
     * Oversized keyframes that exceed UDP chunking limits (>255 chunks)
     * fall back to TCP in sendMediaFrameToiPad. */

    VTCompressionSessionPrepareToEncodeFrames(_session);
    _isActive = YES;

    os_log_info(hevc_log(), "HEVC encoder started: %dx%d @ %dfps, bitrate=%d, quality=%.2f",
                width, height, fps, bitrate, quality);
}

- (void)stop {
    /* Set inactive FIRST to prevent callbacks from delivering frames
     * while we're tearing down the session. */
    _isActive = NO;
    _pendingFrameCount = 0;
    _forceNextKeyframe = false;
    _onEncodedFrame = nil;

    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    os_log_info(hevc_log(), "HEVC encoder stopped");
}

- (void)requestKeyframe {
    if (!_isActive || !_session) return;
    atomic_store_explicit(&_forceNextKeyframe, true, memory_order_relaxed);
}

- (void)updateStreamingRateWithFPS:(int)fps bitrate:(int)bitrate reason:(NSString *)reason {
    if (!_isActive || !_session) {
        os_log(hevc_log(), "HEVC adaptive update skipped: inactive session (fps=%d bitrate=%d reason=%{public}s)",
               fps, bitrate, reason.UTF8String ?: "none");
        return;
    }

    int clampedFPS = MAX(1, fps);
    int clampedBitrate = MAX(250000, bitrate);

    BOOL changed = NO;
    if (clampedFPS != _currentFPS) {
        CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &clampedFPS);
        OSStatus fpsStatus = VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
        CFRelease(fpsRef);
        if (fpsStatus == noErr) {
            _currentFPS = clampedFPS;
            changed = YES;
        } else {
            os_log_error(hevc_log(), "HEVC adaptive fps update failed: status=%d targetFPS=%d reason=%{public}s",
                         (int)fpsStatus, clampedFPS, reason.UTF8String ?: "none");
        }
    }

    if (_currentQuality <= 0.0f && clampedBitrate != _currentBitrate) {
        CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &clampedBitrate);
        OSStatus bitrateStatus = VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
        CFRelease(bitrateRef);
        if (bitrateStatus == noErr) {
            _currentBitrate = clampedBitrate;
            changed = YES;
        } else {
            os_log_error(hevc_log(), "HEVC adaptive bitrate update failed: status=%d targetBitrate=%d reason=%{public}s",
                         (int)bitrateStatus, clampedBitrate, reason.UTF8String ?: "none");
        }
    }

    if (changed) {
        os_log_info(hevc_log(), "HEVC adaptive update applied: fps=%d bitrate=%d reason=%{public}s",
                    _currentFPS, _currentBitrate, reason.UTF8String ?: "none");
    }
}

#pragma mark - Encoding

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer timestamp:(CMTime)timestamp captureTimestampUs:(uint64_t)captureTimestampUs {
    if (!_isActive || !_session) {
        static int skipCount = 0;
        if (skipCount < 3) {
            os_log_error(hevc_log(), "encodePixelBuffer: skipped (isActive=%{public}s, session=%{public}p)",
                         _isActive ? "YES" : "NO", _session);
        }
        skipCount++;
        return;
    }

    /* Frame skip: drop frames when encoder pipeline is saturated.
     * Only allow 1 frame in-flight. With >2, keyframe stalls cascade into
     * 150ms+ gaps (measured: 30 stutters, 46ms jitter at >2 threshold).
     * >1 keeps p95 encode under 35ms and jitter under 5ms. */
    int pending = atomic_load_explicit(&_pendingFrameCount, memory_order_relaxed);
    if (pending > 1) {
        _skipLogCount++;
        if (_skipLogCount <= 5 || _skipLogCount % 100 == 0) {
            os_log(hevc_log(), "encodePixelBuffer: SKIPPED frame (pending=%d, total skipped=%d)",
                   pending, _skipLogCount);
        }
        return;
    }

    static int encodeCount = 0;
    if (encodeCount < 5) {
        size_t w = CVPixelBufferGetWidth(pixelBuffer);
        size_t h = CVPixelBufferGetHeight(pixelBuffer);
        os_log(hevc_log(), "encodePixelBuffer: encoding frame #%d (%zux%zu) ts=%.3fs pending=%d",
               encodeCount, w, h, CMTimeGetSeconds(timestamp), pending);
    }
    encodeCount++;

    /* Pipeline latency probe: capture to encode-submit (should be ~0ms) */
    if (captureTimestampUs > 0) {
        uint64_t nowUs = keydrd_host_time_us();
        uint64_t submitElapsedMs = (nowUs - captureTimestampUs) / 1000;
        static int submitProbeCount = 0;
        if (submitProbeCount < 10 || submitProbeCount % 100 == 0) {
            os_log(hevc_log(), "LATENCY-PROBE encode-submit: %llu ms since capture", submitElapsedMs);
        }
        submitProbeCount++;
    }

    /* Pass capture host-time timestamp through sourceFrameRefcon so the
     * output callback can stamp ts_us at capture time, not encode-output time. */
    uint64_t *tsRef = malloc(sizeof(uint64_t));
    if (tsRef) {
        *tsRef = captureTimestampUs;
    }

    /* Increment pending count BEFORE submitting to encoder */
    atomic_fetch_add_explicit(&_pendingFrameCount, 1, memory_order_relaxed);

    CFDictionaryRef frameProperties = NULL;
    if (atomic_exchange_explicit(&_forceNextKeyframe, false, memory_order_relaxed)) {
        const void *keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        const void *values[] = { kCFBooleanTrue };
        frameProperties = CFDictionaryCreate(kCFAllocatorDefault,
                                             keys,
                                             values,
                                             1,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
        os_log_info(hevc_log(), "Forcing HEVC keyframe on next encode");
    }

    OSStatus status = VTCompressionSessionEncodeFrame(
        _session,
        pixelBuffer,
        timestamp,
        kCMTimeInvalid,  /* duration -- invalid = encoder decides */
        frameProperties,
        tsRef,           /* sourceFrameRefcon -- capture timestamp */
        NULL             /* infoFlagsOut */
    );

    if (frameProperties) {
        CFRelease(frameProperties);
    }

    if (status != noErr) {
        os_log_error(hevc_log(), "VTCompressionSessionEncodeFrame failed: %d", (int)status);
        atomic_fetch_sub_explicit(&_pendingFrameCount, 1, memory_order_relaxed);
        free(tsRef);
    }
}

#pragma mark - Mode Switching

- (void)switchToEcoMode {
    if (_isEcoMode) return;
    _isEcoMode = YES;

    [self stop];

    /* Determine eco resolution based on original dimensions */
    int ecoWidth, ecoHeight, ecoBitrate;
    if (_originalWidth > kEcoMaxWidth1080 || _originalHeight > kEcoMaxHeight1080) {
        /* Source is > 1080p (e.g., 4K) -> scale to 1080p */
        ecoWidth = kEcoMaxWidth1080;
        ecoHeight = kEcoMaxHeight1080;
        ecoBitrate = kBitrate1080;
    } else {
        /* Source is <= 1080p -> scale to 720p */
        ecoWidth = kEcoMaxWidth720;
        ecoHeight = kEcoMaxHeight720;
        ecoBitrate = kBitrate720;
    }

    [self _createSessionWithWidth:ecoWidth height:ecoHeight fps:kEcoFPS bitrate:ecoBitrate quality:0];

    os_log_info(hevc_log(), "Switched to eco mode: %dx%d @ %dfps, bitrate=%d",
                ecoWidth, ecoHeight, kEcoFPS, ecoBitrate);
}

- (void)switchToFullQuality {
    if (!_isEcoMode) return;
    _isEcoMode = NO;

    [self stop];
    [self _createSessionWithWidth:_originalWidth
                           height:_originalHeight
                              fps:_originalFPS
                          bitrate:_originalBitrate
                          quality:_originalQuality];

    os_log_info(hevc_log(), "Switched to full quality: %dx%d @ %dfps",
                _originalWidth, _originalHeight, _originalFPS);
}

#pragma mark - Output Callback

static void _hevcOutputCallback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer) {
    /* Decrement pending frame count at the very beginning of callback.
     * This unblocks the next encodePixelBuffer call as early as possible. */
    HEVCEncoder *encoder = (__bridge HEVCEncoder *)outputCallbackRefCon;
    if (encoder) {
        atomic_fetch_sub_explicit(&encoder->_pendingFrameCount, 1, memory_order_relaxed);
    }

    /* Extract capture timestamp passed via sourceFrameRefcon, free in all paths */
    uint64_t captureTimestampUs = 0;
    if (sourceFrameRefCon) {
        captureTimestampUs = *(uint64_t *)sourceFrameRefCon;
        free(sourceFrameRefCon);
    }

    if (status != noErr) {
        os_log_error(hevc_log(), "HEVC encode callback error: %d", (int)status);
        return;
    }
    if (!sampleBuffer) {
        /* Informational callback (no output) — not an error */
        return;
    }
    if (!encoder || !encoder.isActive || !encoder.onEncodedFrame) return;

    /* Pipeline latency probe: how long from capture to encode-complete? */
    if (captureTimestampUs > 0) {
        uint64_t nowUs = keydrd_host_time_us();
        uint64_t encodeElapsedMs = (nowUs - captureTimestampUs) / 1000;
        static int probeCount = 0;
        if (probeCount < 10 || probeCount % 100 == 0) {
            os_log(hevc_log(), "LATENCY-PROBE encode-complete: %llu ms since capture (seq pending)", encodeElapsedMs);
        }
        probeCount++;
    }

    /* Check if this is a keyframe */
    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = NULL;
        if (CFDictionaryGetValueIfPresent(dict,
                                          kCMSampleAttachmentKey_NotSync,
                                          (const void **)&notSync)) {
            isKeyframe = !CFBooleanGetValue(notSync);
        } else {
            /* If kCMSampleAttachmentKey_NotSync is absent, it IS a sync frame */
            isKeyframe = YES;
        }
    }

    /* Extract encoded data from CMSampleBuffer */
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return;

    size_t sliceLength = 0;
    char *slicePointer = NULL;
    OSStatus accessStatus = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &sliceLength, &slicePointer);
    if (accessStatus != noErr || !slicePointer || sliceLength == 0) return;

    /*
     * For keyframes, prepend VPS/SPS/PPS from the format description.
     * VTCompressionSession stores parameter sets in the CMFormatDescription,
     * NOT in the CMBlockBuffer data. The decoder needs them inline.
     * Format: [4-byte length][NAL unit] for each parameter set, then slice data.
     */
    const void *outputData = slicePointer;
    size_t totalLength = sliceLength;
    uint8_t *keyframeBuf = NULL;

    if (isKeyframe) {
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmtDesc) {
            size_t paramSetCount = 0;
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmtDesc, 0, NULL, NULL, &paramSetCount, NULL);

            /* Calculate total size needed for parameter sets */
            size_t paramTotalSize = 0;
            for (size_t i = 0; i < paramSetCount; i++) {
                const uint8_t *paramSet = NULL;
                size_t paramSetSize = 0;
                if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmtDesc, i, &paramSet, &paramSetSize, NULL, NULL) == noErr) {
                    paramTotalSize += 4 + paramSetSize; /* 4-byte length prefix + NAL data */
                }
            }

            if (paramTotalSize > 0) {
                totalLength = paramTotalSize + sliceLength;
                keyframeBuf = malloc(totalLength);
                if (keyframeBuf) {
                    size_t writeOffset = 0;
                    for (size_t i = 0; i < paramSetCount; i++) {
                        const uint8_t *paramSet = NULL;
                        size_t paramSetSize = 0;
                        if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmtDesc, i, &paramSet, &paramSetSize, NULL, NULL) == noErr) {
                            /* Write 4-byte big-endian length prefix */
                            uint32_t netLen = htonl((uint32_t)paramSetSize);
                            memcpy(keyframeBuf + writeOffset, &netLen, 4);
                            writeOffset += 4;
                            memcpy(keyframeBuf + writeOffset, paramSet, paramSetSize);
                            writeOffset += paramSetSize;
                        }
                    }
                    /* Append slice data */
                    memcpy(keyframeBuf + writeOffset, slicePointer, sliceLength);
                    outputData = keyframeBuf;

                    static BOOL loggedOnce = NO;
                    if (!loggedOnce) {
                        os_log(hevc_log(), "Keyframe: prepended %zu param sets (%zu bytes) + %zu slice = %zu total",
                               paramSetCount, paramTotalSize, sliceLength, totalLength);
                        loggedOnce = YES;
                    }
                }
            }
        }
    }

    /* Capture-time host clock (microseconds) stamped in
     * ScreenCapture.didOutputSampleBuffer, threaded via sourceFrameRefcon.
     * Consistent with LZ4 path and comparable to iPad host-time timestamps. */
    uint64_t tsUs = captureTimestampUs;

    /* Build MediaFrameHeader */
    MediaFrameHeader header;
    header.magic = KEYDRD_MAGIC;
    header.flags = KEYDRD_FLAG_HEVC;  /* HEVC flag always set */
    if (isKeyframe) {
        header.flags |= KEYDRD_FLAG_KEYFRAME;
    }
    header.flags |= KEYDRD_FLAG_LAST_CHUNK;  /* Single chunk for now */
    header.seq = encoder->_seq++;
    header.chunk_idx = 0;
    header.chunk_total = 1;
    header.payload_size = (uint32_t)totalLength;
    header.ts_us = tsUs;
    header.crc32 = 0;  /* CRC computed by transport layer if needed */

    encoder.onEncodedFrame(outputData, totalLength, header);

    if (keyframeBuf) {
        free(keyframeBuf);
    }
}

@end
