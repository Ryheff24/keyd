#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "PairingManager.h"
#import <ApplicationServices/ApplicationServices.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--identity-selftest") == 0) {
                int rc = [PairingManager runIdentitySelfTest];
                fflush(stdout);
                return rc;
            }
            if (strcmp(argv[i], "--ax-check") == 0) {
                /* Accessibility (needed to post input) for this exact signed binary. */
                int trusted = AXIsProcessTrusted() ? 1 : 0;
                printf("AX-CHECK trusted=%d\n", trusted);
                fflush(stdout);
                return trusted ? 0 : 2;
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
