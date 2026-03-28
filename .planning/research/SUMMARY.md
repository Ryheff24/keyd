# Project Research Summary

**Project:** keyd-rd — iPadOS-to-macOS Remote Desktop (v2.0)
**Domain:** Direct-cable remote desktop over USB NCM + Wi-Fi/AWDL fallback
**Researched:** 2026-03-27
**Confidence:** MEDIUM-HIGH

## Executive Summary

keyd-rd is a personal-use remote desktop that streams the Mac display to an iPad over a direct USB-C cable, targeting glass-to-glass latency under 8ms — a bar no commercial product reaches without proprietary hardware. The recommended approach is a purpose-built two-process system: a C+Objective-C macOS agent and a Swift iPadOS app, with no shared binary between them. The hot path runs entirely in C: ScreenCaptureKit delivers `IOSurface`-backed frames, which are XOR-delta-compressed with vendored LZ4 and sent as packed C structs over UDP on the USB NCM interface. The iPad receives, decompresses, and renders via Metal at ProMotion 120Hz. On USB disconnect, the system falls over to Wi-Fi HEVC streaming automatically and silently.

The approach is well-grounded in Apple's own frameworks. All required APIs are publicly available, fully documented, and have confirmed hardware acceleration paths on the target hardware (M1 Max Mac, M4 iPad Pro). The macOS minimum of 14.2 is the only hard constraint, set by the CoreAudio Tap API for system audio capture. Significant reuse is available from keyd v1.0: the QR pairing flow, CGEvent injection patterns, Bonjour/AWDL discovery, transport failover state machine, and menu bar agent shell are all pattern-copies into the new project — not shared binary code, since keyd-rd uses a binary C protocol (not JSON/Swift) and USB NCM transport (not usbmuxd).

The highest-risk area is the ScreenCaptureKit permission lifecycle on macOS Sequoia 15+, which introduced a periodic re-authorization prompt that can silently break unattended capture. This must be handled as a first-class state in Phase 1 and should prompt an Apple entitlement request for `com.apple.developer.screencapture.persist`. The second-highest risk is the correctness of the delta compression pipeline: IOSurface recycling and the delta frame XOR race condition are both silent corruption bugs that require specific data structures (double-buffer reference frames, explicit IOSurface lock lifetime management) from the very start of Phase 1, not as a post-correctness cleanup.

---

## Key Findings

### Recommended Stack

The macOS agent is C + Objective-C only — Swift is explicitly excluded to stay within the <50 MB RSS budget. All necessary Apple frameworks have native C or Objective-C APIs. The iPadOS app is Swift throughout. The only vendored dependency is LZ4 v1.10.0 (two files: `lz4.c` + `lz4.h`, BSD-2-Clause), used in block mode on both sides. Everything else is Apple-native.

See `./.planning/research/STACK.md` for the full version matrix, integration patterns, and "What NOT to Add" justifications.

**Core technologies:**
- **ScreenCaptureKit (SCStream, Obj-C):** Full-display capture at up to 120fps with `IOSurface`-backed CMSampleBuffers and `SCFrameStatusIdle` to skip unchanged frames — only option that achieves zero-copy into the LZ4 pipeline without frame-always delivery.
- **LZ4 v1.10.0 (vendored, block format):** ~8 GB/s compress throughput on M1 Max; <1ms per 4K frame; block API required — not Apple's `Compression.framework`, which uses LZ4 frame format incompatible with the binary protocol design.
- **VideoToolbox (VTCompressionSession / VTDecompressionSession):** HEVC hardware encode on Mac + decode on iPad using dedicated media engines; zero CPU cost; used for wireless mode and eco mode.
- **Network.framework (C API on Mac, Swift API on iPad):** USB NCM interface detection via `nw_path_monitor_create_with_type(nw_interface_type_wired)`, UDP media stream, TCP input stream, TLS 1.3 / DTLS 1.3 enforcement, interface pinning via `NWParameters.requiredInterface`.
- **CoreAudio Tap API (`AudioHardwareCreateProcessTap`, macOS 14.2+):** System audio capture without a virtual audio driver; preferred over SCKit audio capture, which silently fails on macOS 15.
- **Metal + MTKView + CAMetalDisplayLink (iPadOS 17+):** ProMotion 120Hz rendering on iPad with P3 color; `CAMetalDisplayLink` required (not the built-in MTKView timer) for correct adaptive frame pacing.
- **CGEvent (C API, reused from keyd v1.0):** Mouse and keyboard injection; proven against Safari/Firefox; extended with mouse move, scroll, and right-click events for remote desktop use.

