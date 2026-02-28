# Phase 1: Transport and Core Keyboard - Research

**Researched:** 2026-02-27
**Domain:** iOS-to-macOS USB/AWDL transport layer + CGEvent keystroke injection + iOS SwiftUI keyboard + macOS menu-bar agent
**Confidence:** MEDIUM (core Apple APIs are HIGH confidence; AWDL entitlement requirements for self-signed personal-use builds are LOW confidence — must verify by testing on physical device)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### iOS Keyboard & Hotkey Layout
- Keyboard: Custom SwiftUI layout that closely mimics native iOS keyboard appearance (full control over layout, dark/light mode key highlight behavior, hotkey row integration)
- Hotkey panel: Grid layout, 2 columns × N rows, horizontally scrollable. Phase 1 fills 1–2 screens; grid scales for Phase 3 app-aware shortcuts without redesign
- Hotkey button labels: Icons where the action is universally recognized (copy, paste, cut, undo); text labels for less-common shortcuts (screenshot, select all, quit)
- Liquid Glass / glassmorphism: Applied to hotkey panel chrome and overall app chrome only — NOT to individual keyboard key caps, which use standard iOS key appearance

#### Connection Status UI
- Primary status surface: Dynamic Island (Live Activity) — compact shows color dot only (green=USB, yellow=AWDL, red=disconnected); expanded view shows latency and reconnect button. Fallback to top bar indicator on devices without Dynamic Island.
- USB → AWDL handoff: Silent. Status flips directly from USB-green to AWDL-yellow only when AWDL connection is confirmed. No intermediate "Switching..." state.
- Debug screen: Shake-to-reveal popup (available in all builds). Shows: scrollable connection event log, current transport state (USB/AWDL/disconnected), retry count, last error message.

#### Security — One-Time Pairing
- First launch requires QR code pairing: macOS agent displays a QR code; iOS app uses camera to scan it. Encrypted key exchange happens after scan. After first-time pairing, subsequent connections authenticate automatically using stored keys.
- This pairing must happen before any keyboard input is accepted. The keyboard screen stays in "Waiting to pair" state until pairing completes.

#### Keyboard Interaction Model
- Key feedback: Haptic feedback + visual highlight matching native iOS keyboard behavior (key lightens on press in dark mode, darkens in light mode)
- Backspace auto-repeat: First phase deletes single characters (standard key-repeat rate); after holding ~0.5s, switches to deleting entire words. Matches native iOS backspace behavior exactly.
- Hotkey buttons: Single tap sends the full shortcut as one atomic CGEvent sequence (no sticky modifier key needed in Phase 1)
- Modifier safety: Cmd key-up events must always be sent, including in error paths and on disconnect (Swift `defer` blocks). Prevents stuck-Cmd bug if connection drops mid-shortcut.
- Password field detection: When macOS reports a secure input field is focused, iOS keyboard shows a gray overlay with "Password field active" label. Key input is blocked until field changes.

#### First Launch & Setup Flow
- **iOS first launch:** No onboarding screen. App opens directly to the keyboard view in "Waiting to pair" state. QR code pairing screen appears automatically before keyboard becomes active.
- **macOS first launch:** System alert dialog at launch listing both missing permissions (Accessibility + Input Monitoring) with direct "Open System Settings" button. Agent does not accept connections until both are granted. Same alert re-checks on every launch (both permissions are revoked on Xcode rebuild — this is expected).
- **Connection wait state:** Full keyboard layout is visible but dimmed/non-interactive while connecting. Status indicator shows "Connecting…". Keyboard becomes interactive immediately when connection is established.

#### Orientation & Device Support
- Orientation: Portrait only. Landscape not supported in Phase 1 — keyboard height constraints make landscape impractical.
- Device: iPhone and iPad both supported from Phase 1.

#### iOS Interruptions & Background
- Phone call interruption: Transport stays alive during the call. On return to app, keyboard is immediately active — no reconnect needed.
- App backgrounding: Transport attempts to stay alive using iOS background task APIs. Researcher should investigate the correct background API for a persistent TCP connection. App reconnects immediately when foregrounded if background connection was suspended.
- iOS idle timer: Disabled (`UIApplication.shared.isIdleTimerDisabled = true`) while actively connected.

#### macOS Agent
- Menu bar icon: Static keyboard icon. Clicking opens menu showing: connection state, transport type (USB/AWDL), version, Quit.
- Permission prompts: System alert dialog at every launch if either Accessibility or Input Monitoring is missing. Alert is blocking — agent does not proceed until both granted.
- Agent lifecycle: Registered via `SMAppService.mainApp` as Login Item. macOS auto-restarts agent if it crashes or is force-quit.
- Agent UI: Menu bar icon + menu only. No settings window in Phase 1.

### Claude's Discretion
- Exact port number for usbmuxd TCP tunnel (hardcoded for personal use)
- Specific CGEvent tap target (kCGAnnotatedSessionEventTap vs kCGHIDEventTap — research should verify which works for non-sandboxed self-signed helper)
- iOS background task API selection (VoIP mode, BGProcessingTask, or UIApplication background task — researcher to investigate)
- Dynamic Island Live Activity implementation details (ActivityKit vs NotificationCenter-based)
- Exact retry-with-backoff timing for USB reconnect on plug-in

