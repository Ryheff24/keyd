# Architecture Research

**Domain:** iOS-to-macOS remote keyboard / text injection
**Researched:** 2026-02-27
**Confidence:** MEDIUM — Core Apple APIs (usbmuxd, CGEvent, AXUIElement, Multipeer/AWDL) are well-established and stable. Transport abstraction and protocol design patterns are grounded in standard iOS/macOS inter-device patterns. Web search was unavailable; all findings are from training knowledge of official Apple APIs verified at training cutoff (August 2025). Flag for human review on usbmuxd peering details and AWDL entitlement requirements before implementation.

---

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                      iOS App (Sender)                            │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                     UI Layer                                │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │ │
│  │  │  KeyboardVC  │  │  HotkeyPanel │  │  TextPreviewBox  │  │ │
│  │  │  (UIKit KB)  │  │  (Phase 1)   │  │  (Phase 2)       │  │ │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │ │
│  └─────────┼─────────────────┼───────────────────┼────────────┘ │
│            │ KeyEvent/TextEvent                   │ ReflectState │
│  ┌─────────▼─────────────────▼───────────────────▼────────────┐ │
│  │                   Protocol Layer                            │ │
│  │         MessageEncoder  /  MessageDecoder                  │ │
│  │         (length-prefixed binary frames)                     │ │
│  └─────────────────────────┬───────────────────────────────────┘ │
│                            │ Data frames                         │
│  ┌─────────────────────────▼───────────────────────────────────┐ │
│  │                  Transport Layer                            │ │
│  │  TransportManager                                           │ │
│  │  ┌─────────────────────┐  ┌──────────────────────────────┐ │ │
│  │  │  USBTransport        │  │  AWDLTransport               │ │ │
│  │  │  (GCDAsyncSocket     │  │  (MultipeerConnectivity      │ │ │
│  │  │   → usbmuxd port)   │  │   with AWDL interface)       │ │ │
│  │  └─────────────────────┘  └──────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘

                    USB cable / AWDL radio
                         ↕  (bidirectional)

┌──────────────────────────────────────────────────────────────────┐
│                  macOS Helper Agent (Receiver)                   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                  Transport Layer                            │ │
│  │  TransportManager                                           │ │
│  │  ┌─────────────────────┐  ┌──────────────────────────────┐ │ │
│  │  │  USBListener        │  │  AWDLListener                │ │ │
│  │  │  (TCP server on     │  │  (MCSession peer,            │ │ │
│  │  │   usbmuxd port)     │  │   AWDL interface)            │ │ │
│  │  └─────────────────────┘  └──────────────────────────────┘ │ │
│  └─────────────────────────┬───────────────────────────────────┘ │
│                            │ Data frames                         │
│  ┌─────────────────────────▼───────────────────────────────────┐ │
│  │                   Protocol Layer                            │ │
│  │         MessageDecoder  /  MessageEncoder                   │ │
│  └─────────────────────────┬───────────────────────────────────┘ │
│                            │ Typed messages                      │
│  ┌─────────────────────────▼───────────────────────────────────┐ │
│  │                  Injection Layer                            │ │
│  │  ┌─────────────────────┐  ┌──────────────────────────────┐ │ │
│  │  │  CGEventInjector    │  │  AXInjector                  │ │ │
│  │  │  (CGEventPost,      │  │  (AXUIElementSetAttributeValue│ │ │
│  │  │   CGEventCreateKbd) │  │   kAXValueAttribute, etc.)   │ │ │
│  │  └─────────────────────┘  └──────────────────────────────┘ │ │
│  │  InjectionRouter                                            │ │
│  │  (decides CGEvent vs AX based on frontmost app + content)  │ │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              App-Awareness Service (Phase 3)                │ │
│  │  NSWorkspace.frontmostApplication observer                  │ │
│  │  Pushes app name + bundle ID back to iOS                    │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| KeyboardVC (iOS) | Capture every key tap and modifier state; convert to KeyEvent message | UIKeyboardType + UITextDocumentProxy or custom key grid; SwiftUI or UIKit |
| HotkeyPanel (iOS) | Display common macOS shortcuts as tap targets; emit HotkeyEvent | SwiftUI grid over keyboard, Liquid Glass styling |
| TextPreviewBox (iOS) | Show reflected macOS field content for iOS-native editing (Phase 2) | UITextView mirror; receives ReflectState messages from macOS |
| MessageEncoder/Decoder (iOS) | Serialize/deserialize typed messages into length-prefixed binary frames | Swift Codable + Data; or custom binary packing |
| TransportManager (iOS) | Hold active transport reference; handle switchover from USB to AWDL; expose single async send/receive API | Swift actor or class wrapping both transport types |
| USBTransport (iOS) | Connect to macOS TCP port tunneled through usbmuxd | GCDAsyncSocket / NWConnection on loopback port that usbmuxd exposes |
| AWDLTransport (iOS) | Peer-to-peer connection over AWDL radio without infrastructure Wi-Fi | MultipeerConnectivity framework with `.awdl` interface flag |
| USBListener (macOS) | Accept incoming TCP connections on port usbmuxd forwards | Network.framework NWListener on chosen localhost port |
| AWDLListener (macOS) | Accept AWDL peer session from iOS | MCNearbyServiceAdvertiser or MCSession on macOS |
| InjectionRouter (macOS) | Route decoded messages to correct injector; choose CGEvent vs AX based on app heuristics | Swift switch on frontmost app bundle ID; falls back to CGEvent |
| CGEventInjector (macOS) | Synthesize and post keyboard events system-wide | CGEventCreateKeyboardEvent + CGEventPost(kCGHIDEventTap, …) |
| AXInjector (macOS) | Read/write focused element text value via Accessibility API; supports cursor position and selection | AXUIElementCopyAttributeValue / AXUIElementSetAttributeValue on focused element |
| AppAwarenessService (macOS) | Observe frontmost app changes and notify iOS | NSWorkspace.shared.notificationCenter + .didActivateApplicationNotification |