**OS floors:** macOS 14.2 (CoreAudio Tap), iPadOS 17.0 (CAMetalDisplayLink precision).

**What NOT to use:** Swift on macOS agent (RSS overhead ~15-30 MB), `Compression.framework` LZ4 (frame format, not block), usbmuxd for video transport (TCP-per-connection, wrong abstraction for UDP streaming), WebRTC (cloud-oriented, unnecessary complexity), Opus codec (requires libopus; AAC-LC built-in is sufficient), ReplayKit (high latency, no IOSurface access), JSON in data path (~50x too slow).

### Expected Features

See `./.planning/research/FEATURES.md` for the full feature dependency graph, MVP definition, and competitive analysis against Sidecar, Luna Display, Duet Display, and Jump Desktop.

**Must have for v2.0 (table stakes + core differentiators):**
- USB NCM wired transport — proves the sub-8ms latency claim
- Wi-Fi / AWDL fallback transport — makes daily use viable without cable
- Screen streaming: LZ4+delta (wired) + HEVC (wireless) — the entire product value
- Metal rendering at full Retina resolution + ProMotion 120Hz + P3 color
- Touch-to-mouse: tap (left click), two-finger scroll, long-press / two-finger-tap (right click), drag
- Physical keyboard passthrough
- On-screen keyboard passthrough (UITextInput with autocorrect suppressed, forward raw keystrokes)
- Automatic USB ↔ Wi-Fi failover (<2 seconds, no user action)
- QR pairing (reuse keyd v1.0 flow — already validated, pattern-copy with new bundle IDs)
- Connection status HUD (transport mode, latency, FPS)
- Eco mode: 1080p/30Hz, HEVC even over wired, <1% Mac CPU, <20 MB RSS
- TLS 1.3 (TCP input stream) + DTLS (UDP media stream) — no cleartext mode
- Deterministic E2E test suite (RD-TEST-01 through RD-TEST-10)
- macOS Screen Recording + Accessibility permission prompts

**Should have for v2.1:**
- Audio streaming (Mac → iPad) — AAC-LC via CoreAudio Tap → UDP → AVAudioEngine
- Clipboard sync (text only, bidirectional) — NSPasteboard polling + UIPasteboard.changedNotification
- Cursor position overlay on iPad — lightweight TCP event, render cursor in Metal; eliminates "where is my cursor?" confusion
- Trackpad input mode (relative movement, alternative to default direct touch)
- Pinch-to-zoom viewport (iPad-side Metal scale transform; does not affect Mac resolution)
- Multi-monitor display selection

**Defer to v2.2+:**
- File drag-and-drop (requires virtual filesystem protocol)
- iPad C client rewrite (Swift v1 adequate for v2.0)
- Clipboard images and RTF
- Audio routing from iPad microphone to Mac

**Anti-features to avoid:** Bluetooth transport (3 Mbps insufficient for 4K), cloud relay (different product category), HEVC over USB wired non-eco (adds latency vs LZ4), on-screen virtual joystick (obstructs screen), gesture customization panel (adds settings complexity with no standard need), virtual audio driver (requires user-installed system extension).

**Touch input defaults:** Direct Touch as default (tap = absolute click at touched position), Trackpad mode as selectable alternative via HUD button. Standard gesture map: single tap = left click, two-finger tap = right click, long press = right click, two-finger pan = scroll, pinch = viewport zoom (iPad-side only). System edge swipes must NOT be intercepted.

### Architecture Approach

