#import "AppDelegate.h"
#import "SessionManager.h"
#import "StatusBarController.h"

#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>

static os_log_t sLog;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    sLog = os_log_create("com.ryheff.keyd.remote.agent", "AppDelegate");

    /* ---- No dock icon (RD-AGENT-01) ---- */
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    /* ---- Detect --test-mode flag (pattern from keyd v1.0) ---- */
    _testMode = [[NSProcessInfo processInfo].arguments containsObject:@"--test-mode"];
    if (_testMode) {
        os_log(sLog, "Running in test mode");
    }

    /* ---- Register login item via SMAppService (RD-AGENT-03) ---- */
    if (!_testMode) {
        [self registerLoginItem];
    }

    /* ---- Create StatusBarController (menu bar setup) ---- */
    _statusBar = [[StatusBarController alloc] init];

    /* ---- Create SessionManager (owns all pipeline components) ---- */
    _sessionManager = [[SessionManager alloc] initWithTestMode:_testMode];

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

    /* Wire StatusBarController actions back to SessionManager */
    __weak SessionManager *weakSession = _sessionManager;
    _statusBar.onPairRequested = ^{
        [weakSession showPairingQR];
    };
    _statusBar.onResetPairingRequested = ^{
        [weakSession resetPairing];
    };
    _statusBar.onFixLoginItemRequested = ^{
        [self registerLoginItem];
    };

    /* ---- Start permission check flow ---- */
    [_sessionManager start];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    os_log(sLog, "Agent terminating — stopping session");
    [_sessionManager stop];
}

#pragma mark - Login Item

- (void)registerLoginItem {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        BOOL registered = [service registerAndReturnError:&error];

        if (!registered) {
            os_log_error(sLog, "Login item registration failed: %{public}@",
                         error.localizedDescription);
        }

        /* Check status after registration per Pitfall 8 */
        if (service.status != SMAppServiceStatusEnabled) {
            os_log(sLog, "Login item registration may be stuck (status=%ld)",
                   (long)service.status);
        } else {
            os_log(sLog, "Login item registered successfully");
        }
    }
}

@end