---

## Recommended Project Structure

```
keyd/
├── iOS/
│   ├── Sources/
│   │   ├── UI/
│   │   │   ├── KeyboardViewController.swift    # Root keyboard view
│   │   │   ├── HotkeyPanel.swift               # Phase 1 hotkey row
│   │   │   ├── TextPreviewView.swift           # Phase 2 text mirror
│   │   │   └── LiquidGlassStyle.swift         # Shared glassmorphism tokens
│   │   ├── Protocol/
│   │   │   ├── Message.swift                   # Codable message types
│   │   │   ├── MessageEncoder.swift            # Serialize → Data frame
│   │   │   └── MessageDecoder.swift            # Data frame → typed message
│   │   ├── Transport/
│   │   │   ├── TransportProtocol.swift         # Protocol: send(_:), receive, connectionState
│   │   │   ├── TransportManager.swift          # Active transport + switchover logic
│   │   │   ├── USBTransport.swift              # NWConnection to usbmuxd-forwarded port
│   │   │   └── AWDLTransport.swift             # MCSession over AWDL
│   │   └── App/
│   │       └── KeydApp.swift
│   └── Resources/
│       └── Assets.xcassets
│
└── macOS/
    ├── Sources/
    │   ├── Transport/
    │   │   ├── TransportProtocol.swift         # Shared protocol
    │   │   ├── TransportManager.swift          # Selects active listener
    │   │   ├── USBListener.swift               # NWListener on localhost port
    │   │   └── AWDLListener.swift              # MCNearbyServiceAdvertiser
    │   ├── Protocol/
    │   │   ├── Message.swift                   # Must mirror iOS definition exactly
    │   │   ├── MessageEncoder.swift
    │   │   └── MessageDecoder.swift
    │   ├── Injection/
    │   │   ├── InjectionRouter.swift           # Decides CGEvent vs AX
    │   │   ├── CGEventInjector.swift           # CGEventPost keyboard events
    │   │   └── AXInjector.swift                # AXUIElement text manipulation
    │   ├── AppAwareness/
    │   │   └── AppAwarenessService.swift       # NSWorkspace observer → push to iOS
    │   └── App/
    │       └── KeydHelperApp.swift
    └── Resources/
        └── Info.plist                          # Accessibility + USB entitlements
```

