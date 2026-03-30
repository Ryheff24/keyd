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

/* NSWindow subclass that closes on Escape key */
@interface QRWindow : NSWindow
@end
@implementation QRWindow
- (void)cancelOperation:(id)sender { [self close]; }
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

static uint64_t keydrd_host_time_us(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000000.0);
}

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

/* Latency probe */
@property (nonatomic, strong, nullable) NSTimer *latencyProbeTimer;

/* QR code display window */
@property (nonatomic, strong, nullable) NSWindow *qrWindow;

@end

@implementation SessionManager

- (instancetype)initWithTestMode:(BOOL)testMode automationMode:(BOOL)automationMode {
    self = [super init];
    if (self) {
        sLog = os_log_create("com.ryheff.keyd.remote.agent", "SessionManager");
        _testMode = testMode;
        _automationMode = automationMode;
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
        _hevcEncoder = [[HEVCEncoder alloc] init];
        _usbTransport = [[USBNetworkTransport alloc] init];
        _wirelessTransport = [[WirelessTransport alloc] init];
        _pairing = [[PairingManager alloc] init];
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

    if (_pairing.isPaired) {
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

    /* Scale QR to reasonable display size (each module -> 8px) */
    CGFloat scale = 8.0;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *qrImage = [[NSImage alloc] initWithSize:rep.size];
    [qrImage addRepresentation:rep];

    CGFloat imageSize = rep.size.width;
    CGFloat padding = 32;
    CGFloat labelHeight = 40;
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
    NSTextField *label = [NSTextField labelWithString:@"Scan this QR code with the RemoteDesktop iPad app"];
    label.frame = NSMakeRect(0, 8, windowWidth, 24);
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:13];
    label.textColor = NSColor.secondaryLabelColor;
    [contentView addSubview:label];

    [_qrWindow center];
    [_qrWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* Wire pairing completion callback */
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
        os_log(sLog, "USB NCM TCP input ready — sending handshake");
        [strongSelf onTransportConnected];
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
    [_usbTransport startMonitoring];

    __weak SessionManager *weakSelf2 = weakSelf;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SessionManager *self2 = weakSelf2;
        if (!self2) return;
        if (self2->_usbTransport.isConnected) {
            os_log(sLog, "USB NCM connected — starting WiFi advertising anyway (fallback + Bonjour)");
        } else {
            os_log(sLog, "USB NCM not connected after 3s — starting WiFi advertising");
        }
        [self2->_wirelessTransport startAdvertising];
    });
}

- (void)handleTransportEvent:(TransportEvent)event {
    os_log(sLog, "Transport event: %{public}s (current state: %{public}s)",
           transport_event_name(event), transport_state_name(_transportState));

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
    os_log(sLog, "Switching to LZ4 mode (full quality)");
    _isEcoMode = NO;
    [_hevcEncoder stop];

    /* Reconfigure capture for LZ4 compression */
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
    os_log(sLog, "Transport connected -- sending handshake");
    [self transitionTo:SESSION_STREAMING];

    /* Send session handshake (also sets _captureWidth/_captureHeight) */
    [self sendSessionHandshake];

    /* Encoder starts when iPad sends viewport report (after receiving this handshake).
     * If viewport already known (reconnect), start immediately. */
    if (_viewportReceived && _viewportWidth > 0 && _viewportHeight > 0) {
        [self _startEncoderAtViewportResolution];
    } else {
        os_log(sLog, "Encoder deferred — waiting for iPad viewport report after handshake");
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
    } else {
        /* USB: DTLS media is already ready (accepted before onTransportConnected) */
        [self _beginCapture];
    }

    /* Start latency probe timer (every 1 second) */
    [self startLatencyProbeTimer];
}

