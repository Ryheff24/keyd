# Pitfalls Research

**Domain:** iOS→macOS remote keyboard / remote input control app
**Researched:** 2026-02-27
**Confidence:** MEDIUM (WebSearch and WebFetch unavailable; findings drawn from training knowledge of Apple platform internals, peertalk/usbmuxd ecosystem, AX/CGEvent APIs, and community-sourced post-mortems through August 2025 cutoff. Critical claims flagged with confidence level.)

---

## Critical Pitfalls

### Pitfall 1: usbmuxd Port Binding Collision With iTunes/Xcode

**What goes wrong:**
The macOS daemon `usbmuxd` multiplexes all USB communication to/from iOS devices. If iTunes (or the Apple Mobile Device Service) is running, it may already hold exclusive locks on device communication at certain moments — particularly during backup, sync, or pairing. Your macOS helper process connecting to usbmuxd may get connection resets or `ECONNREFUSED` at seemingly random times, especially on first connect or after device re-plug.

**Why it happens:**
Developers assume usbmuxd is a stable shared bus. It is shared, but Apple's own services (iTunes, Xcode device support downloads, backup daemons) connect to it and can dominate device attention during operations. The socket interface at `/var/run/usbmuxd` is available to any process, but device-level multiplexed connections can be closed by the device itself when it's preoccupied with higher-priority services.

**How to avoid:**
- Implement retry-with-backoff on all usbmuxd socket connections; never assume first connection attempt will succeed.
- Log every connection failure with timestamp and error code; surface these to the user so they know to wait.
- Do not assume a device is "ready" immediately after plug-in — the pairing handshake plus Apple daemon initialization can take 2–5 seconds.
- Test with iTunes/Music app closed, then open — verify behavior differs and handle both states.

**Warning signs:**
- Connection works in isolation but fails intermittently when Music/Finder is open.
- `ECONNREFUSED` or `EPIPE` on first connect attempt.
- Works fine in Xcode simulator but fails on physical device.

**Phase to address:** Phase 1 — Transport foundation. This must be solved before any other functionality is built on top.

**Confidence:** MEDIUM (training knowledge; behavior well-documented in peertalk and libimobiledevice GitHub issues)

---

### Pitfall 2: peertalk / Custom usbmuxd Protocol Breaking on New iOS Versions

**What goes wrong:**
Apple periodically updates the usbmuxd plist-based protocol (the "lockdown" layer). Projects using raw usbmuxd socket access (like peertalk) have broken on iOS major version bumps because:
- The device's lockdownd changed handshake requirements.
- New pairing/trust dialog requirements were added (iOS 16+ pairing changes).
- The iOS side app's network extension entitlements changed behavior.

Projects relying on the original peertalk library (last meaningfully updated ~2014) often silently fail or need protocol patches on iOS 16/17/18.

**Why it happens:**
peertalk was written when iOS 6–7 was current. It speaks a relatively stable but undocumented usbmuxd protocol. Apple treats this as a private API surface and doesn't publish a changelog when it changes. Developers assume the library "just works" without verifying against current iOS.

**How to avoid:**
- Do not use the original rsms/peertalk library unchanged. Use a fork that's been verified on iOS 16+/17+/18, or implement the usbmuxd socket protocol directly using libimobiledevice's documented protocol as reference.
- Build a protocol version negotiation or at minimum log the full plist exchange on startup so failures are diagnosable.
- Test against the specific iOS version you'll run on. Test on iOS 18 before shipping Phase 1.
- The iOS side must also use `NSNetService` / `Network.framework` peertalk-style socket servers correctly — test that the TCP listener on the iOS app side starts before the macOS side connects.

**Warning signs:**
- "Device not found" from usbmuxd even though device is trusted and USB-connected.
- Lockdown errors referencing `com.apple.mobile.lockdown` in logs.
- Works on iOS 15 test device but fails on iOS 17/18 production device.

**Phase to address:** Phase 1. Must be verified against the target iOS version during initial transport implementation, not discovered later.

**Confidence:** MEDIUM (training knowledge, corroborated by multiple open-source issues in peertalk forks)

---

### Pitfall 3: AX (Accessibility) Text Injection Silently Failing Per-App

**What goes wrong:**
`AXUIElementSetAttributeValue` for `kAXValueAttribute` (direct text set) and `AXUIElementPerformAction` for `kAXPressAction` work in some apps and fail silently in others. Browser apps (Safari, Firefox) use custom web view rendering that does not always expose standard AX text fields. The macOS web views expose a hierarchy where the focused text element may be several levels deep and may not support `kAXValueAttribute` writes.

