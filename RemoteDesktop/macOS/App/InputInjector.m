#import "InputInjector.h"
#import "protocol.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <os/log.h>

static os_log_t sLog;

static uint64_t host_us(void) { return (uint64_t)(CACurrentMediaTime() * 1000000.0); }

/* USB HID keyboard usage (page 7) -> macOS virtual keycode. 0xFFFF = no key. */
#define NOKEY 0xFFFF
static uint16_t sHidToVK[256];

static void buildKeyTable(void) {
    for (int i = 0; i < 256; i++) sHidToVK[i] = NOKEY;
    const uint16_t letters[26] = {
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z };
    for (int i = 0; i < 26; i++) sHidToVK[0x04 + i] = letters[i];
    const uint16_t digits[10] = { kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                  kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0 };
    for (int i = 0; i < 10; i++) sHidToVK[0x1E + i] = digits[i];
    const struct { uint8_t u; uint16_t vk; } map[] = {
        {0x28, kVK_Return}, {0x29, kVK_Escape}, {0x2A, kVK_Delete}, {0x2B, kVK_Tab},
        {0x2C, kVK_Space}, {0x2D, kVK_ANSI_Minus}, {0x2E, kVK_ANSI_Equal},
        {0x2F, kVK_ANSI_LeftBracket}, {0x30, kVK_ANSI_RightBracket}, {0x31, kVK_ANSI_Backslash},
        {0x32, kVK_ANSI_Backslash}, {0x33, kVK_ANSI_Semicolon}, {0x34, kVK_ANSI_Quote},
        {0x35, kVK_ANSI_Grave}, {0x36, kVK_ANSI_Comma}, {0x37, kVK_ANSI_Period},
        {0x38, kVK_ANSI_Slash}, {0x39, kVK_CapsLock},
        {0x3A, kVK_F1}, {0x3B, kVK_F2}, {0x3C, kVK_F3}, {0x3D, kVK_F4}, {0x3E, kVK_F5},
        {0x3F, kVK_F6}, {0x40, kVK_F7}, {0x41, kVK_F8}, {0x42, kVK_F9}, {0x43, kVK_F10},
        {0x44, kVK_F11}, {0x45, kVK_F12}, {0x46, kVK_F13}, {0x47, kVK_F14}, {0x48, kVK_F15},
        {0x49, kVK_Help}, {0x4A, kVK_Home}, {0x4B, kVK_PageUp}, {0x4C, kVK_ForwardDelete},
        {0x4D, kVK_End}, {0x4E, kVK_PageDown}, {0x4F, kVK_RightArrow}, {0x50, kVK_LeftArrow},
        {0x51, kVK_DownArrow}, {0x52, kVK_UpArrow}, {0x53, kVK_ANSI_KeypadClear},
        {0x54, kVK_ANSI_KeypadDivide}, {0x55, kVK_ANSI_KeypadMultiply},
        {0x56, kVK_ANSI_KeypadMinus}, {0x57, kVK_ANSI_KeypadPlus}, {0x58, kVK_ANSI_KeypadEnter},
        {0x59, kVK_ANSI_Keypad1}, {0x5A, kVK_ANSI_Keypad2}, {0x5B, kVK_ANSI_Keypad3},
        {0x5C, kVK_ANSI_Keypad4}, {0x5D, kVK_ANSI_Keypad5}, {0x5E, kVK_ANSI_Keypad6},
        {0x5F, kVK_ANSI_Keypad7}, {0x60, kVK_ANSI_Keypad8}, {0x61, kVK_ANSI_Keypad9},
        {0x62, kVK_ANSI_Keypad0}, {0x63, kVK_ANSI_KeypadDecimal}, {0x64, kVK_ISO_Section},
        {0x67, kVK_ANSI_KeypadEquals}, {0x68, kVK_F13}, {0x69, kVK_F14}, {0x6A, kVK_F15},
        {0x6B, kVK_F16}, {0x6C, kVK_F17}, {0x6D, kVK_F18}, {0x6E, kVK_F19}, {0x6F, kVK_F20},
        {0x7F, kVK_Mute}, {0x80, kVK_VolumeUp}, {0x81, kVK_VolumeDown},
        {0x87, kVK_JIS_Underscore}, {0x89, kVK_JIS_Yen}, {0x90, kVK_JIS_Kana}, {0x91, kVK_JIS_Eisu},
        {0xE0, kVK_Control}, {0xE1, kVK_Shift}, {0xE2, kVK_Option}, {0xE3, kVK_Command},
        {0xE4, kVK_RightControl}, {0xE5, kVK_RightShift}, {0xE6, kVK_RightOption},
        {0xE7, kVK_RightCommand},
    };
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++) sHidToVK[map[i].u] = map[i].vk;
}

