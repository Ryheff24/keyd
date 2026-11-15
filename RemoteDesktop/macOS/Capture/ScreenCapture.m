#import "ScreenCapture.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <libkern/OSAtomic.h>
#import <zlib.h>

static os_log_t sc_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.keydrd", "capture");
    });
    return log;
}

/* Watchdog interval: fire every 2 seconds */
static const uint64_t kWatchdogIntervalNs = 2ULL * NSEC_PER_SEC;

/* Frame timeout: if no frame for >2s and display is awake, flag re-auth */
static const NSTimeInterval kFrameTimeoutSeconds = 2.0;
static const int32_t kSyntheticFPS = 120;
static const uint32_t kSyntheticCatchUpBurstMax = 3;
/* Striped parallel LZ4 (tla/StripeSync.tla): one stripe per M1 Max performance core.
 * The iPad must decode KEYDRD_FLAG_STRIPED (both apps are built and deployed together). */
static const int kLZ4Stripes = 8;

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
}

uint64_t KeydStressSceneSignature(CGSize size, uint64_t frameIndex) {
    uint64_t sig = 1469598103934665603ULL;
    const uint64_t vals[] = {
        (uint64_t)llround(size.width),
        (uint64_t)llround(size.height),
        frameIndex,
        (frameIndex * 2654435761ULL) ^ 0x9e3779b97f4a7c15ULL
    };
    for (size_t i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
        sig ^= vals[i];
        sig *= 1099511628211ULL;
    }
    return sig;
}

static CGContextRef KeydCreateStressBitmapContext(uint8_t *base,
                                                  size_t width,
                                                  size_t height,
                                                  size_t bytesPerRow) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base,
                                             width,
                                             height,
                                             8,
                                             bytesPerRow,
                                             colorSpace,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    return ctx;
}

void KeydRenderStressScene(CGContextRef ctx, CGSize size, uint64_t frameIndex) {
    CGFloat width = size.width;
    CGFloat height = size.height;
    if (!ctx || width <= 0 || height <= 0) {
        return;
    }

    const int cols = 5;
    const int rows = 3;
    CGFloat tileW = ceil(width / (CGFloat)cols);
    CGFloat tileH = ceil(height / (CGFloat)rows);
    CGFloat t = (CGFloat)frameIndex / (CGFloat)kSyntheticFPS;

    CGContextSetRGBFillColor(ctx, 0.03, 0.04, 0.06, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            CGFloat phase = t * 0.19 + (CGFloat)col * 0.13 + (CGFloat)row * 0.17;
            CGFloat hue = fmod(phase, 1.0);
            CGFloat sat = 0.65 + 0.25 * sin((t * 1.7) + (CGFloat)(row * 2 + col));
            CGFloat val = 0.55 + 0.30 * cos((t * 1.1) + (CGFloat)(col * 3 - row));
            CGFloat x = (CGFloat)col * tileW;
            CGFloat y = (CGFloat)row * tileH;
            CGRect rect = CGRectInset(CGRectMake(x, y, tileW, tileH), 6.0, 6.0);

            NSColor *fill = [NSColor colorWithHue:hue
                                       saturation:MAX(0.0, MIN(1.0, sat))
                                       brightness:MAX(0.0, MIN(1.0, val))
                                            alpha:1.0];
            CGContextSetFillColorWithColor(ctx, fill.CGColor);
            CGContextFillRect(ctx, rect);

            CGFloat borderHue = fmod(hue + 0.18, 1.0);
            NSColor *border = [NSColor colorWithHue:borderHue saturation:0.95 brightness:1.0 alpha:0.95];
            CGContextSetStrokeColorWithColor(ctx, border.CGColor);
            CGContextSetLineWidth(ctx, 8.0);
            CGContextStrokeRect(ctx, CGRectInset(rect, 4.0, 4.0));
        }
    }

    CGFloat bandW = width * 0.18;
    CGFloat bandH = height * 0.22;
    CGFloat bandX = fmod(t * width * 0.27, MAX(width + bandW, 1.0)) - bandW * 0.5;
    CGFloat bandY = fmod(t * height * 0.21, MAX(height + bandH, 1.0)) - bandH * 0.5;

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.12);
    CGContextFillRect(ctx, CGRectMake(bandX, 0, bandW, height));
    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.16);
    CGContextFillRect(ctx, CGRectMake(0, bandY, width, bandH));
}

uint32_t KeydStressSceneCRC(size_t pixelWidth, size_t pixelHeight, uint64_t frameIndex) {
    if (pixelWidth == 0 || pixelHeight == 0) {
        return 0;
    }

    size_t bytesPerRow = pixelWidth * 4;
    size_t byteCount = bytesPerRow * pixelHeight;
    uint8_t *buffer = calloc(1, byteCount);
    if (!buffer) {
        return 0;
    }

    CGContextRef ctx = KeydCreateStressBitmapContext(buffer, pixelWidth, pixelHeight, bytesPerRow);
    if (!ctx) {
        free(buffer);
        return 0;
    }

    KeydRenderStressScene(ctx, CGSizeMake(pixelWidth, pixelHeight), frameIndex);
    CGContextRelease(ctx);

    uint32_t crc = (uint32_t)crc32(0L, (const Bytef *)buffer, (uInt)byteCount);
    free(buffer);
    return crc;
}

static uint32_t KeydCRCForBuffer(const uint8_t *base,
                                 size_t width,
                                 size_t height,
                                 size_t bytesPerRow) {
    if (!base || width == 0 || height == 0) {
        return 0;
    }

    size_t packedBytesPerRow = width * 4;
    uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
    for (size_t row = 0; row < height; row++) {
        crc = (uint32_t)crc32(crc, (const Bytef *)(base + row * bytesPerRow), (uInt)packedBytesPerRow);
    }
    return crc;
}

static uint32_t KeydCRCForPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) {
        return 0;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    uint32_t crc = KeydCRCForBuffer(base, width, height, bytesPerRow);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return crc;
}

