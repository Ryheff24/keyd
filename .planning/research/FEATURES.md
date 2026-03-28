# Feature Research

**Domain:** iPadOS-to-macOS Remote Desktop (keyd-rd v2.0)
**Researched:** 2026-03-27
**Confidence:** MEDIUM-HIGH — Live web research plus spec documents. Commercial solution analysis from official docs, App Store descriptions, and user forums. Technical claims cross-referenced against Apple developer documentation.

---

## Commercial Solution Analysis

### Apple Sidecar
**What it does well:**
- Native OS integration — zero setup friction
- Hardware-accelerated HEVC encode from Mac → iPad (uses same media engine approach we're taking)
- Touch input and Apple Pencil passthrough
- Seamless reconnect in most cases

**What it does poorly:**
- AWDL-dependent wireless path introduces hundreds of milliseconds of latency (confirmed by Apple developer forums and user reports)
- Wireless frequently freezes, disconnects, or degrades after a few minutes of use — reported persistently across Ventura, Sonoma, Sequoia
- Color accuracy degrades ~20% saturation loss on iPad display vs Mac
- Memory leak in WindowServer during extended Sidecar sessions
- Limited to Apple-ID-matched devices; useless if you want to share or use a different account
- No remote desktop mode — it's a second display only, not a primary display replacement
- No eco mode or quality controls

**Confidence:** MEDIUM — Based on Apple Community forum threads and developer forum discussions.

### Luna Display (Astropad)
**What it does well:**
- Hardware dongle-backed signal path; 1–4ms wired latency, 7–25ms Wi-Fi
- Touch + Apple Pencil support with low latency
- Works as extended or mirrored display
- No subscription required

**What it does poorly:**
- Requires a physical USB-A, HDMI, or Mini DisplayPort dongle — not a pure software solution
- NOT recommended for high-motion content (gaming, video playback) — optimized for static desktop reference
- Image quality degrades at high resolution to maintain framerate
- No remote desktop — only second display mode

**Confidence:** MEDIUM — Based on Astropad/Luna product pages and independent review coverage.

### Duet Display
**What it does well:**
- Pure software — no dongle
- Wired connection at up to 60Hz with Retina resolution
- Wireless at ~30Hz
- Shows in-app metrics (encoder bitrate, RTT, variance)
- Works across Mac, PC, iOS, Android — broadest compatibility

**What it does poorly:**
- Wireless framerate caps at ~30Hz
- Requires subscription for advanced features (Duet Air for remote desktop)
- Image quality sometimes pixelated at high resolution wireless
- Not specifically optimized for Mac-to-Mac or Mac-to-iPad direct link

**Confidence:** MEDIUM — Based on Duet Display product pages, App Store reviews, and independent comparisons.

### Jump Desktop (Fluid protocol)
**What it does well:**
- Best-in-class touch input mapping for remote desktop (direct touch + trackpad + pointer modes)
- Three input modes users can switch between:
  - Direct Touch: tap = click at that position (most natural for iPad)
  - Trackpad: relative movement like laptop trackpad
  - Pointer: shows cursor, moves it with finger
- Two-finger tap = right click (in pointer/trackpad mode)
- Long press = right click (in direct touch mode)
- Two-finger scroll = scroll events
- Shows debug latency overlay
- Good audio streaming support

**What it does poorly:**
- Relies on remote Mac running Jump Desktop host software (adds network/firewall complexity)
- Latency over internet connections — not optimized for direct cable connection
- No USB NCM or direct cable path — always goes through network stack

**Confidence:** MEDIUM — Based on Jump Desktop support documentation and App Store description.

### keyd-rd Positioning
keyd-rd targets a gap none of these fill: **zero-latency wired-first remote desktop over direct USB-C connection**, with near-zero Mac CPU cost, for a single personal-use pair of devices. Sidecar is the closest but has well-documented reliability and latency issues over wireless. keyd-rd is what Sidecar should be, focused on the wire path.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features that any remote desktop product must have. Missing these = the product is not a remote desktop.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Screen display — full resolution | The entire premise; without it there is no product | HIGH | ScreenCaptureKit → LZ4+delta (wired) or HEVC (wireless); Metal render on iPad; P3 color |
| Mouse cursor visible on remote screen | Without a visible cursor, touch targeting is guesswork | MEDIUM | Mac must render cursor into frame OR send cursor position separately; cursor overlay on iPad |
| Touch tap = left click | Universal expectation across all remote desktop products | MEDIUM | UITapGestureRecognizer → absolute mouse move + click CGEvent |
| Two-finger scroll = scroll | Universal gesture; tested immediately by any user | MEDIUM | UIPanGestureRecognizer (2-touch) → CGEvent scroll wheel |
| Right-click support | Context menus are essential in macOS | MEDIUM | Long press OR two-finger tap → kCGMouseButtonRight click CGEvent |
| Physical keyboard passthrough | iPad keyboard input → Mac | MEDIUM | UIKeyInput / UITextInput capture → key CGEvents; must intercept at system level |
| USB wired connection | Spec's primary transport; expected to be faster/more reliable | HIGH | USB NCM via Network.framework; NWPathMonitor + requiredInterface to target specific interface |
| Automatic Wi-Fi fallback on unplug | Without this, pulling the cable kills the session | HIGH | NWPathMonitor detects USB NCM interface loss; reconnect over Wi-Fi within 2 seconds |
| Connection status indicator | User must know if connected and over which path | LOW | Three states: USB / Wi-Fi / disconnected; show latency and FPS |
| Quality/FPS metrics overlay | Users want to know actual performance figures | LOW | FPS counter, RTT latency, bitrate; toggle with gesture |
| QR pairing | Competitor standard; first-run experience | MEDIUM | Reuse keyd v1.0 QR pairing + ECDH key exchange — already built |
| Landscape display orientation | Natural iPad orientation for remote desktop | LOW | Constraint in iPad app layout; frame aspect ratio matches Mac display |
| Portrait display orientation | Some iPad use cases favor portrait | LOW | Letterbox or scale-to-fit; lower priority than landscape |

### Differentiators (Competitive Advantage)

Features that go beyond what existing solutions provide, aligned with keyd-rd's core value proposition.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Sub-8ms glass-to-glass wired latency | Faster than Sidecar wireless (100–500ms), Luna wired (1–4ms uses dongle), Duet wired (~16ms); competes with professional KVM switches | HIGH | LZ4+delta over USB NCM UDP path; binary framing; no JSON; no TLS handshake per frame |
| Near-zero Mac CPU (<3%) during streaming | Uniquely enables use alongside local LLM inference — no other solution targets this constraint | HIGH | LZ4 compression on IOSurface in-place; no GPU on Mac; heavy work on iPad M4 |
| LZ4+delta compression for wired path | Avoids HEVC encoder heat/power on Mac; near-zero CPU; still achieves adequate compression for USB3 bandwidth | HIGH | XOR delta frames typically compress to <1% of raw; keyframe every 1–2s; fallback to HEVC for wireless |
| HEVC hardware encode/decode for wireless | Uses dedicated media engine — doesn't compete with CPU/GPU workloads | MEDIUM | VideoToolbox on Mac + VideoToolbox on iPad; hardware path confirmed available on M1 Max and M4 |
| Eco mode (reduced quality, <1% CPU) | Lets user keep Mac screen visible while LLM inference runs at full speed | MEDIUM | Drop to 1080p/720p at 30Hz; HEVC even over wired; target <1% Mac CPU, <20 MB RSS |
| USB NCM transport (not usbmuxd) | Direct Ethernet-over-USB; full link speed; no tunneling overhead; UDP-capable | HIGH | Different from keyd v1.0 (which uses usbmuxd TCP tunnel); requires NWPathMonitor to identify NCM interface; validated as feasible per REMOTE-DESKTOP-SPEC.md |
| Binary protocol (no JSON in data path) | 24-byte media header vs typical JSON framing; eliminates serialization cost in hot path | MEDIUM | Already specced in protocol.h; shares concept with keyd v1.0 but entirely new protocol |
| Metal rendering with P3 color management | iPad Pro has P3 wide-gamut display; most remote desktop clients don't color-manage correctly | MEDIUM | MTKView + Metal shaders; CMSampleBuffer color space metadata available from ScreenCaptureKit |
| ProMotion 120Hz adaptive rendering | iPad Pro M4 supports 120Hz; remote desktop clients typically cap at 60Hz | MEDIUM | MTKView preferredFramesPerSecond; requires 120fps capture from ScreenCaptureKit |
| Pinch-to-zoom viewport control | Useful for viewing small UI elements on Mac from iPad; zoom without changing Mac resolution | MEDIUM | UIScrollView or manual pinch gesture; applies scale transform to Metal render; does not affect Mac |
| Direct touch input mode | Natural iPad interaction — tap where you want to click, no cursor gymnastics | MEDIUM | Absolute coordinate mapping: iPad screen coords → Mac display coords via linear scale |
| Trackpad mode (relative mouse) | For precise work where direct touch is less accurate | MEDIUM | UIPanGestureRecognizer with relative offset accumulation → relative mouse move CGEvents |
| On-screen keyboard passthrough | External keyboard not always attached; on-screen keyboard must work | MEDIUM | Must capture UIKeyInput/UITextInput before iOS intercepts input for system use |
| Latency probe / round-trip measurement | Shows actual measured glass-to-glass RTT; builds trust; useful for debugging | LOW | 0xFF keepalive/probe packet in binary protocol already specced; timestamps on both sides |
| Deterministic E2E test suite | Confidence in correctness without visual verification; essential for a protocol-heavy product | HIGH | RD-TEST-01 through RD-TEST-10 already specced; both devices use same PRNG seed |

### Anti-Features (Commonly Requested, Often Problematic)

| Anti-Feature | Why Requested | Why Problematic | Alternative |
|--------------|---------------|-----------------|-------------|
| Bluetooth transport | "Simpler to pair" | Bluetooth throughput (~3 Mbps) cannot carry 4K screen; latency too high for interactive use; pairing adds friction | USB NCM primary + Wi-Fi fallback covers all meaningful use cases |
| Cloud relay / internet remote access | "Access my Mac from anywhere" | Fundamentally different product; requires server infrastructure, account system, NAT traversal, and latency is unacceptable for low-latency screen streaming | Out of scope; personal-use direct connection is the design constraint |
| Multi-monitor support | "I have two displays" | Doubles bandwidth and compression complexity; requires monitor-selection UI; captures 4K of data not all users need | Deferred to v2.1 per PROJECT.md; single display sufficient for v2.0 |
| File drag-and-drop | Natural extension of clipboard | Requires a virtual filesystem or AirDrop-like transfer protocol; significant complexity beyond clipboard | Clipboard sync covers most file-sharing needs; drag-and-drop deferred to v2.1 |
| App Store distribution | "Others could use it" | Requires app review, entitlement negotiations for Screen Recording + Accessibility; weekly re-signing becomes signing infrastructure; ongoing support burden | Self-signed personal use; weekly Xcode re-sign is fine for one device pair |
| HEVC over USB wired path (non-eco) | "Simpler than implementing LZ4+delta" | HEVC encoder adds ~2–5ms encode latency vs LZ4's <1ms; activates media engine heat; HEVC is designed for bandwidth-constrained paths, not a high-bandwidth wire | LZ4+delta for wired; HEVC reserved for wireless and eco mode |
| On-screen virtual mouse / joystick | "Easier than touch-to-mouse" | Adds a UI widget that obstructs the remote screen; touch-to-mouse mapping is the correct iPad-native approach | Direct touch and trackpad modes cover all cursor control needs |
| Gesture customization panel | "I want to remap gestures" | Adds settings complexity; standard gesture mapping is well-established and users expect it | Stick to industry-standard mapping (tap=click, 2-finger=scroll, long-press=right-click) |
| Audio routing to Mac speakers while streaming | "Keep audio on Mac too" | Requires splitting audio output mid-stream; CoreAudio routing complexity; out of scope for v2.0 | Stream Mac audio to iPad only; Mac audio routing unchanged |
| AirDrop-based pairing alternative | "QR codes are annoying" | AirDrop adds dependency on an AWDL discovery flow that already adds complexity; QR is simpler, faster, and proven in keyd v1.0 | QR + ECDH reuse from keyd v1.0 |

---

## Touch-to-Mouse UX Patterns

This section captures the industry-established gesture mapping that users expect. Deviating from these patterns will surprise users.

### Gesture Mapping (Industry Standard)

| Touch Gesture | Mouse Event | Notes |
|---------------|-------------|-------|
| Single tap | Left click at tap position | Direct touch mode; cursor snaps to position |
| Single tap + move (drag) | Left button held + mouse move | Double-tap to initiate drag in some apps |
| Two-finger tap | Right click | Standard in pointer/trackpad mode |
| Long press (1 finger, ~0.5s) | Right click | Standard in direct touch mode |
| Two-finger pan | Scroll wheel (vertical + horizontal) | UIScrollView-style momentum optional |
| Pinch | Viewport zoom on iPad (does NOT zoom Mac) | Zoom controls the render scale, not Mac resolution |
| Three-finger pan | Mission Control or app-specific | Optional; can be disabled to avoid conflicts |
| Swipe from edge | iPad system gesture (take over, do not intercept) | Must NOT be intercepted; use UIGestureRecognizerDelegate |

### Input Mode Recommendation

**Default mode: Direct Touch** (not trackpad mode)

Rationale:
- Direct touch is the most natural iPad interaction model for first-time users
- Trackpad mode requires users to understand relative vs absolute cursor movement — cognitive load
- Jump Desktop and Duet both default to direct touch equivalents for Mac targets
- Trackpad mode as a selectable alternative covers power-user precision needs

**Mode toggle:** A persistent button in the screen overlay HUD (not buried in settings).

### Cursor Visibility Problem

**The challenge:** In direct touch mode, the Mac cursor is wherever the user last clicked. Users cannot see where it is without a recent click. This causes "where is my cursor?" confusion.

**Industry solution:** Render the Mac cursor position as an overlay on the iPad stream. Options:
1. Mac sends cursor position separately on the input channel (lightweight)
2. Mac renders cursor into the captured frame (simpler but cursor is always in frames even if not moving)
3. iPad renders a local cursor proxy based on the last click position

**Recommendation:** Option 1 — send cursor position as a lightweight event on the TCP input channel. Render cursor overlay on iPad in Metal. This keeps cursor position responsive even when frames are not updating.

---

## Audio Streaming

### Codec Choice: AAC-LC over Opus

**Why not Opus:**
- Apple platforms (iPadOS) have limited native Opus playback support — cannot use system `AVAudioEngine` or `AudioQueue` with Opus without a third-party library
- Adding a third-party Opus library (libopus) increases binary size and maintenance surface
- AAC-LC hardware decode is available via `AudioToolbox` / `AVAudioEngine` on all Apple platforms — no library needed
- Latency difference is minimal at the bitrates used for speech/desktop audio (64–128 kbps)

**AAC-LC parameters for low latency:**
- Bitrate: 128 kbps stereo (sufficient for system audio; not music streaming quality)
- Frame size: 1024 samples at 44.1 kHz = ~23ms per frame — acceptable for desktop audio
- Hardware encode on Mac: `AudioToolbox` `kAudioFormatMPEG4AAC` encoder
- Hardware decode on iPad: `AudioToolbox` or `AVAudioEngine`

**Confidence:** MEDIUM — Based on web research confirming Apple platform Opus playback limitations and `AudioToolbox` AAC support.

### Mac Audio Capture: CoreAudio Taps API (macOS 14.2+)

macOS 14.2 introduced the CoreAudio Taps API, which allows capturing system audio output from specific processes or the entire system without a virtual audio device. This is the modern replacement for virtual audio drivers (Soundflower, BlackHole, etc.).

- API: `CATapDescription` + `CAAudioHardwareService` or `AudioHardwareCreateProcessTap`
- Requires Screen Recording permission (same entitlement already needed for ScreenCaptureKit)
- No need for a virtual audio driver or system extension
- Captures audio at native sample rate before it reaches the DAC

**Complexity:** MEDIUM — API is relatively new (macOS 14.2) and described as "poorly documented" in community resources. Reference implementation exists in `AudioCap` open-source project.

**Minimum macOS version impact:** Requires macOS 14.2 (Sonoma). M1 Max MacBook Pro runs Sonoma/Sequoia — acceptable.

**Confidence:** MEDIUM — CoreAudio Taps confirmed via Apple developer docs and community blog posts (stronglytyped.uk, AudioCap GitHub).

---

## Clipboard Sync

### Bidirectional Clipboard: Complexity Assessment

**Mac → iPad (lower complexity):**
- Mac monitors `NSPasteboard.general` for changes
- On change, serializes clipboard content (plain text, RTF, image) and sends to iPad over TCP control channel
- iPad receives and writes to `UIPasteboard.general`
- Straightforward; `NSPasteboard` change count is the polling mechanism

**iPad → Mac (moderate complexity):**
- iOS 14+ requires explicit user permission for apps to read the pasteboard (`UIPasteboard.general`)
- iOS shows a system banner "App pasted from clipboard" — cannot be suppressed; this is Apple-mandated privacy UI
- App must be foregrounded to reliably access UIPasteboard (background access is restricted)
- On change (via `UIPasteboard.changedNotification`), serialize and send to Mac
- Mac receives and writes to `NSPasteboard.general`

**Format support for v2.0:** Plain text only. RTF and images add significant serialization complexity; text covers the primary use case.

**iOS Privacy Banner Expectation:** The "App pasted from clipboard" system banner WILL appear when keyd-rd reads the iPad clipboard. This is expected behavior and cannot be avoided. Users should be informed of this in onboarding or first-run.

**Confidence:** MEDIUM — `UIPasteboard` behavior and iOS privacy requirements from training data; privacy banner confirmed as unavoidable since iOS 14.

---

## Connection Mode UX

### Transport Cascade: USB NCM → Wi-Fi → AWDL

| Mode | Path | Latency | Quality |
|------|------|---------|---------|
| USB NCM (wired) | USB 3.x / TB4 direct link | <8ms glass-to-glass | LZ4+delta; full resolution; 120fps |
| Wi-Fi | Same network infrastructure | <25ms glass-to-glass | HEVC; 60fps |
| AWDL | Peer-to-peer wireless | 25–40ms glass-to-glass | HEVC; 30–60fps |

**Mode switching UX:**
- USB unplug → automatic Wi-Fi or AWDL fallback within 2 seconds — no user action
- USB re-plug → automatic promotion back to USB within 2 seconds — no user action
- User can manually force eco mode from the HUD regardless of current transport
- Transport mode is shown in the HUD (USB / Wi-Fi / AWDL icon + latency)

**Eco mode:**
- Triggered manually by user or automatically when battery is low (optional future feature)
- Drops to 1080p or 720p at 30Hz
- Uses HEVC even over wired connection
- Target: <1% Mac CPU, <20 MB RSS
- HUD indicator changes to show eco state

---

## Feature Dependencies

```
[USB NCM Transport]
    └──required by──> [Screen streaming (wired, LZ4+delta)]
    └──required by──> [Input events (wired TCP path)]

[Wi-Fi/AWDL Transport]
    └──required by──> [Screen streaming (wireless, HEVC)]
    └──required by──> [Input events (wireless TCP path)]

[Transport (any)]
    └──required by──> [QR Pairing + ECDH key exchange]
    └──required by──> [Audio streaming]
    └──required by──> [Clipboard sync]

[Screen streaming]
    └──required by──> [Metal rendering on iPad]
    └──enhances──> [Cursor overlay (cursor position events)]

[LZ4+delta compression]
    └──required by──> [Wired screen streaming]

[HEVC encode/decode]
    └──required by──> [Wireless screen streaming]
    └──required by──> [Eco mode]

[Touch-to-mouse translation]
    └──required by──> [Left click]
    └──required by──> [Right click]
    └──required by──> [Scroll]
    └──required by──> [Drag]

[Physical keyboard capture]
    └──required by──> [Keyboard passthrough]
    └──required by──> [On-screen keyboard passthrough]

[CoreAudio Taps (macOS 14.2+)]
    └──required by──> [Audio streaming (Mac → iPad)]

[NSPasteboard monitoring]
    └──required by──> [Clipboard sync Mac → iPad]

[UIPasteboard access]
    └──required by──> [Clipboard sync iPad → Mac]

[Eco mode] ──conflicts──> [Full quality wired streaming]
    Note: Eco activates HEVC encoder even over USB; cannot run LZ4+delta and eco simultaneously.

[Direct touch mode] ──conflicts──> [Trackpad mode]
    Note: Mutually exclusive input modes; toggle in HUD.
```

### Dependency Notes

- **Screen streaming blocks everything:** The product does not work at all without this. It is the first phase.
- **Input requires streaming:** Input is meaningless without being able to see the result on screen.
- **Audio and clipboard are independent:** They can ship after screen + input are working; they share the transport but don't depend on compression/rendering.
- **Eco mode requires HEVC:** LZ4+delta cannot achieve the <1% CPU target at reduced resolution; HEVC hardware encoder is the mechanism that achieves this.
- **CoreAudio Taps requires macOS 14.2:** This is a hard OS version dependency for audio streaming. If the Mac runs an older version, audio streaming is not available. M1 Max MacBook Pro running Sonoma/Sequoia satisfies this constraint.

---

## MVP Definition

### Launch With (v2.0)

Minimum viable product — validates the remote desktop concept end-to-end.

- [ ] USB NCM wired transport — proves the core latency claim
- [ ] Wi-Fi / AWDL fallback transport — makes daily use viable without always being plugged in
- [ ] Screen streaming: LZ4+delta (wired) + HEVC (wireless) — the product's core value
- [ ] Metal rendering on iPad at full Retina resolution + ProMotion 120Hz
- [ ] Touch-to-mouse: tap, scroll, right-click, drag — minimal input set for usable remote desktop
- [ ] Physical keyboard passthrough — required for productive work
- [ ] On-screen keyboard passthrough — required when external keyboard not attached
- [ ] Automatic USB ↔ Wi-Fi failover — no manual intervention allowed
- [ ] QR pairing (reuse keyd v1.0 flow) — first-run device linking
- [ ] Connection status HUD (transport mode, latency, FPS) — user confidence
- [ ] Eco mode — required per spec; target hardware constraint (Mac running LLMs)
- [ ] TLS 1.3 / DTLS 1.3 encryption — no cleartext mode
- [ ] macOS Screen Recording permission prompt — required to use ScreenCaptureKit
- [ ] macOS Accessibility permission prompt — required for CGEvent injection
- [ ] Deterministic E2E test suite — required for correctness confidence without visual verification

### Add After Validation (v2.1)

Features to add once v2.0 core is proven stable.

- [ ] Audio streaming (Mac → iPad) — adds significant value for watching video/audio content; depends on CoreAudio Taps (macOS 14.2+)
- [ ] Clipboard sync (bidirectional, text only) — common pain point in remote desktop; medium complexity
- [ ] Cursor position overlay on iPad — eliminates "where is my cursor?" confusion; should be in v2.0 but can ship as fast-follow
- [ ] Trackpad input mode (alternative to direct touch) — for precision tasks
- [ ] Multi-monitor support — select which display to stream — meaningful for users with external monitors attached to Mac
- [ ] Pinch-to-zoom viewport — useful for reading small text on Mac UI

### Future Consideration (v2.2+)

Features to defer until v2.1 is stable.

- [ ] File drag-and-drop (iPad ↔ Mac) — significant protocol complexity; clipboard covers most transfer needs
- [ ] iPad client C rewrite — separate milestone per PROJECT.md; Swift V1 is adequate for v2.0
- [ ] Clipboard sync: images and RTF — text-only is sufficient for v2.0
- [ ] Multi-Retina display streaming — high bandwidth and complexity
- [ ] Audio streaming from iPad → Mac (microphone passthrough) — lower priority than Mac → iPad

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Screen streaming (wired LZ4+delta) | HIGH | HIGH | P1 |
| Screen streaming (wireless HEVC) | HIGH | HIGH | P1 |
| USB NCM transport | HIGH | HIGH | P1 |
| Wi-Fi/AWDL fallback transport | HIGH | HIGH | P1 |
| Touch-to-mouse (tap, scroll, right-click) | HIGH | MEDIUM | P1 |
| Physical keyboard passthrough | HIGH | MEDIUM | P1 |
| QR pairing | HIGH | LOW (reuse keyd) | P1 |
| Metal rendering (P3, 120Hz) | HIGH | MEDIUM | P1 |
| Eco mode | HIGH | MEDIUM | P1 |
| TLS 1.3 / DTLS 1.3 | HIGH | MEDIUM | P1 |
| Connection status HUD | HIGH | LOW | P1 |
| Deterministic E2E tests | HIGH | HIGH | P1 |
| On-screen keyboard passthrough | MEDIUM | MEDIUM | P1 |
| Audio streaming (Mac → iPad) | MEDIUM | MEDIUM | P2 |
| Clipboard sync (text) | MEDIUM | MEDIUM | P2 |
| Cursor overlay on iPad | HIGH | LOW | P2 |
| Trackpad input mode | MEDIUM | LOW | P2 |
| Multi-monitor display selection | MEDIUM | HIGH | P2 |
| Pinch-to-zoom viewport | MEDIUM | LOW | P2 |
| File drag-and-drop | LOW | HIGH | P3 |
| iPad C client rewrite | LOW | HIGH | P3 |
| Clipboard sync (images, RTF) | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for v2.0 launch
- P2: Should have, add in v2.1
- P3: Nice to have, v2.2+

---

## Complexity Notes by Feature

### Screen Streaming (HIGH complexity)
The hardest feature. Requires:
1. ScreenCaptureKit capture pipeline (macOS, Obj-C)
2. IOSurface → LZ4 compress pipeline (C, hot path)
3. Delta frame XOR computation (C, hot path)
4. Binary framing + UDP chunking (C)
5. USB NCM transport (Obj-C, Network.framework)
6. UDP receive + chunk reassembly (Swift)
7. LZ4 decompress + delta apply (Swift wrapping C)
8. Metal render pipeline (Swift + Metal shaders)
9. HEVC encode path (Obj-C VideoToolbox) for wireless + eco
10. HEVC decode path (Swift VideoToolbox) for wireless + eco

Every step must hit budget: <3% Mac CPU, <8ms total wired latency.

### Touch-to-Mouse (MEDIUM complexity)
Well-understood problem; extensive industry precedent. The main challenge is:
- Coordinate mapping: iPad screen pixels → Mac display pixels (must account for aspect ratio mismatch and pinch-to-zoom state)
- Gesture recognition conflicts: iOS system gestures (edge swipes) must be explicitly excluded
- Input polling at 120Hz with batching — straightforward but requires care

### Keyboard Passthrough (MEDIUM complexity)
Capturing UIKeyInput is straightforward for physical keyboards. On-screen keyboard capture requires:
- UITextInput protocol implementation with a fake UITextField as first responder
- Suppressing iOS autocorrect and predictive text (they must not insert text locally)
- Forwarding raw keystrokes, not processed text (to preserve modifier key handling on Mac)

### Audio Streaming (MEDIUM complexity)
CoreAudio Taps is new (macOS 14.2) and poorly documented. The implementation risk is in the capture side. The streaming + decode side is standard `AudioToolbox` AAC. Budget extra time for the CoreAudio Taps integration.

### Clipboard Sync (LOW-MEDIUM complexity)
Mac → iPad is straightforward. iPad → Mac is complicated by iOS privacy restrictions (system banner, foreground-only access). For v2.0 scope: defer clipboard entirely or ship text-only Mac → iPad direction first.

### QR Pairing (LOW complexity — reuse)
keyd v1.0 already built and validated this flow. Copy the QR display (macOS) and scan (iOS) code with new bundle IDs. ECDH key exchange is the same. Re-use aggressively.

### Eco Mode (MEDIUM complexity)
Eco mode is a configuration layer on top of the existing compression pipeline. Once wired LZ4+delta and wireless HEVC paths are both working, eco mode is: set HEVC target resolution/bitrate low and cap framerate at 30Hz. The complexity is in the mode-switching logic and ensuring the Mac CPU budget is actually met.

---

## Dependencies on Existing keyd v1.0 Infrastructure

| Component | Status | Reuse Plan |
|-----------|--------|------------|
| QR pairing + ECDH key exchange | Built and tested | Copy PairingManager pattern; new bundle IDs; new certificate pinning store |
| CGEvent injection (mouse + keyboard) | Built and tested | EventInjector.c carries over directly; mouse events are new but same API |
| Bonjour service discovery (AWDL) | Built and tested | Reuse `_keyd._tcp` discovery pattern with new service name `_keydrd._tcp` |
| Transport failover state machine pattern | Built and tested | Replicate the FSM; transport protocol is entirely new (USB NCM, not usbmuxd) |
| Menu bar agent architecture | Built and tested | Copy NSStatusItem + NSMenu pattern; new agent, new bundle ID |
| SMAppService login item registration | Built and tested | Copy registration pattern |
| usbmuxd TCP transport | Built and tested | NOT reused — keyd-rd uses USB NCM, not usbmuxd |
| SharedProtocol SPM package | Built and tested | NOT reused — keyd-rd protocol is binary C header, not Swift JSON |
| iOS app keyboard UI | Built and tested | NOT applicable — keyd-rd is a full-screen remote display, not a keyboard extension |

The most valuable reuse is the QR pairing flow, CGEvent injection patterns, and Bonjour/AWDL discovery. The transport layer and protocol are entirely new.

---

## Latency / Quality Thresholds

Based on research and spec targets:

| Threshold | Value | Source |
|-----------|-------|--------|
| Glass-to-glass wired (acceptable) | <8ms | REMOTE-DESKTOP-SPEC.md; competitive with KVM switches |
| Glass-to-glass wireless (acceptable) | <25ms | REMOTE-DESKTOP-SPEC.md; better than Sidecar wireless |
| Glass-to-glass wired (perceptible lag) | >16ms | Industry standard: 60Hz display = 16.7ms frame period; any additional delay is noticeable |
| Input-to-screen (wired) | <12ms | REMOTE-DESKTOP-SPEC.md |
| Mac CPU budget (full quality wired) | <3% | PROJECT.md constraint |
| Mac CPU budget (eco mode) | <1% | PROJECT.md constraint |
| Mac RSS budget (full quality wired) | <50 MB | PROJECT.md constraint |
| Mac RSS budget (eco mode) | <20 MB | PROJECT.md constraint |
| LZ4 compress time per 4K frame | <1ms | REMOTE-DESKTOP-SPEC.md; consistent with ~5 GB/s LZ4 throughput on M1 Max |
| Audio latency (acceptable) | <30ms | Desktop audio use case; not music production |
| Failover completion (USB → Wi-Fi) | <2 seconds | REMOTE-DESKTOP-SPEC.md |

---

## Sources

- [REMOTE-DESKTOP-SPEC.md] — Primary specification (project-internal)
- [PROJECT.md] — Core constraints and key decisions (project-internal)
- [Luna Display product page](https://astropad.com/product/lunadisplay/) — Feature set and latency claims (MEDIUM confidence)
- [Astropad latency comparison](https://astropad.com/latency-comparison/) — Wired 1–4ms, wireless 7–25ms
- [Duet Display product page](https://www.duetdisplay.com/) — Feature set and technology overview (MEDIUM confidence)
- [Jump Desktop iOS input methods](https://support.jumpdesktop.com/hc/en-us/articles/216423623-iPad-Input-methods) — Direct touch vs trackpad vs pointer modes; gesture mapping reference (MEDIUM confidence)
- [Screens 5 cursor control modes](https://help.edovia.com/en/screens-5/features/cursor-control-modes-and-other-gestures) — Gesture mapping industry standard reference (MEDIUM confidence)
- [Apple Community: Sidecar lag reports](https://discussions.apple.com/thread/253255262) — Confirms AWDL latency issues (MEDIUM confidence — user reports)
- [Apple CoreAudio Taps API docs](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) — macOS 14.2+ system audio capture (HIGH confidence)
- [AudioCap GitHub](https://github.com/insidegui/AudioCap) — CoreAudio Taps reference implementation (MEDIUM confidence)
- [ScreenCaptureKit Apple docs](https://developer.apple.com/documentation/screencapturekit/) — Capture pipeline and frame delivery (HIGH confidence)
- [Sidecar internals — iMore](https://www.imore.com/how-sidecar-works-macos-catalina) — Sidecar uses HEVC/H.265 streaming similar to FaceTime (MEDIUM confidence)
- [Opus vs AAC for Apple platforms](https://vibbit.ai/blog/aac-vs-opus-audio) — Confirms iOS Opus playback limitations; AAC preferred for Apple ecosystem (MEDIUM confidence)
- [LZ4 performance on Apple M1 Max](https://aras-p.info/blog/2023/01/29/Float-Compression-1-Generic/) — ~5 GB/s decompression throughput; <1ms per 4K frame feasible (MEDIUM confidence)
- [Duet Display gestures help](https://www.duetdisplay.com/help-center/what-touch-gestures-can-i-use-on-my-ipad-or-iphone) — Touch gesture mapping reference (MEDIUM confidence)
- [Splashtop iOS gestures](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/212724363-Introduction-to-iOS-gestures-iPad-iPhone) — Industry-standard gesture mapping (MEDIUM confidence)

---

*Feature research for: iPadOS-to-macOS Remote Desktop (keyd-rd v2.0)*
*Researched: 2026-03-27*
