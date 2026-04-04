#import "SessionManager.h"
#import "ScreenCapture.h"
#import "FrameCompressor.h"
#import "HEVCEncoder.h"
#import "USBNetworkTransport.h"
#import "WirelessTransport.h"
#import "UDPChunker.h"
#import "PairingManager.h"
#import "protocol.h"

#import <os/log.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <limits.h>

/* NSWindow subclass that closes on Escape key */
@interface QRWindow : NSWindow
@end
@implementation QRWindow
- (void)cancelOperation:(id)sender { [self close]; }
@end

@interface StressPatternView : NSView
@property (nonatomic, assign) uint64_t frameIndex;
@end

@implementation StressPatternView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGFloat scale = self.window.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;

    CGContextSaveGState(ctx);
    CGContextScaleCTM(ctx, 1.0 / scale, 1.0 / scale);
    KeydRenderStressScene(ctx,
                          CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale),
                          self.frameIndex);
    CGContextRestoreGState(ctx);
}
@end

static os_log_t sLog;

/* Reconnection backoff intervals (seconds) */
static const NSTimeInterval kReconnectIntervals[] = { 0.5, 1.0, 2.0, 4.0, 8.0 };
static const int kReconnectMaxAttempts = 5;

/* Eco mode constants */
static const int kEcoWidth  = 1920;
static const int kEcoHeight = 1080;
static const int kEcoFPS    = 30;
static const int kEcoBitrate = 8000000; /* 8 Mbps */
static const int kWirelessHEVCFPS = 55;
static const int kWirelessHEVCBitrate = 3500000; /* 3.5 Mbps stability-first baseline */
static const int kWirelessAdaptiveMinFPS = 30;
static const int kWirelessAdaptiveMidFPS = 45;
static const int kWirelessAdaptiveMaxFPS = 55;
static const int kWirelessAdaptiveMinBitrate = 2500000; /* 2.5 Mbps floor */
static const int kWirelessAdaptiveMaxBitrate = 5000000; /* cap burst amplitude to reduce oscillation */
static const int kWirelessAdaptiveBitrateStepDown = 500000;
static const int kWirelessAdaptiveBitrateStepUp = 75000;
static const uint64_t kWirelessAdaptiveDownshiftCooldownMs = 900;
static const uint64_t kWirelessAdaptiveRecoveryHoldMs = 5200;
static const int kWirelessAdaptiveFPSStepUp = 2;
static const int kWirelessAdaptiveFPSStepDownSevereSoft = 8;
static const int kWirelessAdaptiveUpshiftHealthyStreak = 8;
static const int kWirelessAdaptiveMildCongestionStreak = 4;
static const int kWirelessAdaptiveSevereEscalationStreak = 2;
static const int kWirelessAdaptiveMaxUpshiftFPSDelta = 2;
static const int kWirelessAdaptiveMaxUpshiftBitrateDelta = 75000;
static const int kWirelessAdaptiveMaxDownshiftFPSDelta = 10;
static const int kWirelessAdaptiveMaxDownshiftBitrateDelta = 600000;
static const uint32_t kWirelessMaxEncodeWidth = 2496;
static const uint32_t kWirelessMaxEncodeHeight = 1620;
/* Keep wireless media on the established TLS/TCP stream. This removes the
 * paced-DTLS chunk backlog that was inflating tail latency/jitter on Wi-Fi
 * and keeps reconnect/rotation behavior aligned to a single transport socket. */
static const BOOL kWirelessUseTCPMedia = YES;
static const NSUInteger kWirelessLargeFrameChunkThreshold = 320;
static const NSUInteger kWirelessMaxQueuedChunks = 384;
static const NSUInteger kWirelessMildCongestionChunkThreshold = 128;
static const NSUInteger kWirelessSevereCongestionChunkThreshold = 224;
static const uint64_t kWirelessMildCongestedFrameIntervalUs = 16667;  /* ~60fps cadence */
static const uint64_t kWirelessSevereCongestedFrameIntervalUs = 20000;/* stronger smoothing */
static const uint64_t kWirelessPacingToleranceUs = 1500;         /* tolerate source timestamp jitter around cadence */
/* Maximum in-flight TCP sends for Wi-Fi media path.
 * Bounds kernel queue depth to avoid stale-frame tail latency and jitter. */
static const int32_t kMaxMediaSendsInFlightWiFi = 3;
/* Completion latency above this indicates kernel/network backlog in Wi-Fi TCP path. */
static const uint64_t kWirelessTCPSlowCompletionThresholdMs = 25;
/* Keyframe request cooldown after Wi-Fi TCP backpressure drops.
 * Prevents request spam during a short burst while still reducing
 * recovery dwell time when a rare send-side sequence hole occurs. */
static const uint64_t kWirelessTCPDropKeyframeCooldownMs = 120;
/* Detect and recover from Wi-Fi TCP in-flight saturation stalls where
 * completion callbacks stop draining and pre-encode gate starves source frames. */
static const uint64_t kWirelessTCPStallSaturationThresholdMs = 320;
static const uint64_t kWirelessTCPStallNoCompletionThresholdMs = 260;
static const uint64_t kWirelessTCPStallRecoveryCooldownMs = 1200;
static const uint64_t kWirelessTCPPostRecoveryAdaptiveHoldMs = 2600;
static const uint64_t kWirelessTCPStallLogIntervalMs = 500;

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
}

static void keydrd_limit_size(uint32_t sourceWidth, uint32_t sourceHeight,
                              uint32_t maxWidth, uint32_t maxHeight,
                              uint32_t *outWidth, uint32_t *outHeight) {
    if (sourceWidth == 0 || sourceHeight == 0 || maxWidth == 0 || maxHeight == 0) {
        if (outWidth) *outWidth = sourceWidth;
        if (outHeight) *outHeight = sourceHeight;
        return;
    }

    double widthScale = (double)maxWidth / (double)sourceWidth;
    double heightScale = (double)maxHeight / (double)sourceHeight;
    double scale = MIN(1.0, MIN(widthScale, heightScale));

    uint32_t limitedWidth = (uint32_t)llround((double)sourceWidth * scale);
    uint32_t limitedHeight = (uint32_t)llround((double)sourceHeight * scale);

    if (limitedWidth > 1 && (limitedWidth & 1u) != 0) limitedWidth--;
    if (limitedHeight > 1 && (limitedHeight & 1u) != 0) limitedHeight--;

    if (outWidth) *outWidth = MAX(limitedWidth, 2u);
    if (outHeight) *outHeight = MAX(limitedHeight, 2u);
}

/* Maximum number of TCP media sends in-flight before dropping frames.
 * NWConnection.send completion fires when kernel accepts data, so this
 * bounds the kernel TCP send buffer depth. At 2 in-flight, one frame
 * is being transmitted while the next waits — keeps latency bounded
 * without sacrificing throughput on fast links. */
/* Allow 3 concurrent TCP sends to pipeline USB NCM transfers.
 * At 3-4MB per frame and ~400 MB/s USB 3, each send takes ~10ms.
 * With 3 in-flight, the pipeline fills while the first is completing,
 * keeping USB bandwidth saturated for 120fps at larger frame sizes. */
static const int32_t kMaxMediaSendsInFlightUSB = 3;

@interface SessionManager ()

@property (nonatomic, assign, readwrite) SessionState sessionState;
@property (nonatomic, assign, readwrite) TransportState transportState;

/* Pipeline components */
@property (nonatomic, strong) ScreenCapture *capture;
@property (nonatomic, strong) HEVCEncoder *hevcEncoder;
@property (nonatomic, strong) USBNetworkTransport *usbTransport;
@property (nonatomic, strong) WirelessTransport *wirelessTransport;
@property (nonatomic, strong) PairingManager *pairing;

/* Compression state (pure C struct) */
@property (nonatomic, assign) FrameCompressorState compressorState;
@property (nonatomic, assign) BOOL compressorInitialized;

/* Reconnection */
@property (nonatomic, assign) int reconnectAttempt;
@property (nonatomic, strong, nullable) NSTimer *reconnectTimer;

/* Permission polling */
@property (nonatomic, strong, nullable) NSTimer *permissionTimer;

/* Current encode mode */
@property (nonatomic, assign) BOOL isEcoMode;

/* Display info */
@property (nonatomic, assign) uint32_t captureWidth;
@property (nonatomic, assign) uint32_t captureHeight;
@property (nonatomic, assign) float captureScale;

/* Viewport: iPad reports its viewport dims after handshake.
 * Encoder + capture start only after viewport is known. */
@property (nonatomic, assign) uint32_t viewportWidth;
@property (nonatomic, assign) uint32_t viewportHeight;
@property (nonatomic, assign) BOOL viewportReceived;

/* Resolution matching: stored original display mode for revert on disconnect */
@property (nonatomic, assign) CGDisplayModeRef storedDisplayMode;
@property (nonatomic, assign) BOOL resolutionChanged;
@property (nonatomic, copy, nullable) NSString *testCaptureFilePath;
@property (nonatomic, assign) BOOL testCaptureStressMode;

/* Latency probe */
@property (nonatomic, strong, nullable) NSTimer *latencyProbeTimer;
@property (nonatomic, strong, nullable) NSTimer *wirelessPerformanceTimer;

/* Send backpressure: track in-flight TCP media sends.
 * When > kMaxTcpSendsInFlight, drop new frames to prevent queue buildup. */
@property (nonatomic, assign) volatile int32_t tcpMediaSendsInFlight;
@property (nonatomic, assign) volatile int32_t wifiTCPMediaSendsInFlight;
@property (atomic, assign) uint64_t wirelessLastEncodeSubmitUs;
@property (nonatomic, assign) volatile int32_t wifiPerfEncodedFrames;
@property (nonatomic, assign) volatile int32_t wifiPerfEncodedBytes;
@property (nonatomic, assign) volatile int32_t wifiPerfKeyframes;
@property (nonatomic, assign) volatile int32_t wifiPerfMaxFrameBytes;
@property (nonatomic, assign) volatile int32_t wifiPerfPreEncodeDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfQueueDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPFallbacks;
@property (nonatomic, assign) volatile int32_t wifiPerfPeakQueuedChunks;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSendDrops;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPInFlightPeak;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPSlowCompletions;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPMaxCompletionMs;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPDropKeyframeRequests;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPDropKeyframeSuppressed;
@property (nonatomic, assign) volatile int32_t wifiPerfTCPStallRecoveries;
@property (atomic, assign) uint64_t wifiLastTCPDropKeyframeRequestUs;
@property (atomic, assign) uint64_t wifiTCPLastCompletionUs;
@property (atomic, assign) uint64_t wifiTCPInFlightSaturatedSinceUs;
@property (atomic, assign) uint64_t wifiTCPLastStallRecoveryUs;
@property (atomic, assign) uint64_t wifiTCPStallLastLogUs;
@property (atomic, assign) uint32_t wifiTCPSendGeneration;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveDownshifts;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveUpshifts;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveHolds;
@property (nonatomic, assign) volatile int32_t wifiPerfAdaptiveFloorGuards;
@property (nonatomic, assign) int32_t wifiAdaptiveTargetFPS;
@property (nonatomic, assign) int32_t wifiAdaptiveTargetBitrate;
@property (nonatomic, assign) int32_t wifiAdaptiveAppliedFPS;
@property (nonatomic, assign) int32_t wifiAdaptiveAppliedBitrate;
@property (atomic, assign) uint64_t wifiAdaptiveLastChangeUs;
@property (nonatomic, assign) int32_t wifiAdaptiveHealthyStreak;
@property (nonatomic, assign) int32_t wifiAdaptiveMildCongestionStreak;
@property (nonatomic, assign) int32_t wifiAdaptiveSevereCongestionStreak;

/* QR code display window */
@property (nonatomic, strong, nullable) NSWindow *qrWindow;
@property (nonatomic, strong, nullable) NSWindow *stressWindow;
@property (nonatomic, strong, nullable) NSTimer *stressWindowTimer;

- (void)sendMediaFrameHeaderToiPad:(const MediaFrameHeader *)header
                           payload:(const void *)payload
                     payloadLength:(size_t)payloadLen;
- (void)resetWiFiAdaptiveControlState;
- (void)evaluateWiFiAdaptiveRateControl;
- (void)applyWiFiAdaptiveRateTargetsIfNeededWithReason:(NSString *)reason nowUs:(uint64_t)nowUs;
- (BOOL)maybeRecoverWiFiTCPInFlightStallWithInFlight:(int32_t)inFlight nowUs:(uint64_t)nowUs reason:(const char *)reason;

@end

@implementation SessionManager

- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly {
    return [self initWithTestMode:testMode
                   automationMode:automationMode
                        wiredOnly:wiredOnly
                     wirelessOnly:wirelessOnly
              testCaptureFilePath:nil
            testCaptureStressMode:NO];
}

- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly
             testCaptureFilePath:(NSString *)testCaptureFilePath
           testCaptureStressMode:(BOOL)testCaptureStressMode {
    self = [super init];
    if (self) {
        sLog = os_log_create("com.ryheff.keyd.remote.agent", "SessionManager");
        _testMode = testMode;
        _automationMode = automationMode;
        _wiredOnly = wiredOnly;
        _wirelessOnly = wirelessOnly;
        _testCaptureFilePath = [testCaptureFilePath copy];
        _testCaptureStressMode = testCaptureStressMode;
        _sessionState = SESSION_STOPPED;
        _transportState = TRANSPORT_IDLE;
        _compressorInitialized = NO;
        _isEcoMode = NO;
        _reconnectAttempt = 0;
        _storedDisplayMode = NULL;
        _resolutionChanged = NO;
        _captureScale = 2.0f;

        /* Create pipeline components */
        _capture = [[ScreenCapture alloc] init];
        _capture.testCaptureFilePath = _testCaptureFilePath;
        _capture.testCaptureStressMode = _testCaptureStressMode;
        _hevcEncoder = [[HEVCEncoder alloc] init];
        _usbTransport = [[USBNetworkTransport alloc] init];
        _wirelessTransport = [[WirelessTransport alloc] init];
        _pairing = [[PairingManager alloc] init];
        _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
        _wifiAdaptiveTargetBitrate = kWirelessHEVCBitrate;
        _wifiAdaptiveAppliedFPS = 0;
        _wifiAdaptiveAppliedBitrate = 0;
        _wifiAdaptiveLastChangeUs = 0;
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
    }
    return self;
}

- (void)dealloc {
    if (_storedDisplayMode) {
        CGDisplayModeRelease(_storedDisplayMode);
        _storedDisplayMode = NULL;
    }
}

#pragma mark - Lifecycle

