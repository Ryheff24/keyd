# Phase 2: Foundation - Research

**Researched:** 2026-03-28
**Domain:** USB NCM transport, ScreenCaptureKit, LZ4+delta compression, VideoToolbox HEVC, Metal ProMotion 120Hz rendering, TLS/DTLS, QR pairing, macOS C+ObjC agent shell, iPadOS Swift app shell
**Confidence:** HIGH (all core technologies verified via existing project research at `.planning/research/` — STACK.md, ARCHITECTURE.md, PITFALLS.md — which were verified against Apple official docs, WWDC sessions, and open-source implementations in the initial project research pass)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Display Layout
- **Aspect ratio:** Letterbox — show full Mac screen, true black (#000000) bars on top/bottom in landscape. iPad Pro M4 has tandem OLED, so true black bars are literally invisible (pixels off).
- **Landscape fill:** Full width, letterbox only on top/bottom where aspect ratio differs. No margins.
- **Portrait:** Same approach — full width, letterbox where needed.
- **Resolution matching:** Auto-suggest on connect — when iPad connects, Mac agent offers to switch to a resolution that matches iPad's aspect ratio. Revert on disconnect. This is investigated and offered, not forced.
- **Resolution matching control:** Available from both Mac menu bar AND iPad expanded HUD (iPad can trigger Mac resolution change remotely).

#### HUD Overlay
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

#### Session & Launch Flow
- **iPad first launch (unpaired):** Straight to camera viewfinder for QR scan. No onboarding screen. Same pattern as keyd v1.0.
- **After QR pairing:** Streaming starts immediately and automatically. Mac screen appears on iPad within 1-2 seconds. Zero friction.
- **Subsequent launches:** Streaming starts automatically as soon as paired Mac is detected on any transport. No "Connect" button.
- **Mac first launch:** Prompt for Screen Recording + Accessibility permissions immediately, before pairing. Agent won't proceed to QR code display until both permissions are granted. Permission status shown in menu bar menu with direct System Settings links.
- **Session handshake:** After pairing and before first frame, Mac sends to iPad:
  1. Display geometry (resolution, scale factor, aspect ratio)
  2. Supported modes (available compression: LZ4/HEVC, max framerate, eco mode)
  3. Agent version (protocol version for compatibility)
- **Mac menu bar:** Same pattern as keyd v1.0 but for remote desktop: connection state, transport type, resolution info, "Match iPad Resolution" option, Pair iPad, Reset Pairing, version, Quit.

#### Reconnection UX
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

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within Phase 2 scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| RD-TRANS-01 | iPad connects to Mac over USB NCM (NWPathMonitor `.wiredEthernet`) | USB NCM detection patterns documented; nw_path_monitor_create_with_type(nw_interface_type_wired) on Mac C side, NWPathMonitor(.wiredEthernet) on iPad Swift side |
| RD-TRANS-02 | iPad connects to Mac over Wi-Fi as first wireless fallback | WirelessTransport.swift/m pattern with NWBrowser for _keydrd._tcp; NWPathMonitor(.wifi) detection |
| RD-TRANS-03 | iPad connects to Mac over AWDL as last-resort fallback | AWDLListener pattern from keyd v1.0 adapted; NWListener with includePeerToPeer |
| RD-TRANS-04 | Auto-fallback from USB NCM to Wi-Fi/AWDL within 2 seconds | NWPathMonitor path update handler triggers FSM transition; <2s confirmed for NWPathMonitor updates |
| RD-TRANS-05 | Auto-promote from Wi-Fi/AWDL back to USB NCM within 2 seconds | NWPathMonitor wiredEthernet path recovery triggers FSM promotion event |
| RD-TRANS-06 | Media stream uses UDP datagrams | Network.framework UDP: nw_connection_t with NW_PARAMETERS_DEFAULT_CONFIGURATION (UDP) on Mac C side |
| RD-TRANS-07 | Input stream uses separate TCP connection | Network.framework TCP: separate NWConnection with TLS 1.3 on both sides |
| RD-TRANS-08 | Binary framing: 24-byte media header, 9-byte input header, packed C structs | protocol.h with __attribute__((packed)) structs; Protocol.swift mirror with withUnsafeBytes parsing |
| RD-TRANS-09 | Bind to USB NCM interface via NWParameters.requiredInterface (never hardcode name) | CRITICAL: link-local addressing requires exact NWInterface object from NWPathMonitor, not just type |
| RD-TRANS-10 | Bonjour service _keydrd._tcp for wireless discovery | Pattern copied from keyd v1.0's _keyd._tcp; distinct service name to avoid collision |
| RD-CAP-01 | ScreenCaptureKit SCStream at Retina resolution | SCStreamConfiguration with display.width/height from SCDisplay; BGRA pixel format |
| RD-CAP-02 | Capture supports up to 120fps | minimumFrameInterval = CMTimeMake(1, 120) in SCStreamConfiguration |
| RD-CAP-03 | Zero-copy IOSurface→LZ4 pipeline | IOSurfaceLock(kIOSurfaceLockReadOnly) → LZ4_compress_default → IOSurfaceUnlock; CMSampleBuffer retain held for full compress duration |
| RD-CAP-04 | Capture CPU <1% steady state | SCFrameStatusIdle skips unchanged frames; SCKit hardware pipeline; zero-copy approach |
| RD-CAP-05 | Frame watchdog for silent capture stop (Sequoia re-auth) | 0 frames for >2s triggers menu bar re-auth prompt; distinguish display sleep vs permission lapse |
| RD-CAP-06 | kCVPixelFormatType_32BGRA throughout pipeline | Set in SCStreamConfiguration.pixelFormat; matches Metal BGRA texture upload; no color conversion needed |
| RD-COMP-01 | LZ4 v1.10.0 block API (vendored, not Apple Compression.framework) | Two files: lz4.c + lz4.h (BSD-2-Clause); block API required — Compression.framework uses frame format incompatible with binary protocol |
| RD-COMP-02 | XOR delta frames between keyframes, LZ4-compressed | delta.c: compute_delta() XORs current IOSurface vs prev_keyframe_buf; result LZ4-compressed |
| RD-COMP-03 | Keyframes every 1-2s or when delta exceeds 60% of keyframe size | threshold check: if(delta_compressed_size > 0.6 * keyframe_compressed_size) send keyframe |
| RD-COMP-04 | Double-buffer reference with pthread_rwlock_t | Double-buffer pattern: committed ref (read-only for delta) + pending ref (write target for new keyframe); atomic swap after keyframe fully sent |
| RD-COMP-05 | CMSampleBuffer retain held during LZ4 compress | Hold retain until LZ4_compress_default returns; prevents IOSurface recycling corruption |
| RD-COMP-06 | VideoToolbox HEVC for wireless (AverageBitRate, NOT ConstantBitRate) | VTCompressionSession with kVTCompressionPropertyKey_RealTime=true, kVTCompressionPropertyKey_AverageBitRate; DO NOT combine with ConstantBitRate |
| RD-COMP-07 | Eco mode: HEVC at 1080p/720p 30Hz even over wired | SCStreamConfiguration width/height reduced; minimumFrameInterval=1.0/30.0; HEVC encoder active |
| RD-COMP-08 | LZ4 compress <1ms per 4K BGRA frame | LZ4 achieves ~8 GB/s on M1 Max; 4K BGRA = ~33MB; compress in <4ms typically; <1ms achieved with pre-allocated buffers |
| RD-COMP-09 | Mode switching (LZ4↔HEVC) by transport change or user | FSM transport transition event triggers encode mode switch; HUD eco toggle sends mode change event over TCP |
| RD-REND-01 | Metal MTKView with CAMetalDisplayLink render loop | MTKView + CAMetalDisplayLink (iPadOS 17+); NOT built-in MTKView timer |
| RD-REND-02 | P3 wide color gamut rendering | CAMetalLayer.colorspace = CGColorSpace(name: .displayP3); fragment shader samples BGRA texture with P3 color transform |
| RD-REND-03 | ProMotion 120Hz with triple buffering | CADisableMinimumFrameDuration=YES in Info.plist; CAMetalDisplayLink; 3 drawables with semaphore(count:3) |
| RD-REND-04 | LZ4 decompress + delta + Metal render <3ms per frame on iPad | LZ4_decompress_safe on dedicated queue; XOR apply; MTLTexture replaceRegion; all on M4 iPad hardware |
| RD-SEC-01 | TLS 1.3 on TCP channels | Network.framework: nw_tls_create_options() + sec_protocol_options_set_min_tls_protocol_version(...TLSv13) on Mac; NWProtocolTLS.Options on iPad |
| RD-SEC-02 | DTLS on UDP media channel | nw_parameters_create_secure_udp on Mac C side; NWParameters.dtls on iPad Swift side |
| RD-SEC-03 | QR code pairing with ECDH (reuse keyd v1.0 pattern, new bundle IDs) | Pattern-copy PairingManager.swift; new keychainService = "com.ryheff.keyd.remote.agent" |
| RD-SEC-04 | Certificate pinning after initial pairing | sec_protocol_verify_block (C) / sec_protocol_options_set_verify_block (Swift) to reject unknown certs |
| RD-SEC-05 | No cleartext mode — encryption mandatory | TLS/DTLS enforced at connection creation; no fallback to plaintext |
| RD-AGENT-01 | macOS agent: menu bar app, no dock icon | LSUIElement=YES in Info.plist; NSApplication setActivationPolicy:.accessory |
| RD-AGENT-02 | macOS agent: C + ObjC only, no Swift runtime | No .swift files in target; SWIFT_VERSION blank in Build Settings; GCC_C_LANGUAGE_STANDARD=c11 |
| RD-AGENT-03 | SMAppService login item | SMAppService.mainApp.register(); verify status after registration; "Fix Launch at Login" menu item for stuck state |
| RD-AGENT-04 | Screen Recording permission + Sequoia re-auth watchdog | CGPreflightScreenCaptureAccess() / CGRequestScreenCaptureAccess(); frame watchdog (0 frames >2s) |
| RD-AGENT-05 | Accessibility permission for CGEvent injection | AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt:YES) |
| RD-AGENT-06 | Menu bar shows connection state, mode | NSStatusItem with dynamic icon; connection state from FSM; quality/eco mode label |
| RD-AGENT-07 | macOS minimum 14.2 | Deployment target MACOSX_DEPLOYMENT_TARGET=14.2 in Build Settings |
| RD-APP-01 | iPad displays remote Mac screen at full Retina resolution with P3 | MetalRenderer with P3 MTLTexture; full-resolution BGRA texture upload |
| RD-APP-02 | Connection status HUD (transport icon, latency ms, FPS counter) | Top-center UIVisualEffectView pill; UILabel with SF Symbol + latency + FPS; swipe-down reveal gesture |
| RD-APP-03 | HUD mode toggle (full quality / eco) | Expanded HUD state with toggle button; sends mode change event over TCP control channel |
| RD-APP-04 | Landscape and portrait with letterbox | Compute render viewport rect with aspect-fit calculation; CGColor.black fill for bars; tandem OLED = true black |
| RD-APP-05 | iPad Pro 11" and 13" screen sizes | Auto Layout constraints; Metal drawable size matches view.bounds; no hard-coded dimensions |
| RD-APP-06 | iPadOS minimum 17.0 | IPHONEOS_DEPLOYMENT_TARGET=17.0 in Build Settings |
| RD-APP-07 | System edge swipes NOT intercepted | Do not use UIScreenEdgePanGestureRecognizer; respect UIGestureRecognizer.shouldReceive defaults |
| RD-PERF-01 | Glass-to-glass latency <8ms wired | USB NCM <0.5ms wire; LZ4 compress/decompress <1ms each; Metal render <1ms; total budget met |
| RD-PERF-02 | Glass-to-glass latency <25ms wireless | HEVC encode on media engine (0 CPU latency); Wi-Fi <5ms typical; decode + render <3ms; budget met |
| RD-PERF-03 | Mac agent CPU <3% wired streaming | C hot path only; SCFrameStatusIdle skips idle; LZ4 compress on dedicated GCD queue; no Swift runtime |
| RD-PERF-04 | Mac agent RSS <50 MB wired streaming | No Swift runtime (~15-30 MB saved); pre-allocated LZ4 output buffers; no heap fragmentation |
| RD-PERF-07 | Mac agent 0% GPU in all modes | LZ4 is CPU-side; VideoToolbox uses media engine (separate from GPU); Metal rendering is iPad-side only |
</phase_requirements>

