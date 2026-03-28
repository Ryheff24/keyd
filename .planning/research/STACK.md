# Stack Research

**Domain:** iPadOS-to-macOS Remote Desktop (keyd-rd v2.0)
**Researched:** 2026-03-27
**Confidence:** HIGH (Apple frameworks verified via official docs, WWDC sessions, and community projects; LZ4 v1.10.0 verified on GitHub)

---

## Scope

This document covers ONLY the stack additions needed for keyd-rd remote desktop features.
The following are already validated by keyd v1.0 and are NOT re-researched here:

- usbmuxd TCP transport
- AWDL Bonjour discovery (NWBrowser / NWListener)
- CGEvent injection for keyboard input
- QR pairing with ECDH key exchange
- Transport failover FSM pattern
- SharedProtocol SPM package
- iOS UIViewController-based app architecture
- macOS menu bar agent (NSStatusItem, SMAppService)

---

## New Stack: macOS Agent (C + Objective-C only)

### Core Apple Frameworks

| Framework | Min macOS | Language API | Purpose | Why |
|-----------|-----------|-------------|---------|-----|
| ScreenCaptureKit | 12.3 | Objective-C (`SCStream`, `SCStreamDelegate`, `SCStreamOutput`) | Full-display capture at Retina resolution, up to 120fps | Hardware-accelerated. Delivers `IOSurface`-backed `CMSampleBuffer` directly — no copy needed to reach the compressor. `SCFrameStatus` metadata lets you skip idle frames (screen unchanged). `SCStreamConfiguration.minimumFrameInterval` controls target fps (set to `1.0/120.0`). Replaced deprecated `CGDisplayStream`. |
| VideoToolbox | 10.13 (HEVC encode) | C (`VTCompressionSession`, `VTCompressionSessionCreate`, `VTCompressionSessionEncodeFrame`) | HEVC hardware encode for wireless mode | Pure C API. Runs on Apple's dedicated media engine — zero CPU and zero GPU cost. `kVTVideoCodecType_HEVC` + `kVTCompressionPropertyKey_RealTime = kCFBooleanTrue`. Mac CPU budget remains intact for LLM workloads. |
| Network.framework | 10.14 | C (`nw_connection_t`, `nw_listener_t`, `nw_path_monitor_t`) | USB NCM interface detection, UDP media stream, TCP input stream, TLS 1.3 | Full C API with ARC-compatible reference types. `nw_path_monitor_create_with_type(nw_interface_type_wired_ethernet)` detects USB NCM interface connect/disconnect. `nw_tls_create_options()` + `sec_protocol_options_set_min_tls_protocol_version(..., tls_protocol_version_TLSv13)` enforces TLS 1.3 on TCP channel. TLS 1.3 is default since macOS 10.14.4. |
| CoreAudio (Tap API) | 14.2 | C (`AudioHardwareCreateProcessTap`, `CATapDescription`, IO Proc callback) | System audio capture — all processes via single tap | Introduced December 2023. Only built-in API that captures system audio output without a virtual audio driver or kernel extension. `CATapDescription` with empty process list captures all audio. IO Proc delivers PCM buffers. Requires `NSAudioCaptureUsageDescription` in Info.plist. |
| IOSurface | 10.6 | C (`IOSurfaceLock`, `IOSurfaceGetBaseAddress`, `IOSurfaceGetBytesPerRow`) | Zero-copy pixel data access from ScreenCaptureKit frames | Lock surface for CPU read with `IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)`, get raw pointer via `IOSurfaceGetBaseAddress()`, pass directly to `LZ4_compress_default()`. No `memcpy`. |
| AppKit (NSPasteboard) | 10.0 | Objective-C (`NSPasteboard`, `changeCount`) | Clipboard read/write + change detection | `[NSPasteboard generalPasteboard]`. macOS has no clipboard change notification — poll `changeCount` via a low-frequency `dispatch_source_t` timer (~500ms). Write: `clearContents` + `setString:forType:NSPasteboardTypeString`. |
| CoreGraphics (CGEvent) | 10.4 | C — reused from keyd v1.0 | Mouse + keyboard injection | `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventPost`. Already proven against Safari/Firefox. Adding `kCGMouseEventDeltaX`/`Y` for move events and scroll wheel events. |

