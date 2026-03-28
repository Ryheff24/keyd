#import "ScreenCapture.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
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

    /* Fetch shareable content on background queue — can block 3-10s on Sequoia (Pitfall 1) */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            if (error || !content) {
                os_log_error(sc_log(), "Failed to get shareable content: %{public}@",
                             error ? error.localizedDescription : @"nil content");
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
    config.width = (NSUInteger)display.width;
    config.height = (NSUInteger)display.height;

    os_log_info(sc_log(), "Setting up capture: %lux%lu @120fps BGRA",
                (unsigned long)config.width, (unsigned long)config.height);

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

    /* Initialize compressor: BGRA = 4 bytes/pixel */
    size_t frameBytes = (size_t)(display.width * display.height * 4);
    if (frame_compressor_init(&self->_compressor, frameBytes) != 0) {
        os_log_error(sc_log(), "Failed to initialize frame compressor");
        _stream = nil;
        return;
    }
    _compressorInitialized = YES;

    /* Start capture */
    [_stream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            os_log_error(sc_log(), "Failed to start capture: %{public}@",
                         error.localizedDescription);
            self->_stream = nil;
            return;
        }

        os_log_info(sc_log(), "Screen capture started successfully");
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

    /* Update watchdog timestamp */
    _lastFrameTime = [NSDate timeIntervalSinceReferenceDate];

    /* Get pixel buffer and IOSurface */
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        os_log_error(sc_log(), "Nil pixel buffer from sample buffer");
        return;
    }

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        os_log_error(sc_log(), "Nil IOSurface from pixel buffer");
        return;
    }

    /*
     * RD-COMP-05: Hold CMSampleBuffer retain for entire compression duration.
     * CFRetain before dispatching to compress queue, CFRelease after
     * compress_frame returns. This prevents IOSurface recycling.
     */
    CFRetain(sampleBuffer);

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
            int result = compress_frame(&self->_compressor, surface, sampleBuffer, &output);
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
