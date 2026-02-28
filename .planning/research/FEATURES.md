# Feature Research

**Domain:** iOS-to-macOS remote keyboard / text-input controller
**Researched:** 2026-02-27
**Confidence:** MEDIUM — Training data plus first-party Apple documentation patterns. No live web search available (WebSearch/WebFetch denied). Critical claims flagged with confidence level.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features this product must have to feel functional. Missing any of these = the app is broken, not a keyboard.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Type characters into macOS focused field | This is the entire premise — without it there is no product | MEDIUM | Requires CGEvent injection (kCGHIDEventTap or AX) or IME; latency must be imperceptible (<50ms) |
| Backspace / delete character | Every keyboard has delete; users immediately test this | LOW | Single keycode event; must delete on macOS side, not iOS |
| Cmd-C / Cmd-X / Cmd-V (copy/cut/paste) | First thing power users reach for | LOW | Each is a modifier+keycode CGEvent pair |
| Cmd-Z / Cmd-Y (undo/redo) | Muscle memory for text editing | LOW | Same CGEvent pattern as copy/cut/paste |
| Cmd-A (select all) | Essential for "clear field" workflow | LOW | Same CGEvent pattern |
| Cmd-Q (quit) | Extremely common; tested immediately by users | LOW | Same CGEvent pattern |
| Return / Enter key | Required to submit forms and messages | LOW | Single keycode event |
| Tab key | Required to move between form fields | LOW | Single keycode event |
| Escape key | Dismiss dialogs, cancel autocomplete | LOW | Single keycode event |
| Space bar | Character input; also used in shortcuts | LOW | Already part of character input path |
| Transport connection indicator | User needs to know if iOS is connected to macOS | LOW | Binary connected/disconnected state; show in persistent UI chrome |
| Automatic USB → AWDL fallback on unplug | Without this, unplugging USB kills the session silently | HIGH | Requires transport monitoring and seamless protocol handoff; no user action |
| Reconnect on cable re-plug | Plugging cable back in should restore USB | MEDIUM | Monitor IOKit device attach events and re-establish muxd connection |

### Differentiators (Competitive Advantage)

Features that go beyond what a basic remote keyboard does. These are where keyd earns its value.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| iOS-native cursor movement mirrored to macOS | iOS trackpad-style press-hold-space cursor navigation is faster than no cursor control at all | MEDIUM | UITextInput cursor position events must be translated to AX setSelectedTextRange or arrow key CGEvents |
| iOS-native text selection mirrored to macOS | Selecting "this word" on iOS and having it selected on macOS is powerful editing | HIGH | Requires reading AX element text content back onto iOS, syncing selection ranges bidirectionally |
| Delete selected text from iOS | Completing the select→delete editing loop | LOW | Once selection is synced, delete is a single Backspace CGEvent |
| Move cursor to arbitrary position then type | "Tap where you want to edit" is the core iOS editing metaphor | HIGH | Requires bidirectional sync: pull macOS text content into iOS UITextView, map tap position to character offset, push cursor move to macOS |
| iOS predictive text fed into macOS field | Native iOS QuickType bar accepting words that appear in macOS — feels magical | HIGH | Must pipe UITextView insertText delegate calls to macOS; IME may be the right layer so macOS apps see committed text, not interim composing text |
| iOS cut/copy/paste menu reflected on macOS | Select-and-cut/copy on iOS operating on macOS text is fluid | MEDIUM | Depends on bidirectional text sync; copy → read AX value of selection, put in iOS pasteboard; paste → CGEvent Cmd-V |
| Real-time macOS text reflection into iOS text preview | User sees the macOS field contents on iOS, confirming edits landed | MEDIUM | AXObserver on kAXValueChangedNotification; push diff to iOS preview box |
| App-aware hotkey panel | Showing Safari shortcuts when Safari is front, Messages shortcuts when Messages is front — reduces hotkey memorization | MEDIUM | NSWorkspace.shared.frontmostApplication observation; static map of app bundle ID → shortcut set |
| Cmd-Backspace (delete word left) | Power users expect this; not obvious it will work | LOW | Modifier+Backspace CGEvent; already listed in requirements |
| Cmd-Delete (delete line) | Line-clearing shortcut used in text fields and terminal-adjacent apps | LOW | Modifier+Delete CGEvent |
| Cmd-Shift-4 (screenshot) | Convenience trigger from iPhone while hands are on keyboard | LOW | Three-key modifier CGEvent |
| "Liquid Glass" glassmorphism UI | Matches Apple's current design language; makes the app feel native and premium | MEDIUM | SwiftUI `.ultraThinMaterial` or custom CALayer blur; requires careful handling of keyboard height constraints |

