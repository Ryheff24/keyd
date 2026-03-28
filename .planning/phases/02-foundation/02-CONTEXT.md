# Phase 2: Foundation - Context

**Gathered:** 2026-03-28
**Status:** Ready for planning

<domain>
## Phase Boundary

End-to-end wired display pipeline: Mac screen appears on iPad over USB NCM at full Retina resolution with LZ4+delta compression, Metal ProMotion 120Hz rendering, automatic Wi-Fi/AWDL fallback, QR pairing, TLS/DTLS encryption, and both app shells (C+ObjC macOS agent, Swift iPadOS app). This phase delivers a viewable remote desktop — input is Phase 3.

</domain>

<decisions>
## Implementation Decisions

### Display Layout
- **Aspect ratio:** Letterbox — show full Mac screen, true black (#000000) bars on top/bottom in landscape. iPad Pro M4 has tandem OLED, so true black bars are literally invisible (pixels off).
- **Landscape fill:** Full width, letterbox only on top/bottom where aspect ratio differs. No margins.
- **Portrait:** Same approach — full width, letterbox where needed.
- **Resolution matching:** Auto-suggest on connect — when iPad connects, Mac agent offers to switch to a resolution that matches iPad's aspect ratio. Revert on disconnect. This is investigated and offered, not forced.
- **Resolution matching control:** Available from both Mac menu bar AND iPad expanded HUD (iPad can trigger Mac resolution change remotely).

### HUD Overlay
- **Position:** Top-center floating pill.
- **Compact state shows:** SF Symbol transport icon (USB/Wi-Fi/AWDL) + latency in ms + FPS counter. No emoji. Example: `⚡ 4ms 120fps` but with SF Symbol, not emoji.
- **Visual style:** Frosted glass blur (UIVisualEffectView material) over the Mac screen content.
- **Show/hide:** Swipe down from top of screen to reveal pill. Auto-hides after 3 seconds of no interaction.
- **Transport change alert:** Brief color flash on pill background — green for USB, yellow for Wi-Fi, orange for AWDL — then fades back to frosted glass.
- **Expanded state (tap pill to expand):** Shows all of:
  - Quality/Eco mode toggle button
  - Current resolution info (Mac capture + iPad render)
  - Bitrate / bandwidth throughput
  - "Match iPad Resolution" button (triggers Mac resolution change)
  - Disconnect button
- **Auto-hide applies to both compact and expanded states** — collapses and hides after 3s of no interaction.

### Session & Launch Flow
- **iPad first launch (unpaired):** Straight to camera viewfinder for QR scan. No onboarding screen. Same pattern as keyd v1.0.
- **After QR pairing:** Streaming starts immediately and automatically. Mac screen appears on iPad within 1-2 seconds. Zero friction.
- **Subsequent launches:** Streaming starts automatically as soon as paired Mac is detected on any transport. No "Connect" button.
- **Mac first launch:** Prompt for Screen Recording + Accessibility permissions immediately, before pairing. Agent won't proceed to QR code display until both permissions are granted. Permission status shown in menu bar menu with direct System Settings links.
- **Session handshake:** After pairing and before first frame, Mac sends to iPad:
  1. Display geometry (resolution, scale factor, aspect ratio)
  2. Supported modes (available compression: LZ4/HEVC, max framerate, eco mode)
  3. Agent version (protocol version for compatibility)
- **Mac menu bar:** Same pattern as keyd v1.0 but for remote desktop: connection state, transport type, resolution info, "Match iPad Resolution" option, Pair iPad, Reset Pairing, version, Quit.

### Reconnection UX
- **During reconnection:** Freeze last received frame + subtle "Reconnecting..." overlay. NOT black screen — the frozen frame provides visual continuity.
- **Retry strategy:** Exponential backoff with a visible "Retry Now" button always available. User can force an immediate reconnect attempt at any time.
- **Mac sleep/wake:** Auto-reconnect silently when Mac wakes. No user action needed. No HUD flash (silent).
- **iPad app backgrounded → foreground:** Auto-resume streaming. Reconnect if connection dropped while backgrounded. Zero friction.
- **USB replug:** Auto-detect and promote back to USB NCM. Silent reconnection (HUD transport icon updates via color flash per HUD decisions above).

### Claude's Discretion
- Exact backoff timing intervals for reconnection retries
- Exact frosted glass blur material/radius for HUD
- SF Symbol choices for transport icons (USB cable, Wi-Fi fan, AWDL indicator)
- Exact animation duration for HUD color flash
- Session handshake binary format (within the 24-byte protocol constraint)
- How resolution matching suggestions are presented on Mac (alert, menu item, notification)
- Whether to use `CGDisplaySetDisplayMode` or ScreenCaptureKit's own scaling for resolution matching

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- **PairingManager.swift** (macOS/KeydAgent/Pairing/): Curve25519 ECDH, QR payload generation, Keychain storage, test mode support. Pattern-copy with new service name `com.ryheff.keyd.remote.agent`.
- **CGEventInjector.swift** (macOS/KeydAgent/Injection/): HID event tap injection, modifier safety with `defer` blocks, `releaseAllModifiers()` on disconnect. Reuse directly — extend with mouse events in Phase 3.
- **AWDLListener.swift** (macOS/KeydAgent/Transport/): NWListener with `includePeerToPeer`, Bonjour `_keyd._tcp` pattern. Copy and rename service to `_keydrd._tcp`.
- **StatusBarController.swift** (macOS/KeydAgent/MenuBar/): NSStatusItem setup, dynamic icon updates, permission checking with polling, System Settings deep links. Pattern-copy for RD agent.
- **TransportStateMachine.swift** (SharedProtocol/): Pure FSM with `transition(from:on:) -> (state, effects)`. Adapt states for USB NCM > Wi-Fi > AWDL cascade.
- **KeydAgentApp.swift** (macOS/KeydAgent/App/): SMAppService registration, `.accessory` activation policy, `--test-mode` flag. Pattern-copy.

### Established Patterns
- **Actor-based transport:** Listeners are Swift actors with async/await. keyd-rd macOS agent is C+ObjC so this pattern won't transfer directly — use GCD dispatch queues instead.
- **Pure FSM:** Side-effect-free state machine with effects executed separately. This pattern transfers to C (`struct` + `switch` + effects array).
- **Permission polling:** 3-second interval poll until granted, then auto-start. Adapt for Screen Recording permission.

### Integration Points
- keyd-rd is a NEW set of Xcode projects — no code sharing at binary level with keyd v1.0.
- Pattern-copy only: copy the approach, adapt to C+ObjC (Mac) and Swift (iPad).
- Shared C headers in `RemoteDesktop/Shared/` consumed by both projects via include paths.

</code_context>

<specifics>
## Specific Ideas

- True black letterbox bars exploiting iPad Pro's tandem OLED — pixels literally off, creating a seamless edge-to-edge feel.
- Auto-suggest resolution matching on connect — Mac offers to change its resolution to eliminate letterboxing. Triggered from either Mac menu bar or iPad expanded HUD.
- Swipe-down-from-top gesture to reveal HUD pill — intuitive, doesn't conflict with tap/scroll input gestures (Phase 3).
- Frozen last frame during reconnection — visual continuity, not jarring black screen.
- Everything auto: auto-stream after pairing, auto-reconnect on wake, auto-resume on foreground. Zero friction is the design principle.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within Phase 2 scope.

</deferred>

---

*Phase: 02-foundation*
*Context gathered: 2026-03-28*
