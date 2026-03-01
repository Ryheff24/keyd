# Phase 1 Plan 05: Device Validation Checklist (In Progress)

The fixes below made the app connect and become usable, but 01-05 is still open. This file is the live validation checklist for the remaining device bugs and follow-up tuning work.

## Current Checklist

### USB Transport

- [✅] iPhone keyboard is visible and status badge shows "USB" (green)
- [✅] Type "hello" on iPhone keyboard -> "hello" appears in TextEdit in real time
- [✅] Press Backspace on iPhone -> last character deleted in TextEdit
- [✅] Hold Backspace for 0.5s -> entire word deleted in TextEdit (word-delete)
- [✅] Press Return on iPhone -> new line in TextEdit
- [✅] Tap the Tab hotkey on iPhone -> focus moves to next field (test in browser form)
- [✅] Press Escape on iPhone -> escape event received

### Shortcuts

- [✅] Tap "Select All" (Cmd-A) -> all text selected in TextEdit
- [✅] Tap "Copy" (Cmd-C) -> text in clipboard (paste into another app to verify)
- [✅] Tap "Cut" (Cmd-X) -> text removed from TextEdit and in clipboard
- [✅] Tap "Paste" (Cmd-V) -> cut text pasted back
- [✅] Tap "Undo" (Cmd-Z) -> undo paste in TextEdit
- [✅] Tap "Redo" (Cmd-Shift-Z) -> redo in TextEdit
- [✅] Tap "Screenshot" (Cmd-Shift-4) -> crosshair cursor appears on Mac
- [✅] Tap "Quit" -> confirmation dialog appears on iPhone, then Cmd-Q executes when confirmed
- [✅] Tap "Delete Word" (Option-Delete) -> word to left of cursor deleted
- [✅] Tap "Delete Line" (Cmd-Delete) -> line deleted

### AWDL Fallback

- [✅] Disconnect Wi-Fi infrastructure on Mac (System Settings -> Wi-Fi -> off OR join a non-existent network)
- [✅] Turn off Bluetooth on Mac
- [✅] Physically unplug USB cable -> status badge changes from green to yellow within 3 seconds
- [✅] Type "awdl test" on iPhone -> appears in TextEdit over AWDL
- [✅] Replug USB cable -> status badge returns to green within 5 seconds
- [✅] Type one more word -> typing continues normally over USB

### Safety

- [✅] Start a Cmd-based shortcut, unplug USB while the modifier sequence is still in flight -> Command is released on macOS (no stuck modifier after disconnect)
- [✅] Tap the top status badge on iPhone -> debug sheet appears with event log
- [✅] Leave iPhone idle for 2 minutes while connected -> screen stays on (idle timer disabled)

### macOS Agent

- [✅] Rebuild KeydAgent in Xcode -> permissions are revoked (expected)
- [✅] Re-run KeydAgent -> alert "Missing permissions" appears -> click "Open System Settings"
- [✅] Re-grant both permissions -> restart KeydAgent -> keyboard works again

### Security

- [✅] Uninstall KeydApp -> reinstall -> QR scan required again (Keychain cleared on uninstall)
- [-] Second iPhone (different device) cannot connect without pairing QR scan

### Password Field

- [✅] Open a password field on Mac (e.g., Keychain Access or login form in browser)
- [✅] iPhone keyboard shows "Password Field Active" gray overlay
- [✅] Typing on iPhone is blocked (no characters sent)
- [✅] Focus a normal text field on Mac -> keyboard overlay disappears and typing resumes

## Notes From Current Device Testing

- [?] Start a Cmd-based shortcut, unplug USB while the modifier sequence is still in flight -> Command is released on macOS (no stuck modifier after disconnect)
  what does this mean and look like
- [-] Second iPhone (different device) cannot connect without pairing QR scan
  Do not have a second device to verify this yet.

## Codex Addendum (2026-02-28)

