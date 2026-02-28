# Stack Research

**Domain:** iOS-to-macOS keyboard controller (USB/AWDL transport + AX/CGEvent injection)
**Researched:** 2026-02-27
**Confidence:** MEDIUM (web search unavailable; based on training data to August 2025 + official Apple API knowledge; verify versions against Xcode release notes before coding)

---

## Research Note

WebSearch and WebFetch were unavailable during this research session. All findings are based on
training data (cutoff August 2025) and the researcher's knowledge of Apple SDK APIs. Confidence
levels reflect this limitation. Verify specific API availability and deprecation status in the
current Xcode 16.x / iOS 18.x / macOS 15.x release notes before writing any code.

---

## Recommended Stack

### Core Frameworks — iOS App

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift | 6.0 (Xcode 16) | Primary language for iOS app | Swift Concurrency (async/await, actors) is the right model for the event-driven transport + UI work; SwiftUI is the right framework for the Liquid Glass UI; Obj-C would require bridging for no gain |
| SwiftUI | iOS 17+ | Keyboard layout, hotkey panel, Liquid Glass UI | The `.glassEffect()` / `.ultraThinMaterial` approach to Liquid Glass is native in SwiftUI; UIKit would require manual CALayer work for the same effect |
| UIKit (targeted use) | iOS 17+ | Host the stock iOS keyboard inside the app via a hidden text field | Keep a UIKit text field as first responder so the system keyboard stays active, then wrap that host in `UIViewRepresentable` for SwiftUI interop |
| Network.framework | iOS 12+ | AWDL transport (Bonjour service discovery + NWConnection) | Apple's unified transport API; supports AWDL via `NWParameters` with `.peerToPeer` interface; replaces raw BSD sockets for AWDL |
| Foundation (URLSession / Stream) | iOS 16+ | usbmuxd TCP socket communication | usbmuxd exposes a local TCP port (62078) on macOS; on iOS the connection is inbound via a reverse tunnel; use BSD sockets (POSIX) or `NWConnection` over TCP loopback |

### Core Frameworks — macOS Agent

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift | 6.0 (Xcode 16) | Primary language for macOS daemon/agent | Same reasoning as iOS; Swift Concurrency suits the event loop needed to receive packets and dispatch AX calls |
| AppKit | macOS 14+ | NSApplication lifecycle for Login Item / LaunchAgent | macOS agent needs an app bundle or LaunchAgent plist; `NSApplicationActivationPolicy.accessory` hides it from the Dock |
| Accessibility (AX) framework | macOS 14+ | Read focused element, detect secure input, and support later cursor/selection sync | `AXUIElementCreateSystemWide()` + `AXUIElementCopyAttributeValue(kAXFocusedUIElement)` is used for state reads; AX value writes are not treated as the production text-entry path |
| CoreGraphics (CGEvent) | macOS 14+ | Inject keystrokes and modifier+key combos (Cmd-C/V/Z etc.) | `CGEventCreateKeyboardEvent` + `CGEventPost(...)` is the production write path; current implementation uses annotated-session for Unicode text and HID tap for virtual-key shortcuts |
| Network.framework | macOS 12+ | AWDL listener (NWListener) and usbmuxd TCP server | Same NWConnection/NWListener API on macOS; AWDL service advertisement via `NWListener` with Bonjour service name |
| ServiceManagement | macOS 13+ | Register Login Item / privileged helper | `SMAppService.mainApp.register()` replaces the deprecated `SMLoginItemSetEnabled` in macOS 13+; required to auto-start the agent at login |

### Transport Layer Detail

| Component | Technology | Version | Purpose | Why |
|-----------|-----------|---------|---------|-----|
| USB channel | BSD sockets over usbmuxd TCP tunnel | macOS usbmuxd (built-in) | Create a listening TCP server on macOS; usbmuxd forwards iOS connections to that port | The usbmuxd mux daemon (built into macOS since OS X 10.6) handles the USB multiplexing transparently; no additional library needed; just bind to localhost:PORT and receive connections from iOS when the device is plugged in |
| USB channel (iOS side) | BSD sockets (POSIX connect to usbmuxd-forwarded port) | iOS 16+ | iOS initiates TCP connect to the forwarded port | On iOS, iTunes / Apple Devices sets up the forward; the iOS app simply `connect()`s to the loopback address at the negotiated port; usbmuxd handles the rest |
| AWDL channel | Network.framework NWBrowser + NWListener | iOS 12+ / macOS 12+ | Bonjour service discovery over AWDL interface | `NWParameters.applicationService` enables AWDL-capable peer connections without needing explicit AWDL interface selection; Bonjour `_keyd._tcp` service type enables discovery |
| Transport switchover | Custom Swift state machine | N/A | Detect USB disconnect, promote AWDL connection to primary | Monitor usbmuxd connection closure; have AWDL connection pre-established in parallel; switch active channel on USB drop |
| Message framing | Length-prefixed binary frames | N/A | Reliable message boundaries over TCP stream | TCP is a byte stream; prefix each message with a 4-byte big-endian length so receiver can reassemble; simpler and lower overhead than JSON for a real-time keyboard |

