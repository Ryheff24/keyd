#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Posts iPad pointer and keyboard input as CGEvents (tla/InputPath.tla design).
 *
 * All state lives on one serial user-interactive queue. Rules, as modelled:
 *  - SeqGuard: <<session, seq>> per message; stale messages of the current session are dropped.
 *  - HELD resync is release-only: keys/buttons not listed are released, nothing is pressed.
 *  - ReleaseOnLoss: -inputStreamEnded releases everything.
 *  - SilenceDeadline: nothing from the iPad for KEYDRD_INPUT_SILENCE_MS while anything is held
 *    releases everything.
 *  - StopRelease: -releaseAllSync: at agent stop.
 * Posting needs Accessibility; without it CGEventPost drops events silently, so the trust state
 * is logged on the first input message and exposed here.
 */
@interface InputInjector : NSObject

/** Test-mode only: events are posted only while this returns YES (the agent's own test window
 *  is key), so tests never type into whatever app has focus. nil = always post. */
@property (atomic, copy, nullable) BOOL (^postGate)(void);

/** Called on the injector queue after each posted pointer/key event: message type, the iPad
 *  timestamp from the header (iPad host time, us), Mac host time when the event was posted (us). */
@property (atomic, copy, nullable) void (^onPosted)(uint8_t type, uint64_t ipadTsUs, uint64_t postedUs);

@property (atomic, readonly) uint64_t postedCount;
@property (atomic, readonly) uint64_t droppedStaleCount;

/** A whole input message (InputEventHeader + body) of type MOUSE_MOVE, CLICK, SCROLL, KEY,
 *  HELD or TEXT. Copies the bytes; returns at once. */
- (void)handleMessage:(const void *)data length:(size_t)length;

/** Any message arrived from the iPad (keepalive, clock sync, ...): resets the silence deadline. */
- (void)noteActivity;

/** An iPad input connection ended (ReleaseOnLoss). */
- (void)inputStreamEnded:(const char *)which;

/** Release every held key and button now and wait until posted (agent stop). */
- (void)releaseAllSync:(const char *)reason;

+ (BOOL)isInputMessageType:(uint8_t)type;

@end

NS_ASSUME_NONNULL_END
