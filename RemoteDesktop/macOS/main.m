#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "PairingManager.h"
#include <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--identity-selftest") == 0) {
                int rc = [PairingManager runIdentitySelfTest];
                fflush(stdout);
                return rc;
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