### Deferred Ideas (OUT OF SCOPE)
- None — all discussion stayed within Phase 1 scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TRANS-01 | iOS app connects to macOS agent over USB via usbmuxd TCP tunnel | NWConnection (iOS) to loopback port; NWListener (macOS) bound to localhost:PORT; usbmuxd forwards iOS device connections transparently |
| TRANS-02 | iOS app connects to macOS agent over AWDL via Bonjour service discovery (`_keyd._tcp`) | Network.framework NWBrowser (iOS) + NWListener (macOS) advertising `_keyd._tcp.` Bonjour service with AWDL-capable parameters |
| TRANS-03 | Connection automatically falls back from USB to AWDL when USB cable is unplugged | TransportManager state machine: monitors USB connection; on disconnect, promotes pre-warmed AWDL connection to primary |
| TRANS-04 | AWDL transport is pre-warmed while USB is active | AWDL NWBrowser/NWListener started concurrently with USB connection; connection established but kept secondary until USB drops |
| TRANS-05 | Transport protocol is bidirectional (both iOS→Mac and Mac→iOS message types defined in Phase 1) | MessageEncoder/Decoder with typed message enum; reserve Mac→iOS types (ReflectState, AppStateChanged) even if unused until Phase 2 |
| TRANS-06 | Wire protocol uses length-prefixed binary framing (4-byte big-endian length + payload) | Custom binary framing in MessageEncoder/Decoder; ensures reliable message boundaries over TCP byte stream |
| TRANS-07 | USB connection retries with backoff on failure (device takes 2–5s to become available after plug-in) | Exponential backoff in USBTransport.connect(); device enumeration takes 2–5s after plug-in |
| KEY-01 | User can type characters into the currently focused macOS text field from the iOS keyboard | CGEventCreateKeyboardEvent + CGEventPost(kCGAnnotatedSessionEventTap) for character injection; works across Safari, Firefox, Messages |
| KEY-02 | User can press Backspace, Return, Tab, and Escape from iOS keyboard | Standard virtual key codes: kVK_Delete (51), kVK_Return (36), kVK_Tab (48), kVK_Escape (53); same CGEvent injection path |
| KEY-03 | iOS keyboard displays as standard full-width keyboard layout at bottom of screen | Custom SwiftUI keyboard layout in UIViewController; portrait-only; uses safeAreaInsets and keyboardLayoutGuide for layout |
| KEY-04 | iOS app is a foreground UIViewController-based app (NOT a UIInputViewController keyboard extension) | Standard UIViewController with custom SwiftUI keyboard view; NOT a system keyboard extension (extensions cannot initiate network connections) |
| KEY-05 | iOS screen does not auto-lock while keyboard is connected | `UIApplication.shared.isIdleTimerDisabled = true` while transport is in connected state |
| SHORT-01 | User can send Command-C (copy) | CGEventCreateKeyboardEvent(nil, kVK_ANSI_C, keyDown) with CGEventSetFlags(kCGEventFlagMaskCommand); followed by key-up; defer block for modifier release |
| SHORT-02 | User can send Command-X (cut) | Same pattern as SHORT-01 with kVK_ANSI_X |
| SHORT-03 | User can send Command-V (paste) | Same pattern as SHORT-01 with kVK_ANSI_V |
| SHORT-04 | User can send Command-Z (undo) | Same pattern as SHORT-01 with kVK_ANSI_Z |
| SHORT-05 | User can send Command-Y (redo) | Same pattern as SHORT-01 with kVK_ANSI_Y |
| SHORT-06 | User can send Command-A (select all) | Same pattern as SHORT-01 with kVK_ANSI_A |
| SHORT-07 | User can send Command-Q (quit) | Same pattern; add confirmation prompt before sending (destructive action) |
| SHORT-08 | User can send Command-Backspace (delete word left) | CGEvent with kVK_Delete + kCGEventFlagMaskCommand |
| SHORT-09 | User can send Command-Delete (delete entire line) | CGEvent with kVK_ForwardDelete + kCGEventFlagMaskCommand |
| SHORT-10 | User can send Command-Shift-4 (screenshot) | CGEvent with kVK_ANSI_4 + kCGEventFlagMaskCommand + kCGEventFlagMaskShift |
| SHORT-11 | Modifier key-up events are always sent, even if connection drops mid-sequence | Swift `defer` blocks around all modifier-sending code; TransportManager sends modifier-release sequence on disconnect |
| AGENT-01 | macOS helper registers as a Login Item (SMAppService) and starts at login | `SMAppService.mainApp.register()` on first launch; requires app to be code-signed |
| AGENT-02 | macOS helper displays connection status in the menu bar | NSStatusItem with NSStatusBar.system; menu shows USB/AWDL/disconnected state |
| AGENT-03 | macOS helper checks for Accessibility permission at every launch and displays persistent prompt if missing | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` on every launch; block connection acceptance until granted |
| AGENT-04 | macOS helper checks for Input Monitoring permission at every launch and displays persistent prompt if missing | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` check on every launch; both Accessibility AND Input Monitoring required since macOS 10.15 |
| AGENT-05 | macOS helper is built WITHOUT App Sandbox | Set `com.apple.security.app-sandbox` to `false` in entitlements; required for CGEventPost and AX operations |
| AGENT-06 | macOS helper detects secure input mode and sends "keyboard paused" indicator to iOS | `IsSecureEventInputEnabled()` from IOKit; poll or observe; send SecureInputChanged message over transport to iOS |
| UX-01 | iOS app uses Liquid Glass (Glassmorphism) visual style using SwiftUI `.ultraThinMaterial` | SwiftUI `.ultraThinMaterial` ViewModifier for panel chrome; NOT applied to individual key caps |
| UX-02 | iOS app displays connection status indicator (USB / AWDL / disconnected) with color coding, always visible | Dynamic Island Live Activity (ActivityKit) on supported devices; fallback to top status bar overlay on older devices |
| UX-03 | iOS keyboard layout: standard keyboard on bottom, macOS hotkey row above it (Phase 1) | SwiftUI VStack: HotkeyPanel above, KeyboardView below; fixed layout within UIViewController |
</phase_requirements>