### Vendored C Library

| Library | Version | Files to Add | Purpose | Why Not Apple's Built-in |
|---------|---------|-------------|---------|--------------------------|
| LZ4 | v1.10.0 (July 22, 2024) | `lz4.c` + `lz4.h` (2 files, add directly to Xcode target) | LZ4 block compression for wired keyframes and XOR delta frames | Apple's `Compression.framework` (`COMPRESSION_LZ4`) uses **LZ4 frame format** with framing overhead and a streaming API. keyd-rd needs **LZ4 block format** for direct `IOSurface` base address → compressed buffer with no wrapper. Block format also allows precise control over chunk boundaries required by the delta pipeline. v1.10.0 is BSD-2-Clause licensed. Multithreading in v1.10.0 is unused here (single-core hot path). |

### Delta Compression (Pure C, Written from Scratch)

| Component | Location | Purpose |
|-----------|----------|---------|
| `delta.c` / `delta.h` | `RemoteDesktop/Shared/` | XOR current IOSurface frame vs previous keyframe buffer, then LZ4-compress the diff. Threshold: if delta compressed size > 60% of keyframe compressed size, send keyframe instead. ~10 lines of SIMD-friendly XOR code. No external library. |

### Binary Protocol (Pure C, Written from Scratch)

| Component | Location | Purpose |
|-----------|----------|---------|
| `protocol.c` / `protocol.h` | `RemoteDesktop/Shared/` | 24-byte media frame header (magic, flags, seq, chunk index/total, payload size, timestamp, CRC32) + 9-byte input event header (type, timestamp, payload). C structs with `__attribute__((packed))`. Shared between macOS (compiled as C) and iPad (imported via bridging header). |

---

## New Stack: iPadOS App (Swift)

### Core Apple Frameworks

| Framework | Min iPadOS | Language API | Purpose | Why |
|-----------|-----------|-------------|---------|-----|
| Metal + MetalKit (MTKView) | 9.0 | Swift (`MTKView`, `MTKViewDelegate`, `CAMetalLayer`) | Render decompressed frames at ProMotion 120Hz with P3 color | Hardware GPU rendering. `MTKView` manages `CAMetalLayer` and the draw loop. Set `colorPixelFormat = .bgra8Unorm` and `colorspace = CGColorSpace(name: .displayP3)` on `CAMetalLayer` for P3. Use `CAMetalDisplayLink` (iOS 17+) for precise ProMotion frame pacing, or `preferredFramesPerSecond = 120` as fallback (iOS 16). |
| VideoToolbox | 11.0 (HEVC decode) | Swift (C API bridged) — `VTDecompressionSession` | HEVC hardware decode for wireless mode | M4 iPad has dedicated media engine. Decode does not compete with Metal rendering. `VTDecompressionSessionCreate` + `VTDecompressionSessionDecodeFrame`. HEVC hardware decode available on A9+ (iOS 11+); M4 iPad Pro confirmed. |
| Network.framework | 12.0 | Swift (`NWConnection`, `NWListener`, `NWPathMonitor`) | USB NCM transport + TLS + interface detection | Swift API mirrors the C API. `NWPathMonitor(requiredInterfaceType: .wiredEthernet)` detects USB NCM connect/disconnect. `NWProtocolTLS.Options` with `sec_protocol_options_set_min_tls_protocol_version` enforces TLS 1.3. |
| UIKit (UIPasteboard) | 3.0 | Swift | Clipboard read/write + bidirectional sync | `UIPasteboard.general`. Change notification: `NotificationCenter.default.addObserver(..., name: UIPasteboard.changedNotification)`. iOS 14+ shows a system banner on clipboard access — use metadata properties (`hasStrings`) to avoid spurious banners on polling checks. |
| UIKit (gesture recognizers) | 3.2 | Swift | Touch → mouse event translation | `UIPanGestureRecognizer` (mouse move + two-finger scroll), `UITapGestureRecognizer` (single tap = left click, two-finger tap = right click), `UIPinchGestureRecognizer` (viewport zoom), `UIHoverGestureRecognizer` (pointer mode on M4). Poll at 120Hz via `CADisplayLink`. |
| AVFoundation | 3.0 | Swift (`AVAudioSession`, `AVAudioEngine`) | Receive and play audio stream from Mac | `AVAudioSession.sharedInstance().setCategory(.playback)`. `AVAudioEngine` for low-latency PCM playback. AAC-LC decode via built-in `AudioConverter` (no external codec needed). |