static BOOL isModifierUsage(uint16_t u) { return u >= 0xE0 && u <= 0xE7; }

/* Flags real keyboards attach to non-character keys. */
static CGEventFlags keyClassFlags(uint16_t u) {
    if (u >= 0x4F && u <= 0x52) return kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
    if ((u >= 0x3A && u <= 0x45) || (u >= 0x49 && u <= 0x4E) || (u >= 0x68 && u <= 0x6F))
        return kCGEventFlagMaskSecondaryFn;
    if ((u >= 0x53 && u <= 0x63) || u == 0x67) return kCGEventFlagMaskNumericPad;
    return 0;
}

@interface InputInjector ()
@property (atomic, readwrite) uint64_t postedCount;
@property (atomic, readwrite) uint64_t droppedStaleCount;
@end

@implementation InputInjector {
    dispatch_queue_t _queue;
    CGEventSourceRef _source;
    /* SeqGuard */
    BOOL _haveSession;
    uint64_t _session;
    uint64_t _lastSeq;
    /* What the Mac holds now (posted down, not yet up). */
    BOOL _keyHeld[256];
    int _keysHeldCount;
    uint8_t _buttons;
    BOOL _capsOn;
    CGPoint _pos;
    /* Double-click counting. */
    uint8_t _lastDownButton;
    CGPoint _lastDownPos;
    uint64_t _lastDownUs;
    int64_t _clickCount;
    /* Scroll sub-pixel remainder (1/16 px). */
    int32_t _scrollRemX, _scrollRemY;
    /* Key repeat (posted key-downs do not auto-repeat; the Mac repeats the last key). */
    BOOL _macRepeat;
    double _doubleClickInterval;
    uint64_t _curSeq;          /* stamped into kCGEventSourceUserData of every posted event */
    uint64_t _repeatSeq;
    dispatch_source_t _repeatTimer;
    uint16_t _repeatUsage;
    /* SilenceDeadline */
    uint64_t _lastActivityUs;
    dispatch_source_t _silenceTimer;
    BOOL _loggedTrust;
}

+ (BOOL)isInputMessageType:(uint8_t)type {
    switch (type) {
        case KEYDRD_INPUT_MOUSE_MOVE: case KEYDRD_INPUT_CLICK: case KEYDRD_INPUT_SCROLL:
        case KEYDRD_INPUT_KEY: case KEYDRD_INPUT_HELD: case KEYDRD_INPUT_TEXT:
            return YES;
        default:
            return NO;
    }
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLog = os_log_create("com.ryheff.keyd.remote.agent", "Input");
        buildKeyTable();
    });
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _queue = dispatch_queue_create("com.ryheff.keyd.remote.agent.input", attr);
    _source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (_source) CGEventSourceSetLocalEventsSuppressionInterval(_source, 0.0);
    _repeatDelay = [NSEvent keyRepeatDelay];
    _repeatInterval = [NSEvent keyRepeatInterval];
    _doubleClickInterval = [NSEvent doubleClickInterval];
    NSNumber *rep = [[NSUserDefaults standardUserDefaults] objectForKey:@"KeydrdInputMacRepeat"];
    _macRepeat = rep ? rep.boolValue : YES;
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    _pos = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    os_log(sLog, "InputInjector ready: AXIsProcessTrusted=%{public}d repeatDelay=%.3f interval=%.3f doubleClick=%.3f macRepeat=%{public}d",
           AXIsProcessTrusted(), _repeatDelay, _repeatInterval, _doubleClickInterval, _macRepeat);

    _silenceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_silenceTimer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    __weak InputInjector *weakSelf = self;
    dispatch_source_set_event_handler(_silenceTimer, ^{
        InputInjector *s = weakSelf;
        if (!s || ![s anythingHeld]) return;
        uint64_t silentMs = (host_us() - s->_lastActivityUs) / 1000;
        if (silentMs > KEYDRD_INPUT_SILENCE_MS) {
            os_log(sLog, "Input silence %llums with keys/buttons held: releasing all", silentMs);
            [s releaseAll:"silence-deadline"];
        }
    });
    dispatch_resume(_silenceTimer);
    return self;
}