### Structure Rationale

- **Transport/ in both targets:** Transport is isolated so the switchover mechanism can be tested in isolation and the "transport must not change after Phase 1" invariant can be enforced at the file boundary.
- **Protocol/ shared concept:** Message types must be identical on both ends. Swift Package with shared target is the cleanest way; alternatively, keep files in sync manually since this is personal use.
- **Injection/ separate from Transport/:** Injection is macOS-only, deals with different privilege model, and is likely to change more in later phases than transport.
- **AppAwareness/ separate service:** Grows in Phase 3 to include hotkey manifest; isolating it prevents future changes from touching injection logic.

---

## Architectural Patterns

### Pattern 1: Transport Protocol + Manager (Transport Abstraction)

**What:** Define a Swift protocol `TransportProtocol` that both USBTransport and AWDLTransport conform to. TransportManager holds `var active: TransportProtocol` and re-points it on switchover. Higher layers (Protocol/Encoder) never know which transport is active.

**When to use:** Mandatory here — PROJECT.md explicitly requires "transport layer established in Phase 1 must not be modified in later phases." The abstraction enforces this.

**Trade-offs:** Adds a thin indirection layer. For this two-transport system, the overhead is negligible and the boundary protection is worth it.

**Example:**
```swift
// TransportProtocol.swift (shared concept, each target has its own copy)
protocol TransportProtocol: AnyObject {
    var statePublisher: AnyPublisher<TransportState, Never> { get }
    func send(_ data: Data) async throws
    func receive() -> AsyncThrowingStream<Data, Error>
    func connect() async throws
    func disconnect()
}

// TransportManager.swift
final class TransportManager {
    private var active: TransportProtocol
    private var usb: USBTransport
    private var awdl: AWDLTransport

    init() {
        usb = USBTransport()
        awdl = AWDLTransport()
        active = usb  // USB is primary
    }

    // Called when USB disconnects
    func fallbackToAWDL() async throws {
        active = awdl
        try await active.connect()
    }
}
```

---

### Pattern 2: Length-Prefixed Binary Framing (Protocol Layer)

**What:** Prefix every message with a 4-byte big-endian UInt32 indicating payload length. Read length, then read exactly that many bytes. This makes the stream self-delimiting and immune to TCP segment boundary issues.

**When to use:** Any time you send structured messages over a raw byte stream (TCP, usbmuxd, AWDL data channel). Required here for both USB and AWDL paths.

**Trade-offs:** Adds 4 bytes per message (negligible). Requires read-loop state machine on the receiver side. Much simpler than delimiter-based framing for binary payloads.

**Example:**
```swift
// MessageEncoder.swift
func encode(_ message: Message) throws -> Data {
    let payload = try JSONEncoder().encode(message)  // or binary
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    return frame
}

// MessageDecoder.swift (read loop)
func readLoop(stream: AsyncThrowingStream<Data, Error>) async throws {
    var buffer = Data()
    for try await chunk in stream {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = Int(UInt32(bigEndian: buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard buffer.count >= 4 + length else { break }
            let payload = buffer[4..<(4 + length)]
            try await handle(try decoder.decode(Message.self, from: payload))
            buffer = buffer.dropFirst(4 + length)
        }
    }
}
```

---

### Pattern 3: Injection Router with App Heuristic

**What:** On macOS, after decoding a message, InjectionRouter reads the frontmost app's bundle ID and decides whether to use CGEventInjector or AXInjector. CGEvent is the general-purpose path (works in most apps). AX is the precision path for apps where CGEvent creates duplication (e.g., native text fields in apps that intercept raw key events and also respond to AX text-value sets).

**When to use:** Phase 2 onwards, when cursor movement and text selection require reading the current selection state. CGEvent alone cannot read cursor position; AX can.

**Trade-offs:** Requires Accessibility permission on macOS (user must grant in System Settings > Privacy > Accessibility). CGEvent alone requires no special permission beyond running as a normal process. Start with CGEvent-only in Phase 1, add AX in Phase 2.