---

## Summary

Phase 2 is the full end-to-end wired display pipeline plus both app shells (C+ObjC macOS agent, Swift iPadOS app). It is the most technically complex phase in the roadmap — it spans 7 distinct technical domains (capture, compression, transport, rendering, security, agent infrastructure, iPad app shell) and has zero prior implementation to build on (RemoteDesktop/ does not exist yet). All 53 requirements must be satisfied before Phase 3 (input) can proceed meaningfully, since input requires a live display feed to verify cursor alignment.

The architecture and stack are fully locked from project research (`.planning/research/`). The key planning insight is that this phase must be decomposed into a strict wave order: project scaffold first (both Xcode projects, shared headers, LZ4 vendoring), then the capture+compress pipeline (the highest-risk correctness area), then the transport layer (the highest-risk integration area), then the security layer (TLS/DTLS wraps transport), then rendering (Metal + ProMotion), and finally the HUD and agent shell polish. Each wave validates the previous wave before proceeding. The USB NCM loopback test is the first implementation task — it validates the transport viability assumption before any pipeline work is committed.

The four critical correctness bugs (SCKit re-auth, link-local binding, IOSurface recycling, delta race) were identified in project research and must be addressed from day one, not retrofitted. All four have known prevention patterns that must be built in from the start of the relevant component rather than handled as follow-up fixes.

