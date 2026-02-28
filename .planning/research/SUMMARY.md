# Project Research Summary

**Project:** keyd
**Domain:** iOS-to-macOS remote keyboard controller (USB/AWDL transport + AX/CGEvent injection)
**Researched:** 2026-02-27
**Confidence:** MEDIUM

## Executive Summary

keyd is a personal-use iOS app that turns an iPhone into a wireless keyboard for macOS, communicating over USB (via usbmuxd) with automatic AWDL fallback when the cable is unplugged. The project has a clearly constrained scope — no Bluetooth, no infrastructure Wi-Fi, no App Store distribution, no multi-Mac support — which actually simplifies implementation. The right approach is a standard iOS foreground app (not a keyboard extension) paired with a macOS menu-bar helper agent, connected over a length-prefixed binary protocol. Both sides are pure Swift 6 using Network.framework for transport, CGEventPost for keystroke injection, and AXUIElement for reading text state in Phase 2.

The critical architectural insight from research is that the transport layer must be built and frozen in Phase 1, with all later phases adding features above it without touching it. This means designing the binary protocol as bidirectional from day one — even though only iOS→Mac messages are used in Phase 1 — because retrofitting bidirectional support in Phase 2 would require a protocol rearchitect. The build order within Phase 1 is strict: protocol message types first, then USB transport, then CGEvent injection, then the iOS keyboard UI, then AWDL fallback. Each step requires the previous one to be working before adding the next.

The top risks are all Phase 1 risks: usbmuxd connection reliability (retry-with-backoff required from the first line of transport code), macOS Accessibility and Input Monitoring permissions both being required and both being revoked on every Xcode rebuild, AWDL entitlement requirements that may need a paid Apple Developer account, and the binary choice between an in-app keyboard view versus a keyboard extension (extension is wrong and must not be chosen). These are not edge cases — they are guaranteed issues that will surface during initial development. The mitigation in every case is to address them in Phase 1 rather than discover them during Phase 2 or 3.

## Key Findings

### Recommended Stack

Both the iOS app and macOS helper agent are pure Swift 6 (Xcode 16), with no Objective-C or third-party networking libraries. Network.framework (NWConnection / NWListener / NWBrowser) handles both the USB-forwarded TCP connection and the AWDL peer connection via Bonjour service discovery. CGEventCreateKeyboardEvent + CGEventPost handles all keystroke injection on macOS; AXUIElement handles reading text state (focused element, selected range, value) in Phase 2 but is NOT used for writing text in production — CGEvent is the reliable write path for all apps including browsers. SMAppService.mainApp handles Login Item registration on macOS 13+.

The stack explicitly excludes peertalk (unmaintained since 2015, Obj-C, adds no value over raw BSD sockets), Multipeer Connectivity (cannot enforce AWDL-only, opaque session model), InputMethodKit (system-wide input method is overkill for three target apps), and JSON framing (too slow for real-time keyboard). The macOS agent must be built WITHOUT App Sandbox — sandbox blocks CGEventPost and AX operations, and for personal-use this is the correct choice.

**Core technologies:**
- Swift 6 + SwiftUI (iOS): keyboard layout, hotkey panel, Liquid Glass UI — SwiftUI `.ultraThinMaterial` is the correct Liquid Glass foundation
- UIKit text-field host (iOS): stock iOS keyboard is kept active through a hidden text field embedded in the app; this is not a system keyboard extension
- Network.framework (both): USB TCP connection to usbmuxd-forwarded port + AWDL NWListener/NWBrowser via Bonjour `_keyd._tcp`
- CGEventCreateKeyboardEvent + CGEventPost (macOS): all keystroke and modifier injection — the only reliable path across Safari, Firefox, Messages
- AXUIElement (macOS): read-only in Phase 2 — focused element, selected text range, value attribute for bidirectional state sync
- SMAppService.mainApp (macOS): Login Item registration, replaces deprecated SMLoginItemSetEnabled
- Binary framing (both): 4-byte big-endian length prefix + payload — replaces JSON; required for sub-50ms latency

See `./.planning/research/STACK.md` for full version matrix and deployment configuration.

### Expected Features

