#import "AppDelegate.h"
#import "SessionManager.h"
#import "StatusBarController.h"

#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>

static os_log_t sLog;

static NSString * _Nullable valueForArgument(NSArray<NSString *> *args, NSString *flag) {
    NSUInteger idx = [args indexOfObject:flag];
    if (idx == NSNotFound || idx + 1 >= args.count) {
        return nil;
    }
    return args[idx + 1];
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    sLog = os_log_create("com.ryheff.keyd.remote.agent", "AppDelegate");

    /* ---- Skip heavy initialization when running as XCTest host ---- */
    if (NSClassFromString(@"XCTestCase") != nil ||
        [NSProcessInfo processInfo].environment[@"XCTestConfigurationFilePath"] != nil) {
        os_log(sLog, "Running as XCTest host -- skipping app initialization");
        return;
    }

    /* ---- No dock icon (RD-AGENT-01) ---- */
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    /* ---- Prevent macOS from auto-terminating our menu-bar-only agent ---- */
    [[NSProcessInfo processInfo] disableAutomaticTermination:@"Menu bar agent must stay running"];

    /* ---- Detect --test-mode / transport mode flags ---- */
    NSArray *args = [NSProcessInfo processInfo].arguments;
    _testMode = [args containsObject:@"--test-mode"];
    _automationMode = _testMode && [args containsObject:@"--automation-mode"];
    BOOL wiredOnly = [args containsObject:@"--wired-only"];
    BOOL wirelessOnly = [args containsObject:@"--wireless-only"];
    _testCaptureFilePath = [valueForArgument(args, @"--test-capture-file") copy];
    _realCaptureMode = [args containsObject:@"--real-capture"];
    BOOL explicitStressCapture = [args containsObject:@"--stress-capture"];
    _testCaptureStressMode = _testMode && !_realCaptureMode && (_testCaptureFilePath.length == 0 || explicitStressCapture);
    if (_testMode) {
        os_log(sLog, "Running in test mode%{public}s%{public}s%{public}s%{public}s",
               wiredOnly ? " (wired-only)" : "",
               _testCaptureFilePath ? " with synthetic capture file" : "",
               _testCaptureStressMode ? " with stress capture" : "",
               _automationMode ? " with hidden QR window" : "");
        if (wirelessOnly) {
            os_log(sLog, "Wireless-only mode enabled");
        }
        if (_testCaptureFilePath) {
            os_log(sLog, "Test capture file: %{public}@", _testCaptureFilePath);
        }
        if (_testCaptureStressMode) {
            os_log(sLog, "Stress capture mode enabled");
        }
        if (_realCaptureMode) {
            os_log(sLog, "Real desktop capture explicitly enabled");
        }
    }

    /* ---- Register login item via SMAppService (RD-AGENT-03) ---- */
    if (!_testMode) {
        [self registerLoginItem];
    }

    /* ---- Create StatusBarController (menu bar setup) ---- */
    _statusBar = [[StatusBarController alloc] init];

    /* ---- Create SessionManager (owns all pipeline components) ---- */
    _sessionManager = [[SessionManager alloc] initWithTestMode:_testMode
                                                automationMode:_automationMode
                                                     wiredOnly:wiredOnly
                                                  wirelessOnly:wirelessOnly
                                           testCaptureFilePath:_testCaptureFilePath
                                         testCaptureStressMode:_testCaptureStressMode];

    /* Wire SessionManager state changes to StatusBarController */
    __weak StatusBarController *weakBar = _statusBar;
    _sessionManager.onTransportStateChanged = ^(TransportState state) {
        [weakBar updateConnectionState:state];
    };
    _sessionManager.onModeChanged = ^(BOOL isEco) {
        [weakBar updateMode:isEco];
    };
    _sessionManager.onResolutionChanged = ^(uint32_t width, uint32_t height) {
        [weakBar updateResolution:width height:height];
    };
    _sessionManager.onPermissionStatusChanged = ^(BOOL screenGranted, BOOL accessibilityGranted) {
        [weakBar updatePermissionStatus];
    };

    /* Wire StatusBarController actions back to SessionManager */
    __weak SessionManager *weakSession = _sessionManager;
    _statusBar.onPairRequested = ^{
        [weakSession showPairingQR];
    };
    _statusBar.onResetPairingRequested = ^{
        [weakSession resetPairing];
    };
    __weak AppDelegate *weakSelf = self;
    _statusBar.onFixLoginItemRequested = ^{
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        os_log(sLog, "Fix Launch at Login requested from menu");
        [strongSelf registerLoginItem];
    };

    /* ---- Start permission check flow ---- */
    [_sessionManager start];

    /* ---- Test mode: auto-show QR for iPad auto-pair ---- */
    if (_testMode) {
        if (_automationMode) {
            os_log(sLog, "Test mode: auto-showing QR skipped in automation mode (writes payload to /tmp/keydrd-test-qr.json)");
        } else {
            os_log(sLog, "Test mode: auto-showing QR (writes payload to /tmp/keydrd-test-qr.json)");
        }
        /* Delay slightly to ensure TLS identity is ready */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self->_sessionManager showPairingQR];
        });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    os_log(sLog, "Agent terminating — stopping session");
    [_sessionManager stop];
}

#pragma mark - Login Item

- (void)registerLoginItem {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        os_log(sLog, "Login item current status before register: %ld", (long)service.status);

        NSError *error = nil;
        BOOL registered = [service registerAndReturnError:&error];

        if (!registered) {
            os_log_error(sLog, "Login item registration failed: %{public}@",
                         error.localizedDescription);
        }

        /* Check status after registration per Pitfall 8 */
        SMAppServiceStatus status = service.status;
        if (status != SMAppServiceStatusEnabled) {
            os_log(sLog, "Login item registration may be stuck (status=%ld)", (long)status);
            if (status == SMAppServiceStatusRequiresApproval) {
                os_log(sLog, "Login item requires user approval in System Settings > General > Login Items");
                [[NSWorkspace sharedWorkspace] openURL:
                    [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]];
            }
        } else {
            os_log(sLog, "Login item registered successfully (status=enabled)");
        }
    } else {
        os_log_error(sLog, "Login item registration requires macOS 13.0+");
    }
}

@end