- (void)_beginCapture {
    [_capture startCapture];

    /* In test mode, show a persistent animated window that continuously changes
     * the screen content. SCStream only delivers frames when pixels change —
     * a static desktop produces only idle frames with no pixel data.
     * This window animates a color cycle to ensure steady frame delivery. */
    if (_testMode) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            /* Position top-right, 150x150 — small but enough to trigger SCStream frames */
            NSScreen *screen = [NSScreen mainScreen];
            CGFloat x = NSMaxX(screen.visibleFrame) - 160;
            CGFloat y = NSMaxY(screen.visibleFrame) - 160;
            NSWindow *testWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, 150, 150)
                                                              styleMask:NSWindowStyleMaskBorderless
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
            testWindow.level = NSFloatingWindowLevel;
            testWindow.backgroundColor = [NSColor redColor];
            [testWindow orderFront:nil];

            /* Animate at ~30fps to keep SCStream producing complete frames continuously.
             * Each tick changes the background color, ensuring pixels differ every frame. */
            __block CGFloat hue = 0;
            [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *timer) {
                hue = fmod(hue + 0.02, 1.0);
                testWindow.backgroundColor = [NSColor colorWithHue:hue saturation:1.0 brightness:1.0 alpha:1.0];
            }];

            os_log(sLog, "Test mode: animated window active for continuous frame delivery");
        });
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
        size_t totalLen = sizeof(MediaFrameHeader) + output->compressed_size;
        uint8_t *packet = malloc(totalLen);
        if (!packet) return;

        memcpy(packet, &output->header, sizeof(MediaFrameHeader));
        memcpy(packet + sizeof(MediaFrameHeader), output->buf, output->compressed_size);

        [strongSelf sendMediaFrameToiPad:packet length:totalLen];

        free(packet);
    };

    /* Raw pixel buffer callback — feeds HEVC encoder when active */
    _capture.onPixelBuffer = ^(CVPixelBufferRef pixelBuffer, CMTime timestamp, uint64_t captureTimestampUs) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;
        if (!strongSelf->_hevcEncoder.isActive) return;

        [strongSelf->_hevcEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp captureTimestampUs:captureTimestampUs];
    };

    /* HEVC encoder output callback */
    _hevcEncoder.onEncodedFrame = ^(const void *data, size_t len, MediaFrameHeader header) {
        SessionManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.sessionState != SESSION_STREAMING) return;

        static int hevcSentCount = 0;
        if (hevcSentCount < 3) {
            os_log(sLog, "HEVC onEncodedFrame: seq=%u len=%zu flags=0x%02x, sending via UDP chunks",
                   header.seq, len, header.flags);
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

        size_t totalLen = sizeof(MediaFrameHeader) + len;
        uint8_t *packet = malloc(totalLen);
        if (!packet) return;

        memcpy(packet, &header, sizeof(MediaFrameHeader));
        memcpy(packet + sizeof(MediaFrameHeader), data, len);

        [strongSelf sendMediaFrameToiPad:packet length:totalLen];

        free(packet);
    };
}

#pragma mark - Transport Send Helpers

- (void)sendMediaFrameToiPad:(const void *)data length:(size_t)len {
    /* Both USB NCM and WiFi use HEVC + UDP chunking.
     * HEVC frames are 10-200KB, chunked into 1400-byte DTLS datagrams.
     * iPad reassembles via UDPReassembler. */
    if (len < sizeof(MediaFrameHeader)) return;

    const MediaFrameHeader *originalHeader = (const MediaFrameHeader *)data;
    const void *payload = (const uint8_t *)data + sizeof(MediaFrameHeader);
    size_t payloadLen = len - sizeof(MediaFrameHeader);

    if (_usbTransport.isConnected) {
        /* USB NCM: HEVC frames via TCP with length-prefix framing.
         * UDP/DTLS over USB NCM is confirmed broken for media delivery:
         *   - Batch sends (nw_connection_batch): ~29/30 frames dropped
         *   - Completion-paced sequential sends: still black screen
         *   - Root cause: USB NCM DTLS path drops data regardless of pacing
         * TCP with TCP_NODELAY gives 0% loss at 1ms transport RTT. */
        [_usbTransport sendInputEvent:data length:len];
    } else if (_wirelessTransport.isConnected) {
        WirelessTransport *transport = _wirelessTransport;
        chunk_frame(payload, payloadLen, originalHeader->seq, KEYDRD_MTU_WIFI,
                    originalHeader, ^(const void *chunk, size_t chunkLen) {
            [transport sendMediaFrame:chunk length:chunkLen];
        });
    }
}