Two separate Xcode projects (`RemoteDesktop/macOS/` and `RemoteDesktop/iPadOS/`) with a `RemoteDesktop/Shared/` directory of C headers and vendored C source consumed by both via their respective include paths. No shared Swift Package, no xcworkspace, no xcframework. The hot path on the Mac is pure C to minimize runtime overhead at 120Hz; Obj-C wrappers handle the Apple framework integration around that core.

See `./.planning/research/ARCHITECTURE.md` for the full component diagram, project structure, and implementation patterns with code sketches.

**Major components (macOS agent, C + Objective-C):**
1. **ScreenCapture.m** — SCStream setup and delegate callback; extracts IOSurface from CMSampleBuffer and hands off to FrameCompressor
2. **FrameCompressor.c** — Delta XOR computation, LZ4 compress, keyframe/delta decision, 24-byte header pack; pure C, called at up to 120Hz
3. **HEVCEncoder.m** — VTCompressionSession for wireless and eco mode; activated by transport failover state machine
4. **USBNetworkTransport.m** — NWPathMonitor for USB NCM detection, NWListener UDP (media out) + TCP (input in)
5. **WirelessTransport.m** — NWBrowser for `_keydrd._tcp`, NWConnection UDP + TCP over Wi-Fi/AWDL
6. **EventInjector.c** — CGEvent mouse + keyboard injection; pure C; direct reuse from keyd v1.0
7. **main.m** — NSApplication accessory policy, NSStatusItem, SMAppService, permission prompts, agent startup sequence

**Major components (iPadOS app, Swift):**
1. **USBNetworkTransport.swift** — NWPathMonitor `.wiredEthernet` detection, NWConnection UDP recv (media) + TCP send (input)
2. **WirelessTransport.swift** — NWBrowser connect, NWConnection for Wi-Fi/AWDL
3. **LZ4Decompressor.swift** — lz4.c wrapper via bridging header; decompress + XOR delta apply
4. **HEVCDecoder.swift** — VTDecompressionSession, CMSampleBuffer → CVPixelBuffer
5. **MetalRenderer.swift + Shaders.metal** — MTKView delegate, BGRA texture upload, P3 fragment shader, CAMetalDisplayLink render loop, triple buffering
6. **TouchToMouse.swift** — UIGestureRecognizer → input event structs, 120Hz poll with adaptive batching, TCP send
7. **KeyboardCapture.swift** — UITextInput / hardware keyboard intercept → key event structs; autocorrect suppressed
8. **QRPairing.swift** — AVCapture QR scan, ECDH key exchange; pattern from keyd v1.0

**Shared (C only, consumed by both projects):**
- `protocol.h` — `MediaFrameHeader` (24 bytes, `__attribute__((packed))`) + `InputEventHeader` (9 bytes)
- `lz4.c` + `lz4.h` — vendored LZ4 v1.10.0 (block API only)
- `delta.c` / `delta.h` — XOR delta: `compute_delta()`, `apply_delta()`

**Key patterns:**
- USB NCM interface detection: `nw_path_monitor_create_with_type(nw_interface_type_wired)` — never hardcode interface names (en4/en5/en6 vary by system and connection order)
- Zero-copy frame path: `IOSurfaceLock` → base address pointer → `LZ4_compress_default` → `IOSurfaceUnlock`; hold `CMSampleBuffer` retain for entire compress duration
- Binary protocol: `__attribute__((packed))` C structs; both sides are ARM64 little-endian; iPad reads via `withUnsafeBytes`
- Pixel format: `kCVPixelFormatType_32BGRA` throughout — matches Metal texture upload format, no color conversion step
- SCStreamConfiguration: `queueDepth = 3`, `minimumFrameInterval = CMTimeMake(1, 120)`, `pixelFormat = kCVPixelFormatType_32BGRA`
- Transport failover FSM: USB NCM primary → Wi-Fi fallback → AWDL last resort (mirrors keyd v1.0 FSM pattern)
- Double-buffer reference frames for delta compression — atomically swapped, protected by `pthread_rwlock_t`

