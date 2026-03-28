# Requirements: keyd-rd

**Defined:** 2026-03-28
**Core Value:** The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input (mouse + keyboard), hardware-accelerated, with near-zero Mac CPU cost.

## v2.0 Requirements

Requirements for initial remote desktop release. Each maps to roadmap phases.

### Transport

- [ ] **RD-TRANS-01**: iPad connects to Mac over USB NCM network interface (not usbmuxd) detected via NWPathMonitor `.wiredEthernet`
- [ ] **RD-TRANS-02**: iPad connects to Mac over infrastructure Wi-Fi (same network) as first wireless fallback
- [ ] **RD-TRANS-03**: iPad connects to Mac over AWDL as last-resort wireless fallback when no shared Wi-Fi network exists
- [ ] **RD-TRANS-04**: Connection automatically falls back from USB NCM to Wi-Fi/AWDL when cable is unplugged, within 2 seconds
- [ ] **RD-TRANS-05**: Connection automatically promotes from Wi-Fi/AWDL back to USB NCM when cable is re-plugged, within 2 seconds
- [ ] **RD-TRANS-06**: Media stream uses UDP datagrams over the active transport
- [ ] **RD-TRANS-07**: Input stream uses a separate TCP connection over the active transport (reliable, ordered)
- [x] **RD-TRANS-08**: Wire protocol uses binary framing (24-byte media header, 9-byte input header, packed C structs)
- [ ] **RD-TRANS-09**: Both devices bind to USB NCM interface explicitly via `NWParameters.requiredInterface` with the specific `NWInterface` object (never hardcode interface name)
- [ ] **RD-TRANS-10**: Bonjour service `_keydrd._tcp` used for wireless discovery (distinct from keyd's `_keyd._tcp`)

### Screen Capture

- [ ] **RD-CAP-01**: macOS agent captures full display via ScreenCaptureKit (`SCStream`) at Retina resolution
- [ ] **RD-CAP-02**: Capture supports up to 120fps (`minimumFrameInterval = CMTimeMake(1, 120)`)
- [ ] **RD-CAP-03**: Capture delivers IOSurface-backed CMSampleBuffer directly to compress pipeline (zero-copy: `IOSurfaceLock` → LZ4 compress → `IOSurfaceUnlock`)
- [ ] **RD-CAP-04**: Capture CPU usage <1% in steady state
- [ ] **RD-CAP-05**: Frame delivery watchdog detects silent capture stop (0 frames for >2s) and surfaces re-authorization prompt in menu bar (Sequoia monthly re-auth handling)
- [x] **RD-CAP-06**: Pixel format is `kCVPixelFormatType_32BGRA` throughout pipeline (matches Metal texture upload, no color conversion)

### Compression

- [x] **RD-COMP-01**: Wired mode uses vendored LZ4 v1.10.0 block API (not Apple Compression.framework) on full keyframes
- [ ] **RD-COMP-02**: Wired mode uses XOR delta frames between keyframes, LZ4-compressed
- [ ] **RD-COMP-03**: Keyframes sent every 1-2 seconds or when delta exceeds 60% of keyframe size
- [x] **RD-COMP-04**: Delta frame reference buffer uses double-buffer with `pthread_rwlock_t` to prevent XOR race condition
- [ ] **RD-COMP-05**: CMSampleBuffer retain held for entire duration of LZ4 compress (prevents IOSurface recycling corruption)
- [ ] **RD-COMP-06**: Wireless mode uses VideoToolbox HEVC hardware encoder (`VTCompressionSession`, realtime, low-latency profile with `AverageBitRate` — NOT `ConstantBitRate`)
- [ ] **RD-COMP-07**: Eco mode uses HEVC at reduced resolution (1080p or 720p) and framerate (30Hz), even over wired connection
- [ ] **RD-COMP-08**: LZ4 compress completes in <1ms per 4K BGRA frame
- [ ] **RD-COMP-09**: Mode switching (LZ4 ↔ HEVC) triggered automatically by transport change or manually by user via HUD

### Rendering

- [ ] **RD-REND-01**: iPad renders frames via Metal (`MTKView` with `CAMetalDisplayLink` render loop, not built-in timer)
- [ ] **RD-REND-02**: Rendering supports P3 wide color gamut (iPad Pro display)
- [ ] **RD-REND-03**: Rendering supports ProMotion 120Hz (`CADisableMinimumFrameDuration = YES` in Info.plist, triple buffering with 3 drawables)
- [ ] **RD-REND-04**: LZ4 decompression + delta apply + Metal render completes in <3ms per frame on iPad
- [ ] **RD-REND-05**: Cursor position rendered as Metal overlay on iPad (Mac sends cursor position as lightweight TCP event)

### Input

- [ ] **RD-INPUT-01**: Touch gestures on iPad translate to mouse move events on Mac (direct touch mode: tap = click at absolute position)
- [ ] **RD-INPUT-02**: Single tap translates to left click; two-finger tap or long press (~0.5s) translates to right click
- [ ] **RD-INPUT-03**: Two-finger pan translates to scroll events (vertical + horizontal)
- [ ] **RD-INPUT-04**: Single tap + drag translates to left-button held + mouse move
- [ ] **RD-INPUT-05**: Physical keyboard connected to iPad passes keystrokes to Mac via CGEvent
- [ ] **RD-INPUT-06**: On-screen iPad keyboard passes keystrokes to Mac (UITextInput with autocorrect suppressed, raw keystrokes forwarded)
- [ ] **RD-INPUT-07**: Input events polled at 120Hz minimum, batched and sent every ~4ms; clicks and key events never dropped
- [ ] **RD-INPUT-08**: Mac injects all input via CGEvent (mouse move, click, scroll, key up/down)
- [ ] **RD-INPUT-09**: iPad touch coordinates map to absolute Mac screen coordinates (affine transform accounting for Retina scaling + aspect ratio letterboxing; Mac display geometry exchanged in session handshake)
- [ ] **RD-INPUT-10**: Pinch-to-zoom adjusts viewport/resolution on iPad (Metal scale transform, does not affect Mac resolution)

### Audio

- [ ] **RD-AUDIO-01**: macOS agent captures system audio via CoreAudio Tap API (`AudioHardwareCreateProcessTap`, macOS 14.2+)
- [ ] **RD-AUDIO-02**: Audio encoded as AAC-LC (128 kbps stereo, 44.1 kHz) via `AudioConverter` — not Opus
- [ ] **RD-AUDIO-03**: Encoded audio streamed to iPad over UDP on a separate channel from video
- [ ] **RD-AUDIO-04**: iPad decodes and plays audio via `AVAudioEngine` with <30ms audio latency
- [ ] **RD-AUDIO-05**: Audio stream synchronized with video stream (timestamp-based, not frame-locked)

### Clipboard

- [ ] **RD-CLIP-01**: Mac → iPad clipboard sync: macOS agent monitors `NSPasteboard.general` change count, sends text content to iPad over TCP control channel
- [ ] **RD-CLIP-02**: iPad → Mac clipboard sync: iPad monitors `UIPasteboard.changedNotification`, sends text content to Mac over TCP control channel
- [ ] **RD-CLIP-03**: Clipboard sync is text-only for v2.0 (images and RTF deferred to v2.1)
- [ ] **RD-CLIP-04**: iOS "App pasted from clipboard" privacy banner is expected behavior and documented in first-run UX

### Security

- [ ] **RD-SEC-01**: TCP channels encrypted with TLS 1.3 via Network.framework
- [ ] **RD-SEC-02**: UDP media channel encrypted with DTLS via Network.framework
- [ ] **RD-SEC-03**: Initial pairing via QR code (Mac displays, iPad scans) with ECDH key exchange (reuse keyd v1.0 pattern with new bundle IDs)
- [ ] **RD-SEC-04**: Certificate pinning after initial pairing (reject unknown certs)
- [ ] **RD-SEC-05**: No cleartext mode — encryption mandatory even over USB

### Performance

- [ ] **RD-PERF-01**: Glass-to-glass latency <8ms over wired (LZ4+delta path)
- [ ] **RD-PERF-02**: Glass-to-glass latency <25ms over wireless (HEVC path)
- [ ] **RD-PERF-03**: Mac agent CPU usage <3% during wired streaming
- [ ] **RD-PERF-04**: Mac agent RSS <50 MB during wired streaming
- [ ] **RD-PERF-05**: Mac agent CPU usage <1% in eco mode
- [ ] **RD-PERF-06**: Mac agent RSS <20 MB in eco mode
- [x] **RD-PERF-07**: Mac agent uses 0% GPU in all modes (no GPU work on Mac side)
- [ ] **RD-PERF-08**: Input-to-screen latency <12ms (input event sent → result visible on iPad)

### Agent

- [ ] **RD-AGENT-01**: macOS agent runs as menu bar app (no dock icon, `LSUIElement` / accessory activation policy)
- [x] **RD-AGENT-02**: macOS agent written in C + Objective-C only (no Swift runtime; target RSS <5 MB baseline)
- [ ] **RD-AGENT-03**: macOS agent starts at login via SMAppService
- [ ] **RD-AGENT-04**: macOS agent prompts for Screen Recording permission via system alert; handles Sequoia re-auth with frame watchdog
- [ ] **RD-AGENT-05**: macOS agent prompts for Accessibility permission (for CGEvent injection)
- [ ] **RD-AGENT-06**: Menu bar shows connection state (USB/Wi-Fi/AWDL/disconnected) and current mode (quality/eco)
- [x] **RD-AGENT-07**: macOS minimum version: 14.2 (required for CoreAudio Tap API)

### iPad App

- [ ] **RD-APP-01**: iPad app displays remote Mac screen at full Retina resolution with P3 color
- [ ] **RD-APP-02**: iPad app shows connection status HUD (transport mode icon, latency ms, FPS counter; togglable)
- [ ] **RD-APP-03**: iPad app provides mode toggle in HUD (full quality / eco)
- [ ] **RD-APP-04**: iPad app supports landscape and portrait orientation (letterbox or scale-to-fit)
- [ ] **RD-APP-05**: iPad app supports iPad Pro 11" and 13" screen sizes
- [x] **RD-APP-06**: iPadOS minimum version: 17.0 (required for `CAMetalDisplayLink`)
- [ ] **RD-APP-07**: iPad system edge swipes are NOT intercepted (respected as system gestures)

### Testing

- [ ] **RD-TEST-01**: Protocol-level unit tests: known bytes in → framed → deframed → bitwise verify (pure C, no device needed)
- [ ] **RD-TEST-02**: Compression roundtrip tests: synthetic frames → LZ4 compress → decompress → bitwise identical; delta XOR → apply → identical (pure C)
- [ ] **RD-TEST-03**: Throughput benchmarks: measure actual Gbps over each transport (USB NCM, Wi-Fi), report P50/P99
- [ ] **RD-TEST-04**: Latency benchmarks: timestamped ping-pong over each transport, report P50/P99/P999 RTT
- [ ] **RD-TEST-05**: Loopback tests run on single machine (`lo0`) for CI — no hardware required
- [ ] **RD-TEST-06**: E2E device tests: full pipeline (capture → compress → send → recv → decompress → render) with deterministic synthetic frames across 2 physical devices
- [ ] **RD-TEST-07**: Failover tests: kill USB mid-stream → verify seamless Wi-Fi takeover within 2 seconds
- [ ] **RD-TEST-08**: Input roundtrip tests: send known input → verify CGEvent injection → verify ack
- [ ] **RD-TEST-09**: Both devices use same PRNG seed for deterministic payloads — each side knows exactly what the other should send and receive
- [ ] **RD-TEST-10**: Benchmark results saved to JSON for regression tracking across runs

## v2.1 Requirements

Deferred to next milestone. Tracked but not in current roadmap.

### Input (deferred)

- **RD-INPUT-11**: Trackpad input mode (relative mouse movement as alternative to direct touch, toggle via HUD button)

### Display (deferred)

- **RD-DISP-01**: Multi-monitor support — user selects which Mac display to capture
- **RD-DISP-02**: Pinch-to-zoom viewport with persistent zoom level

### Clipboard (deferred)

- **RD-CLIP-05**: Clipboard sync supports images (PNG, JPEG)
- **RD-CLIP-06**: Clipboard sync supports RTF formatted text

### Audio (deferred)

- **RD-AUDIO-06**: Audio routing from iPad microphone to Mac input

## Out of Scope

| Feature | Reason |
|---------|--------|
| Bluetooth transport | 3 Mbps insufficient for 4K screen streaming |
| Cloud relay / internet remote access | Different product category; requires server infrastructure |
| App Store distribution | Personal use, self-signed only |
| File drag-and-drop | Requires virtual filesystem protocol; clipboard covers most transfer needs |
| iPad C client rewrite | Separate milestone (v2.2) after Swift V1 is proven |
| HEVC over wired non-eco | Adds latency vs LZ4; HEVC reserved for wireless and eco |
| On-screen virtual joystick | Obstructs remote screen; direct touch is the correct iPad approach |
| Gesture customization panel | Industry-standard mapping is well-established; settings complexity for no gain |
| Virtual audio driver | CoreAudio Tap API eliminates the need for system extensions |
| Opus audio codec | iPadOS lacks native Opus playback; AAC-LC has native hw encode/decode |
| WebRTC | Cloud-oriented framework; unnecessary complexity for direct cable connection |
| usbmuxd for video transport | TCP-only, tunneled; USB NCM gives native UDP at full link speed |
| JSON in data path | ~50x slower than binary framing for the hot path |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| RD-TRANS-01 | Phase 2 | Pending |
| RD-TRANS-02 | Phase 2 | Pending |
| RD-TRANS-03 | Phase 2 | Pending |
| RD-TRANS-04 | Phase 2 | Pending |
| RD-TRANS-05 | Phase 2 | Pending |
| RD-TRANS-06 | Phase 2 | Pending |
| RD-TRANS-07 | Phase 2 | Pending |
| RD-TRANS-08 | Phase 2 | Complete |
| RD-TRANS-09 | Phase 2 | Pending |
| RD-TRANS-10 | Phase 2 | Pending |
| RD-CAP-01 | Phase 2 | Pending |
| RD-CAP-02 | Phase 2 | Pending |
| RD-CAP-03 | Phase 2 | Pending |
| RD-CAP-04 | Phase 2 | Pending |
| RD-CAP-05 | Phase 2 | Pending |
| RD-CAP-06 | Phase 2 | Complete |
| RD-COMP-01 | Phase 2 | Complete |
| RD-COMP-02 | Phase 2 | Pending |
| RD-COMP-03 | Phase 2 | Pending |
| RD-COMP-04 | Phase 2 | Complete |
| RD-COMP-05 | Phase 2 | Pending |
| RD-COMP-06 | Phase 2 | Pending |
| RD-COMP-07 | Phase 2 | Pending |
| RD-COMP-08 | Phase 2 | Pending |
| RD-COMP-09 | Phase 2 | Pending |
| RD-REND-01 | Phase 2 | Pending |
| RD-REND-02 | Phase 2 | Pending |
| RD-REND-03 | Phase 2 | Pending |
| RD-REND-04 | Phase 2 | Pending |
| RD-SEC-01 | Phase 2 | Pending |
| RD-SEC-02 | Phase 2 | Pending |
| RD-SEC-03 | Phase 2 | Pending |
| RD-SEC-04 | Phase 2 | Pending |
| RD-SEC-05 | Phase 2 | Pending |
| RD-AGENT-01 | Phase 2 | Pending |
| RD-AGENT-02 | Phase 2 | Complete |
| RD-AGENT-03 | Phase 2 | Pending |
| RD-AGENT-04 | Phase 2 | Pending |
| RD-AGENT-05 | Phase 2 | Pending |
| RD-AGENT-06 | Phase 2 | Pending |
| RD-AGENT-07 | Phase 2 | Complete |
| RD-APP-01 | Phase 2 | Pending |
| RD-APP-02 | Phase 2 | Pending |
| RD-APP-03 | Phase 2 | Pending |
| RD-APP-04 | Phase 2 | Pending |
| RD-APP-05 | Phase 2 | Pending |
| RD-APP-06 | Phase 2 | Complete |
| RD-APP-07 | Phase 2 | Pending |
| RD-PERF-01 | Phase 2 | Pending |
| RD-PERF-02 | Phase 2 | Pending |
| RD-PERF-03 | Phase 2 | Pending |
| RD-PERF-04 | Phase 2 | Pending |
| RD-PERF-07 | Phase 2 | Complete |
| RD-INPUT-01 | Phase 3 | Pending |
| RD-INPUT-02 | Phase 3 | Pending |
| RD-INPUT-03 | Phase 3 | Pending |
| RD-INPUT-04 | Phase 3 | Pending |
| RD-INPUT-05 | Phase 3 | Pending |
| RD-INPUT-06 | Phase 3 | Pending |
| RD-INPUT-07 | Phase 3 | Pending |
| RD-INPUT-08 | Phase 3 | Pending |
| RD-INPUT-09 | Phase 3 | Pending |
| RD-INPUT-10 | Phase 3 | Pending |
| RD-PERF-05 | Phase 3 | Pending |
| RD-PERF-06 | Phase 3 | Pending |
| RD-PERF-08 | Phase 3 | Pending |
| RD-TEST-01 | Phase 4 | Pending |
| RD-TEST-02 | Phase 4 | Pending |
| RD-TEST-03 | Phase 4 | Pending |
| RD-TEST-04 | Phase 4 | Pending |
| RD-TEST-05 | Phase 4 | Pending |
| RD-TEST-06 | Phase 4 | Pending |
| RD-TEST-07 | Phase 4 | Pending |
| RD-TEST-08 | Phase 4 | Pending |
| RD-TEST-09 | Phase 4 | Pending |
| RD-TEST-10 | Phase 4 | Pending |
| RD-AUDIO-01 | Phase 5 | Pending |
| RD-AUDIO-02 | Phase 5 | Pending |
| RD-AUDIO-03 | Phase 5 | Pending |
| RD-AUDIO-04 | Phase 5 | Pending |
| RD-AUDIO-05 | Phase 5 | Pending |
| RD-CLIP-01 | Phase 5 | Pending |
| RD-CLIP-02 | Phase 5 | Pending |
| RD-CLIP-03 | Phase 5 | Pending |
| RD-CLIP-04 | Phase 5 | Pending |
| RD-REND-05 | Phase 2 | Pending |

**Coverage:**
- v2.0 requirements: 86 total (note: original estimate of 62 was pre-finalization; actual count from file is 86)
- Mapped to phases: 86
- Unmapped: 0

---
*Requirements defined: 2026-03-28*
*Last updated: 2026-03-27 — traceability populated by roadmapper*
