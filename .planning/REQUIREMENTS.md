# Requirements: keyd

**Defined:** 2026-02-27
**Core Value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.

## v1 Requirements

### Transport

- [x] **TRANS-01**: iOS app connects to macOS agent over USB via usbmuxd TCP tunnel
- [x] **TRANS-02**: iOS app connects to macOS agent over AWDL via Bonjour service discovery (`_keyd._tcp`)
- [x] **TRANS-03**: Connection automatically falls back from USB to AWDL when USB cable is unplugged
- [x] **TRANS-04**: AWDL transport is pre-warmed while USB is active (no delay on unplug fallback)
- [ ] **TRANS-05**: Transport protocol is bidirectional (iOS→Mac and Mac→iOS message types defined in Phase 1, even if Mac→iOS unused until Phase 2)
- [ ] **TRANS-06**: Wire protocol uses length-prefixed binary framing (4-byte big-endian length + payload)
- [x] **TRANS-07**: USB connection retries with backoff on failure (device takes 2–5s to become available after plug-in)

Phase 1 transport is implemented, but 01-05 device validation is still open for AWDL fallback timing and reconnect reliability on hardware.

### Keyboard

- [x] **KEY-01**: User can type characters into the currently focused macOS text field from the iOS keyboard
- [x] **KEY-02**: User can send Backspace, Return, Escape, and Tab from iOS (Tab may come from the hotkey panel when the stock keyboard does not expose it)
- [x] **KEY-03**: iOS keyboard displays as standard full-width keyboard layout at bottom of screen
- [x] **KEY-04**: iOS app is a foreground UIViewController-based app (NOT a UIInputViewController keyboard extension)
- [x] **KEY-05**: iOS screen does not auto-lock while keyboard is connected

### Shortcuts

- [x] **SHORT-01**: User can send Command-C (copy) from iOS hotkey panel
- [x] **SHORT-02**: User can send Command-X (cut) from iOS hotkey panel
- [x] **SHORT-03**: User can send Command-V (paste) from iOS hotkey panel
- [x] **SHORT-04**: User can send Command-Z (undo) from iOS hotkey panel
- [x] **SHORT-05**: User can send Command-Shift-Z (redo) from iOS hotkey panel
- [x] **SHORT-06**: User can send Command-A (select all) from iOS hotkey panel
- [x] **SHORT-07**: User can send Command-Q (quit) from iOS hotkey panel
- [x] **SHORT-08**: User can send Option-Delete (delete word left) from iOS hotkey panel
- [x] **SHORT-09**: User can send Command-Delete (line-delete / line-clear behavior, app-dependent) from iOS hotkey panel
- [x] **SHORT-10**: User can send Command-Shift-4 (screenshot) from iOS hotkey panel
- [x] **SHORT-11**: Modifier key-up events are always sent, even if connection drops mid-sequence (prevents stuck Cmd key)

### Editing (Phase 2)

- [ ] **EDIT-01**: User can move cursor left/right/up/down from iOS controls; cursor moves in frontmost macOS field
- [ ] **EDIT-02**: User can select text in the macOS field using iOS selection controls
- [ ] **EDIT-03**: User can delete selected text in the macOS field from iOS
- [ ] **EDIT-04**: User can move cursor to an arbitrary position in the macOS field and type or delete there
- [ ] **EDIT-05**: iOS predictive text (QuickType) suggestions are context-aware based on current macOS field content
- [ ] **EDIT-06**: iOS app shows a real-time text preview mirroring the content and selection state of the focused macOS field
- [ ] **EDIT-07**: iOS cut/copy/paste editing menu operations are reflected in the macOS focused field

### App Awareness (Phase 3)

- [ ] **APP-01**: macOS agent detects the frontmost application and sends its bundle ID to the iOS app
- [ ] **APP-02**: iOS hotkey panel displays app-specific shortcuts when Safari is frontmost
- [ ] **APP-03**: iOS hotkey panel displays app-specific shortcuts when Firefox is frontmost
- [ ] **APP-04**: iOS hotkey panel displays app-specific shortcuts when Messages is frontmost
- [ ] **APP-05**: iOS hotkey panel falls back to default shortcut set for unrecognized apps
- [ ] **APP-06**: iOS hotkey panel animates transition (fade/slide) when switching between app shortcut sets

### macOS Agent

- [x] **AGENT-01**: macOS helper registers as a Login Item (SMAppService) and starts at login
- [x] **AGENT-02**: macOS helper displays connection status (USB / AWDL / disconnected) in the menu bar
- [x] **AGENT-03**: macOS helper checks for Accessibility permission at every launch and surfaces a menu-driven recovery path if missing
- [x] **AGENT-04**: macOS helper checks for Input Monitoring permission at every launch and surfaces a menu-driven recovery path if missing
- [x] **AGENT-05**: macOS helper is built WITHOUT App Sandbox (required for CGEventPost and AX operations)
- [x] **AGENT-06**: macOS helper detects secure input mode (password fields) and sends "keyboard paused" indicator to iOS