### Critical Pitfalls

See `./.planning/research/PITFALLS.md` for full pitfall documentation with warning signs and integration gotchas.

1. **ScreenCaptureKit monthly re-authorization on macOS Sequoia 15+** — SCStream silently stops delivering frames when the periodic re-authorization lapses; returns `SCStreamError` -3805 or produces zero frame callbacks. Apply for `com.apple.developer.screencapture.persist` entitlement (the VNC-class entitlement Jump Desktop uses); add a frame-delivery watchdog (0 frames for >2 seconds → menu bar re-auth prompt). Handle permission delays (3-10 second startup block) by calling `SCShareableContent` on a background queue with a 5-second timeout. Must address in Phase 1.

2. **Link-local IPv6 requires explicit interface binding on both sides** — Connecting to `fe80::` without pinning to the specific `NWInterface` object from `NWPathMonitor` produces a silent `.failed` connection. Mac C side: set `sin6_scope_id = if_nametoindex(interface_name)`. iPad Swift side: pass the exact `NWInterface` from the path to `NWParameters.requiredInterface`. Write a minimal two-device UDP loopback test on USB NCM before any pipeline work. Must address in Phase 1.

3. **IOSurface recycling corrupts in-flight LZ4 compression** — When `CMSampleBuffer` is released, the backing `IOSurface` returns to the ScreenCaptureKit pool immediately. If LZ4 runs on a background thread and the sample buffer was released on the capture thread first, the pointer is dangling. Hold `CMSampleBuffer` retain for the entire duration of `LZ4_compress_default`; use `IOSurfaceLock`/`IOSurfaceUnlock` around the compress call. Must address in Phase 1.

4. **Delta frame XOR race condition on reference frame buffer** — If the keyframe writer updates the reference buffer while a delta frame reads it, the XOR produces garbage and the decoder state diverges permanently. Use double-buffer reference frames with `pthread_rwlock_t`; atomically swap only after keyframe is fully compressed and sent. Must address in Phase 1.

5. **ProMotion 120Hz requires explicit opt-in** — Without `CADisableMinimumFrameDuration = YES` in Info.plist, the system clamps all CADisplayLink-based rendering to 60Hz even with `preferredFramesPerSecond = 120`. Use `CAMetalDisplayLink` (not the built-in MTKView timer) and triple buffering (3 drawables). Must address in Phase 2.

6. **VideoToolbox low-latency HEVC incompatible with ConstantBitRate** — Setting both `EnableLowLatencyRateControl` and `ConstantBitRate` causes one to be silently ignored (typically the bitrate constraint), flooding the Wi-Fi channel. Use `AverageBitRate` only with low-latency mode. Verify actual output rate experimentally before declaring Wi-Fi mode operational. Must address in Phase 3.

7. **CoreAudio Tap preferred over SCKit audio on macOS 15** — SCKit `capturesAudio = true` silently produces no callbacks on macOS 15. Use `AudioHardwareCreateProcessTap` (CoreAudio Tap, macOS 14.2+) as the primary audio path. Must address in Phase 4.

---

## Implications for Roadmap

Based on research, the feature dependencies, component build-order constraints, and pitfall phase assignments, a 4-phase structure is strongly indicated.

### Phase 1: Foundation — Capture, Compression, and USB Transport

**Rationale:** Screen streaming is the entire premise. Without it there is no product. The LZ4+delta pipeline on USB NCM is the core technical differentiator and the highest-risk implementation area. All four critical correctness pitfalls (SCKit re-auth, link-local binding, IOSurface recycling, delta race condition) live here and must be addressed before any other work begins. Testing in isolation before adding Wi-Fi complexity is mandatory — USB is deterministic (cable in = connected), Wi-Fi adds peer-discovery non-determinism.

**Delivers:** Mac screen displayed on iPad over USB cable at full Retina resolution with correct LZ4+delta compression, zero frame corruption, ProMotion 120Hz Metal rendering, and automatic Wi-Fi/AWDL fallback on USB unplug.