All features flow from a single dependency chain: Transport must exist before any keyboard feature works. Character input must exist before predictive text. Bidirectional text sync must exist before cursor movement, text selection, and the iOS preview box. App-awareness (NSWorkspace observer) is independent of the text sync path and can be done in Phase 3.

**Must have (table stakes):**
- USB transport with usbmuxd TCP tunnel — the entire premise fails without this
- AWDL fallback on USB unplug — without this the app is unusable in daily workflow
- Character input to frontmost macOS field via CGEvent — core value demonstration
- Backspace, Return, Tab, Escape — required to make the keyboard functional for real fields
- Cmd-C/X/V, Cmd-Z/Shift-Z, Cmd-A, Cmd-Q, Option-Delete, Cmd-Delete, Cmd-Shift-4 — all explicitly required shortcuts
- Connection state indicator (USB / AWDL / disconnected) with color coding — user needs confidence commands are arriving
- Liquid Glass glassmorphism UI — stated design constraint, not optional

**Should have (differentiators — Phase 2):**
- iOS cursor movement mirrored to macOS — requires AXInjector for cursor position
- iOS text selection mirrored to macOS — requires bidirectional AX sync
- iOS predictive text (QuickType) fed into macOS via shadow UITextView — requires character input path to be established
- Real-time macOS text reflection into iOS preview box — requires AXObserver infrastructure
- iOS editing menu (cut/copy/paste) operating on macOS text

**Defer (Phase 3+):**
- App-aware hotkey panel (NSWorkspace frontmost app → app-scoped shortcut grid)
- Tap-to-arbitrary-position cursor placement
- Extended per-app hotkey sets for Safari, Firefox, Messages

**Anti-features (never build):**
- Bluetooth transport, infrastructure Wi-Fi transport, mouse/trackpad control, App Store distribution, terminal/coding workflow support, cloud sync, multi-Mac support

See `./.planning/research/FEATURES.md` for full dependency graph, MVP definition, and competitor comparison.

### Architecture Approach

The architecture is a strict three-layer model on each side (UI → Protocol → Transport on iOS; Transport → Protocol → Injection on macOS) with one absolute invariant: no component crosses more than one layer boundary. UI has no import of Network or MultipeerConnectivity. Transport is byte-blind — it sends and receives Data, never typed messages. The InjectionRouter is the only caller of both CGEventInjector and AXInjector. This invariant is enforced by file structure: each layer lives in its own directory, and the "transport must not change after Phase 1" requirement becomes verifiable at the file level.

The build order within the architecture is bottom-up and strict: Protocol (message types + framing) → USB Transport → CGEventInjector → iOS Keyboard UI → AWDL Transport → Hotkey Panel → AXInjector → TextPreviewView → Predictive Text → AppAwarenessService. This order exists because each component requires the previous one to be working before it can be meaningfully tested.

**Major components:**
1. TransportManager (iOS + macOS) — holds active transport reference (USB or AWDL); handles switchover; exposes single `send/receive` API to the Protocol layer; Protocol layer never knows which transport is active
2. MessageEncoder/Decoder (iOS + macOS) — length-prefixed binary framing; message types must be identical on both sides; designed bidirectional from Phase 1 even if only one direction is used initially
3. InjectionRouter + CGEventInjector + AXInjector (macOS) — routes decoded messages to correct injector; CGEvent for all raw keystrokes and modifier combos; AX for reading text state (Phase 2); AX for writing is explicitly NOT used in production (breaks on browsers)
4. SystemKeyboardHost + HotkeyPanel + TextPreviewBox (iOS) — stock keyboard hosted through a hidden text field; HotkeyPanel is Phase 1; TextPreviewBox is Phase 2
5. AppAwarenessService (macOS, Phase 3) — NSWorkspace.frontmostApplication observer; pushes bundle ID back to iOS over the same transport channel

See `./.planning/research/ARCHITECTURE.md` for full component diagram, data flow diagrams, and anti-patterns.

### Critical Pitfalls

1. **iOS keyboard extension vs. in-app keyboard** — Build the keyboard as a UIView embedded in a standard UIViewController. A UIInputViewController keyboard extension cannot initiate network connections, has a restricted sandbox, and is lifecycle-uncontrollable. This architecture choice must be correct from the first Xcode target setup. Recovery cost if wrong: HIGH.