@implementation ScreenCapture {
    /* Strong reference to SCStream — required because SCStream holds its
     * output weakly in Sonoma+ (Pitfall 7). We MUST store this strongly. */
    SCStream *_stream;

    /* Compressor state (pure C) */
    FrameCompressorState _compressor;
    BOOL _compressorInitialized;

    /* Dispatch queues */
    dispatch_queue_t _captureQueue;   /* high-priority serial — SCStream output */
    dispatch_queue_t _compressQueue;  /* high-priority serial — compression */

    /* Frame watchdog */
    dispatch_source_t _watchdogTimer;
    NSTimeInterval _lastFrameTime;
    BOOL _needsReauthorization;

    /* Synthetic file-backed test capture */
    dispatch_source_t _syntheticTimer;
    CGImageRef _syntheticImage;
    AVAsset *_syntheticAsset;
    AVAssetTrack *_syntheticVideoTrack;
    AVAssetReader *_syntheticVideoReader;
    AVAssetReaderTrackOutput *_syntheticVideoOutput;
    CVPixelBufferRef _syntheticLastVideoFrame;
    CVPixelBufferPoolRef _syntheticBufferPool;
    size_t _syntheticPoolWidth;
    size_t _syntheticPoolHeight;
    Float64 _syntheticSourceFPS;
    BOOL _syntheticIsVideo;
    CIContext *_syntheticCIContext;
    uint64_t _syntheticScheduleStartUs;
    uint64_t _syntheticEmittedFrames;
    uint64_t _syntheticCatchupEvents;
    uint64_t _syntheticCatchupFrames;
    uint64_t _syntheticCatchupCappedEvents;
    uint64_t _syntheticEmitAttempts;
    uint64_t _syntheticEmitFailures;
    uint64_t _syntheticEmitConsecutiveFailures;

    /* Cached background for static-image mode.
     * CGContextDrawImage is CPU-only and takes ~24ms at 2752x1786.
     * We render once, then memcpy (~2ms) for each subsequent frame. */
    uint8_t *_cachedBackgroundPixels;
    size_t _cachedBackgroundSize;
    size_t _cachedBackgroundBytesPerRow;

    /* Capture state */
    BOOL _isCapturing;

    /* LZ4 frame skip: only allow 1 frame on the compress queue at a time.
     * SCStream delivers 120fps but LZ4 compress takes ~5ms per frame.
     * Without skip, the queue backs up and pipeline latency grows to 100ms+. */
    volatile int32_t _lz4CompressPending;
}

@synthesize isCapturing = _isCapturing;

- (void)_drainCompressionPipeline {
    /* stopCapture and synthetic reconfigure can race with in-flight LZ4 work.
     * Drain both queues before freeing compressor-owned buffers. */
    if (_compressQueue) {
        dispatch_sync(_compressQueue, ^{});
    }
    if (_compressorInitialized && _compressor.compress_queue) {
        dispatch_sync(_compressor.compress_queue, ^{});
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCapturing = NO;
        _compressorInitialized = NO;
        _needsReauthorization = NO;
        _lastFrameTime = 0;
        self.captureFPS = kSyntheticFPS;
        _syntheticScheduleStartUs = 0;
        _syntheticEmittedFrames = 0;
        _syntheticCatchupEvents = 0;
        _syntheticCatchupFrames = 0;
        _syntheticCatchupCappedEvents = 0;
        _syntheticEmitAttempts = 0;
        _syntheticEmitFailures = 0;
        _syntheticEmitConsecutiveFailures = 0;

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _captureQueue = dispatch_queue_create("com.keydrd.capture", attr);
        _compressQueue = dispatch_queue_create("com.keydrd.compress.sc", attr);
        _syntheticCIContext = [CIContext contextWithOptions:nil];
    }
    return self;
}

- (void)dealloc {
    [self stopCapture];
}

#pragma mark - Permission

- (BOOL)hasPermission {
    return CGPreflightScreenCaptureAccess();
}

- (void)requestPermission:(void (^)(BOOL granted))completion {
    BOOL preflight = CGPreflightScreenCaptureAccess();
    if (preflight) {
        if (completion) completion(YES);
        return;
    }

    /* CGRequestScreenCaptureAccess triggers the system prompt on Sequoia+.
     * It returns synchronously with the result. */
    BOOL granted = CGRequestScreenCaptureAccess();
    if (completion) completion(granted);
}

#pragma mark - Start Capture

- (void)startCapture {
    if (_isCapturing) {
        os_log_info(sc_log(), "Already capturing, ignoring startCapture");
        return;
    }

    if (self.testCaptureFilePath.length > 0 || self.testCaptureStressMode) {
        if (self.testCaptureStressMode) {
            os_log(sc_log(), "startCapture: using procedural stress source");
        } else {
            os_log(sc_log(), "startCapture: using synthetic file-backed source: %{public}@",
                   self.testCaptureFilePath);
        }
        [self _startSyntheticCapture];
        return;
    }

    os_log(sc_log(), "startCapture: requesting shareable content (hasPermission=%{public}s, onPixelBuffer=%{public}s)",
           [self hasPermission] ? "YES" : "NO",
           self.onPixelBuffer ? "SET" : "nil");

    /* Fetch shareable content on background queue — can block 3-10s on Sequoia (Pitfall 1) */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            if (error || !content) {
                os_log_error(sc_log(), "Failed to get shareable content: %{public}@ (error code: %ld)",
                             error ? error.localizedDescription : @"nil content",
                             (long)(error ? error.code : 0));
                return;
            }

            /* Find primary display */
            SCDisplay *primaryDisplay = nil;
            for (SCDisplay *display in content.displays) {
                if (CGDisplayIsMain(display.displayID)) {
                    primaryDisplay = display;
                    break;
                }
            }

            if (!primaryDisplay && content.displays.count > 0) {
                /* Fallback to first display */
                primaryDisplay = content.displays[0];
            }

            if (!primaryDisplay) {
                os_log_error(sc_log(), "No display found for capture");
                return;
            }

            [self _setupStreamWithContent:content display:primaryDisplay];
        }];
    });
}

