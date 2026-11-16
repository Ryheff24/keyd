#import "InputTestHarness.h"
#import "InputInjector.h"
#import "protocol.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <stdatomic.h>

static os_log_t sLog;
static uint64_t host_us(void) { return (uint64_t)(CACurrentMediaTime() * 1000000.0); }

@interface InputTestWindow : NSWindow
@end
@implementation InputTestWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface InputRecorderView : NSView
@property (nonatomic, copy) void (^onEvent)(NSEvent *event, const char *kind);
@end
@implementation InputRecorderView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:1] setFill];
    NSRectFill(dirtyRect);
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:36 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: [NSColor colorWithWhite:0.85 alpha:1] };
    NSString *s = @"keyd input E2E test window (agent-owned; closes when the test ends)";
    NSSize sz = [s sizeWithAttributes:attrs];
    [s drawAtPoint:NSMakePoint((self.bounds.size.width - sz.width) / 2, self.bounds.size.height / 2)
    withAttributes:attrs];
}
#define REC(sel, kind) - (void)sel:(NSEvent *)e { if (self.onEvent) self.onEvent(e, kind); }
REC(keyDown, "keyDown") REC(keyUp, "keyUp") REC(flagsChanged, "flagsChanged")
REC(mouseDown, "leftMouseDown") REC(mouseUp, "leftMouseUp") REC(mouseDragged, "leftMouseDragged")
REC(rightMouseDown, "rightMouseDown") REC(rightMouseUp, "rightMouseUp")
REC(rightMouseDragged, "rightMouseDragged")
REC(otherMouseDown, "otherMouseDown") REC(otherMouseUp, "otherMouseUp")
REC(mouseMoved, "mouseMoved") REC(scrollWheel, "scrollWheel")
#undef REC
@end

@implementation InputTestHarness {
    InputInjector *_injector;
    InputTestWindow *_window;
    NSLock *_lock;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_timing;   /* seq -> times */
    atomic_bool _windowUp;
    atomic_bool _keyAndActive;
}