**Example:**
```swift
// InjectionRouter.swift
func route(_ message: Message) async {
    switch message {
    case .keystroke(let event):
        // CGEvent for all raw keystrokes — works universally
        await cgEventInjector.inject(event)
    case .textInsert(let text):
        // For Phase 2: try AX first, fall back to CGEvent per-character
        let focused = AXUIElementCreateSystemWide()
        // ... get focused element, set value
    case .cursorMove(let direction):
        // AX: read kAXSelectedTextRangeAttribute, modify, write back
        await axInjector.moveCursor(direction)
    case .hotkey(let combo):
        await cgEventInjector.injectHotkey(combo)
    }
}
```

---

## Data Flow

### Primary Flow: Keystroke from iOS to macOS

```
[User taps key on iOS keyboard]
        ↓
KeyboardViewController
        ↓  KeyEvent(keyCode, modifiers, char)
MessageEncoder (→ length-prefixed binary frame)
        ↓  Data
TransportManager.send(_:)
        ↓  active transport (USB or AWDL)
─── USB cable or AWDL radio ───────────────────────────────────────
        ↓  Data
TransportManager (macOS listener receives frame)
        ↓  Data
MessageDecoder (strips length prefix, decodes to Message)
        ↓  Message
InjectionRouter
        ↓  KeyEvent
CGEventInjector
        ↓  CGEventPost(kCGHIDEventTap, keyDownEvent)
        ↓  CGEventPost(kCGHIDEventTap, keyUpEvent)
[Key appears in frontmost macOS app's focused text field]
```

### Secondary Flow: USB Disconnect → AWDL Fallback

```
[User unplugs USB cable]
        ↓
USBTransport.statePublisher emits .disconnected
        ↓
TransportManager.onUSBDisconnect()
        ↓
AWDLTransport.connect()  (MCSession peer discovery over AWDL)
        ↓
TransportManager.active = awdlTransport
        ↓
[Send continues on AWDL; no change to Protocol or Injection layers]
```

### Tertiary Flow: App-Awareness (Phase 3)

```
[macOS frontmost app changes]
        ↓
NSWorkspace.didActivateApplicationNotification
        ↓
AppAwarenessService
        ↓  AppStateMessage(bundleID, appName)
MessageEncoder → TransportManager.send(_:)
        ↓  (back to iOS over same transport)
─── transport ─────────────────────────────────────────────────────
        ↓
MessageDecoder (iOS)
        ↓  AppStateMessage
HotkeyPanel.updateForApp(bundleID)
[iOS HotkeyPanel renders app-specific shortcuts]
```

### Phase 2 Flow: Text Reflection (macOS → iOS)

```
[User types on iOS; text injected on macOS via AX]
        ↓
AXInjector reads kAXValueAttribute from focused element after write
        ↓  current text + selection range
MessageEncoder → TransportManager.send(_:)
        ↓  (back to iOS)
MessageDecoder (iOS)
        ↓  ReflectState(text, cursorOffset, selectedRange)
TextPreviewView.update(state)
[iOS preview box shows exact macOS field content]
```

---

## Component Boundaries and Communication

| Boundary | Direction | Communication | Notes |
|----------|-----------|---------------|-------|
| UI Layer → Protocol Layer (iOS) | iOS outbound | Method calls: `encoder.encode(event)` | UI never touches transport directly |
| Protocol Layer → Transport Layer (iOS) | iOS outbound | Method calls: `manager.send(frame)` | Protocol never knows USB vs AWDL |
| Transport (iOS) ↔ Transport (macOS) | Bidirectional | Raw byte stream over USB/AWDL | The only cross-device boundary |
| Transport Layer → Protocol Layer (macOS) | macOS inbound | AsyncStream of Data frames | Protocol strips framing, types message |
| Protocol Layer → Injection Layer (macOS) | macOS inbound | Method calls: `router.route(message)` | Protocol never calls CGEvent directly |
| Injection Layer ↔ System (macOS) | macOS outbound | CGEventPost / AXUIElementSetAttributeValue | Requires Accessibility entitlement for AX |
| AppAwareness → Transport (macOS outbound) | macOS → iOS | Same message channel, reversed direction | Uses same encoder/transport |

**Key invariant:** No component crosses more than one layer boundary. UI does not call transport. Injection does not call transport. The only layer that calls across the device boundary is Transport.

