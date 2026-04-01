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

@property (nonatomic, strong, nullable) SessionManager *sessionManager;
@property (nonatomic, strong, nullable) StatusBarController *statusBar;

/** YES if launched with --test-mode flag. */
@property (nonatomic, assign, readonly) BOOL testMode;

/** YES if launched with --automation-mode flag. */
@property (nonatomic, assign, readonly) BOOL automationMode;

/** Optional file path used to synthesize frames during --test-mode. */
@property (nonatomic, copy, readonly, nullable) NSString *testCaptureFilePath;

/** YES when launched with --stress-capture. */
@property (nonatomic, assign, readonly) BOOL testCaptureStressMode;

/** YES when launched with --real-capture. */
@property (nonatomic, assign, readonly) BOOL realCaptureMode;

@end