- (void)start {
    os_log(sLog, "Session starting -- checking permissions");
    [self transitionTo:SESSION_AWAITING_PERMISSIONS];

    if (_testMode) {
        os_log(sLog, "Test mode -- skipping permission checks");
        [self onPermissionsGranted];
        return;
    }

    [self checkPermissions];
}

- (void)stop {
    os_log(sLog, "Session stopping");
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.latencyProbeTimer invalidate];
    self.latencyProbeTimer = nil;
    [self stopWirelessPerformanceTimer];
    [self.stressWindowTimer invalidate];
    self.stressWindowTimer = nil;
    [self.stressWindow orderOut:nil];
    self.stressWindow = nil;

    [_capture stopCapture];
    [_hevcEncoder stop];
    [_usbTransport stopMonitoring];
    [_wirelessTransport stopAdvertising];

    if (_compressorInitialized) {
        FrameCompressorState state = _compressorState;
        frame_compressor_destroy(&state);
        _compressorState = state;
        _compressorInitialized = NO;
    }

    /* Revert resolution if changed */
    [self revertDisplayMode];

    [self transitionTo:SESSION_STOPPED];
}

#pragma mark - Permission Gating

- (void)checkPermissions {
    /* Check Screen Recording (RD-AGENT-04) */
    BOOL screenGranted = CGPreflightScreenCaptureAccess();
    if (!screenGranted) {
        CGRequestScreenCaptureAccess();
    }

    /* Check Accessibility (RD-AGENT-05) */
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL accessibilityGranted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

    /* Notify UI of initial permission state */
    if (self.onPermissionStatusChanged) {
        self.onPermissionStatusChanged(screenGranted, accessibilityGranted);
    }

    if (screenGranted && accessibilityGranted) {
        os_log(sLog, "Both permissions already granted");
        [self onPermissionsGranted];
        return;
    }

    os_log(sLog, "Waiting for permissions -- Screen Recording: %{public}s, Accessibility: %{public}s",
           screenGranted ? "granted" : "pending",
           accessibilityGranted ? "granted" : "pending");

    /* Poll every 3 seconds until both granted */
    __weak SessionManager *weakSelf = self;
    _permissionTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                      repeats:YES
                                                        block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }

        BOOL screen = CGPreflightScreenCaptureAccess();
        BOOL accessibility = AXIsProcessTrustedWithOptions(NULL);

        os_log(sLog, "Permission poll: Screen Recording=%{public}s, Accessibility=%{public}s",
               screen ? "granted" : "pending",
               accessibility ? "granted" : "pending");

        /* Update the menu bar UI on every poll */
        if (strongSelf.onPermissionStatusChanged) {
            strongSelf.onPermissionStatusChanged(screen, accessibility);
        }

        if (screen && accessibility) {
            os_log(sLog, "Both permissions now granted");
            [timer invalidate];
            strongSelf.permissionTimer = nil;
            [strongSelf onPermissionsGranted];
        }
    }];
}

- (void)onPermissionsGranted {
    /* Ensure TLS identity exists */
    [_pairing ensureTLSIdentity];

    /* Set TLS identity on transports */
    _usbTransport.tlsIdentity = _pairing.tlsIdentity;
    _wirelessTransport.tlsIdentity = _pairing.tlsIdentity;

    if (_testMode) {
        /* Test mode always re-pairs: iPad auto-pair needs the pairing listener. */
        os_log(sLog, "Test mode -- forcing fresh pairing");
        [_pairing resetPairing];
        [self transitionTo:SESSION_AWAITING_PAIRING];
    } else if (_pairing.isPaired) {
        os_log(sLog, "Already paired -- proceeding to connect");
        [_qrWindow close];
        _qrWindow = nil;
        [self transitionTo:SESSION_CONNECTING];
        [self startTransportMonitoring];
    } else {
        os_log(sLog, "Not yet paired -- awaiting QR pairing");
        [self transitionTo:SESSION_AWAITING_PAIRING];
    }
}

#pragma mark - Pairing

- (void)showPairingQR {
    /* Reset pairing state for fresh QR pairing */
    [_pairing resetPairing];

    NSString *payload = [_pairing generateQRPayload];
    if (!payload) {
        os_log_error(sLog, "Failed to generate QR payload -- TLS identity missing?");
        return;
    }

    os_log(sLog, "QR pairing payload generated (length=%lu)", (unsigned long)payload.length);
    os_log_debug(sLog, "QR payload: %{public}@", payload);

    /* In test mode, write the QR payload to a file for the iPad to read
     * instead of requiring a physical QR scan. */
    if (_testMode) {
        NSError *writeError = nil;
        [payload writeToFile:@"/tmp/keydrd-test-qr.json"
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&writeError];
        if (writeError) {
            os_log_error(sLog, "Test mode: failed to write QR payload to file: %{public}@",
                         writeError.localizedDescription);
        } else {
            os_log(sLog, "Test mode: QR payload written to /tmp/keydrd-test-qr.json");
        }
    }

    /* Wire pairing completion callback before starting listener (with or without QR UI). */
    __weak SessionManager *weakSelf = self;
    _pairing.onPairingComplete = ^{
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        os_log(sLog, "Pairing complete -- closing QR window and starting transport");
        [strongSelf.qrWindow close];
        strongSelf.qrWindow = nil;
        [strongSelf transitionTo:SESSION_CONNECTING];
        [strongSelf startTransportMonitoring];
    };

    if (_testMode && _automationMode) {
        os_log(sLog, "Test mode: QR window suppressed (--automation-mode)");
        [_pairing startPairingListener];
        return;
    }

    /* Generate QR code image using CIFilter */
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [qrFilter setValue:payloadData forKey:@"inputMessage"];
    [qrFilter setValue:@"M" forKey:@"inputCorrectionLevel"];

    CIImage *ciImage = qrFilter.outputImage;
    if (!ciImage) {
        os_log_error(sLog, "CIQRCodeGenerator produced nil image");
        return;
    }

    /* Scale QR to small display size (each module -> 3px) */
    CGFloat scale = 3.0;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *qrImage = [[NSImage alloc] initWithSize:rep.size];
    [qrImage addRepresentation:rep];

    CGFloat imageSize = rep.size.width;
    CGFloat padding = 12;
    CGFloat labelHeight = 28;
    CGFloat windowWidth = imageSize + padding * 2;
    CGFloat windowHeight = imageSize + padding * 2 + labelHeight;

    /* Close existing QR window if open */
    [_qrWindow close];

    NSRect frame = NSMakeRect(0, 0, windowWidth, windowHeight);
    _qrWindow = [[QRWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    _qrWindow.title = @"Scan with iPad";
    _qrWindow.level = NSFloatingWindowLevel;
    _qrWindow.releasedWhenClosed = NO;

    NSView *contentView = _qrWindow.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = NSColor.whiteColor.CGColor;

    /* QR image view */
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:
        NSMakeRect(padding, labelHeight + padding / 2, imageSize, imageSize)];
    imageView.image = qrImage;
    imageView.imageScaling = NSImageScaleNone;
    [contentView addSubview:imageView];

    /* Label */
    NSTextField *label = [NSTextField labelWithString:@"Scan with iPad"];
    label.frame = NSMakeRect(0, 4, windowWidth, 20);
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = NSColor.secondaryLabelColor;
    [contentView addSubview:label];

    [_qrWindow center];
    [_qrWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* Start TLS listener so iPad can connect after scanning */
    [_pairing startPairingListener];
}

- (void)resetPairing {
    os_log(sLog, "Resetting pairing");
    [self stop];
    [_pairing resetPairing];
    [self transitionTo:SESSION_AWAITING_PAIRING];
}

#pragma mark - Transport

- (void)startTransportMonitoring {
    __weak SessionManager *weakSelf = self;

    /* USB NCM: when TCP input connection is accepted, send handshake.
     * The interface appears before any iPad connection arrives. The handshake
     * must wait until the TCP channel is ready (not just interface detected). */
    _usbTransport.onInputConnectionReady = ^{
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_transportState != TRANSPORT_USB_NCM) {
            [strongSelf handleTransportEvent:TRANSPORT_EVT_WIRED_APPEARED];
        } else {
            os_log(sLog, "USB NCM TCP input ready — sending handshake");
            [strongSelf onTransportConnected];
        }
    };

    _usbTransport.onInputConnectionLost = ^{
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleTransportEvent:TRANSPORT_EVT_DISCONNECTED];
    };

    /* USB NCM interface monitoring */
    _usbTransport.onInterfaceChanged = ^(BOOL appeared, nw_interface_t _Nullable interface) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (appeared) {
            [strongSelf handleTransportEvent:TRANSPORT_EVT_WIRED_APPEARED];
        } else {
            [strongSelf handleTransportEvent:TRANSPORT_EVT_WIRED_DISAPPEARED];
        }
    };

    /* USB transport input receive callback */
    _usbTransport.onInputReceived = ^(const void *data, size_t length) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleReceivedInputEvent:data length:length];
    };

    /* Wireless connection monitoring */
    _wirelessTransport.onConnectionChanged = ^(BOOL connected, BOOL isAWDL) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (connected) {
            if (isAWDL) {
                [strongSelf handleTransportEvent:TRANSPORT_EVT_AWDL_AVAILABLE];
            } else {
                [strongSelf handleTransportEvent:TRANSPORT_EVT_WIFI_AVAILABLE];
            }
        } else {
            if (isAWDL) {
                [strongSelf handleTransportEvent:TRANSPORT_EVT_AWDL_UNAVAILABLE];
            } else {
                [strongSelf handleTransportEvent:TRANSPORT_EVT_WIFI_UNAVAILABLE];
            }
        }
    };

    /* Wireless transport input receive callback */
    _wirelessTransport.onInputReceived = ^(const void *data, size_t length) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleReceivedInputEvent:data length:length];
    };

    /* Start USB NCM first (primary transport).
     * Always start WiFi advertising after a delay. USB NCM listeners bind to
     * a specific interface, and WiFi binds to :: with SO_REUSEADDR — no conflict.
     * WiFi advertising must always be active so the iPad can:
     *   1. Discover the Mac via Bonjour (_keydrd._tcp)
     *   2. Fall back to WiFi if USB disconnects
     *   3. Run WiFi rotation tests during E2E suite */
    if (!_wirelessOnly) {
        [_usbTransport startMonitoring];
    } else {
        os_log(sLog, "Wireless-only mode — USB monitoring disabled");
    }

    if (!_wiredOnly) {
        __weak SessionManager *weakSelf2 = weakSelf;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SessionManager *self2 = weakSelf2;
            if (!self2) return;
            if (self2->_wirelessTransport.isConnected) {
                os_log(sLog,
                       "Skipping delayed WiFi advertising start: wireless session already active (state=%{public}s transport=%{public}s)",
                       [self2 sessionStateName:self2->_sessionState], transport_state_name(self2->_transportState));
                return;
            }
            if (self2->_wirelessOnly) {
                os_log(sLog, "Wireless-only mode — starting WiFi advertising");
            } else if (self2->_usbTransport.isConnected) {
                os_log(sLog, "USB NCM connected — starting WiFi advertising anyway (fallback + Bonjour)");
            } else {
                os_log(sLog, "USB NCM not connected after 3s — starting WiFi advertising");
            }
            [self2->_wirelessTransport startAdvertising];
        });
    } else {
        os_log(sLog, "Wired-only mode — WiFi/AWDL advertising disabled");
    }
}

- (void)handleTransportEvent:(TransportEvent)event {
    os_log(sLog, "Transport event: %{public}s (current state: %{public}s)",
           transport_event_name(event), transport_state_name(_transportState));

    /* Before WiFi→USB transition, tell iPad the Mac's new USB NCM IP
     * so it can update its peer address before WiFi drops. */
    if (event == TRANSPORT_EVT_WIRED_APPEARED &&
        (_transportState == TRANSPORT_WIFI || _transportState == TRANSPORT_AWDL)) {
        [self sendPeerAddressUpdate];
    }

    TransportTransition transition = transport_fsm_transition(_transportState, event);
    _transportState = transition.next_state;

    os_log(sLog, "Transitioned to: %{public}s (%d effects)",
           transport_state_name(_transportState), transition.effect_count);

    /* Execute side effects */
    for (int i = 0; i < transition.effect_count; i++) {
        [self executeEffect:transition.effects[i]];
    }

    /* Notify StatusBarController */
    if (self.onTransportStateChanged) {
        self.onTransportStateChanged(_transportState);
    }

    /* Handle connection state changes */
    if (_transportState == TRANSPORT_DISCONNECTED && _sessionState == SESSION_STREAMING) {
        [self startReconnection];
    } else if (_transportState != TRANSPORT_IDLE && _transportState != TRANSPORT_DISCONNECTED) {
        if (_sessionState == SESSION_CONNECTING || _sessionState == SESSION_RECONNECTING) {
            /* Only fire onTransportConnected if a transport actually has an active TCP connection.
             * USB NCM detects the interface before iPad connects — the handshake must wait
             * for onInputConnectionReady. WiFi fires onConnectionChanged only after TCP is ready. */
            if (_usbTransport.isConnected || _wirelessTransport.isConnected) {
                _reconnectAttempt = 0;
                [_reconnectTimer invalidate];
                _reconnectTimer = nil;
                [self onTransportConnected];
            } else {
                os_log(sLog, "Transport state changed but no active TCP connection yet — waiting");
            }
        }
    }
}

- (void)executeEffect:(TransportEffect)effect {
    os_log(sLog, "Executing effect: %{public}s", transport_effect_name(effect));

    switch (effect) {
        case EFFECT_SWITCH_ENCODE_LZ4:
            [self switchToLZ4Mode];
            break;
        case EFFECT_SWITCH_ENCODE_HEVC:
            [self switchToHEVCMode];
            break;
        case EFFECT_NOTIFY_TRANSPORT_CHANGE:
            [self sendTransportChangeNotification];
            break;
        case EFFECT_BIND_USB_NCM:
        case EFFECT_CONNECT_WIFI:
        case EFFECT_CONNECT_AWDL:
        case EFFECT_DISCONNECT_CURRENT:
        case EFFECT_NONE:
            /* Transport modules handle their own binding/connecting */
            break;
    }
}

#pragma mark - Encode Mode Switching

- (void)switchToLZ4Mode {
    os_log(sLog, "Switching to LZ4 mode (lossless, <1ms encode — wired USB only)");
    _isEcoMode = NO;
    [_hevcEncoder stop];

    /* Capture resolution will be set to viewport dims when iPad sends viewport report.
     * If viewport already known (reconnect), resize now. */
    if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        os_log(sLog, "LZ4: resizing capture to viewport %ux%u", _viewportWidth, _viewportHeight);
        [_capture updateCaptureResolution:_viewportWidth height:_viewportHeight];
        _captureWidth = _viewportWidth;
        _captureHeight = _viewportHeight;
        [self sendGeometryUpdate];
    }

    /* Reconfigure capture for LZ4 compression (clears onPixelBuffer so LZ4 path runs) */
    [self configureFrameDelivery];

    if (self.onModeChanged) {
        self.onModeChanged(NO);
    }
}