### Vendored C Library (iPad)

| Library | Version | Integration | Purpose |
|---------|---------|-------------|---------|
| LZ4 | v1.10.0 | `lz4.c` + `lz4.h` added to iPadOS Xcode target; exposed via bridging header `#include "lz4.h"` | LZ4 decompress + delta apply. Same vendored source files as macOS side — single source of truth. |

---

## Security Stack (Both Sides)

| Technology | API | Where Used | Notes |
|------------|-----|-----------|-------|
| TLS 1.3 | macOS C: `nw_tls_create_options()` + `sec_protocol_options_set_min_tls_protocol_version(..., tls_protocol_version_TLSv13)`. iPad Swift: `NWProtocolTLS.Options` | TCP input stream on both sides | Default since iOS 12.2 / macOS 10.14.4. Enforce minimum explicitly to prevent downgrade. |
| DTLS | macOS C: `nw_parameters_create_secure_udp(...)`. iPad Swift: `NWParameters.dtls` | UDP media stream on both sides | Network.framework negotiates DTLS version internally. Available macOS 10.14+ / iOS 12.0+. Enforce minimum via `sec_protocol_options`. |
| Certificate pinning | `Security.framework` — `SecTrust` + `sec_protocol_verify_block` (C) / `sec_protocol_options_set_verify_block` (Swift) | Post-pairing handshakes | After QR pairing ECDH exchange, pin the self-signed cert. Reject any connection presenting a different cert. Reuse the keyd v1.0 keychain storage pattern under new service ID `com.ryheff.keyd.remote`. |

---

## OS Version Requirements (Hard Floors)

| Platform | Minimum | Rationale |
|----------|---------|-----------|
| macOS | **14.2 (Sonoma, December 2023)** | `AudioHardwareCreateProcessTap` / CoreAudio Tap API. Without it, system audio capture requires a user-installed virtual audio driver — unacceptable. ScreenCaptureKit dirty rects and `SCFrameStatusIdle` also fully stable in 14.x. Both target Macs (M1 Max MacBook Pro) ship macOS 14+. |
| iPadOS | **17.0** | `CAMetalDisplayLink` for precise ProMotion 120Hz frame pacing. Without it, `MTKView.preferredFramesPerSecond = 120` works but timing jitters on adaptive displays. M4 iPad Pro ships iPadOS 17+. |

---

