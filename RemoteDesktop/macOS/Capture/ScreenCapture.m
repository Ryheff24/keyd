#import "ScreenCapture.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

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

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
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

    /* Capture state */
    BOOL _isCapturing;
}

@synthesize isCapturing = _isCapturing;

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCapturing = NO;
        _compressorInitialized = NO;
        _needsReauthorization = NO;
        _lastFrameTime = 0;

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _captureQueue = dispatch_queue_create("com.keydrd.capture", attr);
        _compressQueue = dispatch_queue_create("com.keydrd.compress.sc", attr);
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
    config.minimumFrameInterval = CMTimeMake(1, 120); /* RD-CAP-02: 120fps */
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

    os_log(sc_log(), "Setting up capture: %lux%lu @120fps BGRA (display points: %lux%lu)",
           (unsigned long)pixelWidth, (unsigned long)pixelHeight,
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
    if (frame_compressor_init(&self->_compressor, frameBytes) != 0) {
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
    if (!_isCapturing && !_stream) {
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

    /* Destroy compressor */
    if (_compressorInitialized) {
        frame_compressor_destroy(&_compressor);
        _compressorInitialized = NO;
    }

    os_log_info(sc_log(), "Screen capture stopped");
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
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

    dispatch_async(_compressQueue, ^{
        if (!self->_compressorInitialized || !self->_isCapturing) {
            CFRelease(sampleBuffer);
            return;
        }

        __block CompressOutput output;
        output.buf = self->_compressor.output.buf;
        output.buf_capacity = self->_compressor.output.buf_capacity;
        output.compressed_size = 0;

        /*
         * NOTE: We need to call compress_frame on the compressor's own
         * dispatch queue for the dispatch_assert_queue to pass. However,
         * this _compressQueue IS the queue we use for compression. We
         * re-use _compressor.compress_queue by dispatching there.
         */
        dispatch_sync(self->_compressor.compress_queue, ^{
            int result = compress_frame(&self->_compressor, surface, sampleBuffer, captureTimestampUs, &output);
            if (result != 0) {
                os_log_error(sc_log(), "compress_frame failed for seq %u", self->_compressor.seq);
            } else {
                /* Deliver compressed frame to callback */
                if (self.onFrame) {
                    self.onFrame(&output);
                }
            }
        });

        /* Release the CMSampleBuffer retain AFTER compression completes */
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