- (void)sendInputEventToiPad:(const void *)data length:(size_t)len {
    if (_usbTransport.isConnected) {
        [_usbTransport sendInputEvent:data length:len];
    } else if (_wirelessTransport.isConnected) {
        [_wirelessTransport sendInputEvent:data length:len];
    }
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

#pragma mark - Viewport Report (iPad → Mac)

- (void)handleViewportReport:(const void *)data length:(size_t)length {
    if (length < sizeof(InputEventHeader) + sizeof(ViewportReportPayload)) {
        os_log_error(sLog, "Viewport report too short: %zu bytes", length);
        return;
    }

    const ViewportReportPayload *payload =
        (const ViewportReportPayload *)((const uint8_t *)data + sizeof(InputEventHeader));

    _viewportWidth = payload->viewport_width;
    _viewportHeight = payload->viewport_height;
    _viewportReceived = YES;

    os_log(sLog, "iPad viewport report: %ux%u (Mac display: %ux%u)",
           _viewportWidth, _viewportHeight, _captureWidth, _captureHeight);

    /* Start encoder + reconfigure capture at viewport resolution */
    [self _startEncoderAtViewportResolution];
}

- (void)_startEncoderAtViewportResolution {
    if (_viewportWidth == 0 || _viewportHeight == 0) {
        os_log_error(sLog, "_startEncoderAtViewportResolution: viewport not set");
        return;
    }

    int bitrate = _usbTransport.isConnected ? 150000000 : 20000000;

    os_log(sLog, "Starting HEVC encoder at viewport resolution: %ux%u @120fps %dMbps (%s)",
           _viewportWidth, _viewportHeight, bitrate / 1000000,
           _usbTransport.isConnected ? "USB" : "WiFi/default");

    [_hevcEncoder startWithWidth:(int)_viewportWidth
                          height:(int)_viewportHeight
                             fps:120
                         bitrate:bitrate];

    /* Restart capture at viewport resolution.
     * SCStream downscales from Mac display to viewport size in hardware. */
    [_capture stopCapture];
    _capture.captureWidth = _viewportWidth;
    _capture.captureHeight = _viewportHeight;
    [_capture startCapture];

    /* Update captureWidth/Height so handshake/geometry messages reflect actual encode size */
    _captureWidth = _viewportWidth;
    _captureHeight = _viewportHeight;

    /* Reconfigure frame delivery */
    [self configureFrameDelivery];

    /* Send geometry update so iPad knows the new frame dimensions */
    [self sendGeometryUpdate];

    /* Begin capture if not already running */
    [self _beginCapture];
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
        case 0x02: {
            /* Eco mode change: next byte is 0x01 (on) or 0x00 (off) */
            if (length < sizeof(InputEventHeader) + 2) return;
            BOOL ecoOn = (payload[1] != 0);
            [self handleEcoModeRequest:ecoOn];
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

        /* Activate HEVC at reduced resolution (1080p) and 30fps */
        [_hevcEncoder startWithWidth:kEcoWidth height:kEcoHeight fps:kEcoFPS bitrate:kEcoBitrate];

        /* Reconfigure frame delivery for HEVC path */
        [self configureFrameDelivery];
    } else {
        _isEcoMode = NO;
        [_hevcEncoder stop];

        /* Return to LZ4 path */
        [self configureFrameDelivery];
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
    if (!_wirelessTransport.isConnected) {
        os_log(sLog, "Starting WiFi advertising for reconnection (may have been skipped earlier)");
        [_wirelessTransport startAdvertising];
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
