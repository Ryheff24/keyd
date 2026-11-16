#import "StatusBarController.h"
#import "TransportFSM.h"

#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>

static os_log_t sLog;

@interface StatusBarController ()

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;

/* Dynamic menu items */
@property (nonatomic, strong) NSMenuItem *connectionStateItem;
@property (nonatomic, strong) NSMenuItem *modeItem;
@property (nonatomic, strong) NSMenuItem *resolutionItem;
@property (nonatomic, strong) NSMenuItem *screenRecordingItem;
@property (nonatomic, strong) NSMenuItem *accessibilityItem;
/* Set once on the main queue when the Secure Enclave identity is unavailable (fail closed). */
@property (atomic, assign) BOOL identityFailed;

/* State */
@property (nonatomic, assign) TransportState currentTransportState;
@property (nonatomic, assign) BOOL sessionStreaming;
@property (nonatomic, assign) BOOL currentEcoMode;

@end

@implementation StatusBarController

- (instancetype)init {
    self = [super init];
    if (self) {
        sLog = os_log_create("com.ryheff.keyd.remote.agent", "StatusBar");
        _currentTransportState = TRANSPORT_IDLE;
        _currentEcoMode = NO;
        [self setupStatusItem];
        [self buildMenu];
    }
    return self;
}

#pragma mark - Setup

- (void)setupStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = [NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle.slash"
                                        accessibilityDescription:@"Remote Desktop Disconnected"];
    _statusItem.button.imagePosition = NSImageLeading;
}

- (void)buildMenu {
    _menu = [[NSMenu alloc] init];

    /* 1. Connection state (dynamic) */
    _connectionStateItem = [[NSMenuItem alloc] initWithTitle:@"Disconnected"
                                                      action:nil
                                               keyEquivalent:@""];
    _connectionStateItem.enabled = NO;
    [_menu addItem:_connectionStateItem];

    /* 2. Current mode (dynamic) */
    _modeItem = [[NSMenuItem alloc] initWithTitle:@"Full Quality (LZ4)"
                                           action:nil
                                    keyEquivalent:@""];
    _modeItem.enabled = NO;
    [_menu addItem:_modeItem];

    /* 3. Resolution info (dynamic) */
    _resolutionItem = [[NSMenuItem alloc] initWithTitle:@"No display"
                                                action:nil
                                         keyEquivalent:@""];
    _resolutionItem.enabled = NO;
    [_menu addItem:_resolutionItem];

    [_menu addItem:[NSMenuItem separatorItem]]; /* 4. Separator */

    /* 5. Match iPad Resolution */
    NSMenuItem *matchResItem = [[NSMenuItem alloc] initWithTitle:@"Match iPad Resolution"
                                                         action:nil
                                                  keyEquivalent:@""];
    matchResItem.enabled = NO; /* Enabled when connected */
    [_menu addItem:matchResItem];

    [_menu addItem:[NSMenuItem separatorItem]]; /* 6. Separator */

    /* 7. Pair iPad... */
    NSMenuItem *pairItem = [[NSMenuItem alloc] initWithTitle:@"Pair iPad..."
                                                     action:@selector(pairAction:)
                                              keyEquivalent:@""];
    pairItem.target = self;
    [_menu addItem:pairItem];

    /* 8. Reset Pairing */
    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Pairing"
                                                      action:@selector(resetPairingAction:)
                                               keyEquivalent:@""];
    resetItem.target = self;
    [_menu addItem:resetItem];

    [_menu addItem:[NSMenuItem separatorItem]]; /* 9. Separator */

    /* 10. Permission status section */
    _screenRecordingItem = [[NSMenuItem alloc] initWithTitle:@"Screen Recording: Checking..."
                                                     action:@selector(openScreenRecordingSettings:)
                                              keyEquivalent:@""];
    _screenRecordingItem.target = self;
    [_menu addItem:_screenRecordingItem];

    _accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Accessibility: Checking..."
                                                    action:@selector(openAccessibilitySettings:)
                                             keyEquivalent:@""];
    _accessibilityItem.target = self;
    [_menu addItem:_accessibilityItem];

    /* Update permission status immediately */
    [self updatePermissionStatus];

    /* 11. Fix Launch at Login */
    NSMenuItem *fixLoginItem = [[NSMenuItem alloc] initWithTitle:@"Fix Launch at Login"
                                                         action:@selector(fixLoginItemAction:)
                                                  keyEquivalent:@""];
    fixLoginItem.target = self;
    [_menu addItem:fixLoginItem];

    [_menu addItem:[NSMenuItem separatorItem]]; /* 12. Separator */

    /* 13. Version (disabled) */
    NSMenuItem *versionItem = [[NSMenuItem alloc] initWithTitle:@"Version 2.0"
                                                        action:nil
                                                 keyEquivalent:@""];
    versionItem.enabled = NO;
    [_menu addItem:versionItem];

    /* 14. Quit */
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit RemoteDesktopAgent"
                                                      action:@selector(quitAction:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [_menu addItem:quitItem];

    _statusItem.menu = _menu;
}