### macOS Privileged Access

| Concern | Technology | Notes |
|---------|-----------|-------|
| AX permission | Accessibility TCC (macOS Privacy) | User must grant "Accessibility" permission in System Settings > Privacy & Security; the app bundle must be code-signed (self-signed works for personal use); without this, AXUIElement calls silently fail |
| CGEvent permission | Same Accessibility TCC | CGEventPost with `kCGAnnotatedSessionEventTap` requires Accessibility permission for the calling process |
| Input Monitoring | Input Monitoring TCC | Treat as required for this project; the agent checks it at launch and provides a relaunch path after granting |
| Agent auto-start | SMAppService (macOS 13+) | `SMAppService.mainApp` registers the main app as a Login Item without needing a helper bundle; simpler than SMJobBless for this use case |
| No privileged helper needed | — | For AX + CGEvent injection only, a standard user-space agent with Accessibility TCC is sufficient; `SMJobBless` / PrivilegedHelperTool is only needed for kernel-level operations (not required here) |

---

## Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| peertalk (rsms/peertalk) | ~0.x (Obj-C, unmaintained) | Original usbmuxd wrapper used in iOS-Mac USB apps | DO NOT USE — see "What NOT to Use" below; use raw BSD sockets or NWConnection instead |
| libimobiledevice | latest (C library) | Comprehensive iOS device management including usbmuxd | DO NOT USE for this project — see "What NOT to Use"; usbmuxd is built into macOS and accessible via raw TCP without this library |
| Combine | Built-in (Swift 5.5+) | Reactive streams for transport state + UI binding | Use for transport state machine (USB connected/disconnected events) wiring to SwiftUI; pairs with `@Published` properties on the connection manager |
| swift-nio | 2.x | Alternative async TCP/networking primitives | Optional; only if NWConnection proves too high-level for the framing requirements; adds complexity; not recommended unless NWConnection has issues |

---

## Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode 16.x | iOS + macOS development, signing, deployment | Required; use the Simulator for initial AX testing but must test on real device for usbmuxd and AWDL |
| Instruments (Time Profiler) | Latency profiling for keystroke round-trip | Keyboard latency must be under 50ms; profile early |
| `axe` CLI / Accessibility Inspector.app | Inspect AX hierarchy of target apps | Built into Xcode; essential for understanding which AX attributes Safari/Firefox/Messages expose |
| Network Link Conditioner | Simulate USB/AWDL bandwidth and latency | Test AWDL fallback behavior under degraded conditions |
| `idevice_id` / `ideviceinfo` | Verify usbmuxd device detection from command line | Part of libimobiledevice CLI tools; useful for debugging the USB connection independent of app code |

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| USB transport library | Raw BSD sockets over usbmuxd | peertalk (rsms/peertalk) | peertalk is Obj-C, last commit 2015, requires bridging header, adds no value over raw sockets; the usbmuxd protocol it wraps is just a TCP forward |
| USB transport library | Raw BSD sockets over usbmuxd | libimobiledevice | C library, requires SPM wrapping or manual xcframework, adds hundreds of KB, designed for device management not realtime communication; overkill |
| AWDL transport | Network.framework NWListener/NWBrowser | Raw AWDL sockets (BSD + SO_RECV_ANYIF) | Raw AWDL requires entitlements Apple doesn't grant to App Store apps; for self-signed personal use it might work but is undocumented and fragile; Network.framework is the supported path |
| macOS text injection | CGEventCreateKeyboardEvent | IME (Input Method Kit) | IME via InputMethodKit requires a full Input Method bundle registered with the system; massive complexity for personal use; use CGEvent for text entry and reserve AX for state reads/sync |
| macOS text injection | CGEventCreateKeyboardEvent | IOKit HID virtual device | HID virtual device requires a kernel extension (DriverKit in modern macOS) for full compatibility; far more complexity than CGEvent; CGEvent + AX covers all target apps (Safari, Firefox, Messages) |
| Language | Swift (both sides) | Objective-C (both sides) | Obj-C has no advantage here; AX and CGEvent APIs have Swift overlays; Network.framework is Swift-first; Obj-C only makes sense if bridging to existing Obj-C code |
| Language | Swift (both sides) | Mixed Swift + Obj-C | The peertalk dependency would force mixed; since we're not using peertalk, stay pure Swift |
| macOS agent registration | SMAppService.mainApp | LaunchAgent plist | SMAppService is the supported API in macOS 13+; LaunchAgent plists still work but require manual `launchctl` registration; SMAppService integrates with Login Items in System Settings |
| AWDL discovery | Bonjour via NWBrowser (_keyd._tcp) | Multipeer Connectivity (MCSession) | Multipeer Connectivity wraps AWDL+Bluetooth in an opaque session; no control over transport selection; cannot enforce AWDL-only; cannot reliably coexist with USB transport in the same session |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| peertalk (rsms/peertalk) | Unmaintained since ~2015; Obj-C only; forces bridging header; wraps usbmuxd TCP in a way that's easily replicated with 50 lines of Swift using BSD sockets or NWConnection | Raw BSD sockets (`bind`/`accept` on macOS, `connect` on iOS) to the usbmuxd-forwarded port |
| libimobiledevice | C library designed for device management (file transfer, backup, media sync); not designed for real-time bidirectional communication; heavy dependency; complex to build as xcframework | Raw usbmuxd TCP tunnel (no library needed) |
| Multipeer Connectivity | Cannot enforce AWDL-only transport; may use Bluetooth fallback without your knowledge; opaque session model; no control over message framing; discovered latency issues in real-world use | Network.framework NWBrowser/NWListener with `.peerToPeer` parameters over Bonjour |
| InputMethodKit (IME) | Requires registering a system Input Method that replaces the user's keyboard system-wide; requires separate bundle, plist registration, and user consent; excessive complexity for injection into 3 target apps | CGEventCreateKeyboardEvent for text entry; AXUIElement for read/sync only |
| SMJobBless / PrivilegedHelperTool | Requires XPC service, separate signed helper binary, and admin authentication; needed for root-level operations; AX + CGEvent work at user-space level and only need Accessibility TCC | SMAppService.mainApp for Login Item; standard process for AX/CGEvent |
| Bluetooth transport | Explicitly out of scope per project constraints | usbmuxd (USB) + Network.framework AWDL |
| JSON framing over the socket | Parsing overhead adds latency; keyboard events are small fixed-size messages; JSON adds 3-10x payload size for no benefit in this context | 4-byte length-prefixed binary frames with a compact message protocol (e.g., struct with event type + key code + modifiers) |

---

## Stack Patterns by Variant

**For the USB path (usbmuxd):**
- macOS side: `bind()` a TCP socket on `127.0.0.1:PORT`; usbmuxd forwards the iOS device's connection to this port when the device is connected via USB
- iOS side: `connect()` to `127.0.0.1:PORT`; the usbmuxd daemon on macOS proxies the connection through USB
- Port negotiation: use a fixed agreed-upon port (e.g., 12345); no dynamic discovery needed for USB
- Implementation: use POSIX BSD sockets wrapped in a Swift actor for thread safety, or use `NWConnection` with `.tcp` parameters to the loopback address

**For the AWDL path (Network.framework):**
- macOS side: `NWListener` advertising `_keyd._tcp.` Bonjour service; use `NWParameters` with `.applicationService` or custom parameters that allow AWDL
- iOS side: `NWBrowser` browsing for `_keyd._tcp.`; connect to the first discovered endpoint
- The `com.apple.developer.networking.multicast` entitlement is NOT needed for Bonjour/AWDL NWListener/NWBrowser; this is only needed for raw multicast
- AWDL requires the `com.apple.developer.networking.wifi-info` entitlement on iOS for some operations but NWBrowser/NWListener over Bonjour may work without it for personal-use self-signed apps (LOW confidence — verify)

**For AX text injection on macOS:**
- Preferred path: use AX to inspect the focused element, secure-input state, selected range, and later text state for sync
- For cursor-position-aware editing in later phases: use `kAXSelectedTextRangeAttribute` and related read APIs; do not rely on AX value writes as the primary text-entry path
- CGEvent path for keystrokes: `CGEventCreateKeyboardEvent(nil, keyCode, keyDown)` → set flags → `CGEventPost(...)` — current implementation uses annotated-session posting for Unicode text and HID posting for virtual-key shortcuts
- For Safari/Firefox web text fields: treat CGEvent keystroke injection as the reliable write path