## What NOT to Add

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Swift on macOS agent | ~15-30 MB Swift runtime overhead (DC-2: Mac is resource-starved, <50 MB RSS budget). All needed Apple frameworks have native C/Obj-C APIs — no Swift bridge needed. | C + Objective-C only. |
| Apple `Compression.framework` (`COMPRESSION_LZ4`) | Uses LZ4 **frame format** with framing headers, not LZ4 block format. Adds overhead incompatible with the delta pipeline's block-level access. Less control over compression boundaries. | Vendored `lz4.c` + `lz4.h` (2 files, BSD-2-Clause). |
| usbmuxd for video transport | usbmuxd is a TCP tunnel per-connection. For video streaming, each UDP datagram would need a connection — wrong abstraction. USB NCM is a real network interface at full USB 3.x / TB4 speeds with standard UDP. | `Network.framework` UDP over USB NCM `en` interface (`nw_interface_type_wired_ethernet`). |
| ReplayKit | Designed for game recording and broadcast. Adds HEVC encoding overhead regardless of mode and imposes latency incompatible with <8ms target. No IOSurface access. | `ScreenCaptureKit SCStream` → `IOSurface` → LZ4 pipeline. |
| WebRTC | Cloud-infrastructure-oriented (STUN/TURN/ICE). Adds significant complexity and latency for a direct USB or same-LAN scenario. Not needed. | Direct UDP/TCP via `Network.framework`. |
| Opus audio codec | Requires vendoring a ~700 KB C library (libopus). Designed for voice/lossy compression. Adds a dependency with no clear benefit — USB NCM has enough bandwidth for AAC-LC or even uncompressed PCM. | AAC-LC encode via built-in `AudioConverter` on macOS; `AVAudioEngine` decode on iPad. Zero additional dependencies. |
| `AVCaptureSession` for screen capture | Designed for camera capture. No display capture capability. | `ScreenCaptureKit SCStream`. |
| JSON encoding in the data path | Parsing overhead per frame is incompatible with <8ms latency target and <3% CPU budget. Frames are fixed-structure binary data. | Binary protocol: 24-byte media header + 9-byte input header (`__attribute__((packed))` C structs). |
| libx265 (software HEVC encoder) | Software encoder uses CPU — directly competing with LLM workloads on the Mac. Would blow the <3% CPU budget immediately. | `VideoToolbox VTCompressionSession` with `kVTVideoCodecType_HEVC` — media engine, not CPU. |
| Virtual audio driver (BlackHole, etc.) | Requires user to install a system extension. Brittle, version-dependent, invasive for a personal-use tool. | CoreAudio Tap API (`AudioHardwareCreateProcessTap`) — built-in since macOS 14.2. |

---

## Stack Patterns by Mode

**Wired mode (USB NCM, primary path):**
```
SCStream callback → SCFrameStatus check (skip idle) → IOSurfaceLock → base address pointer
→ delta.c XOR vs prev keyframe → LZ4_compress_default() → 24-byte header prepend
→ nw_connection_send() UDP over wiredEthernet interface
```

**Wireless mode (Wi-Fi fallback, auto-triggered on USB NCM path loss):**
```
SCStream callback → CMSampleBuffer → VTCompressionSessionEncodeFrame(kVTVideoCodecType_HEVC)
→ output callback: HEVC NAL units → 24-byte header (HEVC flag set)
→ nw_connection_send() UDP over wifi interface
```

**Eco mode (user-toggled or automatic under thermal pressure):**
- `SCStreamConfiguration.width/height` reduced to 1080p
- `SCStreamConfiguration.minimumFrameInterval = 1.0/30.0`
- Encoding: HEVC even over wired (avoids delta XOR cost)
- Target: <1% CPU, <20 MB RSS

**Audio path (macOS → iPad):**
```
AudioHardwareCreateProcessTap (all processes) → IO Proc PCM callback
→ AudioConverter encode to AAC-LC → separate UDP datagram stream
→ iPad AVAudioEngine decode and playback
```

**Clipboard sync:**
```
macOS: dispatch_source_t timer (500ms) → [NSPasteboard changeCount] changed?
  → yes: read string → send via TCP control channel
iPad: UIPasteboard.changedNotification → read string → send via TCP control channel
Both sides: receive control message → write to local pasteboard
```

---

## Integration Points with keyd v1.0

| v1.0 Component | keyd-rd Reuse Pattern |
|----------------|----------------------|
| QR pairing (PairingManager.m) | Copy and adapt for new bundle IDs (`com.ryheff.keyd.remote.*`). Same ECDH key exchange and QR display/scan flow. New keychain service identifier. |
| Transport failover FSM | Pattern reused. New states: `USB_NCM_CONNECTED`, `WIFI_CONNECTED`, `AWDL_LAST_RESORT`. New trigger: `nw_path_monitor_t` wiredEthernet path loss event. |
| CGEvent injection (EventInjector.c) | Direct reuse. Add: `CGEventCreateMouseEvent` for move/click, `CGEventCreateScrollWheelEvent2` for scroll. Same Accessibility TCC requirement, same validation against Safari/Firefox. |
| Bonjour service discovery | Pattern reused for Wi-Fi fallback (`_keyd-rd._tcp`). Different service name from keyd to avoid collision. |
| Menu bar agent (NSStatusItem, SMAppService) | Direct reuse. New menu items: connection mode indicator (USB NCM / Wi-Fi / AWDL), quality/eco toggle, latency readout. |
| IOKit USB device detection | Reuse `IOServiceAddMatchingNotification` pattern for iPad connection events. keyd-rd uses Network.framework for the data path, but IOKit still useful for connection state notification. |