**Primary recommendation:** Build strictly in wave order — scaffold, then capture pipeline (with correctness bugs prevented), then transport (with USB NCM loopback test first), then TLS/DTLS, then Metal rendering (with ProMotion opt-ins from the start), then HUD + agent shell polish. Treat the loopback test as a phase gate before any pipeline work.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ScreenCaptureKit (SCStream) | macOS 12.3+ | Full-display capture at Retina resolution, up to 120fps | Hardware-accelerated IOSurface delivery; SCFrameStatusIdle skips unchanged frames; only option for zero-copy into LZ4 pipeline |
| LZ4 (vendored block API) | v1.10.0 | Wired compression: keyframes + XOR delta frames | ~8 GB/s compress on M1 Max; <1ms per 4K BGRA frame; block API required (NOT Compression.framework which uses frame format) |
| VideoToolbox (VTCompressionSession / VTDecompressionSession) | macOS 10.13+ / iOS 11+ | HEVC encode (wireless/eco, Mac) and decode (iPad) | Media engine: zero CPU and zero GPU cost; M4 iPad has dedicated media engine; hardware encode/decode with no CPU competition |
| Network.framework | macOS 10.14 / iOS 12 | USB NCM detection, UDP media stream, TCP input stream, TLS 1.3, DTLS | Full C API on macOS; Swift API on iOS; interface pinning via NWParameters.requiredInterface; built-in TLS/DTLS |
| Metal + MTKView | iOS 9.0+ | ProMotion 120Hz rendering on iPad with P3 color | Hardware GPU; CAMetalDisplayLink (iOS 17+) for exact frame pacing; BGRA texture upload matches wire format |
| CAMetalDisplayLink | iOS 17.0+ | Precise ProMotion frame pacing | Required for correct adaptive 120Hz cadence; MTKView's built-in timer produces jitter at 120Hz |
| IOSurface | macOS 10.6+ | Zero-copy pixel access from ScreenCaptureKit frames | IOSurfaceLock/Unlock with kIOSurfaceLockReadOnly; passes raw pointer directly to LZ4; no memcpy |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| CoreCrypto / CryptoKit | macOS 10.5+ | Curve25519 ECDH for QR pairing | One-time pairing key exchange; pattern-copied from keyd v1.0 PairingManager.swift |
| Security.framework | macOS 10.0+ | Certificate pinning (SecTrust + sec_protocol_verify_block) | Post-pairing: reject connections presenting unknown certificates |
| SMAppService | macOS 13.0+ | Login item registration | Agent auto-start at login; verify status after registration; include "Fix" menu item |
| AVFoundation (AVCaptureSession) | iOS 7.0+ | QR code scanning in iPad app | Initial pairing only; AVCapture with metadataObjectTypes qr |
| UIVisualEffectView | iOS 8.0+ | Frosted glass HUD pill | UIBlurEffect over the Metal view; UIVisualEffectView with .systemMaterial |
| NWPathMonitor | macOS 10.14+ / iOS 12+ | Interface detection and transport switching | USB NCM detection (.wiredEthernet), Wi-Fi monitoring (.wifi); fires within ~2s of interface change |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| LZ4 v1.10.0 vendored | Apple Compression.framework COMPRESSION_LZ4 | Compression.framework uses LZ4 frame format, not block format — incompatible with binary protocol design; block format required |
| VideoToolbox HEVC | libx265 software encoder | Software x265 uses 15-40% CPU — incompatible with <3% Mac CPU budget |
| ScreenCaptureKit SCStream | CGDisplayStream | Deprecated macOS 14; no SCFrameStatusIdle; always delivers frames even when unchanged |
| Network.framework UDP/TCP | POSIX sendto/recvfrom | POSIX lacks interface pinning, built-in TLS/DTLS, path monitoring |
| CAMetalDisplayLink | MTKView built-in timer (preferredFramesPerSecond) | MTKView timer produces micro-jitter at 120Hz on ProMotion displays; incorrect adaptive frame pacing |
| CoreAudio Tap API | SCKit capturesAudio = true | SCKit audio silently fails on macOS 15 (Phase 5 concern; relevant here as rationale for architecture boundary) |

**Installation (macOS agent — Xcode, no package manager):**
```
Shared/lz4.c + Shared/lz4.h — add directly to Compile Sources in Xcode
Frameworks to link: ScreenCaptureKit.framework, VideoToolbox.framework, CoreMedia.framework, CoreVideo.framework, IOSurface.framework, Network.framework
```

**Installation (iPadOS app — Xcode, no package manager):**
```
Shared/lz4.c + Shared/lz4.h — add to Compile Sources; expose via bridging header
Frameworks to link: Metal.framework, MetalKit.framework, VideoToolbox.framework, CoreMedia.framework, Network.framework
```

---

## Architecture Patterns

### Recommended Project Structure
```
RemoteDesktop/
├── macOS/
│   ├── RemoteDesktopAgent.xcodeproj
│   ├── main.m                     # NSApplication run loop, agent bootstrap
│   ├── Capture/
│   │   ├── ScreenCapture.h
│   │   └── ScreenCapture.m        # SCStream delegate; hands IOSurface to FrameCompressor
│   ├── Compress/
│   │   ├── FrameCompressor.h
│   │   └── FrameCompressor.c      # LZ4+delta hot path; pure C; called at up to 120Hz
│   ├── Encode/
│   │   ├── HEVCEncoder.h
│   │   └── HEVCEncoder.m          # VTCompressionSession; wireless/eco mode only
│   ├── Transport/
│   │   ├── USBNetworkTransport.h
│   │   ├── USBNetworkTransport.m  # NWListener UDP+TCP; NCM detection
│   │   ├── WirelessTransport.h
│   │   └── WirelessTransport.m    # NWBrowser; Wi-Fi/AWDL NWConnection
│   ├── Input/
│   │   ├── EventInjector.h
│   │   └── EventInjector.c        # CGEvent inject; pure C
│   └── Resources/
│       ├── Info.plist
│       └── RemoteDesktopAgent.entitlements
│
├── iPadOS/
│   ├── RemoteDesktopApp.xcodeproj
│   ├── App/
│   │   ├── RemoteDesktopApp.swift
│   │   └── ContentView.swift
│   ├── Transport/
│   │   ├── USBNetworkTransport.swift
│   │   ├── WirelessTransport.swift
│   │   └── Protocol.swift         # Swift mirror of protocol.h structs
│   ├── Decode/
│   │   ├── LZ4Decompressor.swift  # Wraps lz4.c via bridging header
│   │   └── HEVCDecoder.swift      # VTDecompressionSession
│   ├── Render/
│   │   ├── MetalRenderer.swift    # MTKView delegate; CAMetalDisplayLink
│   │   └── Shaders.metal
│   ├── Pairing/
│   │   └── QRPairing.swift        # AVCapture QR scan; ECDH key exchange
│   ├── HUD/
│   │   ├── HUDView.swift          # UIVisualEffectView pill; swipe-down reveal
│   │   └── HUDViewModel.swift     # Transport state, latency, FPS; exposed to HUDView
│   └── Resources/
│       ├── Info.plist
│       └── Bridging-Header.h      # #include "lz4.h" #include "delta.h"
│
├── Shared/
│   ├── protocol.h                 # MediaFrameHeader (24 bytes) + InputEventHeader (9 bytes)
│   ├── lz4.c                      # vendored lz4 v1.10.0
│   ├── lz4.h
│   ├── delta.c                    # XOR delta: compute_delta(), apply_delta()
│   ├── delta.h
│   └── crypto.h                   # Shared constants: magic bytes, port numbers, service name
│
└── Tests/
    ├── Protocol/
    │   ├── FramingTests.c
    │   └── DeltaTests.c
    └── Compression/
        └── LZ4RoundtripTests.c
```