### Anti-Features (Commonly Requested, Often Problematic)

| Anti-Feature | Why Requested | Why Problematic | Alternative |
|--------------|---------------|-----------------|-------------|
| Bluetooth transport | "Why not Bluetooth? It's simpler" | Deliberately excluded by design constraint; Bluetooth adds pairing friction, breaks on distance, and the whole point is USB/AWDL direct link | USB primary + AWDL fallback already covers all cases |
| Infrastructure Wi-Fi transport | "Can I use it over my home network?" | Breaks local-only constraint; introduces network dependency; latency unpredictable | AWDL handles wireless without infrastructure |
| Mouse/trackpad pointer control | Seems natural extension of keyboard control | Scope creep; fundamentally different input model; CGEvent mouse injection is separate from text input; requires cursor-position awareness on iOS | Out of scope for v1; text-only is the stated goal |
| Terminal / coding workflow support | Power users want to use it in iTerm2/VSCode | Different UX model (keystrokes have side effects, no undo, escape codes matter); AX text sync does not work in terminal emulators | Explicitly out of scope per PROJECT.md |
| App Store distribution | "Let other people use it" | Requires app review, entitlement negotiations for CGEvent injection (requires Accessibility permission), ongoing maintenance burden | Self-signed is intentional; weekly Xcode re-sign is fine for personal use |
| Cloud sync / server components | "Sync my hotkey config to other Macs" | Breaks local-only constraint; adds backend complexity | Local JSON config file per device |
| Voice dictation passthrough | "Have Siri dictate into macOS" | Layering dictation on top of remote keyboard creates ambiguous edit ownership; macOS already has dictation | Use macOS native dictation directly; not a keyboard feature |
| Emoji picker panel on iOS | Nice to have | Low usage relative to implementation cost; iOS keyboard already surfaces emoji natively | Use the iOS globe-key emoji keyboard already present |
| Full clipboard sync (iOS ↔ macOS) | "Paste from Mac to iPhone" | Requires Universal Clipboard (Handoff) infrastructure or custom sync; separate problem from keyboard input | Cmd-V already pastes macOS clipboard into macOS; that is sufficient |
| Multi-Mac support | "Switch between two Macs" | Connection model assumes a single paired macOS host; multi-host adds routing complexity with zero personal-use benefit | One-device-to-one-host is the right scope |

---

## Feature Dependencies

```
[Transport layer: USB/AWDL]
    └──required by──> [Character input to macOS]
                          └──required by──> [Modifier shortcuts (Cmd-C etc.)]
                          └──required by──> [Return / Tab / Escape]

[Character input to macOS]
    └──required by──> [iOS predictive text → macOS]

[Bidirectional text sync (AX pull + IME push)]
    └──required by──> [iOS cursor movement → macOS]
                          └──required by──> [Move cursor to arbitrary position + type]
    └──required by──> [iOS text selection → macOS]
                          └──required by──> [Delete selected text from iOS]
                          └──required by──> [iOS cut/copy/paste menu → macOS]
    └──required by──> [Real-time macOS text preview on iOS]

[NSWorkspace frontmost app observation]
    └──required by──> [App-aware hotkey panel]
                          └──enhances──> [Modifier shortcuts]

[Transport connection indicator]
    └──enhances──> [Automatic USB → AWDL fallback]
    └──enhances──> [Reconnect on cable re-plug]

[iOS predictive text → macOS] ──conflicts──> [Bidirectional text sync]
    Note: QuickType inserts words; if iOS UITextView also mirrors macOS
    content, word suggestions are based on local text not macOS context.
    Resolution: iOS UITextView maintains a local shadow copy of macOS
    text for sync, separate from QuickType's context buffer.
```

### Dependency Notes

- **Character input requires Transport layer:** All CGEvent injection happens on the macOS daemon that receives data from the iOS app over the transport. The transport must be stable before any keyboard feature works.
- **Bidirectional sync requires Character input:** You cannot sync selection state if you cannot also inject the resulting edits.
- **Predictive text is partially independent:** iOS QuickType works on its local UITextView context. If the iOS text view is not populated with the macOS field's current contents, suggestions will be generic. Populating it requires the bidirectional sync path.
- **App-aware hotkeys are independent:** They observe macOS frontmost app state and serve a static shortcut map. They do not depend on text sync — only on the transport being alive.
- **Predictive text conflicts with bidirectional text sync in one specific way:** When macOS text is pulled into the iOS UITextView to enable sync, QuickType suggestions are based on that text. This is actually desirable behavior, but it means the iOS side must not echo those suggestions back as "new edits" — the QuickType insertion path must be clearly separated from the sync update path. (Confidence: MEDIUM — based on UIKit UITextInput/UITextInputDelegate patterns from training data.)