---

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| ScreenCaptureKit | `CGDisplayStream` | Deprecated in macOS 14. No `SCFrameStatusIdle` — always receives frames even when screen is unchanged, wasting compress + send budget. No dirty rect metadata. |
| LZ4 (vendored, block format) | zlib / LZFSE / zstd | zlib: ~200 MB/s compress — exceeds 1ms budget for 4K. zstd: ~500 MB/s at default level — marginal. LZFSE: Apple-proprietary, not open-source embeddable as cleanly. LZ4 at ~8 GB/s compress (measured) is the only option meeting <1ms target for a 4K frame. |
| VideoToolbox HEVC (media engine) | libx265 software encoder | Software x265 consumes 15-40% CPU at real-time quality — incompatible with DC-1. Media engine is isolated. |
| Network.framework UDP | POSIX `sendto`/`recvfrom` | POSIX works but lacks: interface pinning, built-in TLS/DTLS, path monitoring. Network.framework provides all three with a C API that works directly from Objective-C. |
| CoreAudio Tap API | BlackHole / SoundFlower (virtual audio driver) | Requires user to install a system extension. Not acceptable for a self-contained personal-use tool. |
| `CAMetalDisplayLink` (iOS 17+) | `CADisplayLink` / `MTKView` timer | `CADisplayLink` has variable timing on ProMotion displays — micro-jitter visible at 120Hz. `CAMetalDisplayLink` is frame-paced to the exact display refresh cycle. |
| AAC-LC (built-in AudioConverter) | Opus (vendored libopus) | Opus requires a ~700 KB C library. AAC-LC is built into macOS and iOS. For remote desktop audio (44.1/48 kHz stereo), AAC-LC at 128-256 kbps is perceptually transparent. USB NCM easily handles the bitrate. |

---

## Version Compatibility Matrix

| Component | macOS Minimum | iPadOS Minimum | Notes |
|-----------|--------------|----------------|-------|
| ScreenCaptureKit (SCStream) | 12.3 | N/A | macOS only. `SCFrameStatusIdle` available since 12.3. |
| VideoToolbox encode (HEVC) | 10.13 | N/A | Hardware encode: T2 chip (2017 iMac Pro) or Apple Silicon. M1 Max confirmed. |
| VideoToolbox decode (HEVC) | 10.13 | 11.0 | Hardware decode A9+ on iOS. M4 iPad Pro confirmed. |
| Network.framework (C API: `nw_*_t`) | 10.14 | 12.0 | Full C API available. TLS 1.3 default since 10.14.4 / iOS 12.2. |
| CoreAudio Tap (`AudioHardwareCreateProcessTap`) | **14.2** | N/A | Hard floor. macOS only. |
| IOSurface C API (`IOSurfaceLock`, etc.) | 10.6 | 11.0 | Available on both; used on macOS side only. |
| AppKit NSPasteboard | 10.0 | N/A | macOS only (Objective-C). No change notification — poll changeCount. |
| UIPasteboard + changedNotification | N/A | 3.0 | iPad only. iOS 14+ shows access banner — use metadata properties to avoid. |
| Metal / MTKView | 10.11 | 9.0 | Both sides (used on iPad only in keyd-rd). |
| `CAMetalDisplayLink` | 14.0 | **17.0** | Hard floor for ProMotion precision. Fallback: `preferredFramesPerSecond = 120` on iOS 16. |
| LZ4 v1.10.0 (vendored C) | Any | Any | Pure C, no OS dependency. BSD-2-Clause. |
| TLS 1.3 (enforced via sec_protocol_options) | 10.14 | 12.0 | `tls_protocol_version_TLSv13` constant available in Security.framework. |
| `sec_protocol_options_set_min_tls_protocol_version` | 10.15 | 13.0 | The `tls_protocol_version_t` enum was added in macOS 10.15. On 10.14, use `sec_protocol_options_set_min_tls_protocol_version` with the numeric value `0x0304`. Moot given macOS 14.2 floor. |