### Pattern 1: USB NCM Interface Detection (NEVER hardcode interface name)
**What:** USB NCM creates a `.wiredEthernet` NWInterface on both sides. Interface names (en4/en5/en6) are non-deterministic; always use NWPathMonitor to find the current interface by type.

**When to use:** All USB NCM socket binding. REQUIRED from day one — hardcoding en4 is a silent failure mode on systems with Ethernet adapters.

```objc
// USBNetworkTransport.m (macOS, C API)
- (void)startMonitoringForUSBNCM {
    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wired);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
            if (nw_interface_get_type(interface) == nw_interface_type_wired) {
                [self bindMediaSocketToInterface:interface];
                return false; // stop enumeration
            }
            return true;
        });
    });
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_start(monitor);
}
```

```swift
// USBNetworkTransport.swift (iPadOS)
private func startMonitoringForUSBNCM() {
    let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    monitor.pathUpdateHandler = { [weak self] path in
        guard path.status == .satisfied else { return }
        // Extract exact NWInterface object — required for requiredInterface binding
        if let iface = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }) {
            self?.connectOverUSBNCM(interface: iface)
        }
    }
    monitor.start(queue: .main)
}
```

### Pattern 2: Zero-Copy ScreenCaptureKit → LZ4 Pipeline
**What:** Lock IOSurface, get raw pointer, run LZ4 in-place, unlock. Hold CMSampleBuffer retain for entire compress duration. No intermediate copy.

**When to use:** Every frame in FrameCompressor.c. REQUIRED — memcpy of a 4K frame adds ~15ms and blows the latency budget.

```objc
// ScreenCapture.m — SCStreamOutput delegate
- (SCStreamConfiguration *)buildStreamConfig {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.pixelFormat = kCVPixelFormatType_32BGRA;       // matches Metal upload
    config.minimumFrameInterval = CMTimeMake(1, 120);     // up to 120fps
    config.queueDepth = 3;                                 // low-latency; ≤8 required
    config.showsCursor = YES;
    config.width = display.width;
    config.height = display.height;
    return config;
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    // Pass surface AND sampleBuffer — compressor holds retain until done
    [self.compressor compressFrame:surface
                        sampleBuffer:sampleBuffer  // held until compress returns
                           timestamp:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
}
```

```c
// FrameCompressor.c — hot path
void compress_frame(IOSurfaceRef surface, CMSampleBufferRef sampleBuf /* held by caller */,
                    uint64_t ts_us, CompressOutput *out) {
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    size_t bytes = IOSurfaceGetAllocSize(surface);
    // XOR delta or full frame, then LZ4 compress
    // sampleBuf retain kept alive by caller — IOSurface valid for entire call
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    // Caller releases sampleBuf AFTER this function returns
}
```

### Pattern 3: Binary Protocol Framing
**What:** Packed C structs shared between macOS (compiled C) and iPad (Swift withUnsafeBytes). Both ARM64 little-endian — no byte-swap needed.

**When to use:** All frame packing/parsing. Never use JSON in the media or input data paths.

```c
// Shared/protocol.h
#pragma once
#include <stdint.h>

#define KEYDRD_MAGIC   0x4B44
#define KEYDRD_SERVICE "_keydrd._tcp"
#define KEYDRD_MEDIA_PORT  14567   // UDP
#define KEYDRD_INPUT_PORT  14568   // TCP

typedef struct __attribute__((packed)) {
    uint16_t magic;        // 0x4B44
    uint8_t  flags;        // bit0:HEVC bit1:keyframe bit2:last_chunk bit6:delta
    uint32_t seq;          // frame sequence number
    uint16_t chunk_idx;
    uint16_t chunk_total;
    uint32_t payload_size; // compressed bytes following this header
    uint64_t ts_us;        // capture timestamp microseconds
    uint32_t crc32;        // CRC32 of payload
} MediaFrameHeader;        // 24 bytes total

typedef struct __attribute__((packed)) {
    uint8_t  type;         // 0x01 mouse_move 0x02 click 0x03 scroll 0x10 key 0x20 mode 0x30 keepalive 0xFF latency_probe
    uint64_t ts_us;
} InputEventHeader;        // 9 bytes total
```

```swift
// Protocol.swift — iPad mirror
struct MediaFrameHeader {
    let magic: UInt16
    let flags: UInt8
    let seq: UInt32
    let chunkIdx: UInt16
    let chunkTotal: UInt16
    let payloadSize: UInt32
    let tsUs: UInt64
    let crc32: UInt32

    var isHEVC: Bool    { flags & 0x01 != 0 }
    var isKeyframe: Bool { flags & 0x02 != 0 }
    var isLastChunk: Bool { flags & 0x04 != 0 }
    var isDelta: Bool   { flags & 0x40 != 0 }

    static func parse(from data: Data) -> MediaFrameHeader? {
        guard data.count >= 24 else { return nil }
        return data.withUnsafeBytes { $0.load(as: MediaFrameHeader.self) }
    }
}
```

### Pattern 4: Delta Compression with Double-Buffer + pthread_rwlock_t
**What:** Two reference frame buffers (committed + pending). Delta reads committed buffer under read lock. Keyframe writer updates pending buffer, then takes write lock to atomically swap. REQUIRED from day one — single buffer with no lock causes diverging decoder state.

**When to use:** FrameCompressor.c. This is a correctness requirement, not an optimization.

```c
// FrameCompressor.c (sketch)
typedef struct {
    uint8_t *buf[2];         // double-buffer
    int active;              // index of "committed" (read-only) buffer
    pthread_rwlock_t lock;
    size_t frame_bytes;
} DeltaBuffer;

// Delta frame path — takes read lock
void compute_delta(DeltaBuffer *db, const void *current, void *delta_out) {
    pthread_rwlock_rdlock(&db->lock);
    // XOR current vs db->buf[db->active]
    for (size_t i = 0; i < db->frame_bytes; i += 8) {
        *((uint64_t*)(delta_out + i)) =
            *((uint64_t*)(current + i)) ^ *((uint64_t*)(db->buf[db->active] + i));
    }
    pthread_rwlock_unlock(&db->lock);
}

// Keyframe path — writes to pending, then atomically swaps
void update_keyframe_reference(DeltaBuffer *db, const void *keyframe) {
    int pending = 1 - db->active;
    memcpy(db->buf[pending], keyframe, db->frame_bytes);  // write to pending only
    pthread_rwlock_wrlock(&db->lock);
    db->active = pending;                                  // atomic swap under write lock
    pthread_rwlock_unlock(&db->lock);
}
```

### Pattern 5: Metal ProMotion 120Hz (CAMetalDisplayLink + Triple Buffering)
**What:** CAMetalDisplayLink fires at the exact display refresh rate (adaptive 24-120Hz). Triple buffering (semaphore count=3) prevents stalls. Info.plist key required for system opt-in.

**When to use:** MetalRenderer.swift. REQUIRED — without plist key the system clamps to 60Hz regardless of code.

