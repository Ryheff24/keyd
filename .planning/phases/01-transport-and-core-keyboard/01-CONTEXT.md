# Phase 1: Transport and Core Keyboard - Context

**Gathered:** 2026-02-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish and freeze the USB/AWDL transport layer, implement the bidirectional binary protocol, and deliver a working iOS keyboard that types into the frontmost macOS text field. Includes: one-time QR code pairing/encryption, connection status UI, hotkey panel, macOS menu bar agent with permission handling, and Liquid Glass chrome. All transport and protocol decisions made here are immutable — later phases add features above this layer without touching it.

</domain>

<decisions>
## Implementation Decisions

### iOS Keyboard & Hotkey Layout

- Keyboard: Custom SwiftUI layout that closely mimics native iOS keyboard appearance (full control over layout, dark/light mode key highlight behavior, hotkey row integration)
- Hotkey panel: Grid layout, 2 columns × N rows, horizontally scrollable. Phase 1 fills 1–2 screens; grid scales for Phase 3 app-aware shortcuts without redesign
- Hotkey button labels: Icons where the action is universally recognized (copy, paste, cut, undo); text labels for less-common shortcuts (screenshot, select all, quit)
- Liquid Glass / glassmorphism: Applied to hotkey panel chrome and overall app chrome only — NOT to individual keyboard key caps, which use standard iOS key appearance

### Connection Status UI

- Primary status surface: Dynamic Island (Live Activity) — compact shows color dot only (green=USB, yellow=AWDL, red=disconnected); expanded view shows latency and reconnect button. Fallback to top bar indicator on devices without Dynamic Island.
- USB → AWDL handoff: Silent. Status flips directly from USB-green to AWDL-yellow only when AWDL connection is confirmed. No intermediate "Switching..." state.
- Debug screen: Shake-to-reveal popup (available in all builds). Shows: scrollable connection event log, current transport state (USB/AWDL/disconnected), retry count, last error message.

### Security — One-Time Pairing

- First launch requires QR code pairing: macOS agent displays a QR code; iOS app uses camera to scan it. Encrypted key exchange happens after scan. After first-time pairing, subsequent connections authenticate automatically using stored keys.
- This pairing must happen before any keyboard input is accepted. The keyboard screen stays in "Waiting to pair" state until pairing completes.

### Keyboard Interaction Model

- Key feedback: Haptic feedback + visual highlight matching native iOS keyboard behavior (key lightens on press in dark mode, darkens in light mode)
- Backspace auto-repeat: First phase deletes single characters (standard key-repeat rate); after holding ~0.5s, switches to deleting entire words. Matches native iOS backspace behavior exactly.
- Hotkey buttons: Single tap sends the full shortcut as one atomic CGEvent sequence (no sticky modifier key needed in Phase 1)
- Modifier safety: Cmd key-up events must always be sent, including in error paths and on disconnect (Swift `defer` blocks). Prevents stuck-Cmd bug if connection drops mid-shortcut.
- Password field detection: When macOS reports a secure input field is focused, iOS keyboard shows a gray overlay with "Password field active" label. Key input is blocked until field changes.

### First Launch & Setup Flow

- **iOS first launch:** No onboarding screen. App opens directly to the keyboard view in "Waiting to pair" state. QR code pairing screen appears automatically before keyboard becomes active.
- **macOS first launch:** System alert dialog at launch listing both missing permissions (Accessibility + Input Monitoring) with direct "Open System Settings" button. Agent does not accept connections until both are granted. Same alert re-checks on every launch (both permissions are revoked on Xcode rebuild — this is expected).
- **Connection wait state:** Full keyboard layout is visible but dimmed/non-interactive while connecting. Status indicator shows "Connecting…". Keyboard becomes interactive immediately when connection is established.

### Orientation & Device Support

- Orientation: Portrait only. Landscape not supported in Phase 1 — keyboard height constraints make landscape impractical.
- Device: iPhone and iPad both supported from Phase 1.

### iOS Interruptions & Background

- Phone call interruption: Transport stays alive during the call. On return to app, keyboard is immediately active — no reconnect needed.
- App backgrounding: Transport attempts to stay alive using iOS background task APIs. This requires careful use of iOS background process management (BGProcessingTask or VoIP background mode). Researcher should investigate the correct background API for a persistent TCP connection. App reconnects immediately when foregrounded if background connection was suspended.
- iOS idle timer: Disabled (`UIApplication.shared.isIdleTimerDisabled = true`) while actively connected.

### macOS Agent

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

</decisions>

<specifics>
## Specific Ideas

- Dynamic Island as status surface: user explicitly requested it, aware that "it can take 2 live apps at once so there should be plenty of room." Expanded Dynamic Island should show latency + reconnect button.
- QR code pairing is the security model: "nobody can connect" — security is a first-class requirement even for a personal-use app.
- Backspace behavior described as "native behavior" — delete chars then words, matches what users are already trained to expect from iOS keyboard.
- Hotkey grid is designed to scale: "will come in handy for Phase 3" — the 2-col grid layout is a deliberate forward-compatible decision.
- Background transport: user noted "this requires checking in with iOS's background process management rules" — aware of complexity, expects researcher to surface the right API.

</specifics>

<deferred>
## Deferred Ideas

- None — all discussion stayed within Phase 1 scope.

</deferred>

---

*Phase: 01-transport-and-core-keyboard*
*Context gathered: 2026-02-27*