The checklist above was written before the fixes below. Any affected items should be re-tested on device. These updates got the app connecting and usable, but they did not close 01-05.

### Implemented Changes

- Pairing reset on iPhone now sends a remote pairing invalidation before clearing local state.
- macOS now handles `pairingInvalidated` by clearing its stored pairing and resetting the active session.
- Successful pairing now closes the macOS "Pair iPhone" window for both USB and AWDL pairing paths.
- Removed shake-to-debug. Tapping the top status badge now opens the debug sheet.
- Moved "Reset Pairing" into the debug sheet and added "Reconnect" there too.
- Live Activity no longer ends when the iOS app goes to the background/inactive state. It now only ends on app termination.
- Fixed shortcut mappings:
  Redo is now Cmd-Shift-Z instead of Cmd-Y.
  Delete Word is now Option-Delete instead of Cmd-Delete.
  Delete Line is now Cmd-Delete instead of Cmd-ForwardDelete.
  Screenshot remains Cmd-Shift-4 (crosshair capture) after the follow-up hotkey fix.
- Tab and Redo buttons are now icon-only, and Undo/Redo are positioned in the same row.
- iOS no longer sends an extra key-up event for modifier-based shortcuts.
- macOS virtual-key shortcut injection now uses the HID event tap (`cghidEventTap`) so system shortcuts like screenshots can fire more reliably.

### Build Verification Completed After These Changes

- `xcodebuild -project KeydApp/KeydApp.xcodeproj -scheme KeydApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` -> BUILD SUCCEEDED
- `xcodebuild -project macOS/KeydAgent.xcodeproj -scheme KeydAgent CODE_SIGNING_ALLOWED=NO build` -> BUILD SUCCEEDED

### Still Needs Physical-Device Verification

- Whether USB is actually becoming ready when the cable is plugged in, versus AWDL only appearing as standby/active.
- Whether the updated local reset flow always clears the Mac-side connected state in real use.
- Whether Screenshot, Delete Line, and the updated Redo mapping behave correctly across your target apps.

## Codex 01-05 Fix Commits (2026-02-28)

Follow-up fix commits applied during device validation and debugging:

- `79b2991` `fix(01-05): complete the pairing handshake`
  Finalized the macOS pairing response path so iPhone pairing waits for a real Mac acceptance instead of storing pairing state early.
- `28838db` `fix(01-05): stabilize awdl pairing attempts`
  Reduced AWDL pairing races, allowed QR scan before the link is fully ready, and improved pairing-transport state handling.
- `b0056a2` `fix(01-05): restore stock keyboard and reset pairing`
  Removed the custom keyboard implementation, restored the system keyboard host, and added reset-pairing controls on both platforms.
- `7ead18f` `fix(01-05): restore hidden pre-pair awdl`
  Re-enabled pre-pair AWDL as an internal transport path without exposing it as a fully connected session before handshake completion.
- `89adbb9` `fix(01-05): replace stale pre-pair awdl channels`
  Replaced stale hidden AWDL pairing sockets instead of treating all later sockets as duplicates during pairing.
- `ddbf3e3` `fix(01-05): avoid blocking on pairing send`
  Switched the iPhone pairing request send to a non-blocking path so pairing fails with a real timeout/error instead of hanging indefinitely.
- `0f6d548` `fix(01-05): require ready usb before pairing`
  Prevented localhost USB probe sockets from being treated as connected before they were actually ready, so pairing chooses the correct transport.
- `b3a6dc2` `fix(01-05): only activate ready awdl sockets`
  Promoted AWDL sockets only after they reached `.ready`, improving post-pair AWDL reconnect behavior after cable disconnects.
- `41f944e` `fix(01-05): invalidate stale pairings on reset`
  Added remote pairing invalidation so resetting pairing on one side can revoke the old trust instead of allowing silent reuse.

## bugs
- some times the keyboard takes a while to return
- leaving the app causes a long reconnect period
- Lag spike followed buy a large spam of characters