- (void)_setupStreamWithContent:(SCShareableContent *)content
                        display:(SCDisplay *)display {
    /* Configure capture */
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.pixelFormat = kCVPixelFormatType_32BGRA;  /* RD-CAP-06: BGRA throughout */
    uint32_t targetFPS = MAX((uint32_t)1, self.captureFPS > 0 ? self.captureFPS : (uint32_t)kSyntheticFPS);
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)targetFPS);
    config.queueDepth = 3;
    config.showsCursor = YES;
    /* Determine capture resolution.
     * If captureWidth/Height are set (from iPad viewport report), use those —
     * SCStream downscales from native display to target resolution in hardware.
     * Otherwise use the display's native pixel dimensions. */
    size_t pixelWidth, pixelHeight;
    if (self.captureWidth > 0 && self.captureHeight > 0) {
        pixelWidth = self.captureWidth;
        pixelHeight = self.captureHeight;
        os_log(sc_log(), "Using viewport override resolution: %lux%lu",
               (unsigned long)pixelWidth, (unsigned long)pixelHeight);
    } else {
        CGDisplayModeRef displayMode = CGDisplayCopyDisplayMode(display.displayID);
        if (displayMode) {
            pixelWidth  = CGDisplayModeGetPixelWidth(displayMode);
            pixelHeight = CGDisplayModeGetPixelHeight(displayMode);
            CGDisplayModeRelease(displayMode);
        } else {
            pixelWidth  = display.width * 2;
            pixelHeight = display.height * 2;
        }
    }
    config.width = pixelWidth;
    config.height = pixelHeight;

    os_log(sc_log(), "Setting up capture: %lux%lu @%ufps BGRA (display points: %lux%lu)",
           (unsigned long)pixelWidth, (unsigned long)pixelHeight,
           targetFPS,
           (unsigned long)display.width, (unsigned long)display.height);

    /* Create content filter with the display — no excluded apps */
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                      excludingWindows:@[]];

    /* Create stream and store strongly (Pitfall 7: SCStream holds delegate weakly) */
    _stream = [[SCStream alloc] initWithFilter:filter
                                 configuration:config
                                      delegate:nil];

    NSError *addError = nil;
    [_stream addStreamOutput:self
                        type:SCStreamOutputTypeScreen
          sampleHandlerQueue:_captureQueue
                       error:&addError];
    if (addError) {
        os_log_error(sc_log(), "Failed to add stream output: %{public}@",
                     addError.localizedDescription);
        _stream = nil;
        return;
    }

    /* Initialize compressor: BGRA = 4 bytes/pixel at full Retina resolution */
    size_t frameBytes = pixelWidth * pixelHeight * 4;
    if (frame_compressor_init_striped(&self->_compressor, frameBytes, kLZ4Stripes) != 0) {
        os_log_error(sc_log(), "Failed to initialize frame compressor");
        _stream = nil;
        return;
    }
    _compressorInitialized = YES;

    /* Start capture */
    os_log(sc_log(), "Starting SCStream capture (stream=%{public}p)", _stream);
    [_stream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            os_log_error(sc_log(), "Failed to start capture: %{public}@ (code=%ld, domain=%{public}@)",
                         error.localizedDescription, (long)error.code,
                         error.domain);
            self->_stream = nil;
            return;
        }

        os_log(sc_log(), "Screen capture started successfully — waiting for first frame");
        self->_isCapturing = YES;
        self->_lastFrameTime = [NSDate timeIntervalSinceReferenceDate];

        /* Start watchdog timer */
        [self _startWatchdog];
    }];
}

#pragma mark - Stop Capture

- (void)stopCapture {
    if (!_isCapturing && !_stream && !_syntheticTimer) {
        return;
    }

    _isCapturing = NO;

    /* Invalidate watchdog */
    if (_watchdogTimer) {
        dispatch_source_cancel(_watchdogTimer);
        _watchdogTimer = nil;
    }

    /* Stop stream */
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                os_log_error(sc_log(), "Error stopping capture: %{public}@",
                             error.localizedDescription);
            }
        }];
        _stream = nil;
    }

    if (_syntheticTimer) {
        dispatch_source_cancel(_syntheticTimer);
        _syntheticTimer = nil;
    }

    [self _drainCompressionPipeline];

    /* Destroy compressor */
    if (_compressorInitialized) {
        frame_compressor_destroy(&_compressor);
        _compressorInitialized = NO;
    }

    if (_syntheticBufferPool) {
        CVPixelBufferPoolRelease(_syntheticBufferPool);
        _syntheticBufferPool = nil;
        _syntheticPoolWidth = 0;
        _syntheticPoolHeight = 0;
    }

    if (_syntheticImage) {
        CGImageRelease(_syntheticImage);
        _syntheticImage = NULL;
    }
    if (_cachedBackgroundPixels) {
        free(_cachedBackgroundPixels);
        _cachedBackgroundPixels = NULL;
        _cachedBackgroundSize = 0;
        _cachedBackgroundBytesPerRow = 0;
    }
    if (_syntheticLastVideoFrame) {
        CVPixelBufferRelease(_syntheticLastVideoFrame);
        _syntheticLastVideoFrame = NULL;
    }
    if (_syntheticVideoReader) {
        [_syntheticVideoReader cancelReading];
        _syntheticVideoReader = nil;
    }
    _syntheticVideoOutput = nil;
    _syntheticVideoTrack = nil;
    _syntheticAsset = nil;
    _syntheticSourceFPS = 0;
    _syntheticIsVideo = NO;

    os_log_info(sc_log(),
                "Screen capture stopped (synthetic emitted=%llu catchup[events=%llu frames=%llu capped=%llu] emit[attempts=%llu failures=%llu consecutive=%llu])",
                _syntheticEmittedFrames,
                _syntheticCatchupEvents,
                _syntheticCatchupFrames,
                _syntheticCatchupCappedEvents,
                _syntheticEmitAttempts,
                _syntheticEmitFailures,
                _syntheticEmitConsecutiveFailures);

    _syntheticScheduleStartUs = 0;
    _syntheticEmittedFrames = 0;
    _syntheticCatchupEvents = 0;
    _syntheticCatchupFrames = 0;
    _syntheticCatchupCappedEvents = 0;
    _syntheticEmitAttempts = 0;
    _syntheticEmitFailures = 0;
    _syntheticEmitConsecutiveFailures = 0;
}

- (void)updateCaptureResolution:(uint32_t)width height:(uint32_t)height {
    if (!_isCapturing || !_stream) {
        os_log(sc_log(), "updateCaptureResolution: not capturing, storing %ux%u for next start",
               width, height);
        self.captureWidth = width;
        self.captureHeight = height;
        return;
    }

    if (_syntheticTimer) {
        os_log(sc_log(), "Updating synthetic capture resolution to %ux%u", width, height);
        self.captureWidth = width;
        self.captureHeight = height;

        if (_syntheticBufferPool) {
            CVPixelBufferPoolRelease(_syntheticBufferPool);
            _syntheticBufferPool = nil;
            _syntheticPoolWidth = 0;
            _syntheticPoolHeight = 0;
        }

        /* Invalidate cached background so it re-renders at new resolution */
        if (_cachedBackgroundPixels) {
            free(_cachedBackgroundPixels);
            _cachedBackgroundPixels = NULL;
            _cachedBackgroundSize = 0;
            _cachedBackgroundBytesPerRow = 0;
        }

        [self _drainCompressionPipeline];

        if (_compressorInitialized) {
            frame_compressor_destroy(&_compressor);
            _compressorInitialized = NO;
        }

        size_t frameBytes = (size_t)width * (size_t)height * 4;
        if (frameBytes > 0 && frame_compressor_init_striped(&_compressor, frameBytes, kLZ4Stripes) == 0) {
            _compressorInitialized = YES;
        } else {
            os_log_error(sc_log(), "Failed to reinitialize compressor for synthetic resolution %ux%u",
                         width, height);
        }
        return;
    }

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = width;
    config.height = height;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    uint32_t targetFPS = MAX((uint32_t)1, self.captureFPS > 0 ? self.captureFPS : (uint32_t)kSyntheticFPS);
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)targetFPS);
    config.queueDepth = 3;
    config.showsCursor = YES;

    os_log(sc_log(), "Updating capture resolution to %ux%u @%ufps (live reconfigure)", width, height, targetFPS);

    [_stream updateConfiguration:config completionHandler:^(NSError * _Nullable error) {
        if (error) {
            os_log_error(sc_log(), "updateConfiguration failed: %{public}@", error.localizedDescription);
        } else {
            os_log(sc_log(), "Capture resolution updated to %ux%u", width, height);
        }
    }];

    self.captureWidth = width;
    self.captureHeight = height;
}