---

## Summary

Phase 1 establishes the entire foundation of the keyd project: the USB/AWDL transport layer, binary wire protocol, CGEvent keystroke injection engine, iOS keyboard UI, macOS menu-bar agent with permission management, and the one-time QR-code pairing security model. This is the most critical phase because every feature in Phases 2 and 3 builds on what is frozen here. The transport protocol and framing format established in Phase 1 must not be changed in later phases — design it bidirectional from day one even though only iOS→Mac messages are used initially.

The build order within Phase 1 is strict and must be followed: (1) Binary wire protocol definitions and framing → (2) USB transport (macOS listener + iOS connector) → (3) CGEvent injection engine on macOS → (4) iOS keyboard UI → (5) AWDL transport (parallel with USB) → (6) TransportManager switchover logic → (7) Hotkey panel → (8) macOS agent lifecycle (SMAppService, menu bar, permission checks) → (9) QR code pairing → (10) Dynamic Island status. Each step depends on the previous one being testable. Build receiver-first (macOS USB listener + CGEvent injector) with a CLI test sender before building the iOS UI, so the macOS stack is proven before iOS UI work begins.

The most dangerous risks in Phase 1 are: choosing the wrong iOS target architecture (UIInputViewController extension instead of UIViewController — pick wrong and the networking sandbox kills the whole concept), missing the Input Monitoring permission requirement (separate from Accessibility since macOS 10.15 Catalina), AWDL entitlements failing for self-signed personal-use builds (LOW confidence area — must test on physical device before writing AWDL code), and the AX-write-silently-fails-in-browsers pitfall (architecture decision must be "AX read, CGEvent write" from Phase 1). None of these are edge cases — they are guaranteed to occur and must be addressed before anything else is built on top.

**Primary recommendation:** Build the macOS half (USB TCP listener + CGEvent injector + permission checks) and validate it with a simple CLI test client before writing any iOS UI. This proves the full injection pipeline is working and permissions are correctly configured, then iOS UI development is building on a known-good receiver.

---

## Standard Stack

### Core

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Swift 6 | Xcode 16 | Primary language for both iOS app and macOS agent | Swift Concurrency (async/await, actors) is the right model for event-driven transport + UI; SwiftUI is required for Liquid Glass UI |
| SwiftUI | iOS 17+ / macOS 14+ | iOS keyboard layout, hotkey panel, Liquid Glass chrome, macOS menu | `.ultraThinMaterial` for Liquid Glass; native for both platforms |
| Network.framework | iOS 12+ / macOS 10.14+ | USB TCP connection + AWDL Bonjour peer discovery | Apple's unified transport API; NWConnection for USB TCP; NWListener/NWBrowser for AWDL |
| CoreGraphics (CGEvent) | macOS 10.4+ | Keystroke injection + modifier combos | `CGEventCreateKeyboardEvent` + `CGEventPost(kCGAnnotatedSessionEventTap)` — the ONLY reliable write path for Safari, Firefox, Messages |
| Accessibility (AXUIElement) | macOS 10.4+ | Read focused element for secure-input detection; stub for Phase 2 | `AXIsProcessTrustedWithOptions` for permission check; `AXUIElementCreateSystemWide` for focused element queries |
| ServiceManagement (SMAppService) | macOS 13+ | Register macOS agent as Login Item | `SMAppService.mainApp.register()` — replaces deprecated `SMLoginItemSetEnabled` |
| ActivityKit | iOS 16.2+ | Dynamic Island Live Activity for connection status | Required for Lock Screen / Dynamic Island integration; fallback to NSStatusItem overlay |
| AVFoundation (camera) | iOS 17+ | QR code scanning for one-time pairing | `AVCaptureSession` + `AVMetadataObject.ObjectType.qr` |
| CryptoKit | iOS 13+ / macOS 10.15+ | Key exchange for QR pairing (Curve25519 ECDH) | Apple-native; no external crypto dependency needed |

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| Combine | Built-in | Transport state machine reactive binding to SwiftUI | `@Published` properties on TransportManager; UI observes connection state |
| Carbon (virtual key codes) | macOS (stable since 10.x) | CGEvent key code constants (kVK_ANSI_A, kVK_Return, etc.) | Required for CGEventCreateKeyboardEvent; import Carbon.HIToolbox |
| IOKit (IsSecureEventInputEnabled) | macOS | Detect secure input mode (password fields) | `IsSecureEventInputEnabled()` from IOKit/hidsystem/IOLLEvent.h |
| UIKit (targeted use) | iOS 17+ | Idle timer, background task, haptic feedback | `UIApplication.shared.isIdleTimerDisabled`, `UIImpactFeedbackGenerator` |
| AppKit | macOS 14+ | NSStatusItem, NSApplication accessory policy | Menu bar icon + menu; `NSApplicationActivationPolicy.accessory` to hide Dock icon |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Network.framework (NWConnection) for USB | peertalk (rsms/peertalk) | peertalk is unmaintained (~2015), Obj-C only, forces bridging header; NWConnection does the same with 50 lines of Swift |
| Network.framework AWDL | Multipeer Connectivity | MCSession cannot enforce AWDL-only; may silently fall back to Bluetooth or infrastructure Wi-Fi without warning |
| CGEventCreateKeyboardEvent | AXUIElementSetAttributeValue (text write) | AX text write silently fails in Safari, Firefox, Messages (browser web view sandbox); CGEvent is the only reliable path |
| SMAppService.mainApp | LaunchAgent plist | SMAppService integrates with System Settings Login Items; plist requires manual `launchctl` registration |
| ActivityKit (Dynamic Island) | Custom status bar overlay | ActivityKit is the only official API for Dynamic Island; overlay is the fallback for older devices |
| CryptoKit (Curve25519) | CommonCrypto or third-party | CryptoKit is Apple-native, simpler API, no external dependency |