```swift
// MetalRenderer.swift
import Metal
import MetalKit
import QuartzCore

class MetalRenderer: NSObject, MTKViewDelegate {
    var displayLink: CAMetalDisplayLink?
    let inflightSemaphore = DispatchSemaphore(value: 3)  // triple buffer

    func setup(mtkView: MTKView) {
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        // Set P3 color space on the underlying CAMetalLayer
        if let layer = mtkView.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        // Use CAMetalDisplayLink instead of MTKView's built-in timer
        displayLink = CAMetalDisplayLink(metalLayer: mtkView.layer as! CAMetalLayer)
        displayLink?.delegate = self
        displayLink?.add(to: .main, forMode: .common)
    }
}
// Info.plist — REQUIRED for 120Hz on ProMotion hardware:
// <key>CADisableMinimumFrameDuration</key><true/>
```

### Pattern 6: Transport Failover FSM
**What:** Pure FSM with effects. NWPathMonitor events trigger transitions. IDLE → USB_NCM → WIFI → AWDL.

```
States: IDLE | USB_NCM | WIFI | AWDL | DISCONNECTED

Transitions:
  IDLE + wiredEthernet_appeared       → USB_NCM
  USB_NCM + wiredEthernet_disappeared → WIFI (start Wi-Fi connect)
  WIFI + wifi_unavailable             → AWDL (start Bonjour browse)
  Any + wiredEthernet_appeared        → USB_NCM (promote immediately)
  Any + connected                     → switch encode mode (LZ4 ↔ HEVC)

Side effects per transition:
  → USB_NCM: activate LZ4+delta encode, bind sockets to NCM interface
  → WIFI: activate HEVC encode, connect over Wi-Fi NWConnection
  → AWDL: activate HEVC encode, connect over AWDL NWConnection
  → USB_NCM (from fallback): deactivate HEVC, reactivate LZ4+delta, rebind sockets
```

### Pattern 7: C+ObjC Xcode Project Setup (No Swift)
**What:** macOS agent with no Swift runtime. Standard Xcode project with .m and .c files only.

**Build Settings required:**
- `MACOSX_DEPLOYMENT_TARGET = 14.2`
- `GCC_C_LANGUAGE_STANDARD = c11`
- `SWIFT_VERSION` — leave blank (no Swift)
- `HEADER_SEARCH_PATHS = ../Shared`
- `ENABLE_HARDENED_RUNTIME = YES`

**Entitlements (RemoteDesktopAgent.entitlements):**
```xml
<key>com.apple.security.app-sandbox</key><false/>
<key>com.apple.security.network.server</key><true/>
<key>com.apple.security.network.client</key><true/>
<!-- Apply for this entitlement to suppress Sequoia monthly re-auth: -->
<key>com.apple.developer.persistent-content-capture</key><true/>
```

**Info.plist required keys:**
```xml
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key>
<string>Remote Desktop requires screen capture to stream your Mac display to your iPad.</string>
<key>NSAccessibilityUsageDescription</key>
<string>Remote Desktop requires Accessibility to inject mouse and keyboard events.</string>
```

### Pattern 8: QR Pairing (Pattern-Copy from keyd v1.0)
**What:** Curve25519 ECDH via CryptoKit. Mac displays QR payload; iPad scans and responds with its public key. Derived shared secret stored in Keychain.

**Key differences from keyd v1.0:**
- keychainService = `"com.ryheff.keyd.remote.agent"` (NOT `"com.ryheff.keyd.agent"`)
- QR payload includes display geometry + protocol version (not usbmuxd port)
- No JSON transport — pairing handshake is the only JSON use; all subsequent frames are binary

### Pattern 9: Session Handshake After Pairing
**What:** After QR pairing, before first frame, Mac sends display geometry + capabilities over TCP control channel.

**Claude's discretion on binary format:** The 24-byte media header constraint applies to frame headers only. The session handshake is a one-time message; recommend a simple binary struct:

```c
// Session handshake message (sent once after connection, over TCP control channel)
typedef struct __attribute__((packed)) {
    uint16_t magic;          // 0x4B44
    uint8_t  msg_type;       // 0x01 = session_handshake
    uint32_t display_width;  // logical pixels
    uint32_t display_height; // logical pixels
    float    scale_factor;   // Retina scale (1.0 / 2.0 / 3.0)
    float    aspect_ratio;   // width / height
    uint8_t  capabilities;   // bit0:LZ4 bit1:HEVC bit2:eco_available
    uint8_t  max_fps;        // 120
    uint8_t  agent_version;  // protocol version
    uint32_t reserved;
} SessionHandshakeMessage;   // ~26 bytes; exact size TBD during implementation
```

### Anti-Patterns to Avoid
- **Hardcoding interface name (en4/en5/en6):** Silent failure on multi-adapter systems. Always use NWPathMonitor to find the NWInterface object by type.
- **Releasing CMSampleBuffer before LZ4 completes:** IOSurface recycling corruption. Hold retain until LZ4_compress_default returns.
- **Single reference frame buffer without locking:** Delta race condition — diverging decoder state. Use double-buffer + pthread_rwlock_t from the start.
- **MTKView built-in timer for 120Hz:** System clamps to 60Hz without CADisableMinimumFrameDuration and CAMetalDisplayLink.
- **Combining ConstantBitRate + EnableLowLatencyRateControl in VideoToolbox:** One silently ignored; use AverageBitRate only with low-latency mode.
- **LZ4 frame API instead of block API:** Frame format incompatible with binary protocol. Use LZ4_compress_default / LZ4_decompress_safe exclusively.
- **JSON in media/input data path:** ~50x slower than binary framing; incompatible with latency budget.
- **Compressing on main thread:** Blocks frame delivery at 120fps. Compress on dedicated high-priority GCD queue.
- **Allocating LZ4 output buffer per frame:** Heap fragmentation and latency spikes. Pre-allocate LZ4_COMPRESSBOUND(srcSize) buffers in a pool at startup.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Screen capture | Custom CGDisplayStream or pixel copying | ScreenCaptureKit SCStream | Deprecated API; no SCFrameStatusIdle; no IOSurface access |
| Compression | Custom compression algorithm | LZ4 v1.10.0 block API | LZ4 achieves ~8 GB/s compress; custom code won't beat it and will have correctness bugs |
| HEVC encode/decode | libx265 software encoder | VideoToolbox VTCompressionSession | Software x265 = 15-40% CPU; VideoToolbox media engine = 0% CPU |
| Network interface detection | Polling `ifconfig` output | NWPathMonitor | NWPathMonitor is event-driven, handles interface changes reliably, provides NWInterface objects |
| TLS/DTLS | OpenSSL or manual crypto | Network.framework TLS options | Network.framework provides TLS 1.3 and DTLS with built-in cert pinning hooks |
| ProMotion timing | CADisplayLink with fixed interval | CAMetalDisplayLink | CADisplayLink produces jitter at adaptive frame rates; CAMetalDisplayLink is frame-paced |
| QR pairing key exchange | Custom key agreement protocol | CryptoKit Curve25519 (pattern from keyd v1.0) | Proven implementation; Keychain storage included; no cryptographic pitfalls |
| Login item management | launchd plist installation | SMAppService | System-managed; user-visible in System Settings |

**Key insight:** Every "don't hand-roll" item above is either a correctness landmine (compression, TLS, key exchange) or a performance ceiling (HEVC encoding, screen capture, network stack). The Apple frameworks in this domain are the fastest and most correct implementations available — and some (VideoToolbox media engine) are not replicable in software at all.