- (BOOL)_initializeCompressorForWidth:(size_t)pixelWidth height:(size_t)pixelHeight {
    [self _drainCompressionPipeline];

    if (_compressorInitialized) {
        frame_compressor_destroy(&_compressor);
        _compressorInitialized = NO;
    }

    size_t frameBytes = pixelWidth * pixelHeight * 4;
    if (frameBytes == 0) {
        os_log_error(sc_log(), "Cannot initialize compressor for zero-sized frame");
        return NO;
    }

    if (frame_compressor_init_striped(&_compressor, frameBytes, kLZ4Stripes) != 0) {
        os_log_error(sc_log(), "Failed to initialize frame compressor for %lux%lu",
                     (unsigned long)pixelWidth, (unsigned long)pixelHeight);
        return NO;
    }

    _compressorInitialized = YES;
    return YES;
}

- (BOOL)_resetSyntheticVideoReader {
    if (!_syntheticAsset || !_syntheticVideoTrack) {
        return NO;
    }

    if (_syntheticVideoReader) {
        [_syntheticVideoReader cancelReading];
        _syntheticVideoReader = nil;
    }
    _syntheticVideoOutput = nil;

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_syntheticAsset error:&error];
    if (!reader || error) {
        os_log_error(sc_log(), "Failed to create synthetic video reader: %{public}@",
                     error.localizedDescription ?: @"unknown error");
        return NO;
    }

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_syntheticVideoTrack
                                                                        outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        os_log_error(sc_log(), "Cannot add synthetic video track output");
        return NO;
    }

    [reader addOutput:output];
    if (![reader startReading]) {
        os_log_error(sc_log(), "Failed to start synthetic video reader: %{public}@",
                     reader.error.localizedDescription ?: @"unknown error");
        return NO;
    }

    _syntheticVideoReader = reader;
    _syntheticVideoOutput = output;
    return YES;
}

- (BOOL)_loadSyntheticSourceIfNeeded {
    if (self.testCaptureStressMode) {
        return YES;
    }
    if (_syntheticImage || _syntheticIsVideo) {
        return YES;
    }
    if (self.testCaptureFilePath.length == 0) {
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:self.testCaptureFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        os_log_error(sc_log(), "Synthetic capture file does not exist: %{public}@",
                     self.testCaptureFilePath);
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count > 0) {
        _syntheticAsset = asset;
        _syntheticVideoTrack = videoTracks.firstObject;
        _syntheticIsVideo = YES;
        _syntheticSourceFPS = _syntheticVideoTrack.nominalFrameRate > 1.0 ? _syntheticVideoTrack.nominalFrameRate : 60.0;
        _syntheticSourceFPS = MIN(_syntheticSourceFPS, (Float64)kSyntheticFPS);

        if (![self _resetSyntheticVideoReader]) {
            _syntheticVideoTrack = nil;
            _syntheticAsset = nil;
            _syntheticIsVideo = NO;
            _syntheticSourceFPS = 0;
            return NO;
        }

        CGSize naturalSize = _syntheticVideoTrack.naturalSize;
        CGRect transformedRect = CGRectApplyAffineTransform(CGRectMake(0, 0, naturalSize.width, naturalSize.height),
                                                            _syntheticVideoTrack.preferredTransform);
        size_t width = (size_t)llround(fabs(transformedRect.size.width));
        size_t height = (size_t)llround(fabs(transformedRect.size.height));
        os_log(sc_log(), "Loaded synthetic capture video: %zux%zu @%.1ffps",
               width, height, _syntheticSourceFPS);
        return YES;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    if (!image) {
        os_log_error(sc_log(), "Failed to open synthetic capture file: %{public}@",
                     self.testCaptureFilePath);
        return NO;
    }

    CGRect proposedRect = CGRectMake(0, 0, image.size.width, image.size.height);
    _syntheticImage = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (_syntheticImage) {
        CGImageRetain(_syntheticImage);
    }

    if (!_syntheticImage) {
        os_log_error(sc_log(), "Failed to decode synthetic capture image: %{public}@",
                     self.testCaptureFilePath);
        return NO;
    }

    os_log(sc_log(), "Loaded synthetic capture image: %zux%zu",
           CGImageGetWidth(_syntheticImage), CGImageGetHeight(_syntheticImage));
    return YES;
}

- (void)_resolveSyntheticDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight {
    size_t pixelWidth = self.captureWidth;
    size_t pixelHeight = self.captureHeight;

    if (pixelWidth > 0 && pixelHeight > 0) {
        *outWidth = pixelWidth;
        *outHeight = pixelHeight;
        return;
    }

    if (_syntheticIsVideo && _syntheticVideoTrack) {
        CGSize naturalSize = _syntheticVideoTrack.naturalSize;
        CGRect transformedRect = CGRectApplyAffineTransform(CGRectMake(0, 0, naturalSize.width, naturalSize.height),
                                                            _syntheticVideoTrack.preferredTransform);
        pixelWidth = (size_t)llround(fabs(transformedRect.size.width));
        pixelHeight = (size_t)llround(fabs(transformedRect.size.height));
    } else if (_syntheticImage) {
        pixelWidth = CGImageGetWidth(_syntheticImage);
        pixelHeight = CGImageGetHeight(_syntheticImage);
    } else {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
        if (mode) {
            pixelWidth = CGDisplayModeGetPixelWidth(mode);
            pixelHeight = CGDisplayModeGetPixelHeight(mode);
            CGDisplayModeRelease(mode);
        }
    }

    if (pixelWidth == 0 || pixelHeight == 0) {
        pixelWidth = 1920;
        pixelHeight = 1080;
    }

    *outWidth = pixelWidth;
    *outHeight = pixelHeight;
}

- (BOOL)_ensureSyntheticBufferPoolForWidth:(size_t)width height:(size_t)height {
    if (_syntheticBufferPool && _syntheticPoolWidth == width && _syntheticPoolHeight == height) {
        return YES;
    }

    if (_syntheticBufferPool) {
        CVPixelBufferPoolRelease(_syntheticBufferPool);
        _syntheticBufferPool = nil;
    }

    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *pixelAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };

    CVReturn status = CVPixelBufferPoolCreate(NULL,
                                              (__bridge CFDictionaryRef)poolAttrs,
                                              (__bridge CFDictionaryRef)pixelAttrs,
                                              &_syntheticBufferPool);
    if (status != kCVReturnSuccess || !_syntheticBufferPool) {
        os_log_error(sc_log(), "Failed to create synthetic pixel buffer pool: %d", status);
        return NO;
    }

    _syntheticPoolWidth = width;
    _syntheticPoolHeight = height;
    return YES;
}