- (void)dealloc {
    if (_silenceTimer) dispatch_source_cancel(_silenceTimer);
    if (_repeatTimer) dispatch_source_cancel(_repeatTimer);
    if (_source) CFRelease(_source);
}

#pragma mark - Public entry points

- (void)handleMessage:(const void *)data length:(size_t)length {
    uint64_t recvUs = host_us();
    NSData *copy = [NSData dataWithBytes:data length:length];
    dispatch_async(_queue, ^{ [self apply:copy recvUs:recvUs]; });
}

- (void)noteActivity {
    uint64_t now = host_us();
    dispatch_async(_queue, ^{ self->_lastActivityUs = now; });
}

- (void)inputStreamEnded:(const char *)which {
    dispatch_async(_queue, ^{
        if ([self anythingHeld]) os_log(sLog, "Input connection ended (%{public}s): releasing all", which);
        [self releaseAll:"connection-ended"];
    });
}

- (void)releaseAllSync:(const char *)reason {
    dispatch_sync(_queue, ^{ [self releaseAll:reason]; });
}

#pragma mark - Apply (injector queue)

- (BOOL)anythingHeld { return _keysHeldCount > 0 || _buttons != 0; }

- (void)apply:(NSData *)msg recvUs:(uint64_t)recvUs {
    const uint8_t *p = msg.bytes;
    size_t n = msg.length;
    if (n < sizeof(InputEventHeader) + sizeof(InputSeq)) return;
    InputEventHeader h; memcpy(&h, p, sizeof h);
    InputSeq sq; memcpy(&sq, p + sizeof h, sizeof sq);
    const uint8_t *body = p + sizeof h + sizeof sq;
    size_t blen = n - sizeof h - sizeof sq;
    _lastActivityUs = host_us();

    if (!_loggedTrust) {
        _loggedTrust = YES;
        os_log(sLog, "First input message: AXIsProcessTrusted=%{public}d (events are dropped without Accessibility)",
               AXIsProcessTrusted());
    }

    /* SeqGuard (InputPath): another session starts its own count; within a session only newer. */
    if (_haveSession && sq.session == _session && sq.seq <= _lastSeq) {
        self.droppedStaleCount++;
        os_log_debug(sLog, "Dropped stale input type=0x%02x seq=%llu last=%llu", h.type, sq.seq, _lastSeq);
        return;
    }
    if (!_haveSession || sq.session != _session) {
        os_log(sLog, "Input session %016llx (was %016llx)", sq.session, _haveSession ? _session : 0);
    }
    _haveSession = YES; _session = sq.session; _lastSeq = sq.seq;
    _curSeq = sq.seq;

    if (self.postGate && !self.postGate(h.type)) {
        os_log(sLog, "Input type=0x%02x not posted: test gate closed (agent test window not key)", h.type);
        return;
    }

    switch (h.type) {
        case KEYDRD_INPUT_MOUSE_MOVE: {
            if (blen < sizeof(PointerMovePayload)) return;
            PointerMovePayload m; memcpy(&m, body, sizeof m);
            [self moveTo:[self pointFromX:m.x y:m.y]];
            break;
        }
        case KEYDRD_INPUT_CLICK: {
            if (blen < sizeof(PointerButtonPayload)) return;
            PointerButtonPayload b; memcpy(&b, body, sizeof b);
            CGPoint pt = [self pointFromX:b.x y:b.y];
            if (b.down) [self buttonDown:b.button at:pt]; else [self buttonUp:b.button at:pt];
            break;
        }
        case KEYDRD_INPUT_SCROLL: {
            if (blen < sizeof(ScrollPayload)) return;
            ScrollPayload s; memcpy(&s, body, sizeof s);
            [self scroll:s];
            break;
        }
        case KEYDRD_INPUT_KEY: {
            if (blen < sizeof(KeyPayload)) return;
            KeyPayload k; memcpy(&k, body, sizeof k);
            if (k.down) [self keyDown:k.usage repeat:NO]; else [self keyUp:k.usage];
            break;
        }
        case KEYDRD_INPUT_HELD: {
            if (blen < sizeof(HeldPayload)) return;
            HeldPayload hp; memcpy(&hp, body, sizeof hp);
            size_t cnt = MIN((size_t)hp.count, (blen - sizeof hp) / 2);
            BOOL keep[256] = {0};
            for (size_t i = 0; i < cnt; i++) {
                uint16_t u; memcpy(&u, body + sizeof hp + 2 * i, 2);
                if (u < 256) keep[u] = YES;
            }
            [self resyncKeepKeys:keep buttons:hp.buttons];
            break;
        }
        case KEYDRD_INPUT_TEXT: {
            if (blen < sizeof(TextPayload)) return;
            TextPayload tp; memcpy(&tp, body, sizeof tp);
            size_t cnt = MIN((size_t)tp.count, (blen - sizeof tp) / 2);
            [self typeUTF16:(const uint8_t *)(body + sizeof tp) count:cnt];
            break;
        }
        default:
            return;
    }
    if (self.onPosted) self.onPosted(h.type, sq.seq, h.ts_us, recvUs, host_us());
}