2. **Accessibility AND Input Monitoring permissions both required, both revoked on rebuild** — In this project, both permissions are treated as required and both are tied to the binary hash, so they can be silently revoked on every Xcode rebuild. The macOS helper must check both permissions at every launch using `AXIsProcessTrustedWithOptions` and `IOHIDRequestAccess`, surface a clear menu-driven recovery path when either is missing, and document the toggle-off/toggle-on recovery procedure as a required step after every rebuild.

3. **AX text injection silently fails in Safari, Firefox, Messages** — `AXUIElementSetAttributeValue(kAXValueAttribute)` works in TextEdit and Notes but fails silently in browser web views and many real apps. The correct architecture is "AX read, CGEvent write" — use AX only to read focused element, selected text range, and value; use CGEvent for all actual text and keystroke injection. This architecture decision must be made in Phase 1, not discovered when testing browsers in Phase 2.

4. **Bidirectional protocol not designed in Phase 1** — The transport must support Mac→iOS messages from Phase 1 even if they are unused until Phase 2. Retrofitting bidirectional support in Phase 2 requires rearchitecting the wire protocol and causes breaking changes. Reserve message type slots for `ReflectState`, `AppStateChanged`, and any future Mac→iOS events in the Phase 1 protocol definition.

5. **AWDL entitlements require paid Apple Developer account** — Free-tier provisioning profiles do not include `com.apple.developer.networking.wifi-info` and related networking entitlements needed for AWDL direct connections. A $99/year paid developer account is required. A self-signed app with missing entitlements will either crash at launch (`SIGKILL / LAUNCH_CONSTRAINTS_VIOLATION`) or silently fall back to infrastructure Wi-Fi (which defeats AWDL). Test AWDL explicitly with Wi-Fi infrastructure disabled and Bluetooth off to confirm true AWDL, not silent fallback.

Additional high-priority pitfalls: usbmuxd connection requires retry-with-backoff (device takes 2–5 seconds to become ready after plug-in); CGEvent modifier key sequences must send key-up in a `defer` block (stuck Cmd key if connection drops mid-sequence); secure input mode detection required for password fields (`IsSecureEventInputEnabled()`); iOS idle timer must be disabled (`UIApplication.shared.isIdleTimerDisabled = true`) while keyboard is active.

See `./.planning/research/PITFALLS.md` for the full pitfall list with verification checklists and recovery strategies.

## Implications for Roadmap

Based on research, the architecture's build-order constraint, and the feature dependency chain, a three-phase structure is strongly indicated. All Phase 1 pitfalls must be addressed in Phase 1 — they cannot be deferred without causing rework.

### Phase 1: Transport Foundation and Core Keyboard

**Rationale:** The transport layer is a hard dependency for every feature in the product. All critical pitfalls are Phase 1 pitfalls. The project is not functional until USB transport is proven working on a physical device. Building the keyboard UI before the transport is verified means building UI that cannot be tested.

**Delivers:** A working USB-connected keyboard that can type characters, modifier shortcuts, and standard keys (Return/Tab/Escape/Backspace) into the frontmost macOS application. AWDL fallback activates seamlessly on USB unplug. Connection state indicator (USB/AWDL/disconnected) is always visible. Liquid Glass UI is applied. The macOS agent starts at login and lives in the menu bar.

**Implements:**
- Protocol layer: Message type definitions (bidirectional — both iOS→Mac and Mac→iOS types defined even if Mac→iOS unused in Phase 1)
- Binary framing: 4-byte length-prefixed frames, MessageEncoder + MessageDecoder on both sides
- USBTransport (iOS): NWConnection to usbmuxd-forwarded loopback port; retry-with-backoff
- USBListener (macOS): NWListener on localhost port; accepts iOS connection via usbmuxd
- CGEventInjector (macOS): all keystroke + modifier injection; modifier key-up in defer blocks
- AWDLTransport (iOS): NWBrowser for `_keyd._tcp` Bonjour service
- AWDLListener (macOS): NWListener advertising `_keyd._tcp`
- TransportManager (both sides): state machine for USB→AWDL switchover; pre-warms AWDL while USB is connected
- InjectionRouter (macOS): routes messages to CGEventInjector (AXInjector stub for Phase 2)
- iOS SystemKeyboardHost: stock keyboard kept active through a hidden text field inside the app (NOT UIInputViewController)
- iOS HotkeyPanel: static shortcut buttons (Cmd-C/V/Z/Shift-Z, Return, Escape, Tab, delete actions, etc.); Liquid Glass styling
- macOS agent: SMAppService login item registration; NSStatusItem menu bar indicator; AX + Input Monitoring permission check at every launch with menu-driven recovery actions
- iOS idle timer disabled while connected
- Secure input mode detection; "keyboard paused" indicator in iOS when active