---

## Build Order (What Must Exist Before What)

The dependency chain is strict. Build bottom-up.

```
1. Protocol (Message types + framing)
        ↓ required by
2. Transport Layer — USB path only
        ↓ required by
3. CGEventInjector (macOS) — proves end-to-end pipeline
        ↓ required by
4. Keyboard UI (iOS) — needs working pipeline to test against
        ↓ after all of the above work
5. AWDLTransport + USB→AWDL switchover
        ↓ after USB transport stable
6. Hotkey panel UI (iOS) + Hotkey injection (macOS)
        ↓ Phase 1 complete
7. AXInjector (macOS) — cursor, selection, text read-back
        ↓ required by
8. TextPreviewView (iOS) — needs AX read-back working
        ↓ required by
9. iOS predictive text integration — needs mirror state
        ↓ Phase 2 complete
10. AppAwarenessService (macOS) + app-scoped HotkeyPanel (iOS)
        ↓ Phase 3 complete
```

**Rationale for this order:**
- Protocol must come first: both sides share message definitions. Any mismatch breaks everything. Define once, copy to both targets.
- USB before AWDL: USB is deterministic (cable in = connected). AWDL peer discovery adds non-determinism. Validate the pipeline is correct on USB before adding fallback complexity.
- CGEvent before AX: CGEvent requires no special setup on development machines. AX requires granting Accessibility permission and is harder to debug. Prove keystroke injection works before adding the more complex AX path.
- Keyboard UI after pipeline: You need a working receiver (macOS) to know your iOS sender is sending the right bytes. Build receiver first, test with a hardcoded sender, then build the real UI.
- AX before TextPreview: The iOS mirror requires macOS to read and send back text state. AX is the only API that can read the current text value of a focused field without simulating keystrokes.

---

## Integration Points

### External System Boundaries

| System | Integration | macOS Permission Required |
|--------|-------------|--------------------------|
| usbmuxd daemon (macOS) | iOS connects to TCP port on macOS localhost; usbmuxd tunnels it to iOS via USB | None (usbmuxd handles tunneling transparently) |
| CoreGraphics HID event tap | CGEventPost(kCGHIDEventTap, …) injects events at the HID level | None (posting events does not require special entitlement for foreground processes; may need kCGEventTapOptionDefault for background) |
| macOS Accessibility API | AXUIElementSetAttributeValue writes text, selection | Must appear in System Settings → Privacy → Accessibility |
| MultipeerConnectivity / AWDL | MCSession with mandatory AWDL interface flag | com.apple.developer.networking.multipath entitlement NOT needed for personal/self-signed; requires `NSLocalNetworkUsageDescription` in Info.plist |
| NSWorkspace (macOS) | frontmostApplication + change notifications | None |

### Internal Boundaries Enforced by Structure

| Boundary | Communication Contract | Why Enforced |
|----------|----------------------|--------------|
| UI ↔ Protocol | Only typed Message values cross this line | UI changes (e.g., adding Phase 2 preview) must not require Protocol changes |
| Protocol ↔ Transport | Only opaque Data frames cross this line | Message format can evolve without touching transport; transport can change without touching messages |
| Transport ↔ Injection | Transport emits Data; Injection never sees Data | Injection logic is pure platform code, not network code |
| CGEventInjector ↔ AXInjector | InjectionRouter is the only caller of both | Prevents callers from having to know which injector is appropriate |

---

## Scalability Considerations

This system is personal-use, single-user, single-device-pair. Scalability in the traditional sense does not apply. The relevant "scaling" concerns are latency and reliability under load.

| Concern | Normal Use | Typing Fast (10 keys/sec) | Notes |
|---------|-----------|---------------------------|-------|
| Latency budget | USB round-trip ~1ms + processing ~1ms = ~2ms target | Same — USB is synchronous at USB speeds | AWDL adds ~5-15ms; still imperceptible |
| Message queue depth | Zero queue; send synchronously per keystroke | Small bounded queue (max 20 frames) to absorb bursts | Drop oldest if queue full — user sees lag but no hang |
| AX read-back frequency | On each keystroke that could change text | Throttle to 50ms debounce | AX calls block the macOS main thread briefly |
| Connection recovery | Auto-reconnect on disconnect | Same | AWDL peer discovery can take 2-5 seconds |