Specifically:
- Safari's web content process is sandboxed; AX crosses the process boundary but the focused web element may be `AXWebArea` → `AXGroup` → `AXTextField` structure, and only the leaf node accepts value writes.
- Firefox has its own Gecko accessibility layer that partially mirrors MSAA/AX but does not always expose writable `kAXValue` on text fields inside web content.
- Messages uses a custom text input that works with AX for reading but not always for direct value injection.

**Why it happens:**
Developers test AX text injection on TextEdit or Notes (native AppKit text fields), which work perfectly. They don't test on browsers until Phase 2 or 3, when they discover the web view hierarchy is much more complex and partially inaccessible.

**How to avoid:**
- Test AX text injection against all three target apps (Safari, Firefox, Messages) in Phase 1, not just native text fields.
- Prefer CGEvent-based keystroke injection for typing over AX value writes — CGEvent works at the input layer, not the app-internal data model layer, so it bypasses app-specific AX implementation gaps.
- Use AX only for reading context (focused element, selected text, cursor position), not for writing.
- Implement an "AX read + CGEvent write" split: AX tells you what's focused, CGEvent sends the actual keystrokes.

**Warning signs:**
- Text injection works in TextEdit/Notes but not in Safari/Firefox.
- `kAXErrorCannotComplete` or `kAXErrorNotImplemented` returned from `AXUIElementSetAttributeValue`.
- AX element found but value attribute is read-only (`kAXErrorAttributeUnsupported`).

**Phase to address:** Phase 1 for architecture decision (AX read / CGEvent write split). Phase 2 for per-app AX reading of cursor position and selected text.

**Confidence:** HIGH (training knowledge, well-documented in Apple dev forums and AX API documentation)

---

### Pitfall 4: Accessibility Permission Not Persisting / Requiring Manual Toggle After Updates

**What goes wrong:**
macOS requires the helper process (or app bundle) to be granted Accessibility permission in System Settings → Privacy & Security → Accessibility. This permission is tied to the **binary hash** of the executable. Any time the binary changes — including any Xcode rebuild, code signing update, or self-signed certificate renewal — macOS silently revokes the permission. The helper process continues to run but all AX calls return `kAXErrorAPIDisabled` with no useful error message in the console.

**Why it happens:**
Developers grant AX permission once and assume it persists. On a personally-used, self-signed app that is rebuilt frequently (every day or week), the binary hash changes with every code signing operation, so the permission is effectively revoked on every rebuild.

**How to avoid:**
- Design the macOS helper so it checks `AXIsProcessTrustedWithOptions` at startup and displays a clear, persistent UI prompt when trust is missing (not just a console log).
- Automate the "re-grant" workflow: open the accessibility pane, highlight your app, toggle off and on. Document this as a required step after every Xcode rebuild.
- Consider wrapping the helper in a stable outer shell script or Launch Agent that detects the trust revocation and auto-prompts.
- During development, use a "check-then-prompt" pattern on every launch; never silently proceed when untrusted.

**Warning signs:**
- AX calls that worked yesterday now return `kAXErrorAPIDisabled`.
- No AX behavior change observed after rebuild.
- `AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: true})` returns `false` after rebuild.

**Phase to address:** Phase 1. This is a basic infrastructure requirement that must be in the macOS app from day one.

**Confidence:** HIGH (well-documented Apple behavior; confirmed in multiple developer forum threads)

---

### Pitfall 5: CGEvent Keystroke Injection Ignored by Focused App Due to Wrong Event Target

**What goes wrong:**
`CGEventCreateKeyboardEvent` + `CGEventPost(kCGHIDEventTap, event)` posts to the HID event stream. If the app receiving the event is:
- Running in a different security context (secure input mode — e.g., password fields)
- Using a custom event loop that filters synthetic events
- A sandboxed process that ignores events from non-trusted sources

...then the events are generated but silently dropped. Password fields in particular enable "secure input mode" (`CGSSetSecureInputMode`), which causes the system to block synthetic keyboard events. No error is returned — the event appears to be sent successfully but the app never receives it.

**Why it happens:**
`CGEventPost` returns void; there's no feedback mechanism. Developers assume success because no error is thrown. They don't discover the secure-input-mode blocking until someone tests on a login screen or password field.

**How to avoid:**
- Detect secure input mode using `IsSecureEventInputEnabled()` (IOKit) before injecting keystrokes; if active, display "secure input mode — keyboard paused" in the iOS app UI.
- Use `kCGAnnotatedSessionEventTap` instead of `kCGHIDEventTap` if targeting a specific process; this creates a session-level tap that is more reliably received by the front app.
- For text input, prefer `CGEventKeyboardSetUnicodeString` on a key-down event to inject text as Unicode rather than simulating individual keycodes — this bypasses keyboard layout mapping issues.
- Test on: Safari URL bar, Safari password field, Terminal, TextEdit, Messages.

**Warning signs:**
- CGEvent posts succeed (no error) but no text appears.
- Behavior changes based on whether the active field is a password field.
- Works when your process has input monitoring permission but not when it doesn't.