---

## MVP Definition

### Launch With (Phase 1 / v1)

Minimum viable product — validates the transport and basic keyboard concept.

- [ ] USB transport (usbmuxd) with real-time bidirectional communication — proves the core architecture
- [ ] AWDL fallback on USB unplug — makes the app usable in daily workflow
- [ ] Character input: type into frontmost macOS field — core value demonstration
- [ ] Backspace, Return, Tab, Escape — makes the keyboard usable for real fields
- [ ] Cmd-C / Cmd-X / Cmd-V / Cmd-Z / Cmd-Shift-Z / Cmd-A / Cmd-Q — power user hotkeys needed immediately
- [ ] Option-Delete / Cmd-Delete / Cmd-Shift-4 — the listed required shortcuts
- [ ] Connection state indicator on iOS — user needs confidence that commands are arriving
- [ ] Liquid Glass visual styling — stated design constraint, not optional

### Add After Validation (Phase 2)

Features to add once Phase 1 transport is proven stable.

- [ ] iOS cursor movement → macOS — trigger: Phase 1 is reliable and the "I can't position cursor" friction is felt
- [ ] iOS text selection → macOS — trigger: cursor movement is working
- [ ] Delete selected text — trigger: selection sync is working
- [ ] Predictive text (QuickType) → macOS — trigger: character input path is established; shadow text view can be populated
- [ ] Real-time macOS text reflection → iOS preview box — trigger: AXObserver infrastructure exists from text sync work
- [ ] iOS editing menu (cut/copy/paste) → macOS — trigger: bidirectional sync is complete

### Future Consideration (Phase 3)

Features to implement once Phases 1–2 are stable.

- [ ] App-aware hotkey panel — trigger: basic hotkeys are validated as useful; app detection adds value
- [ ] Arbitrary cursor position + type (tap-to-position) — trigger: selection sync is reliable; this is an extension of it
- [ ] Extended hotkey sets (per-app: Safari, Firefox, Messages) — trigger: app detection is working

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| USB transport + character input | HIGH | HIGH | P1 |
| AWDL fallback | HIGH | HIGH | P1 |
| Standard modifier shortcuts (Cmd-C/V/Z etc.) | HIGH | LOW | P1 |
| Return / Tab / Escape | HIGH | LOW | P1 |
| Connection state indicator | HIGH | LOW | P1 |
| Liquid Glass UI | MEDIUM | MEDIUM | P1 (design constraint) |
| iOS cursor movement → macOS | HIGH | MEDIUM | P2 |
| iOS text selection → macOS | HIGH | HIGH | P2 |
| Predictive text → macOS | HIGH | HIGH | P2 |
| Real-time macOS text preview on iOS | MEDIUM | MEDIUM | P2 |
| iOS editing menu → macOS | MEDIUM | MEDIUM | P2 |
| App-aware hotkey panel | MEDIUM | MEDIUM | P3 |
| Tap-to-position cursor | MEDIUM | HIGH | P3 |
| Extended per-app hotkey sets | LOW | LOW | P3 |

**Priority key:**
- P1: Must have for Phase 1 launch
- P2: Should have, add in Phase 2
- P3: Nice to have, Phase 3+

---

## Competitor Feature Analysis

No direct competitors exist for USB/AWDL iOS→macOS text input specifically. The closest analogues are Bluetooth-based remote keyboard apps. Analysis is based on App Store category patterns and Apple's own Continuity Keyboard (available in macOS Sequoia 15+ / iOS 18+).

| Feature | Typeeto / similar BT keyboards | Apple Continuity Keyboard (iOS 18+) | keyd approach |
|---------|-------------------------------|-------------------------------------|---------------|
| Transport | Bluetooth | Automatic proximity (Wi-Fi/BT/Handoff) | USB primary, AWDL fallback (no BT, no infrastructure Wi-Fi) |
| Character input | Full keyboard passthrough | Full iOS keyboard to Mac | Full keyboard via CGEvent / IME |
| Cursor movement | Varies; most do not | Native iOS editing gestures work | iOS UITextInput → AX cursor events |
| Text selection | Varies; most do not | Native iOS selection works | UITextInput selection → AX selection |
| Hotkey shortcuts | Basic (Cmd-C/V/Z typical) | Partial | Explicit required shortcut set + app-aware panel |
| Predictive text | Via iOS keyboard | Full QuickType support | QuickType via UITextView shadow copy |
| App-aware hotkeys | Not present in known apps | Not present | Differentiator — NSWorkspace frontmost app → shortcut map |
| Real-time text reflection (iOS preview) | Not present in known apps | Not applicable (native integration) | Differentiator — AXObserver pull to iOS preview box |
| Connection robustness | Bluetooth pairing (varies) | Seamless (built-in OS feature) | Explicit USB→AWDL failover with UI indicator |