- (CVPixelBufferRef)_copyNextSyntheticVideoFrame {
    if (!_syntheticIsVideo || !_syntheticVideoOutput) {
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_syntheticVideoOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
        if (_syntheticVideoReader.status == AVAssetReaderStatusCompleted ||
            _syntheticVideoReader.status == AVAssetReaderStatusFailed) {
            if (![self _resetSyntheticVideoReader]) {
                return NULL;
            }
            sampleBuffer = [_syntheticVideoOutput copyNextSampleBuffer];
        }
    }

    if (sampleBuffer) {
        CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (frame) {
            CVPixelBufferRetain(frame);
            if (_syntheticLastVideoFrame) {
                CVPixelBufferRelease(_syntheticLastVideoFrame);
            }
            _syntheticLastVideoFrame = frame;
        }
        CFRelease(sampleBuffer);
    }

    if (_syntheticLastVideoFrame) {
        CVPixelBufferRetain(_syntheticLastVideoFrame);
        return _syntheticLastVideoFrame;
    }

    return NULL;
}

- (CVPixelBufferRef)_createSyntheticPixelBufferWithWidth:(size_t)width
                                                  height:(size_t)height
                                              frameIndex:(uint64_t)frameIndex {
    if (![self _ensureSyntheticBufferPoolForWidth:width height:height]) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _syntheticBufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        os_log_error(sc_log(), "Failed to allocate synthetic pixel buffer: %d", status);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    /* Desktop-realistic mode: render the background once via CGContextDrawImage
     * (~24ms), cache it, then memcpy (~2ms) for each subsequent frame.
     * Only the cursor region changes per frame, producing ~5-50KB LZ4 deltas. */

    size_t bufferSize = bytesPerRow * height;
    if (!_cachedBackgroundPixels || _cachedBackgroundSize != bufferSize ||
        _cachedBackgroundBytesPerRow != bytesPerRow) {
        /* Render background once and cache */
        free(_cachedBackgroundPixels);
        _cachedBackgroundPixels = (uint8_t *)malloc(bufferSize);
        _cachedBackgroundSize = bufferSize;
        _cachedBackgroundBytesPerRow = bytesPerRow;

        if (!_cachedBackgroundPixels) {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            return NULL;
        }

        CGContextRef ctx = KeydCreateStressBitmapContext(_cachedBackgroundPixels, width, height, bytesPerRow);
        if (!ctx) {
            free(_cachedBackgroundPixels);
            _cachedBackgroundPixels = NULL;
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            os_log_error(sc_log(), "Failed to create synthetic bitmap context");
            return NULL;
        }

        /* Dark background */
        CGContextSetRGBFillColor(ctx, 0.12, 0.12, 0.14, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

        /* Draw the source image scaled to cover (no pan/zoom animation) */
        CGFloat imageW = (CGFloat)CGImageGetWidth(_syntheticImage);
        CGFloat imageH = (CGFloat)CGImageGetHeight(_syntheticImage);
        CGFloat coverScale = MAX((CGFloat)width / MAX(imageW, 1.0),
                                 (CGFloat)height / MAX(imageH, 1.0));
        CGFloat drawW = imageW * coverScale;
        CGFloat drawH = imageH * coverScale;
        CGFloat drawX = ((CGFloat)width - drawW) * 0.5;
        CGFloat drawY = ((CGFloat)height - drawH) * 0.5;
        CGContextDrawImage(ctx, CGRectMake(drawX, drawY, drawW, drawH), _syntheticImage);

        CGContextRelease(ctx);
        os_log(sc_log(), "Cached synthetic background: %zux%zu (%zu bytes)",
               width, height, bufferSize);
    }

    /* Skip the cached background memcpy — we overwrite 100% of pixels below.
     *
     * Two regions, no per-pixel branching (split into row segments):
     * 1. Scrolling gradient (85%) — structured, compressible LZ4 delta (~200KB)
     * 2. "Video window" (15%) — per-pixel PRNG, incompressible delta (~3MB)
     * Total: ~3.2MB per frame. At USB 3 ~400MB/s, 3.2MB × 120fps = 384MB/s. */
    {
        uint32_t fi = (uint32_t)frameIndex;
        uint32_t *pixels32 = (uint32_t *)base;
        size_t pixelsPerRow = bytesPerRow / 4;

        /* Video window: centered, ~15% of pixels.
         * ~39% width × ~39% height ≈ 15%. */
        size_t vidW = width * 39 / 100;
        size_t vidH = height * 39 / 100;
        size_t vidX = (width - vidW) / 2;
        size_t vidY = (height - vidH) / 2;
        size_t vidXEnd = vidX + vidW;
        size_t vidYEnd = vidY + vidH;

        for (size_t row = 0; row < height; row++) {
            uint32_t *rowOut = pixels32 + row * pixelsPerRow;
            uint32_t rowBase = (uint32_t)row + fi * 3;

            if (row >= vidY && row < vidYEnd) {
                /* Row intersects video window: 3 segments */
                /* Left gradient */
                for (size_t col = 0; col < vidX; col++) {
                    uint32_t v = rowBase + (uint32_t)col;
                    rowOut[col] = 0xFF000000u | ((uint32_t)(uint8_t)(v*7) << 16) |
                                  ((uint32_t)(uint8_t)(v*13+fi) << 8) | (uint8_t)(v*19+fi*3);
                }
                /* Middle: video PRNG (branchless tight loop) */
                uint32_t noise = (uint32_t)row * 2654435761u + fi * 1664525u;
                for (size_t col = vidX; col < vidXEnd; col++) {
                    noise = noise * 1664525u + (uint32_t)col;
                    noise ^= noise >> 16;
                    rowOut[col] = 0xFF000000u | (noise & 0x00FFFFFFu);
                }
                /* Right gradient */
                for (size_t col = vidXEnd; col < width; col++) {
                    uint32_t v = rowBase + (uint32_t)col;
                    rowOut[col] = 0xFF000000u | ((uint32_t)(uint8_t)(v*7) << 16) |
                                  ((uint32_t)(uint8_t)(v*13+fi) << 8) | (uint8_t)(v*19+fi*3);
                }
            } else {
                /* Full gradient row (no video intersection) */
                for (size_t col = 0; col < width; col++) {
                    uint32_t v = rowBase + (uint32_t)col;
                    rowOut[col] = 0xFF000000u | ((uint32_t)(uint8_t)(v*7) << 16) |
                                  ((uint32_t)(uint8_t)(v*13+fi) << 8) | (uint8_t)(v*19+fi*3);
                }
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (CVPixelBufferRef)_createStressPixelBufferWithWidth:(size_t)width
                                               height:(size_t)height
                                           frameIndex:(uint64_t)frameIndex {
    if (![self _ensureSyntheticBufferPoolForWidth:width height:height]) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _syntheticBufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        os_log_error(sc_log(), "Failed to allocate stress pixel buffer: %d", status);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGContextRef ctx = KeydCreateStressBitmapContext(base, width, height, bytesPerRow);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        os_log_error(sc_log(), "Failed to create stress bitmap context");
        return NULL;
    }

    KeydRenderStressScene(ctx, CGSizeMake(width, height), frameIndex);
    CGContextRelease(ctx);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (CVPixelBufferRef)_createSyntheticVideoPixelBufferWithWidth:(size_t)width
                                                       height:(size_t)height
                                             sourcePixelBuffer:(CVPixelBufferRef)sourcePixelBuffer {
    if (!sourcePixelBuffer) {
        return NULL;
    }
    if (![self _ensureSyntheticBufferPoolForWidth:width height:height]) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _syntheticBufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        os_log_error(sc_log(), "Failed to allocate synthetic video pixel buffer: %d", status);
        return NULL;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:sourcePixelBuffer];
    if (!image) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    if (_syntheticVideoTrack) {
        image = [image imageByApplyingTransform:_syntheticVideoTrack.preferredTransform];
        CGRect transformedExtent = image.extent;
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(transformedExtent),
                                                                                 -CGRectGetMinY(transformedExtent))];
    }

    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || extent.size.width <= 0 || extent.size.height <= 0) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CGFloat scale = MAX((CGFloat)width / extent.size.width, (CGFloat)height / extent.size.height);
    CGFloat scaledWidth = extent.size.width * scale;
    CGFloat scaledHeight = extent.size.height * scale;
    CGFloat tx = ((CGFloat)width - scaledWidth) * 0.5;
    CGFloat ty = ((CGFloat)height - scaledHeight) * 0.5;
    CGAffineTransform transform = CGAffineTransformIdentity;
    transform = CGAffineTransformTranslate(transform, tx, ty);
    transform = CGAffineTransformScale(transform, scale, scale);
    image = [image imageByApplyingTransform:transform];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_syntheticCIContext render:image
                toCVPixelBuffer:pixelBuffer
                         bounds:CGRectMake(0, 0, width, height)
                     colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    return pixelBuffer;
}

- (CMSampleBufferRef)_createSyntheticSampleBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                     frameIndex:(uint64_t)frameIndex {
    uint32_t targetFPS = MAX((uint32_t)1, self.captureFPS > 0 ? self.captureFPS : (uint32_t)kSyntheticFPS);
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &format);
    if (formatStatus != noErr || !format) {
        os_log_error(sc_log(), "Failed to create synthetic format description: %d", (int)formatStatus);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .presentationTimeStamp = CMTimeMake((int64_t)frameIndex, (int32_t)targetFPS),
        .decodeTimeStamp = kCMTimeInvalid,
        .duration = CMTimeMake(1, (int32_t)targetFPS),
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(NULL,
                                                                     pixelBuffer,
                                                                     format,
                                                                     &timing,
                                                                     &sampleBuffer);
    CFRelease(format);
    if (sampleStatus != noErr || !sampleBuffer) {
        os_log_error(sc_log(), "Failed to create synthetic sample buffer: %d", (int)sampleStatus);
        return NULL;
    }

    return sampleBuffer;
}

- (BOOL)_emitSyntheticFrameAtIndex:(uint64_t)frameIndex {
    if (!_isCapturing) {
        return NO;
    }

    size_t pixelWidth = 0;
    size_t pixelHeight = 0;
    [self _resolveSyntheticDimensionsWidth:&pixelWidth height:&pixelHeight];
    if (pixelWidth == 0 || pixelHeight == 0) {
        os_log_error(sc_log(), "Synthetic emit failed: frame=%llu reason=invalid-dimensions width=%lu height=%lu",
                     frameIndex, (unsigned long)pixelWidth, (unsigned long)pixelHeight);
        return NO;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    if (self.testCaptureStressMode) {
        pixelBuffer = [self _createStressPixelBufferWithWidth:pixelWidth
                                                       height:pixelHeight
                                                   frameIndex:frameIndex];
    } else if (_syntheticIsVideo) {
        CVPixelBufferRef sourcePixelBuffer = [self _copyNextSyntheticVideoFrame];
        if (!sourcePixelBuffer) {
            os_log_error(sc_log(), "Synthetic emit failed: frame=%llu reason=video-source-unavailable", frameIndex);
            return NO;
        }
        pixelBuffer = [self _createSyntheticVideoPixelBufferWithWidth:pixelWidth
                                                               height:pixelHeight
                                                     sourcePixelBuffer:sourcePixelBuffer];
        CVPixelBufferRelease(sourcePixelBuffer);
    } else {
        if (!_syntheticImage) {
            os_log_error(sc_log(), "Synthetic emit failed: frame=%llu reason=missing-static-image", frameIndex);
            return NO;
        }
        pixelBuffer = [self _createSyntheticPixelBufferWithWidth:pixelWidth
                                                          height:pixelHeight
                                                      frameIndex:frameIndex];
    }
    if (!pixelBuffer) {
        os_log_error(sc_log(), "Synthetic emit failed: frame=%llu reason=create-pixelbuffer-failed", frameIndex);
        return NO;
    }

    if (frameIndex < 10 || frameIndex % 120 == 0) {
        uint64_t sig = KeydStressSceneSignature(CGSizeMake(pixelWidth, pixelHeight), frameIndex);
        uint32_t sceneCRC = self.testCaptureStressMode ? KeydStressSceneCRC(pixelWidth, pixelHeight, frameIndex) : 0;
        uint32_t sourceCRC = KeydCRCForPixelBuffer(pixelBuffer);
        os_log(sc_log(), "FRAME-CHECK source synthetic frame=%llu sig=%{public}016llx scene_crc=%08x source_crc=%08x size=%lux%lu",
               frameIndex, sig, sceneCRC, sourceCRC, (unsigned long)pixelWidth, (unsigned long)pixelHeight);
    }

    CMSampleBufferRef sampleBuffer = [self _createSyntheticSampleBufferForPixelBuffer:pixelBuffer
                                                                            frameIndex:frameIndex];
    CVPixelBufferRelease(pixelBuffer);
    if (!sampleBuffer) {
        os_log_error(sc_log(), "Synthetic emit failed: frame=%llu reason=create-samplebuffer-failed", frameIndex);
        return NO;
    }

    [self _handleCapturedSampleBuffer:sampleBuffer ofType:SCStreamOutputTypeScreen];
    CFRelease(sampleBuffer);
    return YES;
}

- (void)_startSyntheticCapture {
    if (![self _loadSyntheticSourceIfNeeded]) {
        return;
    }

    size_t pixelWidth = 0;
    size_t pixelHeight = 0;
    [self _resolveSyntheticDimensionsWidth:&pixelWidth height:&pixelHeight];
    if (pixelWidth == 0 || pixelHeight == 0) {
        os_log_error(sc_log(), "Synthetic capture has invalid dimensions");
        return;
    }

    if (![self _initializeCompressorForWidth:pixelWidth height:pixelHeight]) {
        return;
    }

    self.captureWidth = (uint32_t)pixelWidth;
    self.captureHeight = (uint32_t)pixelHeight;
    _isCapturing = YES;
    _lastFrameTime = [NSDate timeIntervalSinceReferenceDate];
    [self _startWatchdog];

    __block uint64_t frameIndex = 0;
    double timerFPSValue = MAX(1.0, (double)(self.captureFPS > 0 ? self.captureFPS : (uint32_t)kSyntheticFPS));
    if (_syntheticIsVideo && _syntheticSourceFPS > 1.0) {
        timerFPSValue = MIN(timerFPSValue, _syntheticSourceFPS);
    }
    uint64_t timerIntervalNs = (uint64_t)llround((double)NSEC_PER_SEC / timerFPSValue);
    uint64_t timerIntervalUs = MAX((uint64_t)1, timerIntervalNs / 1000ULL);
    _syntheticScheduleStartUs = keydrd_host_time_us();
    _syntheticEmittedFrames = 0;
    _syntheticCatchupEvents = 0;
    _syntheticCatchupFrames = 0;
    _syntheticCatchupCappedEvents = 0;
    _syntheticEmitAttempts = 0;
    _syntheticEmitFailures = 0;
    _syntheticEmitConsecutiveFailures = 0;
    _syntheticTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    dispatch_source_set_timer(_syntheticTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              timerIntervalNs,
                              NSEC_PER_MSEC * 1);

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_syntheticTimer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        uint64_t nowUs = keydrd_host_time_us();
        uint64_t elapsedUs = nowUs - strongSelf->_syntheticScheduleStartUs;
        uint64_t expectedFrames = (elapsedUs / timerIntervalUs) + 1;
        uint64_t emittedFrames = strongSelf->_syntheticEmittedFrames;
        uint64_t backlogFrames = expectedFrames > emittedFrames ? (expectedFrames - emittedFrames) : 1;
        uint64_t framesThisTick = MIN((uint64_t)kSyntheticCatchUpBurstMax, MAX((uint64_t)1, backlogFrames));

        if (framesThisTick > 1) {
            strongSelf->_syntheticCatchupEvents++;
            strongSelf->_syntheticCatchupFrames += (framesThisTick - 1);
            if (backlogFrames > framesThisTick) {
                strongSelf->_syntheticCatchupCappedEvents++;
            }
            os_log(sc_log(),
                   "Synthetic timer catch-up: expected=%llu emitted=%llu backlog=%llu emitNow=%llu cap=%u lagUs=%llu catchup[events=%llu frames=%llu capped=%llu]",
                   expectedFrames,
                   emittedFrames,
                   backlogFrames,
                   framesThisTick,
                   kSyntheticCatchUpBurstMax,
                   expectedFrames > emittedFrames ? (expectedFrames - emittedFrames) * timerIntervalUs : 0,
                   strongSelf->_syntheticCatchupEvents,
                   strongSelf->_syntheticCatchupFrames,
                   strongSelf->_syntheticCatchupCappedEvents);
        } else if (backlogFrames > framesThisTick) {
            strongSelf->_syntheticCatchupCappedEvents++;
            os_log(sc_log(),
                   "Synthetic timer catch-up capped: expected=%llu emitted=%llu backlog=%llu emitNow=%llu cap=%u lagUs=%llu catchup[events=%llu frames=%llu capped=%llu]",
                   expectedFrames,
                   emittedFrames,
                   backlogFrames,
                   framesThisTick,
                   kSyntheticCatchUpBurstMax,
                   expectedFrames > emittedFrames ? (expectedFrames - emittedFrames) * timerIntervalUs : 0,
                   strongSelf->_syntheticCatchupEvents,
                   strongSelf->_syntheticCatchupFrames,
                   strongSelf->_syntheticCatchupCappedEvents);
        } else if (strongSelf->_syntheticEmittedFrames < 10 || strongSelf->_syntheticEmittedFrames % 600 == 0) {
            os_log(sc_log(),
                   "Synthetic timer steady: expected=%llu emitted=%llu backlog=%llu emitNow=1 lagUs=%llu",
                   expectedFrames,
                   emittedFrames,
                   backlogFrames,
                   expectedFrames > emittedFrames ? (expectedFrames - emittedFrames) * timerIntervalUs : 0);
        }

        uint64_t emittedThisTick = 0;
        for (uint64_t i = 0; i < framesThisTick; i++) {
            strongSelf->_syntheticEmitAttempts++;
            BOOL emitted = [strongSelf _emitSyntheticFrameAtIndex:frameIndex];
            if (!emitted) {
                strongSelf->_syntheticEmitFailures++;
                strongSelf->_syntheticEmitConsecutiveFailures++;
                os_log_error(sc_log(),
                             "Synthetic timer emit failure: frame=%llu tickAttempt=%llu/%llu expected=%llu emitted=%llu backlog=%llu lagUs=%llu emit[attempts=%llu failures=%llu consecutive=%llu]",
                             frameIndex,
                             i + 1,
                             framesThisTick,
                             expectedFrames,
                             strongSelf->_syntheticEmittedFrames,
                             backlogFrames,
                             expectedFrames > strongSelf->_syntheticEmittedFrames ? (expectedFrames - strongSelf->_syntheticEmittedFrames) * timerIntervalUs : 0,
                             strongSelf->_syntheticEmitAttempts,
                             strongSelf->_syntheticEmitFailures,
                             strongSelf->_syntheticEmitConsecutiveFailures);
                break;
            }
            if (strongSelf->_syntheticEmitConsecutiveFailures > 0) {
                os_log(sc_log(),
                       "Synthetic timer emit recovered: frame=%llu consecutiveFailures=%llu expected=%llu emitted=%llu",
                       frameIndex,
                       strongSelf->_syntheticEmitConsecutiveFailures,
                       expectedFrames,
                       strongSelf->_syntheticEmittedFrames);
                strongSelf->_syntheticEmitConsecutiveFailures = 0;
            }
            frameIndex++;
            strongSelf->_syntheticEmittedFrames++;
            emittedThisTick++;
        }
        if (emittedThisTick < framesThisTick) {
            os_log_error(sc_log(),
                         "Synthetic timer partial tick: expected=%llu emitted=%llu backlog=%llu attempted=%llu succeeded=%llu lagUs=%llu emit[attempts=%llu failures=%llu]",
                         expectedFrames,
                         strongSelf->_syntheticEmittedFrames,
                         backlogFrames,
                         framesThisTick,
                         emittedThisTick,
                         expectedFrames > strongSelf->_syntheticEmittedFrames ? (expectedFrames - strongSelf->_syntheticEmittedFrames) * timerIntervalUs : 0,
                         strongSelf->_syntheticEmitAttempts,
                         strongSelf->_syntheticEmitFailures);
        }
    });
    dispatch_resume(_syntheticTimer);

    int timerFPS = (int)llround(timerFPSValue);
    os_log(sc_log(), "Synthetic capture started: %lux%lu @%dfps (%{public}s)",
           (unsigned long)pixelWidth, (unsigned long)pixelHeight,
           timerFPS,
           self.testCaptureStressMode ? "procedural stress" : (_syntheticIsVideo ? "video playback" : self.testCaptureFilePath.UTF8String));
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    [self _handleCapturedSampleBuffer:sampleBuffer ofType:type];
}