**Effective deployment floors:** macOS 14.2 (CoreAudio Tap), iPadOS 17.0 (CAMetalDisplayLink precision). Both are current hardware targets.

---

## Sources

- ScreenCaptureKit `SCFrameStatus` Objective-C API — [developer.apple.com/documentation/screencapturekit/scframestatus?language=objc](https://developer.apple.com/documentation/screencapturekit/scframestatus?language=objc) — MEDIUM confidence (JavaScript-blocked page; confirmed via search showing `?language=objc` variant exists and WWDC22 session "Take ScreenCaptureKit to the next level")
- ScreenCaptureKit `minimumFrameInterval` 120fps — OBS Studio PR #11896 (M1 Max MacBook Pro testing on macOS 15.3.1) + WWDC22 "Take ScreenCaptureKit to the next level" — MEDIUM confidence
- Network.framework C API (`nw_path_monitor_t`, `nw_connection_t`, `nw_tls_create_options`) — [developer.apple.com/documentation/network/nw_path_monitor_t](https://developer.apple.com/documentation/network/nw_path_monitor_t) + iOS 13.0 SDK headers (xybp888/iOS-SDKs) — HIGH confidence
- Network.framework available macOS 10.14 / iOS 12.0 — NWListener Apple docs — HIGH confidence
- TLS 1.3 `sec_protocol_options` C API, `nw_tls_copy_sec_protocol_options` available macOS 10.14 — Rust network-framework-sys bindings + Apple forums — HIGH confidence
- LZ4 v1.10.0 release July 22, 2024; vendoring via `lz4.c` + `lz4.h`; amalgamation via `cat lz4.c lz4hc.c lz4frame.c > lz4_all.c` — [github.com/lz4/lz4](https://github.com/lz4/lz4) lib/README.md — HIGH confidence
- Apple `COMPRESSION_LZ4` uses LZ4 frame format — [developer.apple.com/documentation/compression/compression_algorithm/compression_lz4](https://developer.apple.com/documentation/compression/compression_algorithm/compression_lz4) + WWDC15 session 712 — MEDIUM confidence
- CoreAudio Tap API (`CATapDescription`, `AudioHardwareCreateProcessTap`) introduced macOS 14.2 — insidegui/AudioCap GitHub, makeusabrew/audiotee GitHub, sudara gist — HIGH confidence
- VideoToolbox HEVC encode VTCompressionSession macOS 10.8+ (C API); HEVC support macOS 10.13+ — Apple docs + objc.io VideoToolbox article — HIGH confidence
- VideoToolbox HEVC hardware decode iOS 11+ on A9+ — Apple developer forums + HWDecoder GitHub — MEDIUM confidence
- `CAMetalDisplayLink` iOS 17 / macOS 14 — Apple Developer Forums thread 763426 ("Running 120Hz with low latency") — MEDIUM confidence
- `UIPasteboard.changedNotification` — Apple docs + HackingWithSwift — HIGH confidence
- `NSPasteboard changeCount` polling (no notification on macOS) — [developer.apple.com/documentation/appkit/nspasteboard/1533544-changecount](https://developer.apple.com/documentation/appkit/nspasteboard/1533544-changecount) + Apple Community discussion — HIGH confidence
- USB NCM iPad-Mac creates `wiredEthernet` interface type in `NWPathMonitor` — Apple Developer Forum thread 769793 (USB CDC ECM/NCM) — MEDIUM confidence (confirmed NCM creates an Ethernet interface; NWPathMonitor classifies it as `.wiredEthernet`)

---

*Stack research for: keyd-rd — iPadOS-to-macOS Remote Desktop (v2.0)*
*Researched: 2026-03-27*