**Phase to address:** Phase 1 for basic keystroke injection. Phase 2 when cursor movement and selection control are added.

**Confidence:** HIGH (well-documented Apple platform behavior; `IsSecureEventInputEnabled` and secure input mode are widely discussed in developer forums)

---

### Pitfall 6: CGEvent Requires Input Monitoring Permission Separate From Accessibility

**What goes wrong:**
On macOS 10.15+, posting synthetic keyboard events via `CGEventPost` to the HID event tap (`kCGHIDEventTap`) requires the process to have **Input Monitoring** permission in addition to (or instead of, depending on the event tap type) Accessibility permission. This is a separate Privacy & Security pane entry. Apps that only request Accessibility permission find that `CGEventPost` silently fails for global keyboard injection.

**Why it happens:**
Before Catalina (10.15), Accessibility permission covered keyboard event posting. Post-Catalina, Apple split this into two permissions. Documentation was unclear at launch about exactly which permission covers which operation. Many tutorials and Stack Overflow answers predate this split.

**How to avoid:**
- The macOS helper must declare both Accessibility AND Input Monitoring as required permissions and check for both at startup using `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` and `AXIsProcessTrustedWithOptions`.
- Show a setup wizard on first launch that walks through granting both permissions, with deep-link buttons to the correct preference panes.
- Both permissions suffer the binary-hash revocation issue on rebuild (see Pitfall 4) — document both in the rebuild workflow.

**Warning signs:**
- `AXIsProcessTrustedWithOptions` returns `true` but CGEvent posting doesn't work globally.
- Events work when the helper is the frontmost app but not when a different app is focused.
- Keystrokes appear to post but target app doesn't receive them.

**Phase to address:** Phase 1. Both permissions must be requested and verified in the initial macOS helper setup.

**Confidence:** HIGH (documented Apple behavior since macOS 10.15 Catalina)

---

### Pitfall 7: AWDL Requiring Entitlements Not Available on Non-App-Store Apps

**What goes wrong:**
AWDL (Apple Wireless Direct Link) is accessible from iOS apps through `MultipeerConnectivity` and from macOS through `Network.framework` or `MultipeerConnectivity`. However, activating the AWDL network interface and using it for direct peer connections requires the `com.apple.developer.networking.wifi-info` entitlement and potentially `com.apple.developer.networking.multipath`. These entitlements are provisioned by Apple for App Store apps. For self-signed personal-use apps, the entitlements may be present in the provisioning profile with restrictions, or may cause a `SecTaskCopyValueForEntitlement` failure at runtime.

**Why it happens:**
Developers use `MultipeerConnectivity` which abstracts AWDL, Bluetooth, and Wi-Fi infrastructure under one API. They don't realize that when Bluetooth is disabled (as in this project), MCSession falls back to AWDL, which has entitlement requirements. On a self-signed app, the entitlement may be missing from the provisioning profile entirely, causing silent fallback to infrastructure Wi-Fi (which is also blocked by design in this project).

**How to avoid:**
- Explicitly verify AWDL is the active transport in MCSession by observing the peer's `MCSessionState` and logging the underlying connection details.
- If using `Network.framework` directly for AWDL (via `NWParameters` with `.bonjour` service with `.awdl` interface), test that `NWInterface.InterfaceType == .wifi` and `NWInterface.Name == "awdl0"` are active.
- For self-signed personal use: use a paid Apple Developer account (not free tier) — free-tier provisioning profiles do NOT include the networking entitlements needed. The $99/year developer account provides the required entitlements for personal devices.
- Test AWDL behavior explicitly with Wi-Fi infrastructure disconnected and Bluetooth off to confirm you are truly on AWDL and not falling back silently.

**Warning signs:**
- `MultipeerConnectivity` connects only when both devices are on the same Wi-Fi, not when infrastructure Wi-Fi is off.
- MCSession advertiser is discovered but connection never completes without Wi-Fi.
- Network.framework `NWConnection` never reaches `.ready` state when targeting AWDL interface.

**Phase to address:** Phase 1. AWDL is the specified fallback transport and must be validated end-to-end in Phase 1.

**Confidence:** MEDIUM (entitlement requirements documented in Apple developer docs; free-tier vs paid-tier behavior confirmed in multiple community discussions through training cutoff)

---

### Pitfall 8: iOS Custom Keyboard Extension vs. In-App Keyboard — Wrong Architecture Choice

**What goes wrong:**
Building the iOS side as a **Custom Keyboard Extension** (`UIInputViewController` subclass) seems obvious — it literally installs a system keyboard replacement. However, custom keyboard extensions are heavily sandboxed:
- No network access by default (requires `RequestsOpenAccess` entitlement).
- Even with `RequestsOpenAccess`, the extension runs in a restricted sandbox that complicates USB socket connections.
- Extension lifecycle is not controllable — iOS may kill it at any time.
- No persistent background process; the extension only lives while typing.
- Cannot initiate the USB/AWDL connection proactively; it must wait for user to switch to it.