- (void)_handleCapturedSampleBuffer:(CMSampleBufferRef)sampleBuffer
                             ofType:(SCStreamOutputType)type {
    /* Only process screen frames */
    if (type != SCStreamOutputTypeScreen) {
        return;
    }

    /*
     * Check SCStreamFrameInfo status — SCStream delivers "idle" frames
     * (no pixel data) when the screen hasn't changed. Only process
     * frames with status == SCFrameStatusComplete.
     */
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachmentsArray, 0);
        CFNumberRef statusRef = NULL;
        if (CFDictionaryGetValueIfPresent(dict,
                                          SCStreamFrameInfoStatus,
                                          (const void **)&statusRef)) {
            int64_t status = 0;
            CFNumberGetValue(statusRef, kCFNumberSInt64Type, &status);
            if (status != SCFrameStatusComplete) {
                /* Idle/blank/suspended frame — no pixel data, skip silently */
                static int idleCount = 0;
                if (idleCount < 3) {
                    os_log_info(sc_log(), "Skipping non-complete frame (status=%lld, idle_count=%d)",
                                status, idleCount);
                }
                idleCount++;
                return;
            }
        }
    }

    /* Log first few complete frames */
    static int totalFrameCount = 0;
    if (totalFrameCount < 5) {
        os_log(sc_log(), "didOutputSampleBuffer: complete frame #%d (onPixelBuffer=%{public}s)",
               totalFrameCount, self.onPixelBuffer ? "SET" : "nil");
    }
    totalFrameCount++;

    /* Update watchdog timestamp */
    _lastFrameTime = [NSDate timeIntervalSinceReferenceDate];

    /* Get pixel buffer and IOSurface */
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        os_log_error(sc_log(), "Nil pixel buffer from COMPLETE frame — this should not happen");
        return;
    }

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        os_log_error(sc_log(), "Nil IOSurface from pixel buffer");
        return;
    }

    /*
     * Stamp host-time capture time ONCE at frame arrival — used by both
     * HEVC and LZ4 paths so ts_us is consistent and comparable to
     * iPad's CACurrentMediaTime-derived timestamps.
     */
    uint64_t captureTimestampUs = keydrd_host_time_us();

    /*
     * RD-COMP-05: Hold CMSampleBuffer retain for entire compression duration.
     * CFRetain before dispatching to compress queue, CFRelease after
     * compress_frame returns. This prevents IOSurface recycling.
     */
    CFRetain(sampleBuffer);

    /* HEVC mode: deliver raw pixel buffer for hardware encoding.
     * Skip LZ4 compression entirely — the HEVC encoder handles the frame. */
    if (self.onPixelBuffer) {
        static int hevcFrameCount = 0;
        if (hevcFrameCount < 3) {
            os_log(sc_log(), "onPixelBuffer: delivering frame %d to HEVC encoder", hevcFrameCount);
        }
        hevcFrameCount++;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        self.onPixelBuffer(pixelBuffer, pts, captureTimestampUs);
        CFRelease(sampleBuffer);
        return;
    }

    /* LZ4 frame skip: if a frame is already being compressed, drop this one.
     * Prevents compress queue backup (120fps in, ~5ms per compress = queue overflow).
     * Same pattern as HEVC _pendingFrameCount. */
    if (OSAtomicIncrement32Barrier(&_lz4CompressPending) > 1) {
        OSAtomicDecrement32Barrier(&_lz4CompressPending);
        CFRelease(sampleBuffer);
        return;
    }

    dispatch_async(_compressQueue, ^{
        if (!self->_compressorInitialized || !self->_isCapturing) {
            OSAtomicDecrement32Barrier(&self->_lz4CompressPending);
            CFRelease(sampleBuffer);
            return;
        }

        __block CompressOutput output;
        output.buf = self->_compressor.output.buf;
        output.buf_capacity = self->_compressor.output.buf_capacity;
        output.compressed_size = 0;

        dispatch_sync(self->_compressor.compress_queue, ^{
            BOOL (^gate)(void) = self.shouldCompressFrame;
            if (gate && !gate()) {
                static uint64_t gateSkips = 0;
                gateSkips++;
                if (gateSkips <= 10 || gateSkips % 240 == 0) {
                    os_log(sc_log(), "LZ4 gate: skipped frame before compress (sender saturated), totalSkips=%llu nextSeq=%u",
                           gateSkips, self->_compressor.seq);
                }
                return;
            }
            int result = compress_frame(&self->_compressor, surface, sampleBuffer, captureTimestampUs, &output);
            if (result < 0) {
                os_log_error(sc_log(), "compress_frame failed for seq %u", self->_compressor.seq);
            } else if (result == 0) {
                if (self.onFrame) {
                    self.onFrame(&output);
                }
            }
            /* result == 1: identical frame skipped — no action needed */
        });

        OSAtomicDecrement32Barrier(&self->_lz4CompressPending);
        CFRelease(sampleBuffer);
    });
}