---

## Common Pitfalls

### Pitfall 1: ScreenCaptureKit Monthly Re-Authorization (macOS Sequoia 15+)
**What goes wrong:** SCStream silently stops delivering frames when the Sequoia periodic re-authorization prompt lapses. Returns SCStreamError -3805 or produces zero frame callbacks. Breaks unattended operation.
**Why it happens:** Apple added monthly re-authorization for all SCKit apps in Sequoia. Apps without `SCContentSharingPicker` (which requires user interaction each time) must obtain the `com.apple.developer.persistent-content-capture` entitlement or accept monthly prompts.
**How to avoid:**
1. Add `com.apple.developer.persistent-content-capture` to entitlements file. Self-signed: add the key and re-sign; no Apple approval needed for self-signed apps.
2. Implement a frame delivery watchdog: if 0 frames received for >2 seconds while display is awake, surface a menu bar notification with a "Re-authorize" button that opens System Settings.
3. Call `SCShareableContent.getWithCompletionHandler` on a background queue with a 5-second timeout at startup — it can block for 3-10 seconds on Sequoia.
**Warning signs:** Stream starts successfully, delivers an initial burst, then goes silent. SCStreamError -3805. Works last month, fails this month.

### Pitfall 2: Link-Local IPv6 Requires Exact NWInterface Object (Silent Connection Failure)
**What goes wrong:** `NWConnection` to a link-local address (fe80::) without pinning to the exact NWInterface object from NWPathMonitor silently enters `.failed` state. Setting `requiredInterfaceType: .wiredEthernet` is NOT sufficient — you must pass the exact `NWInterface` object.
**Why it happens:** Link-local addresses are per-interface (same fe80:: prefix on every interface). The OS needs the exact scope ID to route correctly. `requiredInterfaceType` narrows by class; `requiredInterface` (with the object) specifies the exact interface.
**How to avoid:**
- iPad side: extract the specific `NWInterface` object from `path.availableInterfaces` and pass it to `NWParameters.requiredInterface` (not just `requiredInterfaceType`)
- Mac side (C): set `sin6_scope_id = if_nametoindex(nw_interface_get_name(interface))` in `sockaddr_in6` before `connect()`/`bind()`
- Write a minimal UDP loopback test on USB NCM as the FIRST implementation task before any pipeline work
**Warning signs:** NWConnection goes to .failed immediately on wiredEthernet; `ENETUNREACH` or `EHOSTUNREACH` from BSD socket; `ping fe80::... -I en7` works in Terminal but app fails.

### Pitfall 3: IOSurface Recycling Corrupts In-Flight LZ4 Compression
**What goes wrong:** Occasional corrupted frames with clean seams (not noise corruption). Corruption appears only under load when capture rate is high.
**Why it happens:** When CMSampleBuffer is released, the backing IOSurface returns to the SCKit pool immediately. If LZ4 runs on a background thread and the sample buffer was released first, the pointer is dangling.
**How to avoid:** Hold CMSampleBuffer retain for the ENTIRE duration of LZ4_compress_default. In ScreenCapture.m, pass sampleBuffer to FrameCompressor and only release it after compress returns. Use IOSurfaceLock/IOSurfaceUnlock inside the lock/unlock pair.
**Warning signs:** Corruption reproducible only under load; disappears when compression moved to main thread; clean seam-like corruption patterns.

### Pitfall 4: Delta Frame XOR Race Condition
**What goes wrong:** Decoder state drifts over time with corruption increasing between keyframe intervals. Corruption appears only during fast-changing content.
**Why it happens:** Without a reader-writer lock, the keyframe writer can update the reference buffer while a delta frame is being XORed against it. The resulting delta is computed against a half-old, half-new reference.
**How to avoid:** Double-buffer reference frames + pthread_rwlock_t from day one. Delta reads use rdlock; keyframe writes use wrlock on the swap (not the copy). See Pattern 4 above.
**Warning signs:** Adding a sleep before delta computation causes corruption to disappear (masks the race); corruption during scrolling/animation but not static content.