**Features addressed:**
- USB NCM wired transport
- Wi-Fi / AWDL fallback transport
- Screen streaming: LZ4+delta (wired) + HEVC encode/decode (wireless fallback)
- Metal rendering: Retina resolution, ProMotion 120Hz, P3 color
- Automatic USB ↔ Wi-Fi failover
- QR pairing (reuse keyd v1.0 pattern)
- TLS 1.3 + DTLS encryption
- Connection status HUD
- macOS Screen Recording + Accessibility permission prompts
- SMAppService login item

**Pitfalls to address in this phase:** Pitfall 1 (SCKit re-auth on Sequoia), Pitfall 2 (link-local binding), Pitfall 3 (IOSurface recycling), Pitfall 4 (delta race), Pitfall 5 (ProMotion opt-in), Pitfall 8 (SCKit startup block), Pitfall 9 (Local Network permission), Pitfall 10 (NWPathMonitor false positives on multi-adapter setups), Pitfall 12 (SMAppService registration), Pitfall 13 (LZ4 block vs frame API mismatch).

**Research flag:** Needs `research-phase` during planning for two items: (1) USB NCM interface detection and link-local socket binding on iPadOS — confirmed viable via Apple Developer Forum reports but no canonical Apple sample code for the iPad↔Mac direct-cable scenario; (2) `com.apple.developer.screencapture.persist` entitlement request process for self-signed personal-use apps.

### Phase 2: Input — Touch, Keyboard, and Eco Mode

**Rationale:** A display with no input is a monitor, not a remote desktop. Input is the next dependency in the feature tree after screen streaming is proven stable. Eco mode belongs here because it is a configuration layer on top of the already-working HEVC encode path (used by wireless mode in Phase 1), and it is required by the project spec — the Mac must remain usable for concurrent LLM inference.

**Delivers:** Full touch-to-mouse control (tap, scroll, right-click, drag), keyboard passthrough (hardware + on-screen), eco mode (1080p/30Hz HEVC, <1% Mac CPU).

**Features addressed:**
- Touch-to-mouse: direct touch mode (default), scroll, right-click, drag
- Physical keyboard passthrough
- On-screen keyboard passthrough (UITextInput, autocorrect suppressed, raw keystrokes)
- Eco mode (1080p or 720p / 30fps / HEVC even over wired)
- Trackpad input mode (alternative selectable via HUD)

**Pitfalls to address in this phase:** Pitfall 11 (CGEvent injection rate at 120Hz — adaptive event batching from start; never drop clicks or key events), Pitfall 14 (touch coordinate affine transform with Retina scaling + aspect ratio letterboxing — exchange Mac display geometry in session handshake).

**Research flag:** Standard patterns; well-documented CGEvent and UIGestureRecognizer APIs with proven keyd v1.0 precedent. No `research-phase` needed.

### Phase 3: Test Validation and Wi-Fi Quality

**Rationale:** Before adding further features, the E2E test suite must validate correctness of the core pipeline without requiring physical visual verification. The deterministic test suite (both devices using the same PRNG seed) was specified from the start and validates the full pipeline including delta frame correctness, chunk reassembly, and failover behavior. This phase also includes experimental validation of VideoToolbox HEVC bitrate control on the Wi-Fi path, which cannot be validated analytically.

**Delivers:** Deterministic E2E test suite passing end-to-end; Wi-Fi/HEVC path validated at full quality under real-world conditions; cursor overlay on iPad (lightweight addition, high UX value, removes a major friction point).

**Features addressed:**
- Deterministic E2E test suite (RD-TEST-01 through RD-TEST-10)
- Wi-Fi/AWDL HEVC path at full quality (60fps)
- Cursor position overlay on iPad (Mac sends cursor position via TCP; Metal renders overlay)

**Pitfalls to address in this phase:** Pitfall 6 (VideoToolbox HEVC bitrate control — measure actual output rate before declaring Wi-Fi mode complete).

**Research flag:** Standard patterns; no `research-phase` needed.

