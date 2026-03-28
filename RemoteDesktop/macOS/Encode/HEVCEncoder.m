#import "HEVCEncoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <os/log.h>

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
    int _currentWidth;
    int _currentHeight;
    int _currentFPS;
    int _currentBitrate;
    uint16_t _seq;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = NULL;
        _seq = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Session Management

- (void)startWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate {
    if (_isActive) {
        [self stop];
    }

    _originalWidth = width;
    _originalHeight = height;
    _originalFPS = fps;
    _originalBitrate = bitrate;

    [self _createSessionWithWidth:width height:height fps:fps bitrate:bitrate];
}

- (void)_createSessionWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate {
    _currentWidth = width;
    _currentHeight = height;
    _currentFPS = fps;
    _currentBitrate = bitrate;

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

    /* AverageBitRate -- NOT ConstantBitRate (conflicts with low-latency mode per research) */
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    /* Max keyframe interval (seconds) -- force keyframe at least every 2 seconds */
    float maxKeyframeInterval = 2.0f;
    CFNumberRef keyframeRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &maxKeyframeInterval);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeRef);
    CFRelease(keyframeRef);

    /* Expected frame rate hint */
    CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fps);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    VTCompressionSessionPrepareToEncodeFrames(_session);
    _isActive = YES;

    os_log_info(hevc_log(), "HEVC encoder started: %dx%d @ %dfps, bitrate=%d",
                width, height, fps, bitrate);
}

- (void)stop {
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _isActive = NO;
    os_log_info(hevc_log(), "HEVC encoder stopped");
}

#pragma mark - Encoding

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer timestamp:(CMTime)timestamp {
    if (!_isActive || !_session) return;

    /* frameProperties: nil = let encoder decide keyframe placement */
    OSStatus status = VTCompressionSessionEncodeFrame(
        _session,
        pixelBuffer,
        timestamp,
        kCMTimeInvalid,  /* duration -- invalid = encoder decides */
        NULL,            /* frameProperties -- nil */
        NULL,            /* sourceFrameRefcon */
        NULL             /* infoFlagsOut */
    );

    if (status != noErr) {
        os_log_error(hevc_log(), "VTCompressionSessionEncodeFrame failed: %d", (int)status);
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

    [self _createSessionWithWidth:ecoWidth height:ecoHeight fps:kEcoFPS bitrate:ecoBitrate];

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
                          bitrate:_originalBitrate];

    os_log_info(hevc_log(), "Switched to full quality: %dx%d @ %dfps",
                _originalWidth, _originalHeight, _originalFPS);
}

#pragma mark - Output Callback

static void _hevcOutputCallback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) {
        os_log_error(hevc_log(), "HEVC encode callback error: %d", (int)status);
        return;
    }

    HEVCEncoder *encoder = (__bridge HEVCEncoder *)outputCallbackRefCon;
    if (!encoder.onEncodedFrame) return;

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

    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus accessStatus = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (accessStatus != noErr || !dataPointer || totalLength == 0) return;

    /* Get timestamp */
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    uint64_t tsUs = (uint64_t)(CMTimeGetSeconds(pts) * 1000000.0);

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
    header.reserved = 0;
    header.payload_size = (uint32_t)totalLength;
    header.ts_us = tsUs;
    header.crc32 = 0;  /* CRC computed by transport layer if needed */

    encoder.onEncodedFrame(dataPointer, totalLength, header);
}

@end
