#import <Foundation/Foundation.h>

@class InputInjector;

NS_ASSUME_NONNULL_BEGIN

/**
 * E2E input observer, test mode only. On the iPad's "begin" it shows an agent-owned window that
 * covers the main screen above everything and records every NSEvent it receives; the injector
 * may post only while that window is up (and, for keys, while it is key and the agent active),
 * so tests never reach another app. "report" returns the recorded events, each matched to its
 * iPad message by the seq the injector stamps into kCGEventSourceUserData, with the iPad
 * timestamp and the Mac receive/post/observe times. "end" closes the window and the gate.
 */
@interface InputTestHarness : NSObject

- (instancetype)initWithInjector:(InputInjector *)injector;

/** A KEYDRD_INPUT_TEST_CONTROL JSON command; reply is called (on any queue) with JSON bytes. */
- (void)handleControl:(NSData *)json reply:(void (^)(NSData *json))reply;

@end

NS_ASSUME_NONNULL_END