**Addresses from FEATURES.md:** All P1 table-stakes features
**Avoids from PITFALLS.md:** Pitfalls 1 (usbmuxd retry), 2 (peertalk/protocol), 3 (AX write decision), 4 (AX permission check), 5 (CGEvent event target), 6 (Input Monitoring), 7 (AWDL entitlements), 8 (keyboard extension vs in-app), 9 (bidirectional protocol design), 11 (USB hot-plug race), 14 (entitlement crash), 15 (modifier key stuck), 16 (idle timer), 17 (Gatekeeper), 18 (keyboard height)

**Research flag:** Phase 1 needs validation of AWDL entitlement requirements for the specific provisioning profile type before writing any networking code. AWDL behavior under self-signed personal-use builds is underdocumented and must be tested on physical device, not Simulator.

### Phase 2: Bidirectional Text Sync and Advanced Editing

**Rationale:** Phase 2 builds on the stable transport established in Phase 1 without modifying it. All Phase 2 features require AXObserver infrastructure and the Mac→iOS message channel (reserved in Phase 1 protocol). Cursor movement and text selection are the highest-user-value features after Phase 1 basics.

**Delivers:** iOS editing gestures (cursor movement, text selection, delete-selected) operate on the macOS text field. QuickType predictive text suggestions are context-aware (based on the current macOS field content). The iOS app shows a real-time mirror of the macOS field's content and selection state. iOS cut/copy/paste menu operations translate to macOS.

**Implements:**
- AXInjector (macOS): reads `kAXSelectedTextRangeAttribute` and `kAXValueAttribute` from focused element; writes cursor position and selection via AX (not value writes — selection range writes via AX are safe)
- AXObserver (macOS): `kAXValueChangedNotification` + `kAXSelectedTextChangedNotification` on focused element; handles web content process PID discovery for Safari/Firefox (walk to focused element, get its process PID, register observer on that PID)
- ReflectState messages (Mac→iOS): push text content + cursor offset + selected range back to iOS
- TextPreviewBox (iOS): UITextView showing macOS field content; read-only display
- Shadow UITextView (iOS): hidden, zero-frame UITextView for QuickType activation; intercept `shouldChangeTextIn:replacementText:` before local text view updates; translate all deltas to macOS events immediately
- iOS predictive text (QuickType): flows through shadow UITextView; shadow is populated from ReflectState messages to keep suggestions context-relevant
- iOS editing menu → macOS: UITextView selection → read AX value of selection → put in iOS pasteboard; paste → Cmd-V CGEvent

**Addresses from FEATURES.md:** All P2 differentiator features
**Avoids from PITFALLS.md:** Pitfalls 12 (AXObserver wrong PID), 13 (iOS predictive text desync), 19 (AX tree walking performance)

**Research flag:** Phase 2 needs research on AXObserver behavior for Safari and Firefox web content processes specifically — the PID-finding approach is well-understood in principle but has browser-version-specific behavior that should be verified. Also verify UITextInput/UITextInputDelegate patterns for the shadow UITextView approach against current UIKit documentation.

### Phase 3: App-Awareness and Extended Hotkey Panel

**Rationale:** Phase 3 builds on the stable transport and bidirectional channel from Phases 1–2. App-awareness is architecturally independent (NSWorkspace observation does not interact with text sync) and was deferred because the baseline keyboard must be validated as useful before adding app-specific complexity.