- (void)switchToHEVCMode {
    os_log(sLog, "Switching to HEVC mode (encoder deferred until iPad viewport report)");

    if (_compressorInitialized) {
        FrameCompressorState state = _compressorState;
        frame_compressor_destroy(&state);
        _compressorState = state;
        _compressorInitialized = NO;
    }

    /* Ensure display dimensions are available for the handshake.
     * Encoder does NOT start here — it starts when iPad sends viewport dims. */
    if (_captureWidth == 0 || _captureHeight == 0) {
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mainDisplay);
        if (mode) {
            _captureWidth = (uint32_t)CGDisplayModeGetPixelWidth(mode);
            _captureHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
            size_t logicalWidth = CGDisplayModeGetWidth(mode);
            _captureScale = (logicalWidth > 0) ? (float)_captureWidth / (float)logicalWidth : 2.0f;
            CGDisplayModeRelease(mode);
            os_log(sLog, "HEVC: resolved display dimensions %ux%u @%.1fx",
                   _captureWidth, _captureHeight, _captureScale);
        }
    }

    /* If viewport already known (reconnect), start encoder immediately */
    if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        [self _startEncoderAtViewportResolution];
    } else {
        os_log(sLog, "HEVC encoder deferred — waiting for iPad viewport report");
    }

    /* Reconfigure frame delivery for HEVC */
    [self configureFrameDelivery];

    if (self.onModeChanged) {
        self.onModeChanged(YES);
    }
}

- (void)sendTransportChangeNotification {
    /* Send mode_change InputEventHeader to iPad via TCP */
    InputEventHeader header;
    header.type = KEYDRD_INPUT_MODE_CHANGE;
    header.ts_us = [self currentTimestampUs];

    [self sendInputEventToiPad:&header length:sizeof(header)];
}

#pragma mark - Streaming

- (void)onTransportConnected {
    os_log(sLog, "Transport connected -- sending handshake (state=%{public}s transport=%{public}s usbConnected=%{public}d wifiConnected=%{public}d viewportReceived=%{public}d viewport=%ux%u hevcActive=%{public}d)",
           [self sessionStateName:_sessionState],
           transport_state_name(_transportState),
           _usbTransport.isConnected, _wirelessTransport.isConnected,
           _viewportReceived, _viewportWidth, _viewportHeight,
           _hevcEncoder.isActive);
    _tcpMediaSendsInFlight = 0;
    _wifiTCPMediaSendsInFlight = 0;
    _wifiTCPLastCompletionUs = 0;
    _wifiTCPInFlightSaturatedSinceUs = 0;
    _wifiTCPLastStallRecoveryUs = 0;
    _wifiTCPStallLastLogUs = 0;
    _wifiTCPSendGeneration += 1;
    _wirelessLastEncodeSubmitUs = 0;
    [self resetWiFiAdaptiveControlState];
    [self stopWirelessPerformanceTimer];
    [self transitionTo:SESSION_STREAMING];

    /* Send session handshake (also sets _captureWidth/_captureHeight) */
    [self sendSessionHandshake];

    /* HEVC encoder starts when iPad sends viewport report (after receiving this handshake).
     * Only needed for WiFi/AWDL — USB uses LZ4 (no HEVC encoder). */
    if (_usbTransport.isConnected) {
        os_log(sLog, "USB LZ4 mode — no HEVC encoder needed, capture at native %ux%u",
               _captureWidth, _captureHeight);
    } else if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        [self _startEncoderAtViewportResolution];
    } else {
        os_log(sLog, "HEVC encoder deferred — waiting for iPad viewport report after handshake");
    }

    /* Set up frame delivery */
    [self configureFrameDelivery];

    /* For wireless: defer capture until DTLS media channel is ready.
     * HEVC frames are sent via UDP/DTLS — sending before the media
     * connection is established just drops frames silently. */
    if (_wirelessTransport.isConnected && !_usbTransport.isConnected) {
        __weak SessionManager *weakSelf = self;
        _wirelessTransport.onMediaChannelReady = ^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_wirelessTransport.onMediaChannelReady = nil; /* one-shot */
            os_log(sLog, "DTLS media channel ready -- starting capture now");
            [strongSelf _beginCapture];
        };
    } else if (_usbTransport.isConnected && !_hevcEncoder.isActive) {
        /* USB LZ4 mode: defer capture until viewport report arrives.
         * Starting now would capture at 3600x2338 (handshake res), then resize
         * when viewport arrives — but transitional frames at the old size crash
         * the iPad LZ4 decompressor (buffer sized for new dims, frame is old size).
         * Capture starts in handleViewportReport after resize + geometry update. */
        if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
            /* Viewport already known (reconnect) — start immediately at viewport res */
            os_log(sLog, "USB LZ4: viewport known (%ux%u), starting capture now",
                   _viewportWidth, _viewportHeight);
            [self _beginCapture];
        } else {
            os_log(sLog, "USB LZ4: deferring capture until viewport report (avoids size mismatch crash)");
        }
    } else {
        /* USB HEVC or other: start capture immediately */
        [self _beginCapture];
    }

    /* Start latency probe timer (every 1 second) */
    [self startLatencyProbeTimer];
    [self startWirelessPerformanceTimerIfNeeded];
}

- (void)_beginCapture {
    [_capture startCapture];

    /* In explicit real-capture mode, show the same stress scene that synthetic mode
     * renders directly. This isolates ScreenCaptureKit as the primary variable. */
    if (_testMode && _testCaptureFilePath.length == 0 && !_testCaptureStressMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CGDirectDisplayID capturedDisplay = CGMainDisplayID();
            NSScreen *screen = nil;
            for (NSScreen *s in [NSScreen screens]) {
                NSDictionary *desc = [s deviceDescription];
                NSNumber *screenNumber = desc[@"NSScreenNumber"];
                if (screenNumber && [screenNumber unsignedIntValue] == capturedDisplay) {
                    screen = s;
                    break;
                }
            }
            if (!screen) screen = [NSScreen mainScreen];
            [self.stressWindowTimer invalidate];
            self.stressWindowTimer = nil;
            [self.stressWindow orderOut:nil];

            NSWindow *stressWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                                                 styleMask:NSWindowStyleMaskBorderless
                                                                   backing:NSBackingStoreBuffered
                                                                     defer:NO];
            stressWindow.level = NSFloatingWindowLevel + 1;
            stressWindow.opaque = YES;
            stressWindow.backgroundColor = NSColor.blackColor;
            stressWindow.ignoresMouseEvents = YES;
            stressWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

            StressPatternView *patternView = [[StressPatternView alloc] initWithFrame:stressWindow.contentView.bounds];
            patternView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            stressWindow.contentView = patternView;

            self.stressWindow = stressWindow;
            [stressWindow orderFront:nil];
            os_log(sLog, "Test mode: real-capture stress window active at %.0fx%.0f",
                   screen.frame.size.width, screen.frame.size.height);

            __weak SessionManager *weakSelf = self;
            self.stressWindowTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/120.0 repeats:YES block:^(NSTimer *timer) {
                SessionManager *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
                    [timer invalidate];
                    return;
                }
                StressPatternView *view = (StressPatternView *)strongSelf.stressWindow.contentView;
                if (![view isKindOfClass:[StressPatternView class]]) {
                    return;
                }
                view.frameIndex += 1;
                if (view.frameIndex < 10 || view.frameIndex % 120 == 0) {
                    CGFloat scale = strongSelf.stressWindow.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
                    if (scale <= 0.0) scale = 1.0;
                    size_t pixelWidth = (size_t)llround(view.bounds.size.width * scale);
                    size_t pixelHeight = (size_t)llround(view.bounds.size.height * scale);
                    uint64_t sig = KeydStressSceneSignature(CGSizeMake(pixelWidth, pixelHeight), view.frameIndex);
                    uint32_t sceneCRC = KeydStressSceneCRC(pixelWidth, pixelHeight, view.frameIndex);
                    os_log(sLog, "FRAME-CHECK source real-capture frame=%llu sig=%{public}016llx scene_crc=%08x size=%zux%zu scale=%.2f",
                           view.frameIndex, sig, sceneCRC, pixelWidth, pixelHeight, scale);
                }
                [view setNeedsDisplay:YES];
            }];
        });
    } else if (_testMode && (_testCaptureFilePath.length > 0 || _testCaptureStressMode)) {
        if (_testCaptureStressMode) {
            os_log(sLog, "Test mode: using procedural full-frame stress capture");
        } else {
            os_log(sLog, "Test mode: using synthetic capture frames from %{public}@",
                   _testCaptureFilePath);
        }
    }
}

- (void)sendSessionHandshake {
    /* Get display geometry from primary display via CoreGraphics */
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    _captureWidth = (uint32_t)CGDisplayPixelsWide(mainDisplay);
    _captureHeight = (uint32_t)CGDisplayPixelsHigh(mainDisplay);

    /* Calculate scale factor from display mode */
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mainDisplay);
    if (mode) {
        size_t modeWidth = CGDisplayModeGetPixelWidth(mode);
        size_t logicalWidth = CGDisplayModeGetWidth(mode);
        _captureScale = (logicalWidth > 0) ? (float)modeWidth / (float)logicalWidth : 2.0f;

        /* Use pixel dimensions for capture */
        _captureWidth = (uint32_t)modeWidth;
        _captureHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
        CGDisplayModeRelease(mode);
    }

    SessionHandshakeMessage handshake = {
        .magic = KEYDRD_MAGIC,
        .msg_type = KEYDRD_MSG_SESSION_HANDSHAKE,
        .display_width = _captureWidth,
        .display_height = _captureHeight,
        .scale_factor = _captureScale,
        .aspect_ratio = (float)(_captureWidth) / (float)(_captureHeight),
        .capabilities = KEYDRD_CAP_LZ4 | KEYDRD_CAP_HEVC | KEYDRD_CAP_ECO_AVAILABLE,
        .max_fps = 120,
        .agent_version = 1,
        .reserved = 0
    };

    /* Send handshake over active transport's TCP channel */
    [self sendInputEventToiPad:&handshake length:sizeof(handshake)];

    os_log(sLog, "Sent session handshake: %ux%u @%.1fx, aspect=%.4f",
           _captureWidth, _captureHeight, _captureScale, handshake.aspect_ratio);

    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

- (void)configureFrameDelivery {
    __weak SessionManager *weakSelf = self;

    /* LZ4 compressed frame callback (wired/USB mode) */
    _capture.onFrame = ^(CompressOutput *output) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;

        if (strongSelf->_hevcEncoder.isActive) {
            /* HEVC mode: frames sent via onEncodedFrame callback instead */
            return;
        }

        /* LZ4 mode: prepend MediaFrameHeader + send via active transport */
        /* Log frame sizes for debugging bandwidth issues */
        static int lz4SendCount = 0;
        if (lz4SendCount < 10 || lz4SendCount % 200 == 0) {
            BOOL isKey = (output->header.flags & KEYDRD_FLAG_KEYFRAME) != 0;
            os_log(sLog, "LZ4 frame #%d: %zu bytes compressed (%s), seq=%u",
                   lz4SendCount, output->compressed_size,
                   isKey ? "KEYFRAME" : "delta",
                   output->header.seq);
        }
        lz4SendCount++;
        [strongSelf sendMediaFrameHeaderToiPad:&output->header
                                       payload:output->buf
                                 payloadLength:output->compressed_size];
    };

    /* Raw pixel buffer callback — feeds HEVC encoder when active.
     * CRITICAL: only set this when HEVC is active. ScreenCapture.didOutputSampleBuffer
     * checks `if (self.onPixelBuffer)` — if non-nil, it skips LZ4 compression entirely.
     * Setting a block that just returns early still prevents LZ4 from running. */
    if (_hevcEncoder.isActive) {
        _capture.onPixelBuffer = ^(CVPixelBufferRef pixelBuffer, CMTime timestamp, uint64_t captureTimestampUs) {
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;
            if (!strongSelf->_hevcEncoder.isActive) return;

            if (strongSelf->_wirelessTransport.isConnected &&
                !strongSelf->_usbTransport.isConnected) {
                if (kWirelessUseTCPMedia) {
                    int32_t tcpInFlightNow = strongSelf->_wifiTCPMediaSendsInFlight;
                    if (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi) {
                        uint64_t nowUs = keydrd_host_time_us();
                        [strongSelf maybeRecoverWiFiTCPInFlightStallWithInFlight:tcpInFlightNow
                                                                            nowUs:nowUs
                                                                           reason:"pre-encode-gate"];
                        tcpInFlightNow = strongSelf->_wifiTCPMediaSendsInFlight;
                    }
                    if (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeDrops);
                        static int wifiTCPPreEncodeDropCount = 0;
                        wifiTCPPreEncodeDropCount++;
                        if (wifiTCPPreEncodeDropCount <= 10 || wifiTCPPreEncodeDropCount % 100 == 0) {
                            os_log(sLog, "WiFi pre-encode drop: reason=tcp-backpressure inFlight=%d limit=%d totalDropped=%d",
                                   tcpInFlightNow, kMaxMediaSendsInFlightWiFi, wifiTCPPreEncodeDropCount);
                        }
                        return;
                    }
                    static int wifiTCPPreEncodeAdmitCount = 0;
                    wifiTCPPreEncodeAdmitCount++;
                    if (wifiTCPPreEncodeAdmitCount <= 10 || wifiTCPPreEncodeAdmitCount % 200 == 0) {
                        os_log(sLog, "WiFi pre-encode admit: reason=tcp-backpressure-clear inFlight=%d limit=%d",
                               tcpInFlightNow, kMaxMediaSendsInFlightWiFi);
                    }
                    strongSelf.wirelessLastEncodeSubmitUs = 0;
                } else {
                NSUInteger queuedChunks = strongSelf->_wirelessTransport.queuedMediaChunkCount;
                uint64_t minIntervalUs = 0;
                const char *congestionReason = "none";
                if (queuedChunks > kWirelessSevereCongestionChunkThreshold) {
                    minIntervalUs = kWirelessSevereCongestedFrameIntervalUs;
                    congestionReason = "severe";
                } else if (queuedChunks > kWirelessMildCongestionChunkThreshold) {
                    minIntervalUs = kWirelessMildCongestedFrameIntervalUs;
                    congestionReason = "mild";
                }
                if (minIntervalUs > 0) {
                    uint64_t submitTimeUs = captureTimestampUs > 0 ? captureTimestampUs : keydrd_host_time_us();
                    uint64_t nextSubmitUs = strongSelf.wirelessLastEncodeSubmitUs;
                    if (nextSubmitUs > 0 &&
                        submitTimeUs + kWirelessPacingToleranceUs < nextSubmitUs) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfPreEncodeDrops);
                        static int wifiPreEncodeDropCount = 0;
                        wifiPreEncodeDropCount++;
                        if (wifiPreEncodeDropCount <= 10 || wifiPreEncodeDropCount % 100 == 0) {
                            os_log(sLog, "WiFi pre-encode drop: reason=%{public}s queued=%lu minInterval=%lluus delta=%lluus totalDropped=%d",
                                   congestionReason, (unsigned long)queuedChunks, minIntervalUs,
                                   nextSubmitUs > submitTimeUs ? nextSubmitUs - submitTimeUs : 0,
                                   wifiPreEncodeDropCount);
                        }
                        return;
                    }
                    uint64_t scheduledSubmitUs = nextSubmitUs > submitTimeUs ? nextSubmitUs : submitTimeUs;
                    strongSelf.wirelessLastEncodeSubmitUs = scheduledSubmitUs + minIntervalUs;
                    static int wifiPreEncodeAdmitCount = 0;
                    wifiPreEncodeAdmitCount++;
                    if (wifiPreEncodeAdmitCount <= 10 || wifiPreEncodeAdmitCount % 200 == 0) {
                        os_log(sLog, "WiFi pre-encode admit: reason=%{public}s queued=%lu scheduleDelay=%lluus",
                               congestionReason, (unsigned long)queuedChunks,
                               scheduledSubmitUs > submitTimeUs ? scheduledSubmitUs - submitTimeUs : 0);
                    }
                } else {
                    strongSelf.wirelessLastEncodeSubmitUs = 0;
                }
                }
            }

            [strongSelf->_hevcEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp captureTimestampUs:captureTimestampUs];
        };
    } else {
        /* LZ4 mode: clear onPixelBuffer so ScreenCapture falls through to LZ4 compression */
        _capture.onPixelBuffer = nil;
    }

    /* HEVC encoder output callback */
    _hevcEncoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;

        static int hevcSentCount = 0;
        if (hevcSentCount < 3) {
            os_log(sLog, "HEVC onEncodedFrame: seq=%u len=%zu flags=0x%02x, sending via UDP chunks",
                   header.seq, len, header.flags);
        }
        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfEncodedFrames);
        OSAtomicAdd32Barrier((int32_t)MIN(len, (size_t)INT32_MAX), &strongSelf->_wifiPerfEncodedBytes);
        if ((header.flags & KEYDRD_FLAG_KEYFRAME) != 0) {
            OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfKeyframes);
        }
        if ((int32_t)len > strongSelf->_wifiPerfMaxFrameBytes) {
            strongSelf->_wifiPerfMaxFrameBytes = (int32_t)MIN(len, (size_t)INT32_MAX);
        }

        /* Pipeline latency probe: capture → TCP send */
        if (header.ts_us > 0) {
            uint64_t nowUs = (uint64_t)(CACurrentMediaTime() * 1000000.0);
            uint64_t sendElapsedMs = (nowUs - header.ts_us) / 1000;
            if (hevcSentCount < 10 || hevcSentCount % 100 == 0) {
                os_log(sLog, "LATENCY-PROBE tcp-send: %llu ms since capture (seq=%u, %zu bytes)",
                       sendElapsedMs, header.seq, len);
            }
        }

        hevcSentCount++;

        [strongSelf sendMediaFrameHeaderToiPad:&header
                                       payload:data
                                 payloadLength:len];
    };
}

