#pragma once

#import <Cocoa/Cocoa.h>

@class SessionManager;
@class StatusBarController;

/**
 * AppDelegate for the keyd-rd macOS agent.
 *
 * Runs as a menu bar app (NSApplicationActivationPolicyAccessory)
 * with no dock icon. Registers as a login item via SMAppService.
 * Creates and owns SessionManager + StatusBarController.
 */
@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) SessionManager *sessionManager;
@property (nonatomic, strong) StatusBarController *statusBar;

/** YES if launched with --test-mode flag. */
@property (nonatomic, assign, readonly) BOOL testMode;

@end