#pragma mark - Frame Watchdog

- (void)_startWatchdog {
    _watchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));

    dispatch_source_set_timer(_watchdogTimer,
                              dispatch_time(DISPATCH_TIME_NOW, kWatchdogIntervalNs),
                              kWatchdogIntervalNs,
                              NSEC_PER_MSEC * 100); /* 100ms leeway */

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_watchdogTimer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_isCapturing) return;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = now - strongSelf->_lastFrameTime;

        if (elapsed > kFrameTimeoutSeconds) {
            /* Check if display is sleeping — if so, this is expected */
            if (CGDisplayIsAsleep(CGMainDisplayID())) {
                return;
            }

            /* Display is awake but no frames for >2s — likely re-auth needed */
            if (!strongSelf->_needsReauthorization) {
                strongSelf->_needsReauthorization = YES;
                os_log_error(sc_log(),
                    "Watchdog: no frames for %.1fs, display awake — re-authorization may be needed",
                    elapsed);

                if (strongSelf.onReauthorizationNeeded) {
                    strongSelf.onReauthorizationNeeded();
                }
            }
        } else {
            /* Frames are flowing again — clear flag */
            strongSelf->_needsReauthorization = NO;
        }
    });

    dispatch_resume(_watchdogTimer);
    os_log_info(sc_log(), "Watchdog timer started (2s interval)");
}

@end