**Delivers:** The iOS hotkey panel automatically updates with app-specific shortcuts when the macOS frontmost application changes. Safari gets browser shortcuts (new tab, close tab, address bar, back/forward, prev/next tab). Firefox gets the same set. Messages gets messaging shortcuts. All apps get the default set (copy, cut, paste, undo, redo, select all, quit). Animated transition (fade/slide) between shortcut sets with Liquid Glass styling.

**Implements:**
- AppAwarenessService (macOS): `NSWorkspace.shared.publisher(for: \.frontmostApplication)` observer; sends `AppStateChanged(bundleID, appName)` message over existing transport
- HotkeyPanel (iOS): updated from static shortcuts to dynamic app-aware shortcuts; bundle ID → `[Shortcut]` static dictionary lookup; horizontal scroll for overflow; animation on transition
- Static shortcut map: `com.apple.Safari`, `org.mozilla.firefox`, `com.apple.MobileSMS`, default fallback
- Tap-to-arbitrary-position cursor placement (extension of Phase 2 selection sync)
- Extended per-app hotkey sets as needed

**Addresses from FEATURES.md:** All P3 features
**Avoids from PITFALLS.md:** Performance trap of polling frontmost app (use NSWorkspace notification, not polling)

**Research flag:** Phase 3 follows well-documented NSWorkspace patterns. No phase-specific research needed unless new app target support requires deep-dive into specific app's AX hierarchy.

### Phase Ordering Rationale

- Transport before UI: The keyboard UI cannot be meaningfully tested without a working macOS receiver. Building receiver first (USB listener + CGEvent injector) with a hardcoded test sender, then building the real iOS UI, avoids building UI against a mock.
- USB before AWDL: USB is deterministic (cable in = connected). AWDL adds non-deterministic peer discovery. Validate the full pipeline on USB before adding fallback complexity.
- CGEvent before AX: CGEvent requires no special setup beyond a code-signed binary. AX requires granting Accessibility permission and is harder to debug. Prove keystroke injection works before adding the more complex AX read path.
- Bidirectional protocol in Phase 1: The wire protocol is the hardest thing to change after deployment. Design it right once, with all message types reserved, before any feature relies on it.
- AX before TextPreview: iOS mirror requires macOS to read and send back text state. AX is the only API that reads current text value of a focused field. AXObserver must exist before the preview box can receive content.
- App-awareness last: Independent of text sync, no dependencies on Phases 1–2 beyond transport being alive. Deferring it allows Phase 1 and 2 to ship faster and validates the hotkey concept before investing in the app-aware version.

### Research Flags

Phases needing deeper research during planning:
- **Phase 1:** AWDL entitlement requirements for self-signed builds — LOW confidence from research; must be tested on physical device with actual provisioning profile before writing transport code. Also verify usbmuxd TCP port forwarding behavior on current iOS 18 / macOS 15 (libimobiledevice community docs are the best reference, but Apple does not publish a changelog for usbmuxd protocol changes).
- **Phase 2:** AXObserver PID behavior for Safari and Firefox web content processes — MEDIUM confidence; browser-version-specific. Verify UITextInput + QuickType shadow UITextView pattern against current UIKit documentation before implementing predictive text.

Phases with standard patterns (skip research-phase):
- **Phase 1 (non-AWDL):** CGEvent injection, AXIsProcessTrusted, SMAppService, NWConnection — all HIGH confidence, stable APIs, well-documented patterns.
- **Phase 3:** NSWorkspace frontmostApplication observation — HIGH confidence, stable AppKit API with no known version concerns.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Core API confidence is HIGH (CGEvent, AXUIElement, Network.framework, SMAppService all stable and well-documented). AWDL-specific entitlement requirements for self-signed builds are LOW — underdocumented and must be tested. No web search available; all from training data to August 2025. |
| Features | MEDIUM | Feature set is clear from PROJECT.md requirements. UITextInput/QuickType shadow UITextView approach is a common pattern but not verified against current UIKit docs. Apple Continuity Keyboard comparison is MEDIUM confidence. |
| Architecture | MEDIUM | Layer boundaries, build order, and component responsibilities are HIGH confidence based on stable Apple API patterns. AWDL and AXObserver cross-process behavior are MEDIUM — tested patterns but with browser-version-specific caveats. |
| Pitfalls | HIGH for macOS permissions and CGEvent behavior | AX/CGEvent permission model and behavior since macOS 10.15 is thoroughly documented. usbmuxd reliability and AWDL entitlement pitfalls are MEDIUM — well-attested in community but depend on specific iOS/macOS version combination. |