#pragma mark - State Updates

- (void)showIdentityFailure {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.identityFailed = YES;
        self.connectionStateItem.title = @"Not running: secure identity unavailable";
        self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle"
                                                accessibilityDescription:@"Secure identity unavailable"];
        NSMenuItem *detail = [[NSMenuItem alloc] initWithTitle:@"The Secure Enclave TLS key could not be created or loaded. Reinstall a correctly signed build."
                                                        action:nil keyEquivalent:@""];
        detail.enabled = NO;
        NSInteger idx = [self.menu indexOfItem:self.connectionStateItem];
        [self.menu insertItem:detail atIndex:(idx >= 0 ? idx + 1 : 0)];
        os_log_fault(sLog, "Menu bar: showing secure identity failure");
    });
}

- (void)updateConnectionState:(TransportState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTransportState = state;
        [self renderConnectionState];
    });
}

- (void)updateSessionStreaming:(BOOL)streaming {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sessionStreaming = streaming;
        [self renderConnectionState];
    });
}

/* Main queue only. "Connected" means a session is streaming to the iPad, not just that
 * a link is up: a USB cable or Wi-Fi alone says it is waiting for the iPad. */
- (void)renderConnectionState {
    if (self.identityFailed) return;   /* fail-closed state stays visible */

    TransportState state = self.currentTransportState;
    BOOL streaming = self.sessionStreaming;
    NSString *title;
    NSString *symbol;
    switch (state) {
        case TRANSPORT_USB_NCM:
            title = streaming ? @"Connected via USB" : @"USB cable detected \u2014 waiting for iPad app";
            symbol = @"cable.connector.horizontal";
            break;
        case TRANSPORT_WIFI:
            title = streaming ? @"Connected via Wi-Fi" : @"Wi-Fi ready \u2014 waiting for iPad app";
            symbol = @"wifi";
            break;
        case TRANSPORT_AWDL:
            title = streaming ? @"Connected via AWDL" : @"AWDL ready \u2014 waiting for iPad app";
            symbol = @"antenna.radiowaves.left.and.right";
            break;
        case TRANSPORT_DISCONNECTED:
        case TRANSPORT_IDLE:
        default:
            title = @"Disconnected";
            symbol = @"rectangle.on.rectangle.slash";
            break;
    }
    if (!streaming) symbol = @"rectangle.on.rectangle.slash";
    if ([self.connectionStateItem.title isEqualToString:title]) return;
    os_log(sLog, "Menu bar connection: transport=%d streaming=%d -> \"%{public}@\"",
           (int)state, (int)streaming, title);
    self.connectionStateItem.title = title;
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol
                                            accessibilityDescription:title];
}

- (void)updateMode:(BOOL)isEco {
    _currentEcoMode = isEco;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (isEco) {
            self.modeItem.title = @"Eco Mode (HEVC)";
        } else {
            self.modeItem.title = @"Full Quality (LZ4)";
        }
    });
}

- (void)updateResolution:(uint32_t)width height:(uint32_t)height {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.resolutionItem.title = [NSString stringWithFormat:@"%ux%u -> iPad", width, height];
    });
}

- (void)updatePermissionStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL screenGranted = CGPreflightScreenCaptureAccess();
        NSString *screenTitle = screenGranted
            ? @"Screen Recording: Granted"
            : @"Screen Recording: Required";

        BOOL accessibilityGranted = AXIsProcessTrustedWithOptions(NULL);
        NSString *accessTitle = accessibilityGranted
            ? @"Accessibility: Granted"
            : @"Accessibility: Required";

        /* Only log when status actually changes */
        if (![self.screenRecordingItem.title isEqualToString:screenTitle] ||
            ![self.accessibilityItem.title isEqualToString:accessTitle]) {
            os_log(sLog, "Permission status updated: Screen Recording=%{public}s, Accessibility=%{public}s",
                   screenGranted ? "granted" : "required",
                   accessibilityGranted ? "granted" : "required");
        }

        self.screenRecordingItem.title = screenTitle;
        self.accessibilityItem.title = accessTitle;
    });
}

#pragma mark - Menu Actions

- (void)pairAction:(NSMenuItem *)sender {
    if (self.onPairRequested) {
        self.onPairRequested();
    }
}

- (void)resetPairingAction:(NSMenuItem *)sender {
    if (self.onResetPairingRequested) {
        self.onResetPairingRequested();
    }
}

- (void)fixLoginItemAction:(NSMenuItem *)sender {
    os_log(sLog, "fixLoginItemAction: triggered, callback=%{public}s",
           self.onFixLoginItemRequested ? "set" : "nil");
    if (self.onFixLoginItemRequested) {
        self.onFixLoginItemRequested();
    } else {
        os_log_error(sLog, "fixLoginItemAction: onFixLoginItemRequested callback is nil!");
    }
}

- (void)openScreenRecordingSettings:(NSMenuItem *)sender {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openAccessibilitySettings:(NSMenuItem *)sender {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)quitAction:(NSMenuItem *)sender {
    [NSApp terminate:nil];
}

@end