---

## Architecture Patterns

### Recommended Project Structure

```
keyd/
├── KeydApp/                    # iOS app target
│   ├── App/
│   │   ├── KeydApp.swift       # @main, AppDelegate-style setup
│   │   └── RootViewController.swift
│   ├── UI/
│   │   ├── KeyboardView.swift        # SwiftUI custom keyboard layout
│   │   ├── HotkeyPanel.swift         # 2-col grid of shortcut buttons
│   │   ├── ConnectionStatusView.swift # Dynamic Island + fallback overlay
│   │   └── PairingView.swift         # QR code scanner
│   ├── Transport/
│   │   ├── TransportManager.swift    # State machine; USB↔AWDL switchover
│   │   ├── USBTransport.swift        # NWConnection to usbmuxd-forwarded port
│   │   └── AWDLTransport.swift       # NWBrowser for _keyd._tcp
│   └── Protocol/
│       ├── MessageEncoder.swift      # Typed messages → 4-byte-length binary frames
│       ├── MessageDecoder.swift      # 4-byte-length binary frames → typed messages
│       └── Messages.swift            # KeyEvent, HotkeyEvent, ReflectState, etc.
│
├── KeydAgent/                  # macOS agent target (NO App Sandbox)
│   ├── App/
│   │   ├── KeydAgentApp.swift  # @main; NSApplicationActivationPolicy.accessory
│   │   └── AppDelegate.swift   # SMAppService registration; permission checks
│   ├── Transport/
│   │   ├── TransportManager.swift    # Accepts USB + AWDL connections; routes to protocol
│   │   ├── USBListener.swift         # NWListener on localhost:PORT
│   │   └── AWDLListener.swift        # NWListener advertising _keyd._tcp
│   ├── Protocol/
│   │   ├── MessageDecoder.swift      # 4-byte-length frames → typed messages (shared protocol)
│   │   ├── MessageEncoder.swift      # Mac→iOS messages (ReflectState, SecureInputChanged)
│   │   └── Messages.swift            # SHARED: identical to iOS Messages.swift
│   ├── Injection/
│   │   ├── InjectionRouter.swift     # Routes KeyEvent/HotkeyEvent to CGEventInjector
│   │   ├── CGEventInjector.swift     # CGEventCreateKeyboardEvent + CGEventPost
│   │   └── AXInjector.swift          # STUB in Phase 1; reads focused element for secure-input check
│   └── MenuBar/
│       ├── StatusBarController.swift # NSStatusItem; connection state display
│       └── PermissionChecker.swift   # AXIsProcessTrustedWithOptions + IOHIDRequestAccess
│
└── SharedProtocol/             # Swift Package (shared between iOS and macOS targets)
    ├── Messages.swift           # All message type definitions (both directions)
    ├── MessageEncoder.swift
    └── MessageDecoder.swift
```

### Pattern 1: Transport Manager State Machine

**What:** Single actor managing the active transport reference; Protocol layer calls `send()` without knowing whether USB or AWDL is currently active.

**When to use:** Always — this abstraction ensures transport immutability from later phases' perspective.

```swift
// TransportManager.swift (both iOS and macOS versions)
actor TransportManager {
    enum TransportState {
        case disconnected
        case usbConnecting
        case usbConnected(USBTransport)
        case awdlFallback(AWDLTransport)
    }

    private(set) var state: TransportState = .disconnected

    func send(_ data: Data) async throws {
        switch state {
        case .usbConnected(let t): try await t.send(data)
        case .awdlFallback(let t): try await t.send(data)
        case .disconnected, .usbConnecting: throw TransportError.notConnected
        }
    }

    // Called by USBTransport when connection drops
    func usbDidDisconnect() async {
        guard case .usbConnected = state else { return }
        // Promote pre-warmed AWDL if available; else → .disconnected
        if let awdl = awdlPrewarmed {
            state = .awdlFallback(awdl)
        } else {
            state = .disconnected
        }
    }
}
```

### Pattern 2: Length-Prefixed Binary Framing

**What:** Every message is prefixed with a 4-byte big-endian UInt32 length. Receiver reads 4 bytes first, then exactly that many payload bytes. No delimiter scanning needed.

```swift
// MessageEncoder.swift
func encode(_ message: KeydMessage) -> Data {
    let payload = try! encoder.encode(message)  // Codable binary; or manual packing
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    return frame
}

// MessageDecoder.swift — streaming parser state machine
class MessageDecoder {
    private var buffer = Data()
    var onMessage: ((KeydMessage) -> Void)?

    func receive(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = Int(UInt32(bigEndian: buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard buffer.count >= 4 + length else { break }
            let payload = buffer[4..<(4 + length)]
            buffer = buffer.dropFirst(4 + length)
            if let message = try? decoder.decode(KeydMessage.self, from: payload) {
                onMessage?(message)
            }
        }
    }
}
```

### Pattern 3: CGEvent Keystroke Injection with Modifier Safety

**What:** Every modifier key combo sends down/up in atomic sequence; defer blocks guarantee key-up fires even on error.

```swift
// CGEventInjector.swift
func injectHotkey(keyCode: CGKeyCode, modifiers: CGEventFlags) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    defer {
        // ALWAYS release modifier — fires even if below code throws
        let modUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: false)
        modUp?.flags = []
        modUp.map { CGEventPost(.annotatedSession, $0) }
    }
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = modifiers
    keyDown.map { CGEventPost(.annotatedSession, $0) }

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = modifiers
    keyUp.map { CGEventPost(.annotatedSession, $0) }
}
```