#pragma mark - Transport Send Helpers

- (void)sendMediaFrameToiPad:(const void *)data length:(size_t)len {
    if (len < sizeof(MediaFrameHeader)) return;

    const MediaFrameHeader *originalHeader = (const MediaFrameHeader *)data;
    const void *payload = (const uint8_t *)data + sizeof(MediaFrameHeader);
    size_t payloadLen = len - sizeof(MediaFrameHeader);

    if (_usbTransport.isConnected) {
        /* No frame size cap: LZ4 delta compression makes dropping frames
         * catastrophic — the iPad's delta reference desynchronizes and ALL
         * subsequent frames render as garbage until the next keyframe.
         * TCP backpressure (max 2 in-flight sends) is the only safe gate
         * because it fires rarely enough to avoid visible corruption. */

        /* USB NCM: media frames via TCP with length-prefix framing + backpressure.
         * TCP with TCP_NODELAY gives 0% loss at 1ms transport RTT.
         *
         * Backpressure: track in-flight TCP sends. If too many are queued
         * in the kernel buffer, drop this frame — the next frame will carry
         * fresher content anyway. This prevents multi-second queue buildup
         * that causes stale-timestamp latency inflation. */
        int32_t inFlight = OSAtomicIncrement32Barrier(&_tcpMediaSendsInFlight);
        if (inFlight <= 5 || inFlight % 10 == 0) {
            os_log(sLog, "USB send queued: seq=%u inFlight=%d bytes=%zu", originalHeader->seq, inFlight, len);
        }
        if (inFlight > kMaxMediaSendsInFlightUSB) {
            OSAtomicDecrement32Barrier(&_tcpMediaSendsInFlight);
            static int dropCount = 0;
            dropCount++;
            if (dropCount <= 10 || dropCount % 500 == 0) {
                os_log(sLog, "TCP backpressure: dropped frame seq=%u (%d in-flight, total dropped=%d)",
                       originalHeader->seq, inFlight - 1, dropCount);
            }
            return;
        }

        __weak SessionManager *weakSelf = self;
        [_usbTransport sendMediaViaTCP:data length:len completion:^(BOOL success) {
            SessionManager *strongSelf = weakSelf;
            if (strongSelf) {
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_tcpMediaSendsInFlight);
                if (!success || left < 2) {
                    os_log(sLog, "USB send completion: seq=%u success=%{public}s inFlightNow=%d",
                           originalHeader->seq, success ? "yes" : "no", left);
                }
            }
        }];
    } else if (_wirelessTransport.isConnected) {
        if (kWirelessUseTCPMedia) {
            /* WiFi media is now kept on the established TLS/TCP stream.
             * The paced DTLS chunk path still works, but on this workload it
             * was the dominant source of burst loss, recovery freezes, and the
             * reconnect cascade near the end of the long-run test. */
            static int wifiTCPMediaLogCount = 0;
            if (wifiTCPMediaLogCount < 10 || wifiTCPMediaLogCount % 200 == 0) {
                os_log(sLog, "WiFi media via TCP: seq=%u bytes=%zu",
                       originalHeader->seq, payloadLen);
            }
            wifiTCPMediaLogCount++;
            uint32_t seq = originalHeader->seq;
            uint64_t enqueueUs = keydrd_host_time_us();
            uint32_t sendGeneration = self.wifiTCPSendGeneration;
            int32_t inFlight = OSAtomicIncrement32Barrier(&_wifiTCPMediaSendsInFlight);
            if (inFlight > _wifiPerfTCPInFlightPeak) {
                _wifiPerfTCPInFlightPeak = inFlight;
            }
            if (inFlight <= 5 || inFlight % 30 == 0) {
                os_log(sLog, "WiFi TCP send queued: seq=%u inFlight=%d bytes=%zu",
                       seq, inFlight, len);
            }
            if (inFlight > kMaxMediaSendsInFlightWiFi) {
                OSAtomicDecrement32Barrier(&_wifiTCPMediaSendsInFlight);
                OSAtomicIncrement32Barrier(&_wifiPerfTCPSendDrops);
                static int wifiTCPSendDropCount = 0;
                wifiTCPSendDropCount++;
                uint64_t nowUs = keydrd_host_time_us();
                uint64_t lastKeyReqUs = self.wifiLastTCPDropKeyframeRequestUs;
                uint64_t sinceLastReqMs = (lastKeyReqUs > 0 && nowUs > lastKeyReqUs) ? (nowUs - lastKeyReqUs) / 1000 : UINT64_MAX;
                BOOL requestKeyframe = (lastKeyReqUs == 0 || sinceLastReqMs >= kWirelessTCPDropKeyframeCooldownMs);
                if (requestKeyframe) {
                    self.wifiLastTCPDropKeyframeRequestUs = nowUs;
                    OSAtomicIncrement32Barrier(&self->_wifiPerfTCPDropKeyframeRequests);
                    [self->_hevcEncoder requestKeyframe];
                } else {
                    OSAtomicIncrement32Barrier(&self->_wifiPerfTCPDropKeyframeSuppressed);
                }
                if (wifiTCPSendDropCount <= 10 || wifiTCPSendDropCount % 100 == 0) {
                    os_log(sLog, "WiFi TCP backpressure drop: seq=%u inFlight=%d limit=%d totalDropped=%d action=%{public}s reqCooldownMs=%llums sinceLastReqMs=%llums",
                           seq, inFlight - 1, kMaxMediaSendsInFlightWiFi, wifiTCPSendDropCount,
                           requestKeyframe ? "request-keyframe" : "cooldown-suppressed",
                           kWirelessTCPDropKeyframeCooldownMs,
                           sinceLastReqMs == UINT64_MAX ? 0 : sinceLastReqMs);
                }
                return;
            }
            __weak SessionManager *weakSelf = self;
            [_wirelessTransport sendMediaFrameViaTCP:data length:len completion:^(BOOL success) {
                SessionManager *strongSelf = weakSelf;
                if (!strongSelf) return;
                uint64_t doneUs = keydrd_host_time_us();
                uint32_t activeGeneration = strongSelf.wifiTCPSendGeneration;
                if (sendGeneration != activeGeneration) {
                    static int wifiTCPStaleCompletionLogCount = 0;
                    wifiTCPStaleCompletionLogCount++;
                    if (!success || wifiTCPStaleCompletionLogCount <= 10 || wifiTCPStaleCompletionLogCount % 100 == 0) {
                        os_log(sLog, "WiFi TCP stale completion ignored: seq=%u success=%{public}s elapsed=%llums sendGen=%u activeGen=%u sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no",
                               doneUs > enqueueUs ? (doneUs - enqueueUs) / 1000 : 0,
                               sendGeneration, activeGeneration,
                               success ? "sampled" : "forced",
                               wifiTCPStaleCompletionLogCount);
                    }
                    if (!success) {
                        OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSendDrops);
                    }
                    return;
                }
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_wifiTCPMediaSendsInFlight);
                if (left < 0) {
                    os_log_error(sLog, "WiFi TCP in-flight underflow clamp: seq=%u success=%{public}s left=%d action=reset-to-zero",
                                 seq, success ? "yes" : "no", left);
                    strongSelf->_wifiTCPMediaSendsInFlight = 0;
                    left = 0;
                }
                strongSelf.wifiTCPLastCompletionUs = doneUs;
                if (left < kMaxMediaSendsInFlightWiFi) {
                    strongSelf.wifiTCPInFlightSaturatedSinceUs = 0;
                }
                uint64_t elapsedMs = doneUs > enqueueUs ? (doneUs - enqueueUs) / 1000 : 0;
                if ((int32_t)elapsedMs > strongSelf->_wifiPerfTCPMaxCompletionMs) {
                    strongSelf->_wifiPerfTCPMaxCompletionMs = (int32_t)MIN(elapsedMs, (uint64_t)INT32_MAX);
                }
                static int wifiTCPSlowCompletionLogCount = 0;
                static int wifiTCPCompletionLogCount = 0;
                if (elapsedMs >= kWirelessTCPSlowCompletionThresholdMs) {
                    OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSlowCompletions);
                    wifiTCPSlowCompletionLogCount++;
                    if (elapsedMs >= 45 || !success || wifiTCPSlowCompletionLogCount <= 10 || wifiTCPSlowCompletionLogCount % 25 == 0) {
                        os_log(sLog, "WiFi TCP send slow completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no", elapsedMs, left,
                               (elapsedMs >= 45 || !success) ? "forced" : "sampled",
                               wifiTCPSlowCompletionLogCount);
                    }
                } else if (!success || left < 2) {
                    wifiTCPCompletionLogCount++;
                    if (!success || wifiTCPCompletionLogCount <= 10 || wifiTCPCompletionLogCount % 80 == 0) {
                        os_log(sLog, "WiFi TCP send completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d",
                               seq, success ? "yes" : "no", elapsedMs, left,
                               success ? "sampled" : "forced",
                               wifiTCPCompletionLogCount);
                    }
                }
                if (!success) {
                    OSAtomicIncrement32Barrier(&strongSelf->_wifiPerfTCPSendDrops);
                }
            }];
            return;
        }

        /* WiFi: keep the whole stream on UDP when possible.
         * Mixing startup/keyframes across TCP and UDP created visible stalls.
         * Pre-encode pacing decides how much content we feed the encoder.
         * At send time, only guard against path mixing and UDP queue blow-ups. */
        WirelessTransport *transport = _wirelessTransport;
        size_t maxChunkPayload = KEYDRD_MTU_WIFI - sizeof(MediaFrameHeader);
        NSUInteger chunkCount = (payloadLen + maxChunkPayload - 1) / maxChunkPayload;
        NSUInteger queuedChunks = transport.queuedMediaChunkCount;
        if ((int32_t)queuedChunks > _wifiPerfPeakQueuedChunks) {
            _wifiPerfPeakQueuedChunks = (int32_t)queuedChunks;
        }

        if (chunkCount > kWirelessLargeFrameChunkThreshold) {
            OSAtomicIncrement32Barrier(&_wifiPerfQueueDrops);
            static int oversizedDropCount = 0;
            oversizedDropCount++;
            if (oversizedDropCount <= 10 || oversizedDropCount % 100 == 0) {
                os_log(sLog, "WiFi oversized-frame drop: seq=%u chunks=%lu bytes=%zu queued=%lu totalDropped=%d",
                       originalHeader->seq, (unsigned long)chunkCount, payloadLen,
                       (unsigned long)queuedChunks, oversizedDropCount);
            }
            [_hevcEncoder requestKeyframe];
            return;
        }

        if (queuedChunks + chunkCount > kWirelessMaxQueuedChunks) {
            OSAtomicIncrement32Barrier(&_wifiPerfQueueDrops);
            static int wifiQueueDropCount = 0;
            wifiQueueDropCount++;
            if (wifiQueueDropCount <= 10 || wifiQueueDropCount % 100 == 0) {
                os_log(sLog, "WiFi queue-overflow drop: seq=%u chunks=%lu queued=%lu totalDropped=%d",
                       originalHeader->seq, (unsigned long)chunkCount,
                       (unsigned long)queuedChunks, wifiQueueDropCount);
            }
            [_hevcEncoder requestKeyframe];
            return;
        }

        chunk_frame(payload, payloadLen, originalHeader->seq, KEYDRD_MTU_WIFI,
                    originalHeader, ^(const void *chunk, size_t chunkLen) {
            [transport sendMediaFrame:chunk length:chunkLen];
        });
    }
}