### Phase 4: Audio and Clipboard

**Rationale:** Audio and clipboard are genuinely independent of each other and of the compression/rendering pipeline. They share the TCP control channel established in Phase 1 but add no dependencies to earlier phases. Audio is the higher-value addition (video content on Mac becomes usable on iPad); clipboard is moderate complexity with well-understood platform APIs on both sides.

**Delivers:** System audio streaming from Mac to iPad (all processes via CoreAudio Tap → AAC-LC encode → UDP stream → AVAudioEngine decode), bidirectional text clipboard sync.

**Features addressed:**
- Audio streaming Mac → iPad: CoreAudio Tap, AAC-LC via AudioConverter, AVAudioEngine playback
- Clipboard sync: text only, bidirectional; NSPasteboard polling (Mac) + UIPasteboard.changedNotification (iPad)

**Pitfalls to address in this phase:** Pitfall 7 (SCKit audio silent failure on macOS 15 — use CoreAudio Tap API exclusively as primary capture path).

**Research flag:** CoreAudio Tap API is new (macOS 14.2) and described as "poorly documented" in community resources. Needs `research-phase` during planning — study `AudioCap` open-source project (insidegui/AudioCap GitHub) as the reference implementation before writing any audio capture code.

### Phase Ordering Rationale

- Screen streaming must come first: it is the single dependency that everything else requires. Input without screen is injecting into the void. Audio without screen is incomplete. Tests without working core pipeline are testing nothing.
- Input must follow rendering because coordinate mapping requires the render viewport dimensions and a live display feed to verify cursor alignment is correct.
- E2E test suite comes before audio/clipboard because shipping additional features on top of an unvalidated core pipeline creates compounding correctness debt.
- Audio and clipboard are last because they are genuinely independent and add no dependency risk to earlier phases; their most complex aspect (CoreAudio Tap) is a bounded integration problem that benefits from the team having deep familiarity with the codebase.

### Research Flags