### Pitfall 5: ProMotion Capped at 60Hz Without Explicit Opt-In
**What goes wrong:** FPS counter shows 60Hz even with preferredFramesPerSecond = 120. MTKView built-in timer produces uneven 12ms-20ms cadence instead of uniform 8.3ms.
**Why it happens:** Without `CADisableMinimumFrameDuration = YES` in Info.plist, the system clamps CADisplayLink-based rendering to 60Hz. Even with the plist key, MTKView's built-in timer produces jitter on adaptive displays.
**How to avoid:** Add `CADisableMinimumFrameDuration = YES` to Info.plist. Use `CAMetalDisplayLink` (not MTKView's built-in timer). Use 3 drawables with `DispatchSemaphore(value: 3)`.
**Warning signs:** 60Hz in Instruments Time Profiler despite 120Hz hardware; irregular frame intervals.

### Pitfall 6: NWPathMonitor wiredEthernet False Positives (Multiple Adapters)
**What goes wrong:** USB NCM transport fails intermittently when user has a USB Ethernet adapter or hub connected simultaneously. NWPathMonitor reports wiredEthernet for both; wrong interface selected.
**How to avoid:** During pairing, exchange the Mac's USB NCM interface link-local address and store it on the iPad. On subsequent connections, identify the correct wiredEthernet interface by comparing link-local addresses, not just interface type.

### Pitfall 7: SCStream Delegate Held Weakly (Sonoma+)
**What goes wrong:** Stream starts successfully but no frame callbacks are received after initial setup.
**Why it happens:** SCStream holds its output delegate weakly in Sonoma+. If the delegate is a local variable, it is released immediately.
**How to avoid:** Store the SCStream delegate object as a strong ivar on ScreenCapture.m, not a local variable.

### Pitfall 8: SMAppService Login Item Registration Reports Success But Agent Doesn't Launch
**What goes wrong:** SMAppService.mainApp.register() returns .success but agent isn't in process list after login.
**How to avoid:** After registering, check `SMAppService.mainApp.status`. Add a "Fix Launch at Login" menu item that calls `unregister()` then `register()`. This resolves stuck registration state reliably.

### Pitfall 9: Local Network Permission Blocks UDP on First iPad Launch
**What goes wrong:** UDP sends silently dropped on first launch; NWConnection enters `.waiting` state with EPERM.
**How to avoid:** Declare `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist. Trigger the permission prompt explicitly during pairing (send a probe packet), not silently at stream start.

---

## Code Examples

Verified patterns from project research (`.planning/research/ARCHITECTURE.md`):

### SCStreamConfiguration Setup
```objc
// Source: .planning/research/ARCHITECTURE.md Pattern 2
SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
config.pixelFormat = kCVPixelFormatType_32BGRA;
config.minimumFrameInterval = CMTimeMake(1, 120);  // up to 120fps
config.queueDepth = 3;
config.showsCursor = YES;
config.width = display.width;
config.height = display.height;
```

### LZ4 Zero-Copy Compress (C)
```c
// Source: .planning/research/ARCHITECTURE.md Pattern 2
void compress_frame(IOSurfaceRef surface, CompressOutput *out) {
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    size_t bytes = IOSurfaceGetAllocSize(surface);
    int compressed = LZ4_compress_default(base, out->buf, (int)bytes, out->buf_capacity);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    out->compressed_size = compressed;
}
```

### LZ4 Decompress + Delta Apply (Swift)
```swift
// Source: .planning/research/ARCHITECTURE.md Pattern 4 (iPad decode side)
func decompressAndApplyDelta(
    compressed: Data,
    prevKeyframe: UnsafeRawPointer,
    frameBytes: Int
) -> Data? {
    var output = Data(count: frameBytes)
    let result = output.withUnsafeMutableBytes { dst -> Int32 in
        compressed.withUnsafeBytes { src in
            LZ4_decompress_safe(src.baseAddress, dst.baseAddress,
                                Int32(compressed.count), Int32(frameBytes))
        }
    }
    guard result == Int32(frameBytes) else { return nil }
    // Apply XOR delta
    output.withUnsafeMutableBytes { dst in
        for i in stride(from: 0, to: frameBytes, by: 8) {
            let dstPtr = dst.baseAddress!.advanced(by: i).assumingMemoryBound(to: UInt64.self)
            let prevPtr = prevKeyframe.advanced(by: i).assumingMemoryBound(to: UInt64.self)
            dstPtr.pointee ^= prevPtr.pointee
        }
    }
    return output
}
```

### VideoToolbox HEVC Session Create (Low-Latency, AverageBitRate Only)
```objc
// Source: .planning/research/ARCHITECTURE.md Pattern 5
// CRITICAL: Use AverageBitRate, NOT ConstantBitRate with low-latency mode
VTCompressionSessionRef session;
NSDictionary *encoderSpec = @{
    (__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES
};
VTCompressionSessionCreate(
    NULL, width, height,
    kVTVideoCodecType_HEVC,
    (__bridge CFDictionaryRef)encoderSpec,
    NULL, NULL,
    outputCallback, (__bridge void *)self,
    &session
);
VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate,
                     (__bridge CFTypeRef)@(50000000));  // 50 Mbps for 4K
```

### TLS 1.3 on TCP (macOS C API)
```objc
// Source: .planning/research/STACK.md Security Stack
nw_parameters_t params = nw_parameters_create_secure_tcp(
    ^(nw_protocol_options_t tls_options) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
        sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
    },
    NW_PARAMETERS_DEFAULT_CONFIGURATION  // TCP
);
```

### DTLS on UDP (macOS C API)
```objc
// Source: .planning/research/STACK.md Security Stack
nw_parameters_t params = nw_parameters_create_secure_udp(
    ^(nw_protocol_options_t dtls_options) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
        sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
    },
    NW_PARAMETERS_DEFAULT_CONFIGURATION  // UDP
);
```

### QR Pairing (Pattern from keyd v1.0 PairingManager.swift — adapt service name)
```swift
// Pattern: keyd v1.0 macOS/KeydAgent/Pairing/PairingManager.swift
// Change: keychainService = "com.ryheff.keyd.remote.agent" (NOT "com.ryheff.keyd.agent")
// Change: QR payload includes display geometry + protocol version (not usbmuxd port)
// Change: bundle IDs per MEMORY.md: com.ryheff.keyd.remote.agent / .remote.app / .remote.app.tests
let key = Curve25519.KeyAgreement.PrivateKey()
let publicKeyB64 = key.publicKey.rawRepresentation.base64EncodedString()
// Encode into QR payload struct — exact format at Claude's discretion within protocol constraint
```

### Metal BGRA Texture Upload
```swift
// Source: .planning/research/ARCHITECTURE.md Data Flow 1 (iPad render side)
func uploadFrame(_ data: UnsafeRawPointer, width: Int, height: Int, to texture: MTLTexture) {
    let bytesPerRow = width * 4  // BGRA: 4 bytes per pixel
    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: data,
        bytesPerRow: bytesPerRow
    )
}
```

### Letterbox Viewport Calculation
```swift
// HUD + render viewport — letterbox with true black fill (tandem OLED)
func computeRenderViewport(macWidth: Int, macHeight: Int, screenBounds: CGRect) -> CGRect {
    let macAspect = CGFloat(macWidth) / CGFloat(macHeight)
    let screenAspect = screenBounds.width / screenBounds.height
    if macAspect > screenAspect {
        // Mac is wider: full width, letterbox top/bottom
        let renderHeight = screenBounds.width / macAspect
        let yOffset = (screenBounds.height - renderHeight) / 2
        return CGRect(x: 0, y: yOffset, width: screenBounds.width, height: renderHeight)
    } else {
        // Mac is taller: full height, pillarbox left/right
        let renderWidth = screenBounds.height * macAspect
        let xOffset = (screenBounds.width - renderWidth) / 2
        return CGRect(x: xOffset, y: 0, width: renderWidth, height: screenBounds.height)
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CGDisplayStream for screen capture | ScreenCaptureKit SCStream | macOS 12.3 (WWDC 2022), deprecated CGDisplayStream in macOS 14 | IOSurface-backed frames, SCFrameStatusIdle, dirty rect metadata |
| MTKView built-in timer (preferredFramesPerSecond) | CAMetalDisplayLink | iPadOS 17.0 (WWDC 2023) | Correct adaptive ProMotion frame pacing at variable rates |
| Virtual audio driver (BlackHole) for audio capture | CoreAudio Tap API (AudioHardwareCreateProcessTap) | macOS 14.2 (December 2023) | No system extension needed; all-process audio tap |
| SMLoginItemSetEnabled (deprecated) for login items | SMAppService | macOS 13.0 | System Settings visible; proper unregister/register lifecycle |
| WeakRef SCStream delegate | Strong ivar SCStream delegate | macOS 14 Sonoma | SCStream holds delegate weakly in Sonoma+ |

**Deprecated/outdated:**
- `CGDisplayStream`: Deprecated macOS 14. Do not use.
- `SMLoginItemSetEnabled`: Deprecated. Use SMAppService.
- `SCKit capturesAudio = true` on macOS 15: Silently produces no audio callbacks. CoreAudio Tap is the correct path (Phase 5 concern, but documented here as architecture boundary).
- `MTKView.preferredFramesPerSecond`: Not sufficient for ProMotion on iPadOS 17+. CAMetalDisplayLink required.

---

## Open Questions

1. **USB NCM loopback viability on specific iPad M4 + Mac M1 Max direct-cable scenario**
   - What we know: Apple Developer Forum threads confirm `.wiredEthernet` classification for USB NCM on iPadOS; multiple reports of UDP sockets working over this interface
   - What's unclear: Fewer confirmed reports for the iPad↔Mac peer-to-peer direct-cable scenario specifically (vs USB Ethernet adapter scenarios)
   - Recommendation: Write a minimal UDP ping-pong loopback test (both sides) as the absolute first implementation task in Phase 2 — before any pipeline work. Gate all subsequent USB NCM tasks on this test passing.

2. **`com.apple.developer.persistent-content-capture` entitlement behavior on self-signed binaries**
   - What we know: Jump Desktop (App Store) uses this entitlement to bypass Sequoia monthly re-auth; the entitlement key exists; self-signed apps can include arbitrary entitlement keys
   - What's unclear: Whether the macOS TCC subsystem honors this entitlement for self-signed (non-Apple-notarized) binaries; no public documentation on this case
   - Recommendation: Add the entitlement key to the entitlements file and test empirically in Wave 1. Design the frame watchdog + manual re-auth fallback regardless — it must exist either way.

3. **Session handshake binary layout**
   - What we know: Must be sent over TCP control channel after pairing; must contain display geometry + supported modes + agent version; within 24-byte protocol spirit
   - What's unclear: Exact byte layout
   - Recommendation: Claude's discretion (per CONTEXT.md) — implement as a simple packed C struct; exact layout documented when SessionHandshakeMessage is implemented in the protocol component.

4. **CGDisplaySetDisplayMode vs ScreenCaptureKit scaling for resolution matching suggestion**
   - What we know: Both are technically viable; resolution matching is an "offer, not force" UX feature
   - What's unclear: Whether CGDisplaySetDisplayMode requires user confirmation on macOS 14+
   - Recommendation: Claude's discretion (per CONTEXT.md) — start with CGDisplaySetDisplayMode as it directly matches Mac display settings; fall back to ScreenCaptureKit downscaling if permission issues arise.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (unit tests within Xcode projects) + pure C test executables for protocol/compression tests |
| Config file | None — embedded in Xcode project schemes (Wave 0 creates these) |
| Quick run command | `xcodebuild test -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests` |
| Full suite command | Both macOS + iPadOS test schemes; plus pure C tests compiled via Makefile |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| RD-COMP-01 | LZ4 block compress/decompress roundtrip | unit (C) | `make -C RemoteDesktop/Tests test_lz4` | ❌ Wave 0 |
| RD-COMP-02 | XOR delta compute + apply roundtrip, bitwise identical | unit (C) | `make -C RemoteDesktop/Tests test_delta` | ❌ Wave 0 |
| RD-COMP-04 | Delta double-buffer pthread_rwlock concurrent access (no corruption) | unit (C) | `make -C RemoteDesktop/Tests test_delta_concurrent` | ❌ Wave 0 |
| RD-COMP-05 | CMSampleBuffer retain during compress (no use-after-free) | unit (ObjC, AddressSanitizer) | xcodebuild test -scheme RemoteDesktopAgentTests | ❌ Wave 0 |
| RD-TRANS-08 | Protocol framing: known bytes in → packed → unpacked → bitwise identical | unit (C) | `make -C RemoteDesktop/Tests test_protocol` | ❌ Wave 0 |
| RD-TRANS-01/09 | USB NCM UDP loopback: ping-pong over wiredEthernet | integration (2 devices) | Manual / device lab | ❌ Wave 0 |
| RD-SEC-01/02 | TLS 1.3 TCP + DTLS UDP connections established | integration (loopback) | xcodebuild test -scheme RemoteDesktopAgentTests | ❌ Wave 0 |
| RD-REND-03 | ProMotion 120Hz render loop fires at correct cadence | unit (Swift, XCTest) | xcodebuild test -project RemoteDesktop/iPadOS/... | ❌ Wave 0 |
| RD-PERF-03 | Mac agent CPU <3% during wired streaming | perf / Instruments | Manual — Instruments Energy Log | manual-only (requires device) |
| RD-PERF-01 | Glass-to-glass latency <8ms wired | perf / device | Manual — timestamped frames | manual-only (requires 2 devices) |
| RD-CAP-05 | Frame watchdog fires within 2s of 0 frames | unit (ObjC) | xcodebuild test -scheme RemoteDesktopAgentTests | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `make -C RemoteDesktop/Tests test_protocol test_lz4 test_delta` (pure C, <5s)
- **Per wave merge:** Full Xcode scheme test run on macOS agent + iPad simulator
- **Phase gate:** Full suite green + USB NCM loopback test passing on physical devices before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `RemoteDesktop/Tests/Protocol/FramingTests.c` — covers RD-TRANS-08
- [ ] `RemoteDesktop/Tests/Compression/LZ4RoundtripTests.c` — covers RD-COMP-01
- [ ] `RemoteDesktop/Tests/Compression/DeltaTests.c` — covers RD-COMP-02, RD-COMP-04
- [ ] `RemoteDesktop/Tests/Makefile` — builds and runs pure C tests without Xcode
- [ ] `RemoteDesktop/macOS/RemoteDesktopAgentTests/` — XCTest target for macOS agent
- [ ] `RemoteDesktop/iPadOS/RemoteDesktopAppTests/` — XCTest target for iPad app
- [ ] USB NCM loopback test program — covers RD-TRANS-01, RD-TRANS-09 (requires 2 physical devices)

---

## Sources

### Primary (HIGH confidence)
- `.planning/research/STACK.md` — full stack version matrix, vendoring patterns, "What NOT to Add" justifications; researched 2026-03-27 against Apple official docs + WWDC sessions
- `.planning/research/ARCHITECTURE.md` — component diagram, project structure, code patterns with verified API calls; researched 2026-03-27
- `.planning/research/PITFALLS.md` — 14 pitfalls with severity ratings, prevention strategies, warning signs; researched 2026-03-27
- `.planning/research/SUMMARY.md` — executive synthesis with confidence levels; researched 2026-03-27
- Apple developer.apple.com — ScreenCaptureKit, Network.framework C API, VideoToolbox, CAMetalDisplayLink, IOSurface, CGEvent, SMAppService (referenced in STACK.md/ARCHITECTURE.md research)
- LZ4 v1.10.0 — github.com/lz4/lz4 lib/README.md — block vs frame API, BSD-2 license confirmed

### Secondary (MEDIUM confidence)
- Apple Developer Forum thread 769793 — USB NCM `.wiredEthernet` classification in NWPathMonitor on iPadOS
- Apple Developer Forum thread 763426 — CAMetalDisplayLink 120Hz + CADisableMinimumFrameDuration requirement
- WWDC21 VideoToolbox session — EnableLowLatencyRateControl + rate control property interactions
- OBS Studio PR #11896 — ScreenCaptureKit 120fps on M1 Max, macOS 15.3.1

### Tertiary (LOW confidence — validate during implementation)
- USB NCM iPad↔Mac direct peer-to-peer scenario — fewer confirmed reports than general wiredEthernet adapter use; validate with loopback test in Phase 2 Wave 1
- `com.apple.developer.persistent-content-capture` behavior for self-signed non-App-Store binaries — no public documentation; test empirically in Phase 2 Wave 1

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all core APIs verified against Apple docs in project research
- Architecture: HIGH — project structure, component responsibilities, and code patterns fully specified in ARCHITECTURE.md
- Pitfalls: HIGH — all 14 pitfalls verified against Apple Developer Forums, official docs, WWDC sessions, or open-source implementations in project research
- Correctness-critical patterns (double-buffer, IOSurface lock lifetime, link-local binding): HIGH — prevention strategies are specific and implementation-ready
- USB NCM loopback viability: MEDIUM — confirmed via forum reports; specific M4 iPad ↔ M1 Max scenario needs validation

**Research date:** 2026-03-28
**Valid until:** 2026-05-28 (stable APIs; 60-day validity for core Apple frameworks at this OS floor)