- (void)sendMediaFrameHeaderToiPad:(const MediaFrameHeader *)header
                           payload:(const void *)payload
                     payloadLength:(size_t)payloadLen {
    if (!header || (!payload && payloadLen > 0)) {
        os_log_error(sLog, "USB send skipped: invalid header/payload args header=%{public}s payload=%{public}s payloadLen=%zu",
                     header ? "yes" : "no", payload ? "yes" : "no", payloadLen);
        return;
    }

    size_t totalLen = sizeof(MediaFrameHeader) + payloadLen;
    if (_usbTransport.isConnected) {
        int32_t inFlight = OSAtomicIncrement32Barrier(&_tcpMediaSendsInFlight);
        if (inFlight <= 5 || inFlight % 10 == 0) {
            os_log(sLog, "USB split-send queued: seq=%u inFlight=%d bytes=%zu payload=%zu",
                   header->seq, inFlight, totalLen, payloadLen);
        }
        if (inFlight > kMaxMediaSendsInFlightUSB) {
            OSAtomicDecrement32Barrier(&_tcpMediaSendsInFlight);
            static int splitDropCount = 0;
            splitDropCount++;
            if (splitDropCount <= 10 || splitDropCount % 500 == 0) {
                os_log(sLog, "USB split-send backpressure drop: seq=%u inFlight=%d totalDropped=%d",
                       header->seq, inFlight - 1, splitDropCount);
            }
            return;
        }

        __weak SessionManager *weakSelf = self;
        [_usbTransport sendMediaFrameWithHeader:header payload:payload payloadLength:payloadLen completion:^(BOOL success) {
            SessionManager *strongSelf = weakSelf;
            if (strongSelf) {
                int32_t left = OSAtomicDecrement32Barrier(&strongSelf->_tcpMediaSendsInFlight);
                if (!success || left < 2) {
                    os_log(sLog, "USB split-send completion: seq=%u success=%{public}s inFlightNow=%d",
                           header->seq, success ? "yes" : "no", left);
                }
            }
        }];
        return;
    }

    size_t frameLen = sizeof(MediaFrameHeader) + payloadLen;
    uint8_t *packet = malloc(frameLen);
    if (!packet) {
        os_log_error(sLog, "Media send skipped: packet allocation failed seq=%u frameLen=%zu", header->seq, frameLen);
        return;
    }
    memcpy(packet, header, sizeof(MediaFrameHeader));
    if (payloadLen > 0) {
        memcpy(packet + sizeof(MediaFrameHeader), payload, payloadLen);
    }
    [self sendMediaFrameToiPad:packet length:frameLen];
    free(packet);
}

- (void)sendInputEventToiPad:(const void *)data length:(size_t)len {
    if (_usbTransport.isConnected) {
        [_usbTransport sendInputEvent:data length:len];
    } else if (_wirelessTransport.isConnected) {
        [_wirelessTransport sendInputEvent:data length:len];
    }
}

- (void)resetWirelessPerformanceWindow {
    _wifiPerfEncodedFrames = 0;
    _wifiPerfEncodedBytes = 0;
    _wifiPerfKeyframes = 0;
    _wifiPerfMaxFrameBytes = 0;
    _wifiPerfPreEncodeDrops = 0;
    _wifiPerfQueueDrops = 0;
    _wifiPerfTCPFallbacks = 0;
    _wifiPerfPeakQueuedChunks = 0;
    _wifiPerfTCPSendDrops = 0;
    _wifiPerfTCPInFlightPeak = 0;
    _wifiPerfTCPSlowCompletions = 0;
    _wifiPerfTCPMaxCompletionMs = 0;
    _wifiPerfTCPDropKeyframeRequests = 0;
    _wifiPerfTCPDropKeyframeSuppressed = 0;
    _wifiPerfTCPStallRecoveries = 0;
    _wifiPerfAdaptiveDownshifts = 0;
    _wifiPerfAdaptiveUpshifts = 0;
    _wifiPerfAdaptiveHolds = 0;
    _wifiPerfAdaptiveFloorGuards = 0;
}

- (void)startWirelessPerformanceTimerIfNeeded {
    if (![NSThread isMainThread]) {
        __weak SessionManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf startWirelessPerformanceTimerIfNeeded];
        });
        return;
    }

    if (!_testMode || _wirelessPerformanceTimer != nil) {
        return;
    }

    [self resetWirelessPerformanceWindow];
    __weak SessionManager *weakSelf = self;
    _wirelessPerformanceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
            return;
        }
        if (!strongSelf->_wirelessTransport.isConnected || strongSelf->_usbTransport.isConnected) {
            return;
        }

        int32_t encodedFrames = strongSelf->_wifiPerfEncodedFrames;
        int32_t encodedBytes = strongSelf->_wifiPerfEncodedBytes;
        int32_t keyframes = strongSelf->_wifiPerfKeyframes;
        int32_t maxFrameBytes = strongSelf->_wifiPerfMaxFrameBytes;
        int32_t preDrops = strongSelf->_wifiPerfPreEncodeDrops;
        int32_t queueDrops = strongSelf->_wifiPerfQueueDrops;
        int32_t tcpFallbacks = strongSelf->_wifiPerfTCPFallbacks;
        int32_t tcpSendDrops = strongSelf->_wifiPerfTCPSendDrops;
        int32_t peakQueued = strongSelf->_wifiPerfPeakQueuedChunks;
        int32_t tcpInFlightPeak = strongSelf->_wifiPerfTCPInFlightPeak;
        int32_t tcpSlowCompletions = strongSelf->_wifiPerfTCPSlowCompletions;
        int32_t tcpMaxCompletionMs = strongSelf->_wifiPerfTCPMaxCompletionMs;
        int32_t tcpDropKeyReq = strongSelf->_wifiPerfTCPDropKeyframeRequests;
        int32_t tcpDropKeySupp = strongSelf->_wifiPerfTCPDropKeyframeSuppressed;
        int32_t tcpStallRecoveries = strongSelf->_wifiPerfTCPStallRecoveries;
        int32_t tcpInFlightNow = strongSelf->_wifiTCPMediaSendsInFlight;
        NSUInteger queuedNow = strongSelf->_wirelessTransport.queuedMediaChunkCount;
        double avgKB = encodedFrames > 0 ? ((double)encodedBytes / (double)encodedFrames) / 1024.0 : 0.0;
        const char *pacingMode = queuedNow >= 320 ? "congested" : (queuedNow <= 96 ? "fast" : "default");
        [strongSelf evaluateWiFiAdaptiveRateControl];
        int32_t adaptiveDown = strongSelf->_wifiPerfAdaptiveDownshifts;
        int32_t adaptiveUp = strongSelf->_wifiPerfAdaptiveUpshifts;
        int32_t adaptiveHold = strongSelf->_wifiPerfAdaptiveHolds;
        int32_t adaptiveFloor = strongSelf->_wifiPerfAdaptiveFloorGuards;

        os_log(sLog, "WiFi perf 1s: encoded=%d keyframes=%d avg=%.1fKB max=%dKB preDrop=%d queueDrop=%d tcpFallback=%d tcpSendDrop=%d tcpInFlight=%d tcpInFlightPeak=%d tcpSlow=%d tcpMaxCompletion=%dms tcpDropKeyReq=%d tcpDropKeySupp=%d tcpStallRec=%d adaptive[target=%dfps/%dMbps applied=%dfps/%dMbps down=%d up=%d hold=%d floor=%d healthyStreak=%d mildStreak=%d] queuedNow=%lu queuedPeak=%d pacing=%{public}s",
               encodedFrames, keyframes, avgKB, maxFrameBytes / 1024,
               preDrops, queueDrops, tcpFallbacks, tcpSendDrops,
               tcpInFlightNow, tcpInFlightPeak, tcpSlowCompletions, tcpMaxCompletionMs,
               tcpDropKeyReq, tcpDropKeySupp, tcpStallRecoveries,
               strongSelf->_wifiAdaptiveTargetFPS, strongSelf->_wifiAdaptiveTargetBitrate / 1000000,
               strongSelf->_wifiAdaptiveAppliedFPS, strongSelf->_wifiAdaptiveAppliedBitrate / 1000000,
               adaptiveDown, adaptiveUp, adaptiveHold, adaptiveFloor,
               strongSelf->_wifiAdaptiveHealthyStreak, strongSelf->_wifiAdaptiveMildCongestionStreak,
               (unsigned long)queuedNow, peakQueued, pacingMode);

        [strongSelf resetWirelessPerformanceWindow];
    }];
}

- (void)stopWirelessPerformanceTimer {
    if (![NSThread isMainThread]) {
        __weak SessionManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SessionManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf stopWirelessPerformanceTimer];
        });
        return;
    }

    [_wirelessPerformanceTimer invalidate];
    _wirelessPerformanceTimer = nil;
    [self resetWirelessPerformanceWindow];
}

- (void)resetWiFiAdaptiveControlState {
    _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
    _wifiAdaptiveTargetBitrate = kWirelessHEVCBitrate;
    _wifiAdaptiveAppliedFPS = 0;
    _wifiAdaptiveAppliedBitrate = 0;
    _wifiAdaptiveLastChangeUs = 0;
    _wifiAdaptiveHealthyStreak = 0;
    _wifiAdaptiveMildCongestionStreak = 0;
    _wifiAdaptiveSevereCongestionStreak = 0;
    os_log(sLog, "WiFi adaptive control reset: target=%dfps/%dMbps",
           _wifiAdaptiveTargetFPS, _wifiAdaptiveTargetBitrate / 1000000);
}

- (void)evaluateWiFiAdaptiveRateControl {
    if (_sessionState != SESSION_STREAMING || !_wirelessTransport.isConnected || _usbTransport.isConnected || !_hevcEncoder.isActive) {
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
        os_log(sLog, "WiFi adaptive hold: reason=inactive-path state=%{public}s wifi=%{public}d usb=%{public}d hevc=%{public}d",
               [self sessionStateName:_sessionState], _wirelessTransport.isConnected, _usbTransport.isConnected, _hevcEncoder.isActive);
        return;
    }

    uint64_t nowUs = keydrd_host_time_us();
    int32_t tcpInFlightNow = _wifiTCPMediaSendsInFlight;
    int32_t tcpSlowCompletions = _wifiPerfTCPSlowCompletions;
    int32_t tcpMaxCompletionMs = _wifiPerfTCPMaxCompletionMs;
    int32_t preDrops = _wifiPerfPreEncodeDrops;
    int32_t tcpSendDrops = _wifiPerfTCPSendDrops;
    int32_t queueDrops = _wifiPerfQueueDrops;
    uint64_t lastStallRecoveryUs = _wifiTCPLastStallRecoveryUs;
    uint64_t sinceStallRecoveryMs = (lastStallRecoveryUs > 0 && nowUs > lastStallRecoveryUs)
    ? (nowUs - lastStallRecoveryUs) / 1000 : UINT64_MAX;

    BOOL severeCongestion = (tcpSendDrops > 0) ||
                            (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi + 1) ||
                            (tcpMaxCompletionMs >= 52) ||
                            (preDrops >= 3);
    BOOL mildCongestion = !severeCongestion &&
                          ((tcpSlowCompletions >= 1) ||
                           (tcpMaxCompletionMs >= 24) ||
                             (preDrops > 0) ||
                             (tcpInFlightNow >= kMaxMediaSendsInFlightWiFi));
    BOOL tailRiskCongestion = !severeCongestion &&
                              ((tcpSlowCompletions >= 2) ||
                               (tcpMaxCompletionMs >= 32));
    BOOL healthy = !severeCongestion && !mildCongestion &&
                    tcpSendDrops == 0 && queueDrops == 0 && preDrops == 0 &&
                    tcpSlowCompletions == 0 && tcpInFlightNow <= 1 && tcpMaxCompletionMs < 18;
    BOOL postStallHold = (sinceStallRecoveryMs != UINT64_MAX &&
                          sinceStallRecoveryMs < kWirelessTCPPostRecoveryAdaptiveHoldMs);

    static int wifiAdaptiveEvalCount = 0;
    wifiAdaptiveEvalCount++;
    if (wifiAdaptiveEvalCount <= 10 || wifiAdaptiveEvalCount % 30 == 0 ||
        severeCongestion || tailRiskCongestion || tcpSendDrops > 0) {
        os_log(sLog, "WiFi adaptive eval: severe=%{public}s mild=%{public}s tailRisk=%{public}s healthy=%{public}s metrics[inFlight=%d slow=%d max=%dms preDrop=%d sendDrop=%d queueDrop=%d] streaks[h=%d m=%d s=%d] sampled=%{public}s count=%d",
               severeCongestion ? "yes" : "no",
               mildCongestion ? "yes" : "no",
               tailRiskCongestion ? "yes" : "no",
               healthy ? "yes" : "no",
               tcpInFlightNow, tcpSlowCompletions, tcpMaxCompletionMs,
               preDrops, tcpSendDrops, queueDrops,
               _wifiAdaptiveHealthyStreak, _wifiAdaptiveMildCongestionStreak, _wifiAdaptiveSevereCongestionStreak,
               (severeCongestion || tailRiskCongestion || tcpSendDrops > 0) ? "forced" : "sampled",
               wifiAdaptiveEvalCount);
    }

    int32_t prevFPS = _wifiAdaptiveTargetFPS;
    int32_t prevBitrate = _wifiAdaptiveTargetBitrate;
    int32_t targetFPS = prevFPS;
    int32_t targetBitrate = prevBitrate;
    NSString *reason = @"hold-stable";

    if (severeCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak += 1;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=severe-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums healthyStreak=%d mildStreak=%d severeStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs,
                   _wifiAdaptiveHealthyStreak, _wifiAdaptiveMildCongestionStreak, _wifiAdaptiveSevereCongestionStreak);
            return;
        }
        if (_wifiAdaptiveSevereCongestionStreak >= kWirelessAdaptiveSevereEscalationStreak) {
            targetFPS = kWirelessAdaptiveMinFPS;
            reason = @"downshift-severe-hard";
        } else {
            targetFPS = MAX(kWirelessAdaptiveMidFPS, prevFPS - kWirelessAdaptiveFPSStepDownSevereSoft);
            reason = @"downshift-severe-soft";
        }
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - kWirelessAdaptiveBitrateStepDown);
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (tailRiskCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak += 1;
        _wifiAdaptiveSevereCongestionStreak = 0;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=tail-risk-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums mildStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveMildCongestionStreak);
            return;
        }
        if (_wifiAdaptiveMildCongestionStreak < kWirelessAdaptiveMildCongestionStreak) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=tail-risk-hysteresis target=%dfps/%dMbps mildStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, _wifiAdaptiveMildCongestionStreak, kWirelessAdaptiveMildCongestionStreak);
            return;
        }
        targetFPS = MIN(prevFPS, kWirelessAdaptiveMidFPS);
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - kWirelessAdaptiveBitrateStepDown);
        reason = @"downshift-tail-guard";
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (mildCongestion) {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak += 1;
        _wifiAdaptiveSevereCongestionStreak = 0;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveDownshiftCooldownMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=mild-cooldown floor=%dfps target=%dfps/%dMbps sinceLast=%llums mildStreak=%d",
                   kWirelessAdaptiveMinFPS, prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveMildCongestionStreak);
            return;
        }
        if (_wifiAdaptiveMildCongestionStreak < kWirelessAdaptiveMildCongestionStreak) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=mild-hysteresis target=%dfps/%dMbps mildStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, _wifiAdaptiveMildCongestionStreak, kWirelessAdaptiveMildCongestionStreak);
            return;
        }
        targetFPS = prevFPS;
        targetBitrate = MAX(kWirelessAdaptiveMinBitrate, prevBitrate - kWirelessAdaptiveBitrateStepDown);
        reason = @"downshift-mild-bitrate";
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveDownshifts);
    } else if (healthy) {
        if (postStallHold) {
            _wifiAdaptiveHealthyStreak = 0;
            _wifiAdaptiveMildCongestionStreak = 0;
            _wifiAdaptiveSevereCongestionStreak = 0;
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=post-stall-recovery target=%dfps/%dMbps sinceRecovery=%llums holdMs=%llums",
                   prevFPS, prevBitrate / 1000000, sinceStallRecoveryMs, kWirelessTCPPostRecoveryAdaptiveHoldMs);
            return;
        }
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
        _wifiAdaptiveHealthyStreak += 1;
        uint64_t sinceMs = (_wifiAdaptiveLastChangeUs > 0 && nowUs > _wifiAdaptiveLastChangeUs) ? (nowUs - _wifiAdaptiveLastChangeUs) / 1000 : UINT64_MAX;
        if (sinceMs != UINT64_MAX && sinceMs < kWirelessAdaptiveRecoveryHoldMs) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=recovery-hold target=%dfps/%dMbps sinceLast=%llums healthyStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, sinceMs, _wifiAdaptiveHealthyStreak, kWirelessAdaptiveUpshiftHealthyStreak);
            return;
        }
        if (_wifiAdaptiveHealthyStreak < kWirelessAdaptiveUpshiftHealthyStreak) {
            OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
            os_log(sLog, "WiFi adaptive hold: reason=healthy-hysteresis target=%dfps/%dMbps healthyStreak=%d threshold=%d",
                   prevFPS, prevBitrate / 1000000, _wifiAdaptiveHealthyStreak, kWirelessAdaptiveUpshiftHealthyStreak);
            return;
        }
        if (prevFPS < kWirelessAdaptiveMaxFPS) {
            targetFPS = MIN(kWirelessAdaptiveMaxFPS, prevFPS + kWirelessAdaptiveFPSStepUp);
        }
        if (prevBitrate < kWirelessAdaptiveMaxBitrate) {
            targetBitrate = MIN(kWirelessAdaptiveMaxBitrate, prevBitrate + kWirelessAdaptiveBitrateStepUp);
        }
        reason = @"recovery-upshift";
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveUpshifts);
    } else {
        _wifiAdaptiveHealthyStreak = 0;
        _wifiAdaptiveMildCongestionStreak = 0;
        _wifiAdaptiveSevereCongestionStreak = 0;
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveHolds);
        os_log(sLog, "WiFi adaptive hold: reason=transitional target=%dfps/%dMbps slow=%d maxMs=%d preDrop=%d sendDrop=%d",
               prevFPS, prevBitrate / 1000000, tcpSlowCompletions, tcpMaxCompletionMs, preDrops, tcpSendDrops);
        return;
    }

    targetFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, targetFPS));
    targetBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, targetBitrate));

    _wifiAdaptiveTargetFPS = targetFPS;
    _wifiAdaptiveTargetBitrate = targetBitrate;
    [self applyWiFiAdaptiveRateTargetsIfNeededWithReason:reason nowUs:nowUs];
}