#pragma mark - Pointer

- (CGPoint)pointFromX:(uint16_t)x y:(uint16_t)y {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    return CGPointMake(b.origin.x + (x / 65535.0) * (b.size.width - 1),
                       b.origin.y + (y / 65535.0) * (b.size.height - 1));
}

- (void)post:(CGEventRef)ev {
    if (!ev) return;
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, (int64_t)(_curSeq & 0x7FFFFFFFFFFFFFFFULL));
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
    self.postedCount++;
}

- (CGEventFlags)currentFlags {
    CGEventFlags f = 0;
    if (_keyHeld[0xE0]) f |= kCGEventFlagMaskControl | NX_DEVICELCTLKEYMASK;
    if (_keyHeld[0xE4]) f |= kCGEventFlagMaskControl | NX_DEVICERCTLKEYMASK;
    if (_keyHeld[0xE1]) f |= kCGEventFlagMaskShift | NX_DEVICELSHIFTKEYMASK;
    if (_keyHeld[0xE5]) f |= kCGEventFlagMaskShift | NX_DEVICERSHIFTKEYMASK;
    if (_keyHeld[0xE2]) f |= kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK;
    if (_keyHeld[0xE6]) f |= kCGEventFlagMaskAlternate | NX_DEVICERALTKEYMASK;
    if (_keyHeld[0xE3]) f |= kCGEventFlagMaskCommand | NX_DEVICELCMDKEYMASK;
    if (_keyHeld[0xE7]) f |= kCGEventFlagMaskCommand | NX_DEVICERCMDKEYMASK;
    if (_capsOn) f |= kCGEventFlagMaskAlphaShift;
    return f;
}

- (void)moveTo:(CGPoint)pt {
    CGEventType t = kCGEventMouseMoved;
    CGMouseButton mb = kCGMouseButtonLeft;
    if (_buttons & KEYDRD_BUTTON_LEFT) t = kCGEventLeftMouseDragged;
    else if (_buttons & KEYDRD_BUTTON_RIGHT) { t = kCGEventRightMouseDragged; mb = kCGMouseButtonRight; }
    else if (_buttons & KEYDRD_BUTTON_OTHER) { t = kCGEventOtherMouseDragged; mb = kCGMouseButtonCenter; }
    CGEventRef ev = CGEventCreateMouseEvent(_source, t, pt, mb);
    if (ev) {
        CGEventSetIntegerValueField(ev, kCGMouseEventDeltaX, (int64_t)lround(pt.x - _pos.x));
        CGEventSetIntegerValueField(ev, kCGMouseEventDeltaY, (int64_t)lround(pt.y - _pos.y));
        CGEventSetFlags(ev, [self currentFlags]);
    }
    _pos = pt;
    [self post:ev];
}

static void buttonTypes(uint8_t button, CGEventType *down, CGEventType *up, CGMouseButton *mb) {
    if (button & KEYDRD_BUTTON_RIGHT) { *down = kCGEventRightMouseDown; *up = kCGEventRightMouseUp; *mb = kCGMouseButtonRight; }
    else if (button & KEYDRD_BUTTON_OTHER) { *down = kCGEventOtherMouseDown; *up = kCGEventOtherMouseUp; *mb = kCGMouseButtonCenter; }
    else { *down = kCGEventLeftMouseDown; *up = kCGEventLeftMouseUp; *mb = kCGMouseButtonLeft; }
}