**Confidence note:** The Apple Continuity Keyboard feature (introduced iOS 18 / macOS Sequoia) is the closest Apple-native analogue. It is worth understanding as a reference — keyd deliberately differs by using USB/AWDL instead of system Handoff infrastructure, and by providing an explicit app-aware hotkey layer. (Confidence: MEDIUM — Apple Continuity Keyboard feature knowledge from training data, not verified against current official docs due to WebFetch/WebSearch being unavailable.)

---

## Answering the Specific Research Questions

### 1. Text editing behaviors that must be supported

**Cursor movement:**
- Character-by-character left/right: arrow key CGEvents (`kVK_LeftArrow`, `kVK_RightArrow`)
- Word-by-word left/right: Option+arrow CGEvents
- Line start/end: Cmd+Left / Cmd+Right CGEvents
- Document start/end: Cmd+Up / Cmd+Down CGEvents
- iOS UI mechanism: UITextInput `beginningOfDocument`, `endOfDocument`, `positionFromPosition:offset:`, translated to the above CGEvent sequences

**Selection:**
- Extend selection: any of the above cursor movements with Shift modifier added
- Select word: double-tap → UITextInput `tokenizer:rangeEnclosingPosition:withGranularity:inDirection:`, translated to Shift+Option+Arrow pair on macOS
- Select all: Cmd-A CGEvent
- iOS gesture-driven selection uses UITextInput delegate callbacks; the range must be translated to macOS AX `setSelectedTextRange:` or equivalent Shift+cursor CGEvents

**Delete:**
- Delete character left: Backspace (`kVK_Delete`) CGEvent
- Delete character right: Forward Delete (`kVK_ForwardDelete`) CGEvent
- Delete word left: Option+Backspace CGEvent
- Delete word right: Option+ForwardDelete CGEvent
- Delete to line start: Cmd+Backspace CGEvent
- Delete to line end: Cmd+Delete CGEvent (macOS behavior; varies by app)
- Delete selected: once selection is active, Backspace deletes it

**Confidence: HIGH** — These are standard macOS text editing shortcuts documented at https://support.apple.com/en-us/102650 and match the CGEvent keycodes in `Carbon/Carbon.h`. The iOS UITextInput protocol behavior is well-established in UIKit.

### 2. Most critical macOS shortcut keys

Priority order based on daily-use frequency:

1. Cmd-C, Cmd-X, Cmd-V — copy/cut/paste (highest daily usage)
2. Cmd-Z, Cmd-Shift-Z — undo/redo
3. Cmd-A — select all
4. Option-Delete — delete word left (text fields)
5. Cmd-Q — quit app
6. Return / Enter — submit
7. Escape — dismiss
8. Tab — next field
9. Cmd-Delete — delete to line end
10. Cmd-Shift-4 — screenshot (explicitly required)

**Second tier (app-aware panel candidates):**
- Cmd-T (new tab, Safari/Firefox)
- Cmd-W (close tab)
- Cmd-L (focus address bar, browsers)
- Cmd-R (reload, browsers)
- Cmd-Shift-[ / ] (previous/next tab, browsers)
- Cmd-N (new window/message)
- Option-Command-Esc (force quit — important safety shortcut)

**Confidence: HIGH** — Based on Apple's official keyboard shortcut documentation which is stable.

### 3. How predictive text should work in this context

The correct model is a **shadow UITextView** on iOS:

1. iOS maintains a local UITextView that is not visible but accumulates the text that has been sent to macOS.
2. This shadow text view is the source for QuickType suggestions — iOS sees it as the "current document" and generates contextually relevant word completions.
3. When the user taps a QuickType suggestion, `textView:shouldChangeTextInRange:replacementText:` fires with the suggestion text. This is forwarded to macOS via the transport as a character insertion event, replacing the partial word if any.
4. The shadow text view must also be updated from AX pull when macOS text changes externally (e.g., app autocorrect fires on macOS), to keep suggestions coherent.
5. Predictive text is native iOS behavior — there is no need to implement it from scratch. The key task is ensuring the shadow UITextView has current context and that UITextView delegate calls are correctly piped to macOS.

**Risk:** If the shadow UITextView gets out of sync with the macOS field, QuickType suggestions become irrelevant. The Phase 2 bidirectional text sync (AXObserver pull) is what keeps the shadow in sync. Predictive text quality depends on sync quality.