The correct approach for this project is a **regular iOS app with a custom in-app keyboard view** — not a system keyboard extension. The app runs in the foreground, controls its own lifecycle, and owns the network connections.

**Why it happens:**
"iOS keyboard app" sounds like it should be a keyboard extension. The distinction between "app that contains a keyboard UI" and "system keyboard extension" is not immediately obvious to developers who haven't shipped both.

**How to avoid:**
- Build the iOS keyboard as a `UIView` subclass embedded in a standard `UIViewController`, NOT as `UIInputViewController` / keyboard extension.
- The app must run in the foreground to maintain the USB/AWDL connection. Design the UI so the user keeps it frontmost while typing on Mac.
- Use `UIApplication.shared.isIdleTimerDisabled = true` to prevent screen lock while the app is in active keyboard use.

**Warning signs:**
- Initial architecture puts keyboard UI in an Extension target in Xcode.
- Network code doesn't compile in the extension target due to sandbox restrictions.
- Connection drops whenever the iOS device screen dims.

**Phase to address:** Phase 1. Architecture must be established correctly before any networking code is written.

**Confidence:** HIGH (UIKit keyboard extension sandboxing is thoroughly documented in Apple HIG and developer docs)

---

### Pitfall 9: Text State Desync Between iOS and macOS — No Ground Truth

**What goes wrong:**
When the iOS app sends keystrokes to macOS via CGEvent, the macOS text field's actual state (content, cursor position, selection) changes. But the iOS app has no automatic way to know the new state — it must either:
a) Maintain a local model of what it believes the macOS text field contains, OR
b) Poll the macOS text field via AX to read actual state, OR
c) Receive real-time state updates from the macOS helper.

Option (a) fails when the user also types directly on the Mac keyboard, when auto-correct fires, when the app modifies text programmatically (e.g., form auto-fill), or when macOS text field value changes due to app logic.

Option (b) adds AX polling round-trip latency and drains battery. Option (c) requires the macOS helper to watch AX notifications (`kAXValueChangedNotification`, `kAXSelectedTextChangedNotification`) and push updates back over the connection — adding significant complexity.

**Why it happens:**
Developers start with one-way flow (iOS sends, macOS receives) because it's simpler. The "real-time reflection" requirement from Phase 2 is treated as a Phase 2 problem. But without designing the bidirectional state sync protocol in Phase 1's transport layer, adding it in Phase 2 requires rearchitecting the connection protocol.

**How to avoid:**
- Design the transport protocol as bidirectional from Phase 1 even if only one direction is used initially. Reserve message types for macOS→iOS state updates.
- In Phase 2, implement AX notification observation on the macOS side (`AXObserverCreate`, `kAXSelectedTextChangedNotification`) to push cursor/selection state back to iOS.
- Treat the macOS AX-read state as authoritative; iOS maintains a local cache for responsiveness but syncs on every received update.

**Warning signs:**
- iOS shows wrong cursor position after user types directly on Mac keyboard.
- Delete key deletes wrong content because iOS believes different text is in the field.
- Phase 2 implementation requires changing the Phase 1 message protocol.

**Phase to address:** Phase 1 for protocol design. Phase 2 for full implementation.

**Confidence:** MEDIUM (architectural pattern derived from remote-input system design; specific AX notification APIs confirmed from training knowledge)

---

## Moderate Pitfalls

### Pitfall 10: macOS Firewall Blocking AWDL / Bonjour Discovery

**What goes wrong:**
macOS's application-level firewall (`/Library/Preferences/com.apple.alf`) can block incoming Bonjour/mDNS service advertisements and TCP connections. When the macOS firewall is set to "Block all incoming connections" or "Allow signed applications only," the macOS helper process (which is self-signed, not notarized) will be silently blocked from receiving AWDL connections. The macOS side will advertise fine but iOS will not be able to complete the TCP handshake.

**How to avoid:**
- Add the macOS helper to the firewall's allowed-apps list as part of the setup documentation.
- Test specifically with the macOS application firewall enabled (it defaults to off but many users turn it on).
- Display a setup-time check: use `SCDynamicStoreCopyValue` or parse `com.apple.alf` to detect if the firewall is active, and warn the user.

**Confidence:** MEDIUM

**Phase to address:** Phase 1 setup and onboarding.

---

### Pitfall 11: USB Hot-Plug Reconnection Race Condition