- (void)buttonDown:(uint8_t)button at:(CGPoint)pt {
    if (_buttons & button) return;                  /* already down: nothing to post */
    if (!CGPointEqualToPoint(pt, _pos)) [self moveTo:pt];
    uint64_t now = host_us();
    BOOL near = fabs(pt.x - _lastDownPos.x) <= 4 && fabs(pt.y - _lastDownPos.y) <= 4;
    if (button == _lastDownButton && near && (now - _lastDownUs) <= (uint64_t)(_doubleClickInterval * 1e6)) {
        _clickCount++;
    } else {
        _clickCount = 1;
    }
    _lastDownButton = button; _lastDownPos = pt; _lastDownUs = now;
    CGEventType d, u; CGMouseButton mb; buttonTypes(button, &d, &u, &mb);
    CGEventRef ev = CGEventCreateMouseEvent(_source, d, pt, mb);
    if (ev) {
        CGEventSetIntegerValueField(ev, kCGMouseEventClickState, _clickCount);
        CGEventSetFlags(ev, [self currentFlags]);
    }
    _buttons |= button;
    [self post:ev];
}

- (void)buttonUp:(uint8_t)button at:(CGPoint)pt {
    if (!(_buttons & button)) return;               /* not held: never post a stray up */
    if (!CGPointEqualToPoint(pt, _pos)) [self moveTo:pt];
    CGEventType d, u; CGMouseButton mb; buttonTypes(button, &d, &u, &mb);
    CGEventRef ev = CGEventCreateMouseEvent(_source, u, pt, mb);
    if (ev) {
        CGEventSetIntegerValueField(ev, kCGMouseEventClickState, button == _lastDownButton ? _clickCount : 1);
        CGEventSetFlags(ev, [self currentFlags]);
    }
    _buttons &= (uint8_t)~button;
    [self post:ev];
}

- (void)scroll:(ScrollPayload)s {
    CGPoint pt = [self pointFromX:s.x y:s.y];
    if (!CGPointEqualToPoint(pt, _pos) && _buttons == 0) [self moveTo:pt];
    int32_t ax = s.dx + _scrollRemX, ay = s.dy + _scrollRemY;
    int32_t px = ax / 16, py = ay / 16;
    _scrollRemX = ax - px * 16; _scrollRemY = ay - py * 16;
    if (s.phase == KEYDRD_SCROLL_PHASE_ENDED || s.phase == KEYDRD_SCROLL_PHASE_CANCELLED) {
        _scrollRemX = _scrollRemY = 0;
    }
    CGEventRef ev = CGEventCreateScrollWheelEvent2(_source, kCGScrollEventUnitPixel, 2, py, px, 0);
    if (!ev) return;
    CGEventSetLocation(ev, _pos);
    CGEventSetIntegerValueField(ev, kCGScrollWheelEventIsContinuous, 1);
    int64_t phase = 0;
    switch (s.phase) {
        case KEYDRD_SCROLL_PHASE_BEGAN: phase = kCGScrollPhaseBegan; break;
        case KEYDRD_SCROLL_PHASE_CHANGED: phase = kCGScrollPhaseChanged; break;
        case KEYDRD_SCROLL_PHASE_ENDED: phase = kCGScrollPhaseEnded; break;
        case KEYDRD_SCROLL_PHASE_CANCELLED: phase = kCGScrollPhaseCancelled; break;
        default: phase = 0; break;
    }
    CGEventSetIntegerValueField(ev, kCGScrollWheelEventScrollPhase, phase);
    CGEventSetFlags(ev, [self currentFlags]);
    [self post:ev];
}

#pragma mark - Keyboard

- (void)keyDown:(uint16_t)usage repeat:(BOOL)isRepeat {
    if (usage >= 256) return;
    uint16_t vk = sHidToVK[usage];
    if (vk == NOKEY) { os_log_debug(sLog, "Unmapped HID usage 0x%02x", usage); return; }
    if (usage == 0x39) {                            /* Caps Lock toggles; one flagsChanged per press */
        if (isRepeat) return;
        _capsOn = !_capsOn;
        CGEventRef ev = CGEventCreateKeyboardEvent(_source, vk, true);
        if (ev) { CGEventSetType(ev, kCGEventFlagsChanged); CGEventSetFlags(ev, [self currentFlags]); }
        [self post:ev];
        return;
    }
    if (isModifierUsage(usage)) {
        if (_keyHeld[usage]) return;
        _keyHeld[usage] = YES; _keysHeldCount++;
        CGEventRef ev = CGEventCreateKeyboardEvent(_source, vk, true);
        if (ev) { CGEventSetType(ev, kCGEventFlagsChanged); CGEventSetFlags(ev, [self currentFlags]); }
        [self post:ev];
        return;
    }
    if (!isRepeat) {
        if (!_keyHeld[usage]) { _keyHeld[usage] = YES; _keysHeldCount++; }
    } else if (!_keyHeld[usage]) {
        return;
    }
    CGEventRef ev = CGEventCreateKeyboardEvent(_source, vk, true);
    if (ev) {
        CGEventSetFlags(ev, [self currentFlags] | keyClassFlags(usage));
        if (isRepeat) CGEventSetIntegerValueField(ev, kCGKeyboardEventAutorepeat, 1);
    }
    [self post:ev];
    if (!isRepeat) [self startRepeatFor:usage];
}