### Pattern 4: QR Code Pairing (One-Time)

**What:** macOS agent generates a QR code encoding a CryptoKit Curve25519 public key + port + device ID. iOS scans with AVFoundation, extracts public key, performs ECDH key exchange over the new transport connection. Derived shared secret encrypts all subsequent messages.

**Phases:**
1. macOS generates `Curve25519.KeyAgreement.PrivateKey`; encodes public bytes + port in QR
2. iOS scans QR; connects via USB; sends its own Curve25519 public key
3. Both sides compute `sharedSecret = ECDH(myPrivate, theirPublic)` using CryptoKit
4. Derive symmetric key: `HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedSecret, ...)`
5. All subsequent messages encrypted with AES-GCM using derived key
6. Keys persisted to Keychain for subsequent auto-connect

### Pattern 5: iOS Background Transport Keep-Alive

**What:** iOS VoIP background mode is the correct API for persistent TCP connections. Declare `voip` in `UIBackgroundModes` in Info.plist. Use `setKeepAliveTimeout(_:handler:)` on the socket for periodic keep-alive pings.

**Research finding (Claude's Discretion item):** The VoIP background mode is the correct choice for this project because:
- `UIApplication.beginBackgroundTask` only gives 30 seconds (orderly shutdown, not persistence)
- `BGProcessingTask` is for long-running processing, not real-time network connections
- VoIP background mode specifically allows persistent TCP sockets to remain alive while backgrounded
- Warning: App Store review scrutiny — acceptable for personal-use self-signed app
- Alternative: Background audio mode (`audio`) works but is more deceptive; VoIP is semantically correct

```xml
<!-- Info.plist -->
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
</array>
```

### Pattern 6: Dynamic Island Live Activity

**What:** ActivityKit `Activity<KeydConnectionAttributes>` for Dynamic Island status display. Use `ActivityAuthorizationInfo().areActivitiesEnabled` check before starting.

**Research finding (Claude's Discretion item):** Use ActivityKit (not NotificationCenter) for Dynamic Island:
- `ActivityKit.framework` (iOS 16.2+) is the official Dynamic Island API
- Define `ActivityAttributes` struct with content state (ConnectionStatus enum: usb, awdl, disconnected)
- Compact leading/trailing views show color dot; expanded view shows latency + reconnect button
- Lock Screen widget shows full status
- For devices without Dynamic Island (pre-iPhone 14 Pro), ActivityKit still shows on Lock Screen; fallback to custom overlay view in the app chrome

### Anti-Patterns to Avoid

- **UIInputViewController (keyboard extension):** Extensions cannot initiate network connections; lifecycle is uncontrollable; DO NOT build the keyboard as a system extension target in Xcode
- **AX text value writes (`kAXValueAttribute`):** Silently fails in Safari, Firefox, Messages; use CGEvent for ALL text input and key injection; AX is read-only in this project
- **JSON framing over the socket:** Parsing overhead; keyboard events are small fixed-size messages; use binary framing with 4-byte length prefix
- **Polling `frontmostApplication` or text state:** Use NSWorkspace notifications and AXObserver; polling burns CPU and adds latency
- **Registering AXObserver on main browser PID:** Safari/Firefox web content runs in separate process; Phase 2 concern, but document the pattern now
- **Multipeer Connectivity for AWDL:** Cannot enforce AWDL-only; may silently fall back to Bluetooth; use Network.framework NWListener/NWBrowser with Bonjour `_keyd._tcp`

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CGEvent key codes | Custom key code lookup table | Import `Carbon.HIToolbox` | Carbon HIToolbox has all `kVK_*` constants; available on macOS in Swift with `import Carbon` |
| USB transport | Raw usbmuxd protocol parser, peertalk | `NWConnection` on loopback TCP port | usbmuxd handles device multiplexing transparently; just bind TCP and receive iOS connections |
| AWDL peer discovery | Raw AWDL socket with `SO_RECV_ANYIF` | Network.framework `NWBrowser`/`NWListener` | Raw AWDL requires undocumented entitlements; NWBrowser/NWListener is the supported path |
| Binary frame parser | Custom streaming parser | MessageDecoder with 4-byte length prefix pattern | The streaming parser is 20 lines; hand-rolling over NWConnection's async receive API handles edge cases correctly |
| Crypto (key exchange) | Manual ECDH math | CryptoKit `Curve25519.KeyAgreement` + HKDF | CryptoKit handles constant-time operations, key material zeroing; don't hand-roll crypto |
| Permission state | Manual `AXIsProcessTrusted` polling | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | This API auto-prompts and is the documented path; manual polling has no advantage |
| Login Item registration | `LaunchAgent` plist + `launchctl` | `SMAppService.mainApp.register()` | SMAppService is the supported API in macOS 13+; integrates with System Settings |

---

## Common Pitfalls

### Pitfall 1: Wrong iOS Target Architecture

**What goes wrong:** Building the keyboard as a `UIInputViewController` keyboard extension — the extension sandbox prevents initiating network connections, lifecycle is uncontrollable, and iOS may kill it at any time.

**How to avoid:** iOS target is a standard `UIViewController`-based app. Custom keyboard UI is a `UIView` or SwiftUI `View` embedded in the view controller. The keyboard extension target type must never be selected in Xcode for this project.

**Warning signs:** Extension target in Xcode → Network code won't compile → Drop this approach immediately.

### Pitfall 2: Missing Input Monitoring Permission (Separate from Accessibility)

**What goes wrong:** Since macOS 10.15 Catalina, `CGEventPost` for global key injection requires **Input Monitoring** permission in addition to Accessibility. Apps that only request Accessibility find CGEvent silently fails when another app is frontmost.

**How to avoid:** Check BOTH at every launch:
```swift
// Check Accessibility
let axTrusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)
// Check Input Monitoring
let hmTrusted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
```
Block connection acceptance until both are `true`.

### Pitfall 3: AX Permission Revoked on Every Xcode Rebuild

**What goes wrong:** AX and Input Monitoring permissions are tied to the binary hash. Every Xcode rebuild revokes both. AX calls return `kAXErrorAPIDisabled` with no useful log output.

**How to avoid:** Check BOTH permissions at EVERY launch (not just first launch). Show blocking UI when missing. Document "toggle off/on in System Settings" as the standard rebuild recovery procedure.

### Pitfall 4: AWDL Entitlement Requirements for Self-Signed Apps

**What goes wrong:** NWBrowser/NWListener with AWDL may require `com.apple.developer.networking.wifi-info` entitlement. Free-tier provisioning profiles may not include this. App may crash at launch with `LAUNCH_CONSTRAINTS_VIOLATION` or silently fall back to infrastructure Wi-Fi.

**How to avoid (LOW confidence — must test):**
- Use a paid Apple Developer account ($99/year); free-tier profiles lack networking entitlements
- Audit `.entitlements` file — remove anything not in the provisioning profile
- Test AWDL with Wi-Fi infrastructure disconnected AND Bluetooth off — confirm true AWDL, not silent fallback
- Do this test on day 1 of Phase 1 before writing any AWDL-dependent code

### Pitfall 5: usbmuxd Connection Requires Retry-With-Backoff

**What goes wrong:** Device takes 2–5 seconds to become ready after plug-in; first connection attempt always fails; app appears broken on every cable plug.

**How to avoid:** Implement exponential backoff in `USBTransport.connect()`: initial 0.5s delay, double on each failure, cap at 5s, max 10 retries. Log every attempt. Surface retry state to iOS UI ("Connecting...").

### Pitfall 6: CGEvent Modifier Key Gets Stuck

**What goes wrong:** If connection drops during a Cmd+C sequence after key-down but before key-up, macOS behaves as if Cmd is permanently held. Every subsequent key becomes a shortcut.

**How to avoid:** Always send key-up in a Swift `defer` block. On transport disconnect, `TransportManager` sends a "release all modifiers" synthetic CGEvent sequence before closing.

### Pitfall 7: CGEvent Secure Input Mode Blocking

**What goes wrong:** Password fields enable secure input mode. `CGEventPost` succeeds (no error) but events are silently dropped. User types into void with no indication.

**How to avoid:** Poll `IsSecureEventInputEnabled()` or observe via `kAXFocusedUIElementChangedNotification`. When secure input is detected, send `SecureInputChanged(true)` message to iOS. iOS shows "Password field active" overlay and blocks all key sending.

### Pitfall 8: Keyboard Height Breaking on iPhone Models With Dynamic Island / Home Indicator

**What goes wrong:** Hard-coded keyboard frame sizes or `UIScreen.main.bounds` (deprecated iOS 16) produce clipped or mispositioned keyboard on newer devices.

**How to avoid:** Use `safeAreaInsets` and `keyboardLayoutGuide` (iOS 15+) for all layout. Test on: iPhone SE (no notch), iPhone 13 (notch), iPhone 14 Pro+ (Dynamic Island).

---

## Claude's Discretion Recommendations

### CGEvent Tap Target

**Recommendation: `kCGAnnotatedSessionEventTap`** (also spelled `.annotatedSession` in Swift enum)

`kCGAnnotatedSessionEventTap` posts events at the session level and is more reliably received by the frontmost application in a non-sandboxed helper. `kCGHIDEventTap` posts at the HID level and may have different permission requirements. For a non-sandboxed self-signed macOS helper with both Accessibility and Input Monitoring permissions granted, `kCGAnnotatedSessionEventTap` is the documented recommendation for injecting events into the frontmost app.

**Confidence:** MEDIUM — verify by testing `CGEventPost(.annotatedSession, event)` vs `CGEventPost(.hidSystemState, event)` on macOS 15 with the helper running.

### usbmuxd TCP Port

**Recommendation: Port 12345** (hardcoded; no dynamic discovery needed for personal use)

The macOS `USBListener` binds `NWListener` to `127.0.0.1:12345`. usbmuxd forwards incoming iOS device connections to this port. The iOS app's `USBTransport` connects to the same loopback port from the device side via the USB tunnel.

For a personal-use app with a single device pair, a fixed port is sufficient and simpler. Document the port in a `SharedConstants.swift` file shared between targets.

### iOS Background Task API

**Recommendation: VoIP background mode**

Declare `voip` in `UIBackgroundModes` (Info.plist). This allows persistent TCP socket connections while the app is backgrounded. The VoIP background mode is semantically correct for persistent real-time communication sockets. BGProcessingTask is for batch processing jobs; UIApplication.beginBackgroundTask gives only 30 seconds; neither is appropriate for a persistent keyboard connection.

Note: `setKeepAliveTimeout(_:handler:)` was deprecated in iOS 13; use `Network.framework`'s built-in keep-alive parameters on `NWConnection` instead. Configure `NWProtocolTCP.Options.enableKeepalive = true` on the NWParameters.

### Dynamic Island Implementation

**Recommendation: ActivityKit `Activity<KeydConnectionAttributes>`**

ActivityKit is the correct framework for Dynamic Island and Lock Screen Live Activities. Define:
```swift
struct KeydConnectionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: ConnectionStatus  // .usb, .awdl, .disconnected
        var latencyMs: Int?
    }
}
```
Update the Live Activity content state when transport switches. For pre-Dynamic Island devices, ActivityKit still displays on the Lock Screen; add a SwiftUI overlay view in the app chrome as the fallback visible-while-in-app indicator.

### Retry-With-Backoff Timing

**Recommendation:**
- Initial delay before first attempt: 0.5 seconds (device needs minimum 0.5s after usbmuxd `DeviceAdd` event)
- Backoff: exponential with base 2 — 0.5s, 1s, 2s, 4s, 5s (cap at 5s)
- Max retries: 10 before surfacing "Unable to connect — unplug and replug cable"
- On successful connection: reset retry counter immediately

---

## Code Examples

### USB Transport — macOS NWListener

```swift
// USBListener.swift (macOS)
import Network

actor USBListener {
    private var listener: NWListener?

    func start(port: UInt16 = 12345, onConnection: @escaping (NWConnection) -> Void) throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true  // Only accept from loopback (usbmuxd tunnel)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { connection in
            connection.start(queue: .global())
            onConnection(connection)
        }
        listener?.start(queue: .global())
    }
}
```

### USB Transport — iOS NWConnection

```swift
// USBTransport.swift (iOS)
import Network

actor USBTransport {
    private var connection: NWConnection?

    func connect(port: UInt16 = 12345) async throws {
        let params = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: params)
        // Retry-with-backoff handled by caller (TransportManager)
        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            connection?.start(queue: .global())
        }
    }
}
```

### AWDL Transport — NWListener with Bonjour

```swift
// AWDLListener.swift (macOS)
import Network

actor AWDLListener {
    private var listener: NWListener?

    func advertise(serviceName: String = "keyd") throws {
        let params = NWParameters.applicationService  // AWDL-capable
        listener = try NWListener(using: params)
        listener?.service = NWListener.Service(type: "_keyd._tcp")
        listener?.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // Hand to TransportManager
        }
        listener?.start(queue: .global())
    }
}
```

### CGEvent Injection — Character Input

```swift
// CGEventInjector.swift
import CoreGraphics
import Carbon

func injectUnicodeString(_ string: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    let utf16 = Array(string.utf16)
    for scalar in utf16 {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
        down.map { CGEventPost(.annotatedSession, $0) }

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
        up.map { CGEventPost(.annotatedSession, $0) }
    }
}
```

### Secure Input Detection

```swift
// macOS helper — check before injecting
import IOKit.hidsystem

func isSecureInputActive() -> Bool {
    return IsSecureEventInputEnabled()
}
```

### Permission Check Pattern

```swift
// PermissionChecker.swift (macOS)
import Accessibility
import IOKit.hid

func checkPermissions() -> (accessibility: Bool, inputMonitoring: Bool) {
    let ax = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt: true] as CFDictionary
    )
    let im = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    return (accessibility: ax, inputMonitoring: im)
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SMLoginItemSetEnabled (deprecated) | SMAppService.mainApp.register() | macOS 13 | SMLoginItemSetEnabled removed in macOS 15; use SMAppService |
| `UIScreen.main.bounds` | View geometry / `UIWindowScene.keyWindow.bounds` | iOS 16 | UIScreen.main deprecated iOS 16; use window-relative layout |
| peertalk (rsms/peertalk) | Raw NWConnection over usbmuxd TCP | 2014 (last peertalk update) | peertalk is unmaintained Obj-C; NWConnection is the supported path |
| SMJobBless privileged helper | Not needed (AX + CGEvent work at user space) | Always true | CGEvent injection only needs Accessibility TCC; no kernel extensions required |
| `MultipeerConnectivity` for AWDL | `Network.framework` NWBrowser/NWListener | iOS 12 / macOS 10.14 | NWBrowser gives explicit Bonjour control; MCSession is opaque |
| `setKeepAliveTimeout(_:handler:)` | `NWProtocolTCP.Options.enableKeepalive` | iOS 13 | Old API deprecated; configure on NWParameters before connection |

**Deprecated/outdated:**
- `SMLoginItemSetEnabled`: removed macOS 15; use SMAppService
- `UIScreen.main.bounds`: deprecated iOS 16; use scene/window geometry
- `peertalk`: unmaintained ~2015; use NWConnection
- `NSNetService` (deprecated iOS 15): use `NWListener` with NWListener.Service for Bonjour

---

## Open Questions

1. **AWDL entitlement requirements under self-signed personal-use builds**
   - What we know: NWBrowser/NWListener with Bonjour over AWDL may need `com.apple.developer.networking.wifi-info`; free-tier provisioning profiles lack networking entitlements
   - What's unclear: Whether Bonjour-based peer discovery specifically (vs. raw multicast) requires the `wifi-info` entitlement; behavior with a paid-but-non-App-Store provisioning profile
   - Recommendation: On day 1 of Phase 1, test NWBrowser + NWListener with infrastructure Wi-Fi OFF and Bluetooth OFF on a physical iPhone and Mac. If connection completes = entitlement not required or already included. If not = purchase paid developer account and re-provision. DO NOT write any AWDL-dependent code until this is verified.

2. **usbmuxd iOS 18 + macOS 15 protocol compatibility**
   - What we know: The raw TCP-over-usbmuxd approach (NWConnection to loopback port; usbmuxd handles device routing transparently) avoids the plist-level usbmuxd protocol entirely
   - What's unclear: Whether Apple changed any aspect of the port forwarding behavior in iOS 18 or macOS 15
   - Recommendation: Validate USB transport (NWListener on macOS + NWConnection on iOS to same port) works end-to-end before building anything on top. This is the day-1 smoke test.

3. **Secure input mode detection — polling vs. observer**
   - What we know: `IsSecureEventInputEnabled()` returns current state; no documented notification for changes
   - What's unclear: Whether AXObserver can notify on secure-input field focus changes; or if polling is required
   - Recommendation: Poll `IsSecureEventInputEnabled()` every 0.5s on the macOS helper; on change, send `SecureInputChanged` message. If polling proves too expensive, investigate `kAXFocusedUIElementChangedNotification` + checking attribute of focused element.

4. **CGEvent tap target: `kCGAnnotatedSessionEventTap` vs `kCGHIDEventTap`**
   - What we know: Both can post keyboard events; `.annotatedSession` is session-level; `.hidSystemState` is HID-level
   - What's unclear: Which has fewer entitlement requirements on macOS 15 for a non-sandboxed non-App-Store app
   - Recommendation: Start with `.annotatedSession`; if typing doesn't reach frontmost app, fall back to `.hidSystemState`. Test in Safari, Firefox, Messages.

---

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation: CGEventCreateKeyboardEvent, CGEventPost, CGEventSetFlags — stable since macOS 10.4; confirmed in training data
- Apple Developer Documentation: AXIsProcessTrustedWithOptions, AXUIElementCreateSystemWide — Accessibility APIs stable since macOS 10.4
- Apple Developer Documentation: Network.framework NWConnection, NWListener, NWBrowser, NWParameters — training data to August 2025
- Apple Developer Documentation: ServiceManagement SMAppService.mainApp — macOS 13+ API; training knowledge HIGH confidence
- Apple Developer Documentation: ActivityKit — iOS 16.2+ API; training knowledge HIGH confidence
- Apple Developer Documentation: UIApplication.isIdleTimerDisabled — stable UIKit API
- Carbon.HIToolbox virtual key codes (kVK_*) — stable since macOS 10.x
- macOS 10.15 privacy split: Accessibility vs Input Monitoring permissions — well-documented in Apple dev forums; training knowledge HIGH

### Secondary (MEDIUM confidence)
- usbmuxd TCP forwarding behavior — documented in libimobiledevice project; widely tested; usbmuxd behavior is stable on macOS but not Apple-official documentation
- AWDL via Network.framework NWListener/NWBrowser with Bonjour — multiple community implementations; entitlement requirements for non-App-Store apps are the uncertain part
- peertalk deprecation status — GitHub commit history; last meaningful commit ~2014; training knowledge MEDIUM

### Tertiary (LOW confidence)
- AWDL entitlement requirements for self-signed personal-use apps (free-tier vs paid-tier provisioning) — community discussions through training cutoff; real behavior must be tested on device
- Bonjour-specific AWDL (`_keyd._tcp` NWBrowser/NWListener) vs raw multicast: whether `com.apple.developer.networking.wifi-info` is strictly required for Bonjour-style peer discovery

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Core Apple APIs (CGEvent, Network.framework, AXUIElement, SMAppService, ActivityKit) are stable, well-documented, and high-confidence from training data
- Architecture: HIGH — Layer boundaries, component responsibilities, and build order are grounded in stable Apple API patterns and established iOS/macOS architecture
- Pitfalls: HIGH for macOS permissions, CGEvent behavior, UIInputViewController sandbox — thoroughly documented. MEDIUM for usbmuxd reliability. LOW for AWDL entitlements under self-signed builds
- AWDL specifically: LOW — must test on physical device before writing code

**Research date:** 2026-02-27
**Valid until:** 2026-03-27 (stable APIs; AWDL section should be re-validated after physical device testing)

---

## RESEARCH COMPLETE

**Phase:** 1 - Transport and Core Keyboard
**Confidence:** MEDIUM (HIGH for APIs; LOW for AWDL entitlements — verify on device first)

### Key Findings
- Build order is strict: protocol definitions → USB transport → CGEvent injector → iOS keyboard → AWDL → switchover logic → hotkey panel → macOS agent lifecycle → QR pairing → Dynamic Island
- Architecture is "AX read, CGEvent write" — AX is never used to write text in this project (silently fails in browsers); CGEvent is the only reliable injection path
- iOS target MUST be UIViewController-based app (NOT UIInputViewController extension) — extensions cannot initiate network connections
- Both Accessibility AND Input Monitoring permissions are required since macOS 10.15; both must be checked at EVERY launch; both are revoked on every Xcode rebuild
- AWDL entitlement requirements for self-signed builds are the single biggest unknown — must test on physical device on day 1 before writing any AWDL code
- VoIP background mode (`UIBackgroundModes: [voip]`) is the correct iOS background API for persistent TCP sockets
- Use ActivityKit for Dynamic Island; fallback to in-app overlay for older devices
- usbmuxd TCP tunnel is transparent — just bind TCP on macOS and connect on iOS; no usbmuxd protocol parsing needed
- Bidirectional protocol must be defined in Phase 1 even if only iOS→Mac messages are used — Mac→iOS slots (ReflectState, SecureInputChanged, AppStateChanged) must be reserved now

### File Created
`./.planning/phases/01-transport-and-core-keyboard/01-RESEARCH.md`

### Open Questions
1. AWDL entitlement behavior under self-signed builds (LOW confidence — device test required)
2. `kCGAnnotatedSessionEventTap` vs `kCGHIDEventTap` — test both on macOS 15
3. Secure input mode: polling vs AXObserver notification approach
4. usbmuxd iOS 18 + macOS 15 TCP forwarding compatibility (smoke test first thing)

### Ready for Planning
Research complete. Planner can now create PLAN.md files.