- (BOOL)maybeRecoverWiFiTCPInFlightStallWithInFlight:(int32_t)inFlight nowUs:(uint64_t)nowUs reason:(const char *)reason {
    if (inFlight < kMaxMediaSendsInFlightWiFi) {
        self.wifiTCPInFlightSaturatedSinceUs = 0;
        return NO;
    }

    @synchronized (self) {
        uint64_t saturatedSinceUs = self.wifiTCPInFlightSaturatedSinceUs;
        if (saturatedSinceUs == 0) {
            self.wifiTCPInFlightSaturatedSinceUs = nowUs;
            self.wifiTCPStallLastLogUs = nowUs;
            os_log(sLog, "WiFi TCP saturation enter: reason=%{public}s inFlight=%d limit=%d",
                   reason ?: "unknown", inFlight, kMaxMediaSendsInFlightWiFi);
            return NO;
        }

        uint64_t saturatedMs = nowUs > saturatedSinceUs ? (nowUs - saturatedSinceUs) / 1000 : 0;
        uint64_t lastCompletionUs = self.wifiTCPLastCompletionUs;
        uint64_t noCompletionMs = (lastCompletionUs > 0 && nowUs > lastCompletionUs) ? (nowUs - lastCompletionUs) / 1000 : UINT64_MAX;
        uint64_t lastRecoveryUs = self.wifiTCPLastStallRecoveryUs;
        uint64_t sinceRecoveryMs = (lastRecoveryUs > 0 && nowUs > lastRecoveryUs) ? (nowUs - lastRecoveryUs) / 1000 : UINT64_MAX;

        if (saturatedMs < kWirelessTCPStallSaturationThresholdMs ||
            noCompletionMs < kWirelessTCPStallNoCompletionThresholdMs) {
            uint64_t lastLogUs = self.wifiTCPStallLastLogUs;
            if (lastLogUs == 0 || nowUs - lastLogUs >= kWirelessTCPStallLogIntervalMs * 1000) {
                self.wifiTCPStallLastLogUs = nowUs;
                os_log(sLog, "WiFi TCP saturation observe: reason=%{public}s inFlight=%d sat=%llums noCompletion=%llums thresholdSat=%llums thresholdNoCompletion=%llums",
                       reason ?: "unknown", inFlight, saturatedMs,
                       noCompletionMs == UINT64_MAX ? 0 : noCompletionMs,
                       kWirelessTCPStallSaturationThresholdMs,
                       kWirelessTCPStallNoCompletionThresholdMs);
            }
            return NO;
        }

        if (sinceRecoveryMs != UINT64_MAX && sinceRecoveryMs < kWirelessTCPStallRecoveryCooldownMs) {
            uint64_t lastLogUs = self.wifiTCPStallLastLogUs;
            if (lastLogUs == 0 || nowUs - lastLogUs >= kWirelessTCPStallLogIntervalMs * 1000) {
                self.wifiTCPStallLastLogUs = nowUs;
                os_log(sLog, "WiFi TCP stall recovery hold: reason=%{public}s inFlight=%d sat=%llums noCompletion=%llums sinceRecovery=%llums cooldown=%llums",
                       reason ?: "unknown", inFlight, saturatedMs,
                       noCompletionMs == UINT64_MAX ? 0 : noCompletionMs,
                       sinceRecoveryMs, kWirelessTCPStallRecoveryCooldownMs);
            }
            return NO;
        }

        int32_t oldInFlight = _wifiTCPMediaSendsInFlight;
        uint32_t oldGeneration = self.wifiTCPSendGeneration;
        self.wifiTCPSendGeneration = oldGeneration + 1;
        _wifiTCPMediaSendsInFlight = 0;
        self.wifiTCPInFlightSaturatedSinceUs = 0;
        self.wifiTCPLastStallRecoveryUs = nowUs;
        self.wifiTCPStallLastLogUs = nowUs;
        OSAtomicIncrement32Barrier(&_wifiPerfTCPStallRecoveries);

        uint64_t lastKeyReqUs = self.wifiLastTCPDropKeyframeRequestUs;
        uint64_t sinceLastReqMs = (lastKeyReqUs > 0 && nowUs > lastKeyReqUs) ? (nowUs - lastKeyReqUs) / 1000 : UINT64_MAX;
        BOOL requestKeyframe = (lastKeyReqUs == 0 || sinceLastReqMs >= kWirelessTCPDropKeyframeCooldownMs);
        if (requestKeyframe) {
            self.wifiLastTCPDropKeyframeRequestUs = nowUs;
            OSAtomicIncrement32Barrier(&_wifiPerfTCPDropKeyframeRequests);
            [self->_hevcEncoder requestKeyframe];
        } else {
            OSAtomicIncrement32Barrier(&self->_wifiPerfTCPDropKeyframeSuppressed);
        }

        os_log_error(sLog, "WiFi TCP stall recovery: reason=%{public}s action=reset-inflight oldInFlight=%d sat=%llums noCompletion=%llums gen=%u->%u keyframe=%{public}s cooldownMs=%llums",
                     reason ?: "unknown", oldInFlight, saturatedMs,
                     noCompletionMs == UINT64_MAX ? 0 : noCompletionMs,
                     oldGeneration, self.wifiTCPSendGeneration,
                     requestKeyframe ? "requested" : "cooldown-suppressed",
                     kWirelessTCPStallRecoveryCooldownMs);
        return YES;
    }
}

- (void)applyWiFiAdaptiveRateTargetsIfNeededWithReason:(NSString *)reason nowUs:(uint64_t)nowUs {
    int32_t requestedFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, _wifiAdaptiveTargetFPS));
    int32_t requestedBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, _wifiAdaptiveTargetBitrate));
    int32_t targetFPS = requestedFPS;
    int32_t targetBitrate = requestedBitrate;

    int32_t currentFPS = _wifiAdaptiveAppliedFPS > 0 ? _wifiAdaptiveAppliedFPS : kWirelessAdaptiveMaxFPS;
    int32_t currentBitrate = _wifiAdaptiveAppliedBitrate > 0 ? _wifiAdaptiveAppliedBitrate : kWirelessHEVCBitrate;
    int32_t fpsDelta = requestedFPS - currentFPS;
    int32_t bitrateDelta = requestedBitrate - currentBitrate;

    if (fpsDelta > kWirelessAdaptiveMaxUpshiftFPSDelta) {
        targetFPS = currentFPS + kWirelessAdaptiveMaxUpshiftFPSDelta;
    } else if (fpsDelta < -kWirelessAdaptiveMaxDownshiftFPSDelta) {
        targetFPS = currentFPS - kWirelessAdaptiveMaxDownshiftFPSDelta;
    }

    if (bitrateDelta > kWirelessAdaptiveMaxUpshiftBitrateDelta) {
        targetBitrate = currentBitrate + kWirelessAdaptiveMaxUpshiftBitrateDelta;
    } else if (bitrateDelta < -kWirelessAdaptiveMaxDownshiftBitrateDelta) {
        targetBitrate = currentBitrate - kWirelessAdaptiveMaxDownshiftBitrateDelta;
    }

    targetFPS = MAX(kWirelessAdaptiveMinFPS, MIN(kWirelessAdaptiveMaxFPS, targetFPS));
    targetBitrate = MAX(kWirelessAdaptiveMinBitrate, MIN(kWirelessAdaptiveMaxBitrate, targetBitrate));

    BOOL floorGuardEngaged = (requestedFPS <= kWirelessAdaptiveMinFPS || targetFPS <= kWirelessAdaptiveMinFPS);
    if (targetFPS < kWirelessAdaptiveMinFPS) {
        floorGuardEngaged = YES;
        targetFPS = kWirelessAdaptiveMinFPS;
    }
    if (floorGuardEngaged) {
        OSAtomicIncrement32Barrier(&_wifiPerfAdaptiveFloorGuards);
    }

    BOOL fpsChanged = (_wifiAdaptiveAppliedFPS != targetFPS);
    BOOL bitrateChanged = (_wifiAdaptiveAppliedBitrate != targetBitrate);
    if (!fpsChanged && !bitrateChanged) {
        if (requestedFPS != targetFPS || requestedBitrate != targetBitrate) {
            os_log(sLog, "WiFi adaptive smooth hold: reason=%{public}s requested=%dfps/%dMbps applied=%dfps/%dMbps maxStepUp=%dfps/%dKbps maxStepDown=%dfps/%dKbps",
                   reason.UTF8String ?: "none",
                   requestedFPS, requestedBitrate / 1000000,
                   _wifiAdaptiveAppliedFPS, _wifiAdaptiveAppliedBitrate / 1000000,
                   kWirelessAdaptiveMaxUpshiftFPSDelta, kWirelessAdaptiveMaxUpshiftBitrateDelta / 1000,
                   kWirelessAdaptiveMaxDownshiftFPSDelta, kWirelessAdaptiveMaxDownshiftBitrateDelta / 1000);
        }
        return;
    }

    _capture.captureFPS = (uint32_t)targetFPS;
    if (fpsChanged && _captureWidth > 0 && _captureHeight > 0) {
        [_capture updateCaptureResolution:_captureWidth height:_captureHeight];
    }
    [_hevcEncoder updateStreamingRateWithFPS:targetFPS bitrate:targetBitrate reason:reason];

    _wifiAdaptiveAppliedFPS = targetFPS;
    _wifiAdaptiveAppliedBitrate = targetBitrate;
    _wifiAdaptiveLastChangeUs = nowUs;
    os_log(sLog, "WiFi adaptive apply: reason=%{public}s requested=%dfps/%dMbps applied=%dfps/%dMbps prev=%dfps/%dMbps floor=%dfps floorGuard=%{public}s smoothDelta=%+dfps/%+dKbps",
           reason.UTF8String ?: "none",
           requestedFPS, requestedBitrate / 1000000,
           targetFPS, targetBitrate / 1000000,
           currentFPS, currentBitrate / 1000000,
           kWirelessAdaptiveMinFPS, floorGuardEngaged ? "engaged" : "clear",
           targetFPS - currentFPS, (targetBitrate - currentBitrate) / 1000);
}

#pragma mark - Latency Probe

- (void)startLatencyProbeTimer {
    [_latencyProbeTimer invalidate];
    __weak SessionManager *weakSelf = self;
    _latencyProbeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) {
            [timer invalidate];
            return;
        }
        [strongSelf sendLatencyProbeResponse];
    }];
}

- (void)sendLatencyProbeResponse {
    /* Latency probes are echoed back -- iPad sends, Mac echoes.
     * This timer is just a keepalive. The actual echo happens in handleReceivedInputEvent. */
}