- (void)keyUp:(uint16_t)usage {
    if (usage >= 256 || !_keyHeld[usage]) return;   /* never post a stray up */
    uint16_t vk = sHidToVK[usage];
    _keyHeld[usage] = NO; _keysHeldCount--;
    if (_repeatUsage == usage) [self stopRepeat];
    CGEventRef ev = CGEventCreateKeyboardEvent(_source, vk, false);
    if (ev) {
        if (isModifierUsage(usage)) {
            CGEventSetType(ev, kCGEventFlagsChanged);
            CGEventSetFlags(ev, [self currentFlags]);
        } else {
            CGEventSetFlags(ev, [self currentFlags] | keyClassFlags(usage));
        }
    }
    [self post:ev];
}

- (void)startRepeatFor:(uint16_t)usage {
    [self stopRepeat];
    if (!_macRepeat || _repeatInterval <= 0) return;
    _repeatUsage = usage;
    _repeatSeq = _curSeq;
    _repeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_repeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_repeatDelay * NSEC_PER_SEC)),
                              (uint64_t)(_repeatInterval * NSEC_PER_SEC), NSEC_PER_MSEC);
    __weak InputInjector *weakSelf = self;
    dispatch_source_set_event_handler(_repeatTimer, ^{
        InputInjector *s = weakSelf;
        if (!s) return;
        if (!s->_keyHeld[usage] || (s.postGate && !s.postGate(KEYDRD_INPUT_KEY))) { [s stopRepeat]; return; }
        s->_curSeq = s->_repeatSeq;
        [s keyDown:usage repeat:YES];
    });
    dispatch_resume(_repeatTimer);
}

- (void)stopRepeat {
    if (_repeatTimer) { dispatch_source_cancel(_repeatTimer); _repeatTimer = nil; }
    _repeatUsage = 0;
}

- (void)typeUTF16:(const uint8_t *)units count:(size_t)count {
    for (size_t off = 0; off < count; off += 20) {
        size_t len = MIN((size_t)20, count - off);
        UniChar chunk[20];
        for (size_t i = 0; i < len; i++) memcpy(&chunk[i], units + 2 * (off + i), 2);
        for (int down = 1; down >= 0; down--) {
            CGEventRef ev = CGEventCreateKeyboardEvent(_source, 0, (bool)down);
            if (!ev) continue;
            CGEventSetFlags(ev, 0);
            CGEventKeyboardSetUnicodeString(ev, len, chunk);
            [self post:ev];
        }
    }
}

#pragma mark - Release

/* HELD: release what the iPad no longer holds; never press (InputPath Resync). */
- (void)resyncKeepKeys:(const BOOL *)keep buttons:(uint8_t)keepButtons {
    int released = 0;
    for (int u = 0; u < 256; u++) {
        if (_keyHeld[u] && !keep[u]) { [self keyUp:(uint16_t)u]; released++; }
    }
    for (uint8_t b = KEYDRD_BUTTON_LEFT; b <= KEYDRD_BUTTON_OTHER; b <<= 1) {
        if ((_buttons & b) && !(keepButtons & b)) { [self buttonUp:b at:_pos]; released++; }
    }
    os_log(sLog, "HELD resync: released %d (now keys=%d buttons=0x%02x)", released, _keysHeldCount, _buttons);
}

- (void)releaseAll:(const char *)reason {
    [self stopRepeat];
    if (![self anythingHeld]) return;
    BOOL none[256] = {0};
    os_log(sLog, "Release all (%{public}s): keys=%d buttons=0x%02x", reason, _keysHeldCount, _buttons);
    [self resyncKeepKeys:none buttons:0];
}

@end
