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

/** Test-mode only: an event of this message type is posted only while this returns YES (the
 *  agent's own test window covers the screen / is key), so tests never reach another app.
 *  nil = always post. Called on the injector queue. */
@property (atomic, copy, nullable) BOOL (^postGate)(uint8_t type);

/** Called on the injector queue after each applied pointer/key message: type, seq, the iPad
 *  timestamp (iPad host time, us), Mac host time at receive and after posting (us). Every
 *  CGEvent posted for it carries seq in kCGEventSourceUserData. */
@property (atomic, copy, nullable) void (^onPosted)(uint8_t type, uint64_t seq, uint64_t ipadTsUs,
                                                     uint64_t recvUs, uint64_t postedUs);

/** Key repeat timing the injector uses (from the Mac's keyboard settings). */
@property (nonatomic, readonly) double repeatDelay;
@property (nonatomic, readonly) double repeatInterval;

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