#pragma mark - Received Input Events from iPad

- (void)handleReceivedInputEvent:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader)) return;

    const InputEventHeader *header = (const InputEventHeader *)data;

    switch (header->type) {
        case KEYDRD_INPUT_RES_MATCH_REQUEST:
            [self handleResolutionMatchRequest:data length:length];
            break;

        case KEYDRD_INPUT_MODE_CHANGE:
            [self handleModeChangeFromiPad:data length:length];
            break;

        case KEYDRD_INPUT_VIEWPORT_REPORT:
            [self handleViewportReport:data length:length];
            break;

        case KEYDRD_INPUT_CLOCK_SYNC_REQ:
            [self handleClockSyncRequest:data length:length];
            break;

        case KEYDRD_INPUT_LATENCY_PROBE:
            /* Echo latency probe back to iPad immediately */
            [self sendInputEventToiPad:data length:length];
            break;

        case KEYDRD_INPUT_KEEPALIVE:
            /* Just a keepalive, no action needed */
            break;

        default:
            os_log_debug(sLog, "Unhandled input event type: 0x%02x", header->type);
            break;
    }
}

#pragma mark - Peer Address Update (Mac → iPad)

- (void)sendPeerAddressUpdate {
    /* Get Mac's USB NCM IP from the USB transport */
    NSString *usbIP = _usbTransport.localIPAddress;
    if (!usbIP || usbIP.length == 0) {
        os_log(sLog, "sendPeerAddressUpdate: no USB NCM IP available");
        return;
    }

    os_log(sLog, "Sending peer address update to iPad: %{public}@ (before WiFi→USB switch)", usbIP);

    const char *ipCStr = [usbIP UTF8String];
    size_t ipLen = strlen(ipCStr) + 1; /* include null terminator */
    size_t totalLen = sizeof(InputEventHeader) + ipLen;

    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    InputEventHeader header;
    header.type = KEYDRD_INPUT_PEER_ADDRESS_UPDATE;
    header.ts_us = [self currentTimestampUs];

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), ipCStr, ipLen);

    /* Send over whatever transport is alive (WiFi at this point) */
    [self sendInputEventToiPad:packet length:totalLen];
    free(packet);
}

#pragma mark - Viewport Report (iPad → Mac)

- (void)_autoMatchDisplayModeForViewport {
    if (_viewportWidth == 0 || _viewportHeight == 0) return;

    CGDirectDisplayID mainDisplay = CGMainDisplayID();

    /* Store current display mode for revert on disconnect (if not already stored) */
    if (!_resolutionChanged) {
        CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
        if (currentMode) {
            if (_storedDisplayMode) {
                CGDisplayModeRelease(_storedDisplayMode);
            }
            _storedDisplayMode = currentMode;
            /* Don't release — we keep it for revert */
        }
    }

    /* Get all available display modes */
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(mainDisplay, NULL);
    if (!allModes) {
        os_log_error(sLog, "_autoMatchDisplayModeForViewport: failed to get display modes");
        return;
    }

    /* Find the BEST display mode for remote desktop:
     *
     * PRIORITY: HiDPI (Retina) modes >> 1x modes.
     * A 2x mode at 2880x1864 with slight SCStream downscale (0.96x) gives FAR better
     * text quality than a 1x mode at 2704x1756 where macOS renders text without HiDPI.
     *
     * Algorithm:
     * 1. First pass: find closest HiDPI mode (pixel width > logical width) where
     *    pixel width >= 85% of viewport width.
     * 2. If no HiDPI mode qualifies, fall back to closest 1x mode.
     * 3. Among qualifying modes, pick the one whose pixel count is closest to viewport
     *    (prefer modes >= viewport to avoid upscale, but accept smaller within 15% DPI). */
    uint32_t vpW = _viewportWidth;
    uint32_t vpH = _viewportHeight;
    size_t vpPixelCount = (size_t)vpW * (size_t)vpH;
    float minWidth = 0.85f * (float)vpW;

    CGDisplayModeRef bestHiDPI = NULL;
    size_t bestHiDPIDiff = SIZE_MAX;
    size_t bestHiDPIPixelW = 0, bestHiDPIPixelH = 0;

    CGDisplayModeRef best1x = NULL;
    size_t best1xDiff = SIZE_MAX;
    size_t best1xPixelW = 0, best1xPixelH = 0;

    /* Also check the current mode — maybe it's already optimal */
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
    size_t currentPixelW = 0, currentPixelH = 0;
    float currentScale = 1.0f;
    if (currentMode) {
        currentPixelW = CGDisplayModeGetPixelWidth(currentMode);
        currentPixelH = CGDisplayModeGetPixelHeight(currentMode);
        size_t currentLogW = CGDisplayModeGetWidth(currentMode);
        currentScale = (currentLogW > 0) ? (float)currentPixelW / (float)currentLogW : 1.0f;
        CGDisplayModeRelease(currentMode);
    }

    CFIndex modeCount = CFArrayGetCount(allModes);
    os_log(sLog, "_autoMatchDisplayModeForViewport: scanning %ld modes for viewport %ux%u (minWidth=%.0f, currentScale=%.1f)",
           (long)modeCount, vpW, vpH, minWidth, currentScale);

    for (CFIndex i = 0; i < modeCount; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t modeW = CGDisplayModeGetPixelWidth(mode);
        size_t modeH = CGDisplayModeGetPixelHeight(mode);
        size_t modeLogW = CGDisplayModeGetWidth(mode);

        if (modeW == 0 || modeH == 0) continue;

        /* DPI constraint: pixel width must be >= 85% of viewport width */
        if ((float)modeW < minWidth) continue;

        /* Determine if this is a HiDPI (Retina) mode */
        BOOL isHiDPI = (modeLogW > 0 && modeW > modeLogW);

        /* Compute difference from viewport pixel count */
        size_t modePixelCount = modeW * modeH;
        size_t diff = (modePixelCount > vpPixelCount)
            ? (modePixelCount - vpPixelCount)
            : (vpPixelCount - modePixelCount);

        if (isHiDPI) {
            if (diff < bestHiDPIDiff) {
                bestHiDPI = mode;
                bestHiDPIDiff = diff;
                bestHiDPIPixelW = modeW;
                bestHiDPIPixelH = modeH;
            }
        } else {
            if (diff < best1xDiff) {
                best1x = mode;
                best1xDiff = diff;
                best1xPixelW = modeW;
                best1xPixelH = modeH;
            }
        }
    }

    /* Prefer HiDPI mode; fall back to 1x only if no HiDPI available */
    CGDisplayModeRef bestMode;
    size_t bestPixelWidth, bestPixelHeight;
    if (bestHiDPI) {
        bestMode = bestHiDPI;
        bestPixelWidth = bestHiDPIPixelW;
        bestPixelHeight = bestHiDPIPixelH;
        os_log(sLog, "_autoMatchDisplayModeForViewport: selected HiDPI mode %zux%zu (diff=%zu from viewport)",
               bestPixelWidth, bestPixelHeight, bestHiDPIDiff);
    } else if (best1x) {
        bestMode = best1x;
        bestPixelWidth = best1xPixelW;
        bestPixelHeight = best1xPixelH;
        os_log(sLog, "_autoMatchDisplayModeForViewport: no HiDPI mode, using 1x mode %zux%zu",
               bestPixelWidth, bestPixelHeight);
    } else {
        bestMode = NULL;
        bestPixelWidth = 0;
        bestPixelHeight = 0;
    }

    if (!bestMode) {
        os_log(sLog, "_autoMatchDisplayModeForViewport: no suitable mode found");
        CFRelease(allModes);
        return;
    }

    /* Check if the best mode differs from the current display mode */
    if (bestPixelWidth == currentPixelW && bestPixelHeight == currentPixelH) {
        os_log(sLog, "_autoMatchDisplayModeForViewport: current mode %zux%zu already optimal",
               currentPixelW, currentPixelH);
        CFRelease(allModes);
        return;
    }

    /* Read logical width BEFORE releasing allModes (bestMode belongs to allModes) */
    size_t bestLogicalWidth = CGDisplayModeGetWidth(bestMode);

    /* Switch display mode */
    os_log(sLog, "_autoMatchDisplayModeForViewport: switching %zux%zu -> %zux%zu (viewport: %ux%u)",
           currentPixelW, currentPixelH, bestPixelWidth, bestPixelHeight, vpW, vpH);

    CGError err = CGDisplaySetDisplayMode(mainDisplay, bestMode, NULL);
    CFRelease(allModes);

    if (err != kCGErrorSuccess) {
        os_log_error(sLog, "_autoMatchDisplayModeForViewport: CGDisplaySetDisplayMode failed: %d", err);
        return;
    }

    _resolutionChanged = YES;

    /* Update capture dimensions to the new native pixel dimensions.
     * SCStream will capture at 1:1 (no downscale blur). */
    _captureWidth = (uint32_t)bestPixelWidth;
    _captureHeight = (uint32_t)bestPixelHeight;
    _captureScale = (bestLogicalWidth > 0) ? (float)bestPixelWidth / (float)bestLogicalWidth : 2.0f;

    os_log(sLog, "_autoMatchDisplayModeForViewport: display mode changed to %ux%u @%.1fx",
           _captureWidth, _captureHeight, _captureScale);
}

- (void)handleViewportReport:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader) + sizeof(ViewportReportPayload)) {
        os_log_error(sLog, "Viewport report too short: %zu bytes", length);
        return;
    }

    const ViewportReportPayload *payload =
        (const ViewportReportPayload *)((const uint8_t *)data + sizeof(InputEventHeader));

    uint32_t oldViewportWidth = _viewportWidth;
    uint32_t oldViewportHeight = _viewportHeight;
    _viewportWidth = payload->viewport_width;
    _viewportHeight = payload->viewport_height;
    _viewportReceived = YES;

    BOOL viewportChanged = (_viewportWidth != oldViewportWidth) || (_viewportHeight != oldViewportHeight);
    os_log(sLog, "iPad viewport report: %ux%u (previous: %ux%u, changed=%{public}d, Mac display: %ux%u, hevcActive=%{public}d, usbConnected=%{public}d)",
           _viewportWidth, _viewportHeight,
           oldViewportWidth, oldViewportHeight, viewportChanged,
           _captureWidth, _captureHeight, _hevcEncoder.isActive, _usbTransport.isConnected);

    if (!_usbTransport.isConnected && _hevcEncoder.isActive) {
        uint32_t expectedEncodeWidth = _viewportWidth;
        uint32_t expectedEncodeHeight = _viewportHeight;
        keydrd_limit_size(_viewportWidth, _viewportHeight,
                          kWirelessMaxEncodeWidth, kWirelessMaxEncodeHeight,
                          &expectedEncodeWidth, &expectedEncodeHeight);
        if (!viewportChanged &&
            _captureWidth == expectedEncodeWidth &&
            _captureHeight == expectedEncodeHeight) {
            os_log(sLog, "Skipping redundant HEVC restart on unchanged viewport during active wireless session (expected=%ux%u capture=%ux%u)",
                   expectedEncodeWidth, expectedEncodeHeight, _captureWidth, _captureHeight);
            return;
        }
    }

    /* In LZ4 mode (wired USB), no HEVC encoder needed.
     * Resize capture to viewport dims, send geometry update to iPad so LZ4
     * decompressor uses the correct size, THEN start capture.
     * Order matters: geometry update must arrive before frames at new size. */
    if (!_hevcEncoder.isActive && _usbTransport.isConnected) {
        os_log(sLog, "LZ4 mode (USB) — setting capture to viewport %ux%u, then starting capture",
               _viewportWidth, _viewportHeight);
        _captureWidth = _viewportWidth;
        _captureHeight = _viewportHeight;

        /* Tell iPad the frame size BEFORE any frames arrive */
        [self sendGeometryUpdate];

        /* Set capture resolution (SCStream config update) */
        _capture.captureWidth = _viewportWidth;
        _capture.captureHeight = _viewportHeight;

        /* NOW start capture — iPad decompressor is already at correct size */
        [self _beginCapture];

        if (self.onResolutionChanged) {
            self.onResolutionChanged(_captureWidth, _captureHeight);
        }
        return;
    }

    /* HEVC mode (WiFi): start encoder + reconfigure capture at viewport resolution */
    [self _startEncoderAtViewportResolution];
}