### UX / Design

- [x] **UX-01**: iOS app uses Liquid Glass (Glassmorphism) visual style throughout, using SwiftUI `.ultraThinMaterial` as foundation
- [x] **UX-02**: iOS app displays connection status indicator (USB / AWDL / disconnected) with color coding, always visible
- [x] **UX-03**: iOS keyboard layout: standard keyboard on bottom, macOS hotkey row above it (Phase 1)
- [ ] **UX-04**: iOS keyboard layout in Phase 2: adds predictive text bar above keyboard and text preview box above that

## v2 Requirements

### Extended Transport

- **TRANS-EXT-01**: Connection indicator shows latency/signal quality
- **TRANS-EXT-02**: Manual reconnect button when disconnected

### Extended Shortcuts

- **SHORT-EXT-01**: User can define custom shortcut buttons beyond the built-in set
- **SHORT-EXT-02**: Option-Command-Escape (Force Quit) shortcut

### Extended App Awareness

- **APP-EXT-01**: User can customize the shortcut set for each app
- **APP-EXT-02**: App awareness expanded to additional apps beyond Safari, Firefox, Messages

## Out of Scope

| Feature | Reason |
|---------|--------|
| Bluetooth transport | Explicitly excluded by design constraint |
| Infrastructure Wi-Fi transport | Explicitly excluded by design constraint |
| App Store distribution | Personal use only; self-signed |
| Terminal / coding workflow support | Explicitly excluded (non-goal) |
| Mouse / trackpad control | Not in scope; keyboard only |
| Multi-Mac support | Personal use; single Mac target |
| Cloud sync / server-side components | Local-only by design |
| UIInputViewController keyboard extension | Must be regular app — extensions cannot initiate network connections |
| AX text value writes in production | Silently fails in Safari/Firefox; CGEvent is the only reliable write path |
| Multipeer Connectivity framework | Cannot enforce AWDL-only; opaque fallback to Bluetooth |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| TRANS-01 | Phase 1 | Complete |
| TRANS-02 | Phase 1 | In Progress |
| TRANS-03 | Phase 1 | In Progress |
| TRANS-04 | Phase 1 | In Progress |
| TRANS-05 | Phase 1 | Pending |
| TRANS-06 | Phase 1 | Pending |
| TRANS-07 | Phase 1 | Complete |
| KEY-01 | Phase 1 | Complete |
| KEY-02 | Phase 1 | Complete |
| KEY-03 | Phase 1 | Complete |
| KEY-04 | Phase 1 | Complete |
| KEY-05 | Phase 1 | Complete |
| SHORT-01 | Phase 1 | Complete |
| SHORT-02 | Phase 1 | Complete |
| SHORT-03 | Phase 1 | Complete |
| SHORT-04 | Phase 1 | Complete |
| SHORT-05 | Phase 1 | Complete |
| SHORT-06 | Phase 1 | Complete |
| SHORT-07 | Phase 1 | Complete |
| SHORT-08 | Phase 1 | Complete |
| SHORT-09 | Phase 1 | Complete |
| SHORT-10 | Phase 1 | Complete |
| SHORT-11 | Phase 1 | Complete |
| AGENT-01 | Phase 1 | Complete |
| AGENT-02 | Phase 1 | Complete |
| AGENT-03 | Phase 1 | Complete |
| AGENT-04 | Phase 1 | Complete |
| AGENT-05 | Phase 1 | Complete |
| AGENT-06 | Phase 1 | Complete |
| UX-01 | Phase 1 | Complete |
| UX-02 | Phase 1 | Complete |
| UX-03 | Phase 1 | Complete |
| EDIT-01 | Phase 2 | Pending |
| EDIT-02 | Phase 2 | Pending |
| EDIT-03 | Phase 2 | Pending |
| EDIT-04 | Phase 2 | Pending |
| EDIT-05 | Phase 2 | Pending |
| EDIT-06 | Phase 2 | Pending |
| EDIT-07 | Phase 2 | Pending |
| UX-04 | Phase 2 | Pending |
| APP-01 | Phase 3 | Pending |
| APP-02 | Phase 3 | Pending |
| APP-03 | Phase 3 | Pending |
| APP-04 | Phase 3 | Pending |
| APP-05 | Phase 3 | Pending |
| APP-06 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 44 total
- Mapped to phases: 44
- Unmapped: 0 ✓

---
*Requirements defined: 2026-02-27*
*Last updated: 2026-02-28 after Phase 1 doc reconciliation*