- (instancetype)initWithInjector:(InputInjector *)injector {
    self = [super init];
    if (!self) return nil;
    sLog = os_log_create("com.ryheff.keyd.remote.agent", "InputTest");
    _injector = injector;
    _lock = [NSLock new];
    _events = [NSMutableArray array];
    _timing = [NSMutableDictionary dictionary];
    atomic_store(&_windowUp, false);
    atomic_store(&_keyAndActive, false);

    __weak InputTestHarness *weakSelf = self;
    /* The gate: pointer events only while the window covers the screen; keys only while it is
     * key and the agent is active. Nothing posts in test mode otherwise. */
    injector.postGate = ^BOOL(uint8_t type) {
        InputTestHarness *s = weakSelf;
        if (!s || !atomic_load(&s->_windowUp)) return NO;
        switch (type) {
            case KEYDRD_INPUT_MOUSE_MOVE: case KEYDRD_INPUT_CLICK: case KEYDRD_INPUT_SCROLL:
                return YES;
            default:
                return atomic_load(&s->_keyAndActive);
        }
    };
    injector.onPosted = ^(uint8_t type, uint64_t seq, uint64_t ipadTs, uint64_t recvUs, uint64_t postedUs) {
        InputTestHarness *s = weakSelf;
        if (!s) return;
        [s->_lock lock];
        s->_timing[@(seq)] = @{ @"type": @(type), @"ipad": @(ipadTs), @"recv": @(recvUs), @"posted": @(postedUs) };
        [s->_lock unlock];
    };

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                   NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification]) {
        [nc addObserver:self selector:@selector(focusChanged:) name:n object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)focusChanged:(NSNotification *)n {
    BOOL ka = _window && _window.isVisible && _window.isKeyWindow && NSApp.isActive;
    atomic_store(&_keyAndActive, ka);
    os_log(sLog, "Test window focus: %{public}@ -> keyAndActive=%{public}d", n.name, ka);
}

- (void)record:(NSEvent *)e kind:(const char *)kind {
    uint64_t obs = host_us();
    CGEventRef cg = e.CGEvent;
    int64_t seq = cg ? CGEventGetIntegerValueField(cg, kCGEventSourceUserData) : 0;
    NSPoint p = [NSEvent mouseLocation];   /* global, bottom-left origin */
    NSRect screen = NSScreen.mainScreen.frame;
    NSMutableDictionary *d = [@{ @"t": @(kind), @"seq": @(seq), @"obs": @(obs),
                                 @"evts": @((uint64_t)(e.timestamp * 1e6)),
                                 @"fl": @((uint64_t)e.modifierFlags),
                                 @"x": @(p.x - screen.origin.x),
                                 @"y": @(screen.size.height - (p.y - screen.origin.y)) } mutableCopy];
    if (e.type == NSEventTypeKeyDown || e.type == NSEventTypeKeyUp) {
        d[@"kc"] = @(e.keyCode);
        d[@"ch"] = e.characters ?: @"";
        d[@"rep"] = @(e.isARepeat ? 1 : 0);
    } else if (e.type == NSEventTypeFlagsChanged) {
        d[@"kc"] = @(e.keyCode);
    } else if (e.type == NSEventTypeScrollWheel) {
        d[@"dx"] = @(e.scrollingDeltaX); d[@"dy"] = @(e.scrollingDeltaY);
        d[@"ph"] = @((uint64_t)e.phase); d[@"precise"] = @(e.hasPreciseScrollingDeltas ? 1 : 0);
    } else if (e.type != NSEventTypeMouseMoved) {
        d[@"cc"] = @(e.clickCount);
    }
    [_lock lock];
    if (_events.count < 4000) [_events addObject:d];
    [_lock unlock];
}

- (NSData *)json:(NSDictionary *)o {
    return [NSJSONSerialization dataWithJSONObject:o options:0 error:nil] ?: [NSData data];
}

- (NSDictionary *)stateDict {
    return @{ @"axTrusted": @(AXIsProcessTrusted()), @"active": @(NSApp.isActive),
              @"key": @(_window.isKeyWindow), @"windowUp": @(atomic_load(&_windowUp)),
              @"repeatDelay": @(_injector.repeatDelay), @"repeatInterval": @(_injector.repeatInterval),
              @"posted": @(_injector.postedCount), @"droppedStale": @(_injector.droppedStaleCount),
              @"screenW": @(NSScreen.mainScreen.frame.size.width),
              @"screenH": @(NSScreen.mainScreen.frame.size.height) };
}

- (void)handleControl:(NSData *)jsonData reply:(void (^)(NSData *))reply {
    NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    NSString *name = [cmd isKindOfClass:[NSDictionary class]] ? cmd[@"cmd"] : nil;
    os_log(sLog, "Input test command: %{public}@", name ?: @"(invalid)");
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([name isEqualToString:@"begin"]) {
            [self showWindow];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self focusChanged:[NSNotification notificationWithName:@"begin" object:nil]];
                NSMutableDictionary *r = [[self stateDict] mutableCopy];
                r[@"cmd"] = @"begin";
                os_log(sLog, "Input test begin: %{public}@", r);
                reply([self json:r]);
            });
        } else if ([name isEqualToString:@"report"]) {
            /* Let events already posted reach the window before answering. */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self->_lock lock];
                NSArray *events = [self->_events copy];
                NSMutableDictionary *timing = [NSMutableDictionary dictionary];
                for (NSNumber *k in self->_timing) timing[k.stringValue] = self->_timing[k];
                [self->_events removeAllObjects];
                [self->_timing removeAllObjects];
                [self->_lock unlock];
                NSMutableDictionary *r = [[self stateDict] mutableCopy];
                r[@"cmd"] = @"report"; r[@"tag"] = cmd[@"tag"] ?: @"";
                r[@"events"] = events; r[@"timing"] = timing;
                os_log(sLog, "Input test report %{public}@: %lu events, %lu timed", cmd[@"tag"] ?: @"",
                       (unsigned long)events.count, (unsigned long)timing.count);
                reply([self json:r]);
            });
        } else if ([name isEqualToString:@"end"]) {
            [self closeWindow];
            NSMutableDictionary *r = [[self stateDict] mutableCopy];
            r[@"cmd"] = @"end";
            reply([self json:r]);
        } else {
            reply([self json:@{ @"cmd": name ?: @"", @"error": @"unknown command" }]);
        }
    });
}

- (void)showWindow {
    if (!_window) {
        NSRect frame = NSScreen.mainScreen.frame;
        _window = [[InputTestWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered defer:NO];
        _window.level = NSStatusWindowLevel + 1;
        _window.releasedWhenClosed = NO;
        _window.acceptsMouseMovedEvents = YES;
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;
        InputRecorderView *v = [[InputRecorderView alloc] initWithFrame:(NSRect){ .size = frame.size }];
        __weak InputTestHarness *weakSelf = self;
        v.onEvent = ^(NSEvent *e, const char *kind) { [weakSelf record:e kind:kind]; };
        _window.contentView = v;
    }
    [_lock lock]; [_events removeAllObjects]; [_timing removeAllObjects]; [_lock unlock];
    [_window setFrame:NSScreen.mainScreen.frame display:YES];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_window.contentView];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    atomic_store(&_windowUp, true);
    os_log(sLog, "Input test window up: frame=%{public}@ AX=%{public}d", NSStringFromRect(_window.frame), AXIsProcessTrusted());
}

- (void)closeWindow {
    atomic_store(&_windowUp, false);
    atomic_store(&_keyAndActive, false);
    [_injector releaseAllSync:"input-test-end"];
    [_window orderOut:nil];
    os_log(sLog, "Input test window closed");
}

@end