- (void)_startEncoderAtViewportResolution {
    if (_viewportWidth == 0 || _viewportHeight == 0) {
        os_log_error(sLog, "_startEncoderAtViewportResolution: viewport not set");
        return;
    }

    /* Always use viewport dimensions for encoding — no display mode matching.
     * SCStream downscales from Mac native (e.g. 3600x2338) to viewport (2752x1786). */
    uint32_t encodeWidth = _viewportWidth;
    uint32_t encodeHeight = _viewportHeight;

    /* USB: AverageBitRate=40Mbps — realistic target the encoder can track.
     * At 150Mbps the encoder undershoots to 6Mbps (too much headroom).
     * At 40Mbps it produces 15-30Mbps actual = good text quality + fast encode.
     * Quality-based (0.85-0.95) was tried but makes encoder work much harder
     * per frame (~40ms vs ~20ms), causing stutter on complex content.
     * WiFi: use a lower, steadier operating point. 120 Hz / 20 Mbps produced
     * 300-800 KB frames and overwhelmed the paced DTLS path. */
    int bitrate;
    float quality;
    int fps;
    if (_usbTransport.isConnected) {
        bitrate = 40000000; /* 40 Mbps — realistic target, not undershooting */
        quality = 0.0f;     /* bitrate-based, faster than quality-based */
        fps = 120;
        _capture.captureFPS = 120;
        self.wirelessLastEncodeSubmitUs = 0;
        [self resetWiFiAdaptiveControlState];
    } else {
        bitrate = kWirelessHEVCBitrate;
        quality = 0.0f;     /* bitrate-based */
        fps = kWirelessHEVCFPS;
        _capture.captureFPS = fps;
        self.wirelessLastEncodeSubmitUs = 0;
        _wifiAdaptiveTargetFPS = kWirelessAdaptiveMaxFPS;
        _wifiAdaptiveTargetBitrate = kWirelessHEVCBitrate;
        _wifiAdaptiveAppliedFPS = fps;
        _wifiAdaptiveAppliedBitrate = bitrate;
        _wifiAdaptiveLastChangeUs = keydrd_host_time_us();
        keydrd_limit_size(_viewportWidth, _viewportHeight,
                          kWirelessMaxEncodeWidth, kWirelessMaxEncodeHeight,
                          &encodeWidth, &encodeHeight);
        if (encodeWidth != _viewportWidth || encodeHeight != _viewportHeight) {
            os_log(sLog, "WiFi encode cap: viewport %ux%u -> %ux%u to keep keyframes on UDP",
                   _viewportWidth, _viewportHeight, encodeWidth, encodeHeight);
        }
    }

    os_log(sLog, "Starting HEVC encoder: %ux%u @%dfps bitrate=%dMbps (capture: %ux%u, viewport: %ux%u)",
           encodeWidth, encodeHeight, fps, bitrate / 1000000,
           _captureWidth, _captureHeight, _viewportWidth, _viewportHeight);

    [_hevcEncoder startWithWidth:(int)encodeWidth
                          height:(int)encodeHeight
                             fps:fps
                         bitrate:bitrate
                         quality:quality];

    /* Live-reconfigure capture resolution.
     * Uses SCStream.updateConfiguration — no stop/start, no Sequoia re-auth prompt. */
    [_capture updateCaptureResolution:encodeWidth height:encodeHeight];

    /* Update captureWidth/Height so handshake/geometry messages reflect actual encode size */
    _captureWidth = encodeWidth;
    _captureHeight = encodeHeight;

    /* Reconfigure frame delivery */
    [self configureFrameDelivery];

    /* Send geometry update so iPad knows the new frame dimensions */
    [self sendGeometryUpdate];

    /* Notify Mac UI (menu bar) of the new resolution */
    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

#pragma mark - Clock Sync (Cristian's Algorithm)

- (void)handleClockSyncRequest:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader)) return;

    /* t2: Mac receive host time (as close to reception as possible) */
    uint64_t t2Us = keydrd_host_time_us();

    /* Extract t1 from request (iPad send time, stored in ts_us) */
    const InputEventHeader *reqHeader = (const InputEventHeader *)data;
    uint64_t t1Us = reqHeader->ts_us;

    /* Build response: InputEventHeader + ClockSyncResponse */
    size_t totalLen = sizeof(InputEventHeader) + sizeof(ClockSyncResponse);
    uint8_t packet[sizeof(InputEventHeader) + sizeof(ClockSyncResponse)];

    /* t3: Mac send host time (just before send) */
    uint64_t t3Us = keydrd_host_time_us();

    InputEventHeader respHeader;
    respHeader.type = KEYDRD_INPUT_CLOCK_SYNC_RESP;
    respHeader.ts_us = t3Us;

    ClockSyncResponse resp;
    resp.t1_ipad_us = t1Us;
    resp.t2_mac_us = t2Us;
    resp.t3_mac_us = t3Us;

    memcpy(packet, &respHeader, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &resp, sizeof(ClockSyncResponse));

    [self sendInputEventToiPad:packet length:totalLen];
}

#pragma mark - Mode Change from iPad

- (void)handleModeChangeFromiPad:(const void *)data length:(size_t)length {
    /* After the 9-byte InputEventHeader, subtype byte indicates the change type */
    if (length < sizeof(InputEventHeader) + 1) return;

    const uint8_t *payload = (const uint8_t *)data + sizeof(InputEventHeader);
    uint8_t subtype = payload[0];

    switch (subtype) {
        case KEYDRD_MODE_CHANGE_ECO: {
            /* Eco mode change: next byte is 0x01 (on) or 0x00 (off) */
            if (length < sizeof(InputEventHeader) + 2) return;
            BOOL ecoOn = (payload[1] != 0);
            [self handleEcoModeRequest:ecoOn];
            break;
        }
        case KEYDRD_MODE_CHANGE_REQUEST_KEYFRAME: {
            os_log(sLog, "Immediate HEVC keyframe requested by iPad recovery path");
            [_hevcEncoder requestKeyframe];
            break;
        }
        default:
            os_log_debug(sLog, "Unknown mode change subtype: 0x%02x", subtype);
            break;
    }
}

#pragma mark - Eco Mode

- (void)handleEcoModeRequest:(BOOL)ecoOn {
    os_log(sLog, "Eco mode request: %{public}s", ecoOn ? "ON" : "OFF");

    if (ecoOn) {
        _isEcoMode = YES;
        _capture.captureFPS = kEcoFPS;

        /* Activate HEVC at reduced resolution (1080p) and 30fps.
         * Eco mode always uses bitrate-based encoding (quality=0). */
        [_hevcEncoder startWithWidth:kEcoWidth height:kEcoHeight fps:kEcoFPS bitrate:kEcoBitrate quality:0];

        /* Reconfigure frame delivery for HEVC path */
        [self configureFrameDelivery];
    } else {
        _isEcoMode = NO;

        /* Restart HEVC at viewport resolution (not Mac native) */
        if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
            [self _startEncoderAtViewportResolution];
        } else {
            os_log_error(sLog, "Eco OFF but no viewport — cannot restart encoder");
            [_hevcEncoder stop];
            [self configureFrameDelivery];
        }
    }

    if (self.onModeChanged) {
        self.onModeChanged(_isEcoMode);
    }
}

#pragma mark - Resolution Matching

- (void)handleResolutionMatchRequest:(const void *)data length:(size_t)length {
    /* Payload: InputEventHeader (9 bytes) + ResolutionMatchPayload (8 bytes) */
    if (length < sizeof(InputEventHeader) + sizeof(ResolutionMatchPayload)) {
        os_log_error(sLog, "Resolution match request too short: %zu bytes", length);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    const ResolutionMatchPayload *payload =
        (const ResolutionMatchPayload *)((const uint8_t *)data + sizeof(InputEventHeader));

    uint32_t iPadWidth = payload->ipad_width;
    uint32_t iPadHeight = payload->ipad_height;

    os_log(sLog, "Resolution match request: iPad wants %ux%u", iPadWidth, iPadHeight);

    if (iPadWidth == 0 || iPadHeight == 0) {
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    CGDirectDisplayID mainDisplay = CGMainDisplayID();

    /* Store current display mode for revert on disconnect */
    if (!_resolutionChanged) {
        CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplay);
        if (currentMode) {
            if (_storedDisplayMode) {
                CGDisplayModeRelease(_storedDisplayMode);
            }
            _storedDisplayMode = currentMode;
        }
    }

    /* Get all available display modes */
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(mainDisplay, NULL);
    if (!allModes) {
        os_log_error(sLog, "Failed to get display modes");
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_NO_MODE width:0 height:0 scale:0];
        return;
    }

    /* Find best mode matching iPad aspect ratio */
    float targetAspect = (float)iPadWidth / (float)iPadHeight;
    CGDisplayModeRef bestMode = NULL;
    size_t bestPixelCount = 0;
    float bestAspectDiff = HUGE_VALF;

    CFIndex modeCount = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < modeCount; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t modeWidth = CGDisplayModeGetPixelWidth(mode);
        size_t modeHeight = CGDisplayModeGetPixelHeight(mode);

        if (modeWidth == 0 || modeHeight == 0) continue;

        float modeAspect = (float)modeWidth / (float)modeHeight;
        float aspectDiff = fabsf(modeAspect - targetAspect);

        /* Accept modes within 2% aspect ratio difference */
        if (aspectDiff < 0.02f) {
            size_t pixelCount = modeWidth * modeHeight;
            /* Prefer higher resolution modes, but also prefer closer aspect ratio */
            if (aspectDiff < bestAspectDiff ||
                (aspectDiff == bestAspectDiff && pixelCount > bestPixelCount)) {
                bestMode = mode;
                bestPixelCount = pixelCount;
                bestAspectDiff = aspectDiff;
            }
        }
    }

    if (!bestMode) {
        os_log(sLog, "No suitable display mode found for aspect ratio %.4f", targetAspect);
        CFRelease(allModes);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_NO_MODE width:0 height:0 scale:0];
        return;
    }

    /* Apply the display mode */
    CGError err = CGDisplaySetDisplayMode(mainDisplay, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        os_log_error(sLog, "CGDisplaySetDisplayMode failed: %d", err);
        CFRelease(allModes);
        [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_FAILED width:0 height:0 scale:0];
        return;
    }

    _resolutionChanged = YES;

    /* Read back the new geometry */
    size_t newPixelWidth = CGDisplayModeGetPixelWidth(bestMode);
    size_t newPixelHeight = CGDisplayModeGetPixelHeight(bestMode);
    size_t newLogicalWidth = CGDisplayModeGetWidth(bestMode);
    float newScale = (newLogicalWidth > 0) ? (float)newPixelWidth / (float)newLogicalWidth : 2.0f;

    CFRelease(allModes);

    os_log(sLog, "Display mode changed to %zux%zu @%.1fx", newPixelWidth, newPixelHeight, newScale);

    /* Update capture dimensions */
    _captureWidth = (uint32_t)newPixelWidth;
    _captureHeight = (uint32_t)newPixelHeight;
    _captureScale = newScale;

    /* Restart capture with new geometry */
    [_capture stopCapture];
    [_capture startCapture];
    [self configureFrameDelivery];

    /* Send success response */
    [self sendResolutionMatchResponse:KEYDRD_RES_MATCH_OK
                                width:_captureWidth
                               height:_captureHeight
                                scale:_captureScale];

    /* Send geometry update to iPad */
    [self sendGeometryUpdate];

    if (self.onResolutionChanged) {
        self.onResolutionChanged(_captureWidth, _captureHeight);
    }
}

- (void)sendResolutionMatchResponse:(uint8_t)result
                              width:(uint32_t)width
                             height:(uint32_t)height
                              scale:(float)scale {
    InputEventHeader header;
    header.type = KEYDRD_INPUT_RES_MATCH_RESPONSE;
    header.ts_us = [self currentTimestampUs];

    ResolutionMatchResponse response;
    response.result = result;
    response.new_width = width;
    response.new_height = height;
    response.new_scale = scale;

    size_t totalLen = sizeof(InputEventHeader) + sizeof(ResolutionMatchResponse);
    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &response, sizeof(ResolutionMatchResponse));

    [self sendInputEventToiPad:packet length:totalLen];

    free(packet);
}

- (void)sendGeometryUpdate {
    InputEventHeader header;
    header.type = KEYDRD_INPUT_GEOMETRY_UPDATE;
    header.ts_us = [self currentTimestampUs];

    GeometryUpdatePayload geo;
    geo.display_width = _captureWidth;
    geo.display_height = _captureHeight;
    geo.scale_factor = _captureScale;
    geo.aspect_ratio = (float)_captureWidth / (float)_captureHeight;

    size_t totalLen = sizeof(InputEventHeader) + sizeof(GeometryUpdatePayload);
    uint8_t *packet = malloc(totalLen);
    if (!packet) return;

    memcpy(packet, &header, sizeof(InputEventHeader));
    memcpy(packet + sizeof(InputEventHeader), &geo, sizeof(GeometryUpdatePayload));

    [self sendInputEventToiPad:packet length:totalLen];

    free(packet);

    os_log(sLog, "Sent geometry update: %ux%u @%.1fx", _captureWidth, _captureHeight, _captureScale);
}

- (void)revertDisplayMode {
    if (!_resolutionChanged || !_storedDisplayMode) return;

    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGError err = CGDisplaySetDisplayMode(mainDisplay, _storedDisplayMode, NULL);
    if (err == kCGErrorSuccess) {
        os_log(sLog, "Display mode reverted to original");
    } else {
        os_log_error(sLog, "Failed to revert display mode: %d", err);
    }

    CGDisplayModeRelease(_storedDisplayMode);
    _storedDisplayMode = NULL;
    _resolutionChanged = NO;
}

#pragma mark - Reconnection

- (void)startReconnection {
    os_log(sLog, "Connection lost -- starting reconnection with exponential backoff");
    [self transitionTo:SESSION_RECONNECTING];
    [_capture stopCapture];
    [_latencyProbeTimer invalidate];
    _latencyProbeTimer = nil;

    /* Revert resolution on disconnect */
    [self revertDisplayMode];

    /* Ensure WiFi advertising is active so the iPad can reconnect wirelessly.
     * If USB connected first during startTransportMonitoring, WiFi advertising
     * was skipped. Start it now so transport rotation tests (and real reconnections)
     * can discover the Mac over WiFi/AWDL. */
    if (!_wiredOnly) {
        [_wirelessTransport beginReconnectWindow];
    }

    if (!_wiredOnly && !_wirelessTransport.isConnected) {
        os_log(sLog, "Starting WiFi advertising for reconnection (may have been skipped earlier, state=%{public}s transport=%{public}s)",
               [self sessionStateName:_sessionState], transport_state_name(_transportState));
        [_wirelessTransport startAdvertising];
    } else if (!_wiredOnly) {
        os_log(sLog, "Reconnect path: WiFi advertising already active (wirelessConnected=%{public}d state=%{public}s transport=%{public}s)",
               _wirelessTransport.isConnected, [self sessionStateName:_sessionState], transport_state_name(_transportState));
    }

    _reconnectAttempt = 0;
    [self scheduleReconnect];
}

- (void)scheduleReconnect {
    if (_reconnectAttempt >= kReconnectMaxAttempts) {
        os_log(sLog, "Max reconnection attempts reached -- waiting for transport event");
        return;
    }

    NSTimeInterval delay = kReconnectIntervals[_reconnectAttempt];
    os_log(sLog, "Reconnection attempt %d in %.1fs", _reconnectAttempt + 1, delay);

    __weak SessionManager *weakSelf = self;
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.sessionState != SESSION_RECONNECTING) return;

        strongSelf.reconnectAttempt++;

        /* Check if transport is back */
        if (strongSelf.usbTransport.isConnected || strongSelf.wirelessTransport.isConnected) {
            os_log(sLog, "Transport reconnected on attempt %d", strongSelf.reconnectAttempt);
            [strongSelf onTransportConnected];
        } else {
            [strongSelf scheduleReconnect];
        }
    }];
}

#pragma mark - State Transitions

- (void)transitionTo:(SessionState)newState {
    if (_sessionState == newState) return;

    os_log(sLog, "Session state: %{public}s -> %{public}s",
           [self sessionStateName:_sessionState],
           [self sessionStateName:newState]);

    _sessionState = newState;

    if (self.onSessionStateChanged) {
        self.onSessionStateChanged(newState);
    }
}

- (const char *)sessionStateName:(SessionState)state {
    switch (state) {
        case SESSION_AWAITING_PERMISSIONS: return "AWAITING_PERMISSIONS";
        case SESSION_AWAITING_PAIRING:    return "AWAITING_PAIRING";
        case SESSION_CONNECTING:          return "CONNECTING";
        case SESSION_STREAMING:           return "STREAMING";
        case SESSION_RECONNECTING:        return "RECONNECTING";
        case SESSION_STOPPED:             return "STOPPED";
    }
    return "UNKNOWN";
}

#pragma mark - Utilities

- (uint64_t)currentTimestampUs {
    return keydrd_host_time_us();
}

@end