**For the macOS agent lifecycle:**
- Use `NSApplicationActivationPolicy.accessory` so agent has no Dock icon
- Register as Login Item via `SMAppService.mainApp.register()` on first launch
- Use a menu bar `NSStatusItem` for "running" indicator and manual quit

---

## Version Compatibility

| Component | iOS Minimum | macOS Minimum | Notes |
|-----------|-------------|---------------|-------|
| Network.framework NWBrowser/NWListener | iOS 12.0 | macOS 10.14 | Well-established; use iOS 17+ / macOS 14+ to get Swift Concurrency integration (async/await on NWConnection) |
| NWParameters.applicationService (AWDL-capable) | iOS 14.0 | macOS 11.0 | The specific parameter that enables peer-to-peer without explicit AWDL interface selection; verify entitlement requirements for self-signed apps |
| SMAppService.mainApp | — | macOS 13.0 | New Login Items API; falls back to `SMLoginItemSetEnabled` on macOS 12 and earlier; since personal-use, target macOS 14+ and use SMAppService exclusively |
| AXUIElement text injection | — | macOS 10.4+ | Stable, long-standing API; no version concerns |
| CGEventCreateKeyboardEvent | — | macOS 10.4+ | Stable; CGEventPost behavior with `kCGAnnotatedSessionEventTap` unchanged since introduction |
| Swift Concurrency (actors, async/await) | iOS 15+ | macOS 12+ | Use for transport state machine; requires deployment target iOS 15+ / macOS 12+; since personal-use targeting latest, use iOS 17 / macOS 14 |
| SwiftUI `.ultraThinMaterial` (Liquid Glass base) | iOS 15+ | macOS 12+ | The `.ultraThinMaterial` and `.regularMaterial` environment are the foundation for Liquid Glass/glassmorphism in SwiftUI |
| usbmuxd TCP forwarding | iOS 5+ | macOS 10.6+ | Built-in to macOS; no version concerns for modern targets |

---

## Deployment Configuration

This is a personal-use, self-signed project. Key configuration facts:

- **iOS app:** sign with personal Apple Developer account (free tier or paid); weekly re-sign via Xcode or `codesign`; do NOT build as a Custom Keyboard Extension (UIInputViewController) — build as a regular app that presents a keyboard-like UI, since a keyboard extension cannot initiate network connections
- **macOS agent:** sign with same personal certificate; must be code-signed for AX TCC to grant permission; use `--deep` signing; Accessibility permission is app-identity-bound, so re-signing with the same certificate preserves the TCC grant
- **Entitlements required (iOS):** `com.apple.developer.networking.wifi-info` (may be needed for AWDL NWBrowser), standard `com.apple.security.network.client`
- **Entitlements required (macOS):** `com.apple.security.network.server`, `com.apple.security.network.client`, standard sandbox or disable App Sandbox (preferred for personal use to avoid AX sandbox restrictions)
- **CRITICAL:** macOS App Sandbox blocks `CGEventPost` and many AX operations; for a personal-use agent, build WITHOUT App Sandbox (set `com.apple.security.app-sandbox` to `false` in entitlements); this is fine for personal use and required for the injection to work

---

## Sources

- Apple Developer Documentation: Accessibility (AXUIElement, kAXValueAttribute, kAXFocusedUIElement) — training data, HIGH confidence for API existence, MEDIUM confidence for current behavior in macOS 15.x Safari/Firefox
- Apple Developer Documentation: Network.framework (NWConnection, NWListener, NWBrowser, NWParameters) — training data to August 2025, HIGH confidence for API existence and AWDL support
- Apple Developer Documentation: Core Graphics (CGEventCreateKeyboardEvent, CGEventPost) — training data, HIGH confidence (stable API since macOS 10.4)
- Apple Developer Documentation: ServiceManagement (SMAppService) — training data, HIGH confidence for macOS 13+
- usbmuxd protocol behavior — MEDIUM confidence (widely documented in open-source projects like libimobiledevice, pymobiledevice3; behavior is stable and well-understood)
- AWDL entitlement requirements for self-signed apps — LOW confidence (underdocumented; verify by testing)
- peertalk deprecation status — MEDIUM confidence (last commit 2015 per GitHub; no evidence of active maintenance)
- Multipeer Connectivity AWDL exclusivity limitations — MEDIUM confidence (documented in developer forums and WWDC sessions)

---

*Stack research for: keyd — iOS-to-macOS keyboard controller (USB/AWDL + AX/CGEvent)*
*Researched: 2026-02-27*