**What goes wrong:**
When USB is replugged after being disconnected, the usbmuxd device notification fires before the device is fully enumerated and trusted. Attempting to reconnect immediately on notification receipt results in connection failure. Additionally, the AWDL→USB switchover (which must happen on re-plug) races with the AWDL session teardown, potentially leaving the app in a state where neither transport is active.

**How to avoid:**
- On USB-plug notification (via `IOKit` device notifications or usbmuxd protocol `DeviceAdd` message), add a 1–2 second delay before attempting reconnect.
- Implement a connection state machine: `disconnected` → `usb_connecting` → `usb_connected` / `awdl_fallback`. Never attempt both connections simultaneously.
- For the USB→AWDL fallback on unplug: start AWDL advertiser/browser when USB connects (so it's ready to go) and activate it immediately on USB disconnect.

**Confidence:** MEDIUM

**Phase to address:** Phase 1.

---

### Pitfall 12: AXObserver Notification Missing for Web Views in Sandboxed Browser Processes

**What goes wrong:**
Safari and Firefox run their web content in separate sandboxed helper processes. `AXObserverCreate` must be called with the **web content process PID**, not the main browser PID, to receive text-change notifications from web forms. Finding the correct PID requires walking the process tree and AX hierarchy, which is non-trivial and can change between browser versions.

**How to avoid:**
- Use `AXUIElementCreateSystemWide()` and walk to the focused element to find the correct process, then use that PID for `AXObserverCreate`.
- Subscribe to `kAXFocusedUIElementChangedNotification` on the system-wide AX element to detect when focus moves to a different process, and re-register the observer for the new process PID.
- Test in both Safari and Firefox and verify that AX notifications fire for web form text changes in both.

**Confidence:** MEDIUM

**Phase to address:** Phase 2 (real-time reflection implementation).

---

### Pitfall 13: iOS Predictive Text / Autocorrect Firing on the iOS Side Instead of macOS Side

**What goes wrong:**
The iOS app embeds a keyboard view. If the keyboard view is attached to a local `UITextField` or `UITextView` (a common approach to make iOS predictive text and autocorrect work), those corrections fire locally on iOS. But when the corrected text is sent to macOS as keystroke events, the sequence is: backspace × N + replacement text — which is visually disruptive and may fail if the CGEvent backspace events don't land in the right sequence.

**Why it happens:**
Getting iOS's native predictive text and autocorrect to work requires a real `UITextInput`-conforming responder. Developers hook this up locally, then find their local text state and macOS text state diverge because macOS processed different events.

**How to avoid:**
- Use a hidden, minimal `UITextView` as the keyboard attachment point purely to activate predictive text. Intercept all `shouldChangeTextIn:replacementText:` and `selectionDidChange:` delegate/notification callbacks before they touch the local text view.
- Treat the local text view as a scratch buffer — translate every delta (insertion, deletion, selection change) into a macOS event immediately rather than updating the local buffer first.
- Never display the local text view's content; it is purely a keyboard-activation mechanism.

**Confidence:** MEDIUM

**Phase to address:** Phase 2.

---

### Pitfall 14: Self-Signed App Crashing on iOS Due to Missing Entitlements at Runtime

**What goes wrong:**
A self-signed iOS app built with a personal developer account may have entitlements in the `.entitlements` file that are not present in the provisioning profile. On iOS, this causes a hard crash at launch (`SIGKILL` from the OS, typically `LAUNCH_CONSTRAINTS_VIOLATION` in crash logs) with no useful message displayed to the user. Common culprits: `com.apple.developer.networking.wifi-info`, `com.apple.developer.networking.multipath`, and any push notification entitlements accidentally included.

**Why it happens:**
Xcode sometimes auto-generates entitlements files with capabilities that were added in the UI but not properly provisioned. Personal team provisioning profiles are more restrictive than paid-account profiles.

**How to avoid:**
- Audit the `.entitlements` file before building: every key must be matched by a capability in the provisioning profile.
- For a personal-use self-signed app, keep entitlements minimal: remove everything not explicitly needed.
- Use a paid Apple Developer account (not free personal team) — the free personal team cannot provision networking-related entitlements, including those needed for AWDL direct connections.
- After every entitlement change, do a clean build and test launch on device.

**Warning signs:**
- App launches briefly then immediately exits on device (no crash dialog).
- Xcode shows `SIGKILL` with `LAUNCH_CONSTRAINTS` in the device log.
- Works on Simulator but crashes on physical device.

**Confidence:** HIGH

**Phase to address:** Phase 1.

---

### Pitfall 15: CGEvent Modifier Key State Getting Stuck

**What goes wrong:**
When injecting modifier-key combinations (Cmd-C, Cmd-V, etc.), you must explicitly send:
1. Key-down for the modifier (Cmd)
2. Key-down for the character (C) with modifier flag set
3. Key-up for the character
4. Key-up for the modifier

If the app crashes, freezes, or the connection drops mid-sequence, the modifier key-up event never fires. The macOS system then behaves as if Cmd is physically held down, causing bizarre behavior in the frontmost app until the user manually presses and releases Cmd.

**Why it happens:**
CGEvent injection is not atomic. Event sequences are posted one at a time. Error paths often don't include cleanup code for partially-sent modifier sequences.

**How to avoid:**
- Always post modifier key-up events in a `defer` block (Swift) or `@finally` handler so they fire even on error paths.
- Send modifier key-up events with a synthetic "release all modifiers" sequence on connection drop/reconnect.
- Keep the macOS helper's sent-modifier state, and on unexpected disconnection, send release events for all pending modifiers.

**Confidence:** HIGH

**Phase to address:** Phase 1 (hotkeys are Phase 1 scope).

---

## Minor Pitfalls

### Pitfall 16: iOS App Background Suspension Killing the Connection

**What goes wrong:**
If the user switches away from the iOS keyboard app (to check another app, for example), iOS will suspend the app within ~30 seconds. All TCP connections (USB and AWDL) will be severed. On return, the app must reconnect from scratch, adding 2–5 seconds of latency before keyboard is usable again.

**How to avoid:**
- Implement a clear "suspended" state in the iOS UI (grayed-out keyboard, "reconnecting..." message).
- Use `UIApplication.shared.beginBackgroundTask` to request up to 30 seconds of background time for orderly disconnection (not for persistent operation — that's not available without background modes).
- Explore declaring the `audio` background mode as a keep-alive mechanism (controversial; not recommended for App Store, acceptable for personal use).
- Accept this limitation and document it — it's a user-education issue, not a bug.

**Confidence:** MEDIUM

**Phase to address:** Phase 1 (connection lifecycle management).

---

### Pitfall 17: macOS App Notarization Requirement for Gatekeeper

**What goes wrong:**
A self-signed macOS app that is not notarized will be quarantined by Gatekeeper on first launch. The user must right-click → Open to bypass the quarantine warning. After a macOS update, the quarantine flag may be re-applied to already-launched apps in some scenarios. This is not a stopper for personal use but is a friction point that must be managed.

**How to avoid:**
- Document the right-click → Open procedure as part of app setup.
- Use `xattr -d com.apple.quarantine /path/to/App.app` in a setup script to permanently remove the quarantine flag.
- Run `spctl --master-disable` is an option for personal machines but is too aggressive; prefer the per-app quarantine removal.

**Confidence:** HIGH

**Phase to address:** Phase 1 setup documentation.

---

### Pitfall 18: Keyboard Height Calculation Breaking on iPhone Models With Dynamic Island / Home Indicator

**What goes wrong:**
The iOS keyboard view layout must account for the safe area insets, which change across iPhone models (notch, Dynamic Island, home indicator). Hard-coding keyboard frame sizes or using `UIScreen.main.bounds` (deprecated in iOS 16) for layout calculations produces clipped or incorrectly positioned keyboard UI on newer devices.

**How to avoid:**
- Use `safeAreaInsets` and `keyboardLayoutGuide` (iOS 15+) for all keyboard-related layout.
- Test the UI on iPhone models with: no notch (SE), notch (iPhone 13), and Dynamic Island (iPhone 14 Pro+).
- Avoid `UIScreen.main.bounds` — use `UIWindowScene.keyWindow.bounds` or view-relative frame calculations.

**Confidence:** HIGH

**Phase to address:** Phase 1 UI implementation.

---

### Pitfall 19: AX Walking Performance — Traversing Large Web Document Hierarchies

**What goes wrong:**
When using `AXUIElementCopyAttributeValue` to walk the accessibility tree of a browser tab with a large web document, each AX call is a cross-process IPC call. Walking deep hierarchies (large web pages with thousands of elements) can block for 100ms+ per query, making the AX-read-then-inject latency noticeable.

**How to avoid:**
- Cache the focused AX element reference. Only re-query on focus-change notification.
- Never walk the full AX tree for every keystroke — only walk on focus change.
- Use `kAXFocusedUIElementAttribute` on the app-level AX element to jump directly to the focused element without traversal.

**Confidence:** HIGH

**Phase to address:** Phase 2 (when AX reading is implemented for real-time reflection).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| AX value write instead of CGEvent injection | Simpler code, no key-code mapping | Breaks silently on browsers, password fields, most real apps | Never for this project — use CGEvent for all writes |
| One-way transport (iOS→Mac only) | Simpler Phase 1 protocol | Phase 2 text reflection requires full protocol rearchitect | Never — reserve bidirectional message types from Phase 1 |
| Polling macOS text state instead of AX notifications | Simpler than observer setup | Battery drain, adds latency to every state read | Only as a temporary fallback if AX notifications fail for a specific app |
| Using peertalk unchanged without iOS 16+ testing | Faster Phase 1 start | High risk of silent failure on production device | Never — validate against target iOS version before any other Phase 1 work |
| Requesting only Accessibility permission | Single permission flow | CGEvent global injection fails without Input Monitoring permission too | Never — request both from day one |
| Hardcoding AWDL service name / port | Simpler discovery | Conflicts if multiple instances of app run | Acceptable for personal use with single device pair |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| usbmuxd socket | Assuming connection succeeds on first try immediately after plug | Retry with exponential backoff; device takes 2–5s to become ready |
| AXObserver (Safari) | Registering observer on main Safari PID | Walk to focused element, get its process PID, register observer on that PID |
| CGEvent modifier combos | Sending key-down only or not sending key-up | Always send complete down/up sequences; use defer/finally for key-up |
| MultipeerConnectivity + no Bluetooth | Assuming MCSession uses AWDL automatically | Must explicitly disable Bluetooth transport in MCSession and verify AWDL is active interface |
| iOS keyboard view attachment | Attaching keyboard to a visible UITextField with content | Use a hidden zero-frame UITextView as input responder; never display its content |
| macOS Accessibility trust | Checking permission once at startup | Check every launch; binary hash changes on rebuild revoke permission |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| AX cross-process IPC on every keystroke | Keystroke latency 100-500ms; CPU spike | Cache focused element; only query on focus change | Immediately visible on web pages with complex DOM |
| Large CGEvent queue (no flow control) | Keystrokes arrive out of order or duplicated on macOS | Process one keystroke round-trip before sending next; add sequence numbers | Under fast typing (>8 keys/sec) |
| AWDL vs USB not actually switching | USB unplug causes multi-second outage | Pre-warm AWDL while USB is connected; switch in <100ms | On USB unplug event |
| JSON serialization for every message | Latency increases with message frequency | Use fixed-size binary framing (4-byte length + payload) for high-frequency messages | Under sustained typing load |
| Polling macOS focused app for hotkey panel | CPU usage visible in Activity Monitor | Use `NSWorkspace.didActivateApplicationNotification` instead of polling | Immediately at all loads |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| No authentication on USB/AWDL socket | Any app on the Mac can connect to the iOS listener socket and inject keystrokes if it can communicate over AWDL | Add a shared secret / challenge-response handshake in Phase 1 (even a simple hardcoded token is sufficient for personal use) |
| Logging keystrokes to persistent file for debugging | Keylog file on disk with all typed content | Never log keystroke content; log only metadata (message type, length, timestamp) |
| No bounds checking on incoming protocol messages | Malformed message could crash helper | Validate message length and type before parsing; cap message size at sane limit (e.g., 64KB) |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| No visual feedback for "connected" vs "disconnected" state | User types into void thinking Mac is receiving | Persistent connection status indicator in iOS app header; never assume connected |
| Keyboard dismisses when tapping outside the keyboard area | Loss of keyboard focus while trying to interact with iOS app controls (hotkey buttons) | Use a container that keeps iOS keyboard presented even when tapping non-text UI |
| Sending Cmd-Q accidentally | Quits the frontmost macOS app — impossible to undo | Require confirmation for destructive hotkeys (Cmd-Q, Cmd-W); add a "confirm dangerous shortcuts" setting |
| No indication of frontmost macOS app on iOS | User confused about which macOS app is receiving keystrokes | Display app name/icon of frontmost macOS app in iOS header using AX `kAXFrontmostApplicationAttribute` pushed from macOS helper |
| iOS screen lock while user is using keyboard | Connection drops, must reconnect and re-unlock | Set `UIApplication.shared.isIdleTimerDisabled = true` while connection is active |

---

## "Looks Done But Isn't" Checklist

- [ ] **USB transport:** Works on physical device connected to Mac — verify NOT just on Simulator
- [ ] **AWDL transport:** Works with Wi-Fi infrastructure OFF and Bluetooth OFF — verify it's truly AWDL, not infrastructure fallback
- [ ] **USB→AWDL switchover:** Test by physically unplugging USB mid-session — verify <2 second switchover with no message loss
- [ ] **AX permission:** Re-grant after a fresh Xcode build and verify it still works — do not assume permission persists
- [ ] **Input Monitoring permission:** Verify granted separately from Accessibility permission
- [ ] **CGEvent in Safari:** Test typing into a Google search bar — not just TextEdit
- [ ] **CGEvent in password field:** Verify behavior is correct (should be blocked; iOS UI should show "secure input" notice)
- [ ] **CGEvent modifier key-up:** Simulate connection drop during Cmd hold — verify Cmd is not stuck after reconnect
- [ ] **AWDL entitlements:** Verify app launches without crash on device, not just Simulator — entitlement mismatches only manifest on device
- [ ] **Keyboard height:** Test on iPhone SE (small, no notch) and iPhone 14 Pro+ (Dynamic Island) — verify layout not clipped
- [ ] **Idle timer:** Verify iOS screen does not lock while keyboard app is foreground and connected
- [ ] **Hotkey destructive actions:** Test Cmd-Q from iOS — verify confirmation prompt fires before sending

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| usbmuxd/peertalk protocol break on new iOS version | HIGH | Port usbmuxd protocol to updated iOS handshake; may require reverse engineering. Mitigation: use libimobiledevice as reference. |
| AX permission revoked after rebuild | LOW | System Settings → Privacy → Accessibility → toggle off/on for the helper |
| Input Monitoring permission revoked | LOW | System Settings → Privacy → Input Monitoring → toggle off/on |
| AWDL entitlements missing in provisioning profile | MEDIUM | Regenerate provisioning profile with paid developer account; clean build and resign |
| Text state desync requiring protocol rearchitect | HIGH | Stop and redesign bidirectional protocol before Phase 2 work proceeds |
| Modifier key stuck | LOW | User presses Cmd key manually; add "reset modifier state" button to iOS UI |
| AX value write chosen over CGEvent (wrong architecture) | HIGH | Rewrite all text injection paths to use CGEvent; Phase 1 scope |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| usbmuxd port collision / retry required | Phase 1 | Connect with Music app open; verify stable reconnect |
| peertalk protocol break on iOS 16+/17+/18 | Phase 1 (before writing anything else) | Test on physical device running target iOS version on day 1 |
| AX text injection per-app failures | Phase 1 architecture decision | Test AX write on TextEdit AND Safari; confirm only CGEvent write is used |
| AX permission revocation on rebuild | Phase 1 | Rebuild, re-run; verify permission-check-and-prompt works |
| CGEvent requires Input Monitoring permission | Phase 1 | Check both permissions at startup; test with both denied/granted |
| CGEvent secure input mode blocking | Phase 1 | Test in password field; verify iOS UI shows "secure input" message |
| AWDL entitlements + provisioning | Phase 1 | Test AWDL with Wi-Fi and Bluetooth off; verify connection completes |
| iOS keyboard extension vs in-app keyboard | Phase 1 architecture | App target structure correct in Xcode from first commit |
| Bidirectional protocol not designed in Phase 1 | Phase 1 | Protocol message types defined for both directions even if Mac→iOS unused initially |
| USB hot-plug race condition | Phase 1 | Plug/unplug USB rapidly 10x; verify stable reconnect |
| macOS firewall blocking AWDL | Phase 1 setup | Test with macOS firewall enabled; document exception step |
| Self-signed entitlement crash | Phase 1 | Audit .entitlements; test launch on device |
| CGEvent modifier key stuck | Phase 1 | Force-kill helper mid-Cmd sequence; verify no stuck modifier |
| AXObserver wrong PID for Safari | Phase 2 | Verify kAXValueChangedNotification fires for typing in Safari web forms |
| iOS predictive text desync | Phase 2 | Verify autocorrect replacements land correctly in macOS field |
| iOS screen lock during use | Phase 1 | Let screen idle with keyboard connected; verify no lock and no connection drop |

---

## Sources

- Apple AXUIElement documentation and macOS Accessibility API (training knowledge, confidence HIGH)
- CGEvent API documentation — `CGEventCreateKeyboardEvent`, `CGEventPost`, secure input mode behavior (training knowledge, confidence HIGH)
- macOS Privacy & Security permission model changes in Catalina (10.15) and later — Accessibility vs Input Monitoring split (training knowledge, confidence HIGH)
- peertalk GitHub repository (rsms/peertalk) and known forks — iOS version compatibility history (training knowledge, confidence MEDIUM)
- usbmuxd protocol documentation from libimobiledevice project (training knowledge, confidence MEDIUM)
- MultipeerConnectivity AWDL entitlement requirements — Apple developer documentation (training knowledge, confidence MEDIUM)
- UIInputViewController sandbox restrictions — Apple developer documentation (training knowledge, confidence HIGH)
- `IsSecureEventInputEnabled()` / `CGSSetSecureInputMode` behavior — Apple developer forums (training knowledge, confidence HIGH)
- AXObserver cross-process PID behavior for sandboxed browser processes (training knowledge, confidence MEDIUM)

**Note:** WebSearch and WebFetch tools were unavailable during this research session. All findings are drawn from training knowledge (cutoff August 2025). For high-stakes implementation decisions — especially usbmuxd protocol compatibility with the specific iOS version being targeted and AWDL entitlement requirements under the specific provisioning profile type — verify against current Apple developer documentation before implementation.

---
*Pitfalls research for: iOS→macOS remote keyboard / remote input control (keyd)*
*Researched: 2026-02-27*