**Confidence: MEDIUM** — UITextInput + QuickType integration patterns from training data; the shadow UITextView approach is a common iOS IME implementation pattern but not verified against current UIKit docs.

### 4. What "app-aware" hotkey switching looks like

**Detection mechanism:**
```swift
// macOS daemon side
NSWorkspace.shared.publisher(for: \.frontmostApplication)
    .sink { app in
        let bundleID = app?.bundleIdentifier ?? ""
        sendToiOS(event: .frontmostAppChanged(bundleID: bundleID))
    }
```

**iOS side behavior:**
- Receives `frontmostAppChanged` event over transport
- Looks up bundle ID in a static `[String: [Shortcut]]` dictionary
- Updates the hotkey panel row above the keyboard with app-specific shortcuts
- Transitions animate (fade or slide) using the Liquid Glass aesthetic

**Hotkey panel design:**
- Persistent row above the iOS keyboard (always visible, not a modal)
- Scrollable horizontally if shortcuts exceed screen width
- Each button shows: icon (optional), key combo label (e.g., "⌘T"), and a short label ("New Tab")
- Tapping a button sends the corresponding CGEvent sequence to macOS

**Static app map for v1 (target apps):**
- `com.apple.Safari` → New Tab, Close Tab, Reload, Address Bar, Back, Forward, Prev Tab, Next Tab
- `org.mozilla.firefox` → same set (Firefox uses same shortcuts)
- `com.apple.MobileSMS` → New Message, Back (Cmd-[)
- Default fallback → copy, cut, paste, undo, redo, select all, quit

**Confidence: MEDIUM** — NSWorkspace.frontmostApplication is well-established macOS API; the UI pattern is design inference based on PROJECT.md description plus common iOS keyboard extension patterns.

### 5. Transport UX that matters

**Connection indicator (required):**
- Single persistent indicator in the iOS app chrome — top bar or floating badge
- Three states minimum: `connected (USB)`, `connected (AWDL)`, `disconnected`
- Color coding: green = USB, amber = AWDL, red = disconnected
- Shows transport type so user understands why latency might differ
- Must update within 500ms of state change

**Reconnect behavior:**
- On USB unplug: silently switch to AWDL if in range; indicator transitions amber; no user action required
- On AWDL loss (both gone): indicator goes red; show brief non-blocking banner "Connection lost — reconnecting..."
- On USB re-plug: automatically prefer USB; indicator goes green; no user action required
- No manual "Connect" button in v1 — reconnect is fully automatic

**Latency feedback:**
- Optional: show connection quality indicator (ping/latency) — LOW priority, not table stakes
- If latency exceeds ~100ms, typing feel degrades; AWDL is typically 5–15ms so this should not be a problem in practice

**What NOT to do:**
- Do not show a modal on disconnect — it interrupts typing context
- Do not require the user to select a transport mode — automatic is the correct UX
- Do not show IP addresses or technical details — transport is invisible infrastructure

**Confidence: MEDIUM** — Transport UX patterns from general networking app design; specific latency numbers for AWDL from training data knowledge of Apple Wireless Direct Link characteristics, not measured.

---

## Sources

- PROJECT.md and idea.md (primary requirements, first-party)
- Apple keyboard shortcuts reference: https://support.apple.com/en-us/102650 (referenced in idea.md; content inferred from training data — HIGH confidence the URL is correct)
- Apple iOS text editing guide: https://support.apple.com/guide/iphone/select-and-edit-text-iph1a9cae52c/ios (referenced in idea.md)
- UIKit UITextInput protocol: https://developer.apple.com/documentation/uikit/uitextinput (training data; MEDIUM confidence current)
- NSWorkspace frontmostApplication: https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication (training data; HIGH confidence stable API)
- CGEvent keyboard injection: Carbon.h virtual key codes (training data; HIGH confidence stable — unchanged since macOS 10.x)
- Apple Accessibility (AX) framework / AXObserver: https://developer.apple.com/documentation/applicationservices/axobserver (training data; HIGH confidence stable)
- Apple Continuity Keyboard (iOS 18 / macOS Sequoia): mentioned as competitive context, not a primary source (training data; MEDIUM confidence)
- **NOTE:** WebSearch and WebFetch were unavailable during this research session. All external sources are from training data. Findings have been conservatively confidence-rated. Phase-specific research should verify UITextInput/IME integration patterns and current AX API capabilities before implementation.

---

*Feature research for: iOS-to-macOS remote keyboard / text-input controller (keyd)*
*Researched: 2026-02-27*