**Overall confidence:** MEDIUM

Research is sufficient to begin implementation. The critical unknowns (AWDL entitlements, usbmuxd iOS 18 behavior) are best resolved by a 30-minute test on a physical device in Phase 1, not by additional research.

### Gaps to Address

- **AWDL entitlement requirements under personal-use self-signed provisioning:** Research confidence is LOW. Resolution: test NWBrowser + NWListener over Bonjour on a physical device with infrastructure Wi-Fi and Bluetooth both off. If connection fails, verify paid Apple Developer account is required. Do this before writing any AWDL-dependent code.
- **usbmuxd iOS 18 protocol compatibility:** Research recommends against peertalk and in favor of raw NWConnection to the forwarded TCP port. The raw TCP approach avoids the plist-level usbmuxd protocol entirely (usbmuxd handles the forwarding transparently). Verify this by testing iOS-initiated connect to macOS-bound TCP port on iOS 18 + macOS 15 before building the full transport layer.
- **AXObserver cross-process PID for Safari web content on current Safari version:** The PID-finding approach (walk to focused element, get its PID, register AXObserver on that PID) is well-established but Safari's web content process architecture changes with major versions. Verify in Phase 2 before implementing real-time reflection.
- **CGEvent kCGAnnotatedSessionEventTap vs kCGHIDEventTap:** Research recommends kCGAnnotatedSessionEventTap for more reliable delivery to the front app. Verify this does not require additional entitlements on current macOS 15 for a non-sandboxed self-signed helper.

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation: AXUIElement, kAXValueAttribute, kAXFocusedUIElement, AXObserver — stable macOS accessibility APIs; training data consistent with documented behavior
- Apple Developer Documentation: CGEventCreateKeyboardEvent, CGEventPost, secure input mode — stable since macOS 10.4; training knowledge
- Apple Developer Documentation: Network.framework NWConnection, NWListener, NWBrowser — training data to August 2025
- Apple Developer Documentation: ServiceManagement SMAppService — stable macOS 13+ API; training knowledge
- Apple Developer Documentation: NSWorkspace.frontmostApplication — stable AppKit API; training knowledge
- Carbon.h virtual key codes — stable since macOS 10.x; training knowledge
- macOS Catalina (10.15) Privacy & Security permission model changes (Accessibility vs Input Monitoring split) — well-documented in Apple developer forums; training knowledge HIGH confidence

### Secondary (MEDIUM confidence)
- usbmuxd TCP forwarding protocol behavior — documented in libimobiledevice project; widely tested in community; behavior stable on macOS but not Apple-official documentation
- AWDL via Network.framework NWListener/NWBrowser with Bonjour — multiple community implementations; entitlement requirements for non-App-Store apps are the uncertain part
- peertalk (rsms/peertalk) deprecation status — GitHub commit history; last meaningful commit ~2014; training knowledge
- UITextInput + UITextInputDelegate for QuickType shadow UITextView — common UIKit pattern; not verified against current UIKit docs due to no web search available
- AXObserver cross-process PID behavior for sandboxed browser processes — confirmed pattern in Apple AX programming guide; browser-version-specific behavior is the uncertain part
- Apple Continuity Keyboard (iOS 18 / macOS Sequoia) as competitive context — training data; MEDIUM confidence

### Tertiary (LOW confidence)
- AWDL entitlement requirements for self-signed personal-use apps (free-tier vs paid-tier provisioning) — community discussions through training cutoff; real behavior must be tested on device
- `com.apple.developer.networking.wifi-info` requirement for NWBrowser/NWListener Bonjour AWDL — underdocumented; may not be required for Bonjour-based peer discovery as opposed to raw multicast

**Note:** WebSearch and WebFetch were unavailable during all four research sessions. All findings are from training data (cutoff August 2025). Gaps identified above should be resolved by targeted testing on physical devices in the first days of Phase 1 implementation, not by additional research sessions.

---
*Research completed: 2026-02-27*
*Ready for roadmap: yes*