Needs `research-phase` during planning:
- **Phase 1:** USB NCM interface detection and link-local socket binding on iPadOS — confirmed viable from forum reports but no canonical Apple sample code for the iPad↔Mac direct-cable peer scenario. Write a minimal loopback test (UDP ping-pong over USB NCM) before any pipeline work.
- **Phase 1:** `com.apple.developer.screencapture.persist` entitlement request process for a self-signed non-App-Store personal-use app — whether Apple approves this for personal use is unknown; the fallback (manual re-authorization flow in menu bar) must be designed in Phase 1 regardless.
- **Phase 4:** CoreAudio Tap API (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`) — new API (macOS 14.2), poor documentation; study `insidegui/AudioCap` before planning audio work.

Standard patterns (skip `research-phase`):
- **Phase 2:** CGEvent injection, UIGestureRecognizer, UITextInput — well-documented, proven in keyd v1.0 and industry practice.
- **Phase 2/3:** QR pairing + ECDH — fully pattern-reused from keyd v1.0 with validated code.
- **Phase 3:** E2E test structure — standard XCTest + pure C unit test patterns.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Core Apple APIs (ScreenCaptureKit, VideoToolbox, Network.framework, Metal, CGEvent) verified via official docs, WWDC sessions, and open-source projects. LZ4 v1.10.0 license and vendoring confirmed on GitHub. One MEDIUM item: SCKit SCFrameStatus Obj-C variant confirmed via search but not directly viewable. |
| Features | MEDIUM-HIGH | Commercial solution analysis from official product pages and developer forums. Technical feature claims cross-referenced against Apple docs. USB NCM `.wiredEthernet` classification confirmed via Apple Developer Forum thread 769793. iOS clipboard privacy banner behavior confirmed as Apple-mandated and unavoidable since iOS 14. |
| Architecture | MEDIUM-HIGH | Core APIs confirmed HIGH confidence. USB NCM interface name non-determinism (en4/en5/en6) confirmed — always use NWPathMonitor type detection. DTLS in Network.framework confirmed HIGH. Sequoia re-authorization behavior documented from developer forum reports and Jump Desktop precedent. |
| Pitfalls | MEDIUM-HIGH | All pitfalls verified against Apple Developer Forums, official docs, WWDC sessions, or open-source implementations. IOSurface recycling and delta race are architecture-level findings with clear prevention patterns. VideoToolbox low-latency + CBR incompatibility confirmed via WWDC21 session and developer forum reports. |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **USB NCM viability on specific iPad-to-Mac direct-cable configuration:** Confirmed viable via forum reports that USB NCM creates a `.wiredEthernet` interface accessible to iPadOS apps, but fewer confirmed reports exist for the iPad↔Mac peer scenario specifically (vs USB Ethernet adapter scenarios). Resolution: write a one-file loopback test (UDP ping-pong over USB NCM) as the first implementation task in Phase 1 before committing to the full pipeline.
- **`com.apple.developer.screencapture.persist` for personal-use self-signed apps:** Jump Desktop uses this entitlement. Whether Apple approves it for a self-signed non-App-Store personal-use app is undocumented. Design the fallback (menu bar re-auth prompt, frame watchdog) in Phase 1 regardless of entitlement status.
- **NWInterface scope ID + link-local IPv6 on both sides with USB NCM:** The Mac C approach (`sin6_scope_id = if_nametoindex(...)`) and iPad Swift approach (`NWParameters.requiredInterface` with exact NWInterface object) are well-known patterns but have not been tested specifically with the M1 Max + M4 iPad direct-cable configuration. Validate in Phase 1 loopback test.
- **VideoToolbox HEVC AverageBitRate effectiveness on Apple Silicon hardware encoder:** The `AverageBitRate` + `EnableLowLatencyRateControl` combination behavior requires experimental verification during Phase 3 — the hardware encoder may silently ignore bitrate constraints.

---

## Sources

### Primary (HIGH confidence)
- Apple developer.apple.com documentation — ScreenCaptureKit, Network.framework (C API), VideoToolbox, CoreAudio Tap API, Metal/MTKView, IOSurface, CGEvent, NSPasteboard, UIPasteboard, CAMetalDisplayLink
- LZ4 v1.10.0 — github.com/lz4/lz4 lib/README.md — vendoring pattern, block vs frame API distinction, BSD-2 license
- Network.framework C API headers — xybp888/iOS-SDKs (macOS 14 SDK), `nw_path_monitor_t`, `nw_tls_create_options`
- CoreAudio Tap API — developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

### Secondary (MEDIUM confidence)
- Apple Developer Forum thread 769793 — USB NCM `.wiredEthernet` classification in NWPathMonitor on iPadOS
- Apple Developer Forum thread 763426 — `CAMetalDisplayLink` 120Hz + `CADisableMinimumFrameDuration` requirement
- insidegui/AudioCap GitHub — CoreAudio Tap reference implementation
- OBS Studio PR #11896 — ScreenCaptureKit 120fps on M1 Max, macOS 15.3.1
- WWDC21 VideoToolbox session — `EnableLowLatencyRateControl` + rate control property interactions
- Jump Desktop support documentation — input mode documentation (direct touch / trackpad / pointer modes)
- Astropad/Luna Display product pages, Duet Display product pages — competitive analysis
- Apple Community forum threads — Sidecar AWDL latency reports
- makeusabrew/audiotee, sudara AudioCap gist — CoreAudio Tap usage confirmation
- REMOTE-DESKTOP-SPEC.md + PROJECT.md — project-internal latency and resource budget targets

### Tertiary (LOW confidence — validate during implementation)
- USB NCM specific iPad↔Mac direct peer-to-peer scenario — fewer confirmed reports than general wiredEthernet adapter use cases; validate with loopback test in Phase 1
- `com.apple.developer.screencapture.persist` approval process for self-signed non-App-Store apps — no public documentation
- VideoToolbox AverageBitRate effectiveness on Apple Silicon hardware encoder specifically — known developer forum issue, not officially documented

---

*Research completed: 2026-03-27*
*Ready for roadmap: yes*
