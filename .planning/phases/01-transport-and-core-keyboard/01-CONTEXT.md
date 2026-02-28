# Phase 1: Transport and Core Keyboard - Context

**Gathered:** 2026-02-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish and stabilize the USB/AWDL transport layer, implement the bidirectional binary protocol, and deliver a working in-app iOS keyboard host that types into the frontmost macOS text field. Includes: one-time QR code pairing/encryption, connection status UI, hotkey panel, macOS menu bar agent with permission handling, and Liquid Glass chrome. The intent is still to freeze transport and protocol here, but 01-05 device validation remains open while fallback and reconnect bugs are being closed.

</domain>

<decisions>
## Implementation Decisions

### iOS Keyboard & Hotkey Layout

- Keyboard: Use the stock iOS keyboard by keeping a hidden UIKit text field first responder inside the app. The app forwards text and special-key events to macOS instead of drawing a full custom keyboard.
- Hotkey panel: Grid layout, 2 columns × N rows, horizontally scrollable. Phase 1 fills 1–2 screens; grid scales for Phase 3 app-aware shortcuts without redesign.
- Hotkey button labels: Icons where the action is universally recognized (copy, paste, cut, undo, redo, tab); text labels for less-common shortcuts (screenshot, select all, quit, delete actions).
- Liquid Glass / glassmorphism: Applied to hotkey panel chrome and overall app chrome only. The stock system keyboard keeps its native appearance.

### Connection Status UI

- Primary in-app status surface: Always-visible top status badge. Tapping it opens the debug sheet. Dynamic Island (Live Activity) mirrors connection state on supported devices and still provides the reconnect deep link.
- USB → AWDL handoff target: Silent. Status should flip directly from USB-green to AWDL-yellow only when AWDL connection is confirmed. 01-05 is still validating the timing and reliability of this behavior.
- Debug screen: Top-status-badge debug sheet (available in all builds). Shows the connection event log, current transport state, AWDL standby state, and actions for reconnect/reset pairing.

### Security — One-Time Pairing

- First launch requires QR code pairing: macOS agent displays a QR code; iOS app uses camera to scan it. Encrypted key exchange happens after scan. After first-time pairing, subsequent connections authenticate automatically using stored keys.
- This pairing must happen before any keyboard input is accepted. Pairing can be reset from either side, and the reset flow invalidates the remote pairing before clearing local state.

### Keyboard Interaction Model

- Key feedback: The stock iOS keyboard provides native key visuals. The custom hotkey panel adds haptics for app-owned shortcut buttons.
- Backspace auto-repeat: First phase deletes single characters, then ramps into word-delete on a sustained hold. The target behavior remains "native-feeling," but the exact timing is still being tuned during 01-05.
- Hotkey buttons: Single tap sends the full shortcut as one atomic CGEvent sequence (no sticky modifier key needed in Phase 1).
- Modifier safety: Cmd key-up events must always be sent, including in error paths and on disconnect (Swift `defer` blocks). Prevents stuck-Cmd bug if connection drops mid-shortcut.
- Password field detection: When macOS reports a secure input field is focused, iOS keyboard shows a gray overlay with "Password field active" label. Key input is blocked until field changes.

### First Launch & Setup Flow

- **iOS first launch:** No onboarding screen. App launches directly into the QR pairing view when unpaired. The keyboard view is shown only after pairing succeeds.
- **macOS first launch:** The menu bar agent launches immediately, shows permission state in its menu, and provides direct actions to open the relevant System Settings panes. Once both permissions are granted, the agent starts transport automatically. The QR pairing window is opened from the menu and closes automatically after successful pairing.
- **Connection wait state:** Once paired, the keyboard layout is visible but dimmed/non-interactive while connecting. The top status badge remains visible, and the app offers an explicit retry path while disconnected.

### Orientation & Device Support

- Orientation: Portrait only. Landscape not supported in Phase 1 — keyboard height constraints make landscape impractical.
- Device: iPhone and iPad both supported from Phase 1.

### iOS Interruptions & Background

- Phone call interruption: The app should resume cleanly when it becomes active again, but 01-05 still treats reconnect/resume behavior as validation work rather than a guaranteed solved case.
- App backgrounding: Phase 1 no longer depends on a persistent background transport strategy. Live Activity can remain visible while backgrounded, but reconnect/resume behavior is handled when the app becomes active again.
- iOS idle timer: Disabled (`UIApplication.shared.isIdleTimerDisabled = true`) while actively connected.

### macOS Agent

- Menu bar icon: Static keyboard icon. Clicking opens a menu showing: connection state, transport type (USB/AWDL), Pair iPhone, Reset Pairing, version, Quit.
- Permission prompts: Missing permissions are surfaced in the menu with direct actions to open the relevant System Settings panes plus a relaunch action. The agent starts transport after both permissions are granted.
- Agent lifecycle: Registered via `SMAppService.mainApp` as Login Item. macOS auto-restarts agent if it crashes or is force-quit.
- Agent UI: Menu bar icon + menu, plus a temporary QR pairing window in Phase 1 when pairing is needed.

### Claude's Discretion

- Exact port number for usbmuxd TCP tunnel (hardcoded for personal use).
- Exact retry-with-backoff timing for USB reconnect on plug-in.
- Remaining 01-05 tuning for USB readiness detection vs AWDL standby promotion on real hardware.

</decisions>

<specifics>
## Specific Ideas

- Dynamic Island as mirrored status surface: user explicitly requested it. It now complements the in-app top status badge instead of replacing it.
- QR code pairing is the security model: "nobody can connect" — security is a first-class requirement even for a personal-use app.
- Backspace behavior is still meant to feel native: delete characters first, then ramp into word delete as the hold continues.
- Hotkey grid is designed to scale: "will come in handy for Phase 3" — the 2-col grid layout is a deliberate forward-compatible decision.
- Background transport is no longer a locked Phase 1 dependency. The current priority is reliable reconnect and clear status when the app becomes active again.

</specifics>

<deferred>
## Deferred Ideas

- None — all discussion stayed within Phase 1 scope.

</deferred>

---

*Phase: 01-transport-and-core-keyboard*
*Context gathered: 2026-02-27*
*Reconciled with current Phase 1 implementation: 2026-02-28*