---

## Anti-Patterns

### Anti-Pattern 1: Mixing Transport Logic into UI

**What people do:** Put the `NWConnection` or `MCSession` directly in the ViewController. Wire button taps to `connection.send()` calls.

**Why it's wrong:** When transport changes (USB → AWDL switchover, or Phase 1 → Phase 2 protocol upgrade), every UI file must change. The "transport must not change after Phase 1" invariant becomes impossible to verify.

**Do this instead:** UI calls `TransportManager.send(message)`. TransportManager decides which transport is active. UI has no import of Network or MultipeerConnectivity.

---

### Anti-Pattern 2: Encoding Message Types in the Transport Layer

**What people do:** USBTransport knows about `KeyEvent`, `HotkeyEvent`, `CursorMoveEvent` — it serializes them internally.

**Why it's wrong:** Adding a new message type in Phase 2 forces changes to transport code. This violates the Phase 1 transport immutability requirement.

**Do this instead:** Transport sends and receives `Data`. Protocol layer owns encoding/decoding. Transport is byte-blind.

---

### Anti-Pattern 3: Using CGEvent for All Text in Phase 2

**What people do:** Implement cursor movement as simulated arrow key presses (CGEvent with kVK_LeftArrow). Implement text selection by simulating Shift+Arrow. Implement text deletion by simulating Backspace.

**Why it's wrong:** This only works when the cursor is at the position you think it is. It does not let you move to an arbitrary position, read current selection state, or feed iOS predictive text (which produces a string, not individual keypresses). CGEvent alone cannot implement "move cursor to arbitrary position" or the TextPreviewBox mirror.

**Do this instead:** Use AXUIElement to read `kAXSelectedTextRangeAttribute` and `kAXValueAttribute`, modify them directly, and write back. This gives absolute cursor positioning and enables the mirror. Reserve CGEvent for raw keystrokes and modifier combos where AX is insufficient (e.g., Cmd-C where AX doesn't know copy was executed).

---

### Anti-Pattern 4: Hardcoding Port Numbers or Service Names in Both Targets

**What people do:** `let usbPort = 12345` appears in both iOS and macOS source files. Service name `"keyd-service"` appears in two MCNearbyServiceAdvertiser initializers.

**Why it's wrong:** When you need to change them (port conflict, name collision), you miss one and the connection silently fails with no error message.

**Do this instead:** Define protocol constants in one place. For personal use (no SPM shared target), put them in a `ProtocolConstants.swift` on each side and add a build warning comment: `// MUST MATCH iOS/Sources/Protocol/ProtocolConstants.swift`.

---

### Anti-Pattern 5: Requesting Accessibility Permission Without Explanation

**What people do:** The macOS helper silently calls AXUIElementSetAttributeValue and fails because Accessibility is not granted. No UI, no instructions.

**Why it's wrong:** The helper will appear to do nothing. Debugging this is confusing because there's no error thrown — AX just returns AXError.notImplemented or silently does nothing on some apps.

**Do this instead:** On launch, check `AXIsProcessTrusted()`. If false, call `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` to show the system dialog, and display a menu bar status item indicating "Accessibility not granted — text editing features disabled."

---

## Sources

- Apple Accessibility Programming Guide for macOS (training knowledge, HIGH confidence for AXUIElement pattern)
- CGEvent Reference / Quartz Event Services (training knowledge, HIGH confidence — stable API since macOS 10.4)
- MultipeerConnectivity framework documentation (training knowledge, MEDIUM confidence — AWDL interface flag behavior is underdocumented; verify entitlement requirements)
- usbmuxd protocol: libimobiledevice project documentation (training knowledge, MEDIUM confidence — open source reverse-engineering; verify port forwarding behavior on current iOS/macOS versions)
- NSWorkspace / NSWorkspaceDidActivateApplicationNotification (training knowledge, HIGH confidence — stable AppKit API)

---

*Architecture research for: iOS-to-macOS remote keyboard / text injection (keyd)*
*Researched: 2026-02-27*
