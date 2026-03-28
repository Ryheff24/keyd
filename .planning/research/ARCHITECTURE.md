# Architecture Research

**Domain:** iPadOS-to-macOS remote desktop (keyd-rd v2.0) + integration with existing keyd v1.0
**Researched:** 2026-03-27
**Confidence:** MEDIUM-HIGH — Core Apple APIs (ScreenCaptureKit, VideoToolbox, Network.framework, Metal, CGEvent) are well-documented. USB NCM interface detection behavior has partial documentation; key conclusions drawn from Apple Developer Forum discussions and NWPathMonitor API docs (verified HIGH confidence for the .wiredEthernet classification). DTLS support in Network.framework verified HIGH confidence. Sequoia screen recording permission behavior has a known complexity (monthly prompt / persistent-content-capture entitlement) flagged below.

---

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│           macOS — RemoteDesktopAgent (C + Objective-C)                  │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Capture Layer                                                  │    │
│  │  ScreenCapture.m (SCStream → IOSurface CMSampleBuffer)         │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ IOSurface pointer (zero-copy)              │
│  ┌──────────────────────────▼──────────────────────────────────────┐    │
│  │  Compression Layer                                              │    │
│  │  FrameCompressor.c (LZ4+delta) ←→ HEVCEncoder.m (VideoToolbox)│    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ compressed bytes + 24-byte header          │
│  ┌──────────────────────────▼──────────────────────────────────────┐    │
│  │  Transport Layer                                                │    │
│  │  USBNetworkTransport.m (UDP over NCM)                          │    │
│  │  WirelessTransport.m (UDP over Wi-Fi / AWDL)                   │    │
│  │  protocol.c/h (binary framing, header pack/unpack)             │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│          (media UDP out)    │    (input TCP in)                         │
│  ┌──────────────────────────▼──────────────────────────────────────┐    │
│  │  Input Layer                                                    │    │
│  │  EventInjector.c (CGEvent mouse + keyboard)                    │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Agent Shell (main.m)                                           │    │
│  │  NSApplication accessory policy, NSStatusItem menu bar,        │    │
│  │  SMAppService login item, permission check + prompt            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────┬──────────────────────────────┘
         USB NCM (UDP media + TCP input)   │   Wi-Fi/AWDL fallback
         USB cable (Thunderbolt/USB-C)     │   same protocol, HEVC encode
                                           │
┌──────────────────────────────────────────▼──────────────────────────────┐
│           iPadOS — RemoteDesktopApp (Swift)                              │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Transport Layer                                                │    │
│  │  USBNetworkTransport.swift (UDP recv over NCM)                 │    │
│  │  WirelessTransport.swift (UDP recv over Wi-Fi / AWDL)          │    │
│  │  Protocol.swift (binary framing, header parse)                 │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ reassembled frame bytes                    │
│  ┌──────────────────────────▼──────────────────────────────────────┐    │
│  │  Decode Layer                                                   │    │
│  │  LZ4Decompressor.swift (decompress + XOR delta apply)          │    │
│  │  HEVCDecoder.swift (VideoToolbox hardware decode)               │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ CVPixelBuffer / raw frame                  │
│  ┌──────────────────────────▼──────────────────────────────────────┐    │
│  │  Render Layer                                                   │    │
│  │  MetalRenderer.swift (MTKView, texture upload, draw)           │    │
│  │  Shaders.metal (fragment shader, P3 color space)               │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Input Layer (outbound)                                         │    │
│  │  TouchToMouse.swift (gesture recognizers → input events)       │    │
│  │  KeyboardCapture.swift (UITextInput / hardware keyboard)        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Pairing                                                        │    │
│  │  QRPairing.swift (AVCapture QR scan, ECDH key exchange)        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Integration with Existing keyd v1.0

keyd v1.0 and keyd-rd v2.0 are separate Xcode projects in the same repo. They do NOT share a running process. Integration points are pattern-level (copy and adapt), not code-level (shared binary).

```
keyd/ (repo root)
├── KeydApp/                    # keyd v1.0 — iOS keyboard app (EXISTING, DO NOT MODIFY)
├── macOS/KeydAgent/            # keyd v1.0 — macOS agent (EXISTING, DO NOT MODIFY)
├── SharedProtocol/             # keyd v1.0 — SPM package (EXISTING, DO NOT MODIFY)
└── RemoteDesktop/              # keyd-rd v2.0 — NEW (entirely separate)
    ├── macOS/                  # C + Objective-C macOS agent
    ├── iPadOS/                 # Swift iPad app
    ├── Shared/                 # C headers only (no SPM, no Swift)
    └── Tests/                  # C and Objective-C tests
```

**What is reused from keyd v1.0 (pattern-copy, not shared binary):**
- QR pairing flow: copy PairingManager.swift pattern into QRPairing.swift for the new bundle IDs
- CGEvent injection: EventInjector.c replicates the proven patterns from keyd v1.0's Swift injector
- Bonjour / AWDL service discovery: WirelessTransport uses the same `_keydrd._tcp` Bonjour service pattern
- Transport failover state machine: the USB-primary → Wi-Fi-fallback → AWDL-last-resort FSM mirrors keyd v1.0's USB→AWDL FSM
- Menu bar agent: NSStatusItem architecture is identical to keyd v1.0's macOS agent

**What is NOT reused:**
- SharedProtocol SPM package — keyd-rd uses its own C binary protocol (no JSON, no Swift on macOS)
- usbmuxd TCP transport — keyd-rd uses USB NCM direct sockets, not usbmuxd
- Message encoding/decoding — binary framing via protocol.c/h, not JSON Codable

---

### Component Responsibilities

| Component | Language | Responsibility |
|-----------|----------|----------------|
| ScreenCapture.m | Obj-C | SCStream setup, delegate callback, IOSurface hand-off to FrameCompressor |
| FrameCompressor.c | C | Delta XOR computation, LZ4 compress, keyframe/delta decision, 24-byte header pack |
| HEVCEncoder.m | Obj-C | VTCompressionSession create/manage, CMSampleBuffer → VTEncodeInfoFlags, output callback |
| USBNetworkTransport.m | Obj-C | NWPathMonitor for USB NCM detection, NWListener UDP server (media) + NWListener TCP server (input) |
| WirelessTransport.m | Obj-C | NWBrowser for _keydrd._tcp, NWConnection UDP + TCP over Wi-Fi/AWDL |
| protocol.c/h | C | Struct definitions for MediaFrameHeader + InputEventHeader, pack/unpack functions, CRC32 |
| EventInjector.c | C | CGEventCreateMouseEvent, CGEventCreateKeyboardEvent, CGEventPost |
| main.m | Obj-C | NSApplication run loop, NSStatusItem, SMAppService, CGRequestScreenCaptureAccess, AXIsProcessTrusted |
| USBNetworkTransport.swift | Swift | NWPathMonitor .wiredEthernet detection, NWConnection UDP recv (media) + TCP send (input) |
| WirelessTransport.swift | Swift | NWBrowser connect, NWConnection for Wi-Fi/AWDL paths |
| Protocol.swift | Swift | C header mirror as Swift structs, unpack media headers, pack input headers |
| LZ4Decompressor.swift | Swift | Wrapper over lz4.c (bridging header), decompress + XOR delta apply |
| HEVCDecoder.swift | Swift | VTDecompressionSession, CMSampleBuffer → CVPixelBuffer |
| MetalRenderer.swift | Swift | MTKView delegate, CVPixelBuffer → MTLTexture, draw call |
| Shaders.metal | Metal | Fragment shader: BGRA texture sample, P3 color transform |
| TouchToMouse.swift | Swift | UIGestureRecognizer → input event structs, 120Hz poll, TCP send |
| KeyboardCapture.swift | Swift | UITextInput / hardware keyboard intercept → key event structs |
| QRPairing.swift | Swift | AVCapture QR code scan, SecKeyCreateRandomKey ECDH, TLS identity setup |

---

## Recommended Project Structure

```
RemoteDesktop/
│
├── macOS/
│   ├── RemoteDesktopAgent.xcodeproj
│   ├── main.m                      # Entry point. NSApplication run loop, agent bootstrap.
│   ├── Capture/
│   │   ├── ScreenCapture.h
│   │   └── ScreenCapture.m         # SCStream delegate. Calls FrameCompressor with IOSurface.
│   ├── Compress/
│   │   ├── FrameCompressor.h
│   │   └── FrameCompressor.c       # LZ4+delta hot path. Pure C. No Obj-C runtime.
│   ├── Encode/
│   │   ├── HEVCEncoder.h
│   │   └── HEVCEncoder.m           # VideoToolbox VTCompressionSession. Wireless mode only.
│   ├── Transport/
│   │   ├── USBNetworkTransport.h
│   │   ├── USBNetworkTransport.m   # NWListener UDP+TCP, NCM interface detection.
│   │   ├── WirelessTransport.h
│   │   └── WirelessTransport.m     # NWBrowser, Wi-Fi/AWDL NWConnection.
│   ├── Input/
│   │   ├── EventInjector.h
│   │   └── EventInjector.c         # CGEvent inject. Pure C.
│   └── Resources/
│       └── Info.plist
│
├── iPadOS/
│   ├── RemoteDesktopApp.xcodeproj
│   ├── App/
│   │   ├── RemoteDesktopApp.swift
│   │   └── ContentView.swift
│   ├── Transport/
│   │   ├── USBNetworkTransport.swift
│   │   ├── WirelessTransport.swift
│   │   └── Protocol.swift          # Swift mirror of protocol.h structs.
│   ├── Decode/
│   │   ├── LZ4Decompressor.swift   # Wraps lz4.c via bridging header.
│   │   └── HEVCDecoder.swift       # VTDecompressionSession.
│   ├── Render/
│   │   ├── MetalRenderer.swift     # MTKView delegate.
│   │   └── Shaders.metal
│   ├── Input/
│   │   ├── TouchToMouse.swift
│   │   └── KeyboardCapture.swift
│   ├── Pairing/
│   │   └── QRPairing.swift
│   └── Resources/
│       └── SharedProtocol-Bridging-Header.h   # #import "lz4.h", #import "delta.h"
│
├── Shared/
│   ├── protocol.h                  # MediaFrameHeader + InputEventHeader structs (C99)
│   ├── lz4.c                       # vendored, lz4/lib/lz4.c (r131 or later)
│   ├── lz4.h                       # vendored, lz4/lib/lz4.h
│   ├── delta.c                     # XOR delta: compute_delta(), apply_delta()
│   ├── delta.h
│   └── crypto.h                    # Shared constants: magic bytes, port numbers, service name
│
└── Tests/
    ├── Protocol/
    │   ├── FramingTests.c
    │   ├── DeltaTests.c
    │   └── ChunkReassemblyTests.c
    ├── Compression/
    │   ├── LZ4RoundtripTests.c
    │   ├── DeltaCompressionTests.c
    │   └── ThroughputBenchmark.c
    ├── Transport/
    │   ├── LoopbackSpeedTest.c
    │   ├── USBSpeedTest.m
    │   ├── WiFiSpeedTest.m
    │   └── LatencyTest.m
    ├── Integration/
    │   ├── PipelineTest.m
    │   ├── DegradationTest.m
    │   ├── FailoverTest.m
    │   └── InputRoundtripTest.m
    └── Fixtures/
        ├── test_frame_4k_desktop.raw
        ├── test_frame_4k_scroll.raw
        ├── test_frame_gradient.raw
        └── test_payload_1mb.bin
```

### Structure Rationale

- **Shared/ contains only C headers and C source:** No Swift, no Obj-C. Both macOS agent and iPadOS app consume these via their respective include paths. LZ4 vendored directly — two files (lz4.c, lz4.h) added to Xcode targets' "Compile Sources" phase. No SPM, no xcframework needed.
- **FrameCompressor.c is pure C, not Obj-C:** The hot-path LZ4+delta compressor is the one function called at up to 120Hz. Pure C avoids Obj-C runtime dispatch and message passing overhead. Obj-C wrapper (ScreenCapture.m) extracts the IOSurface from the CMSampleBuffer and hands a raw pointer to FrameCompressor.
- **EventInjector.c is pure C:** CGEvent functions are C functions (`CGEventCreateKeyboardEvent`, `CGEventPost`). No Obj-C needed. Stays pure C.
- **Separate Xcode projects for macOS and iPadOS:** No shared workspace or xcworkspace needed for personal use. Each project builds independently.
- **Tests/ is its own target group:** Protocol and compression tests are pure C and run on any CI machine without physical devices. Transport and integration tests require hardware and are separate targets.

---

## Architectural Patterns

### Pattern 1: USB NCM Interface Detection

**What:** On macOS, when an iPad is connected via USB-C/Thunderbolt, the system automatically creates a USB NCM (Network Control Model) virtual Ethernet interface — typically named `en4`, `en5`, or `en6` depending on system configuration. This interface appears as `.wiredEthernet` in NWPathMonitor's interface type classification (HIGH confidence: NWInterface.InterfaceType.wiredEthernet covers all Ethernet-class adapters including USB NCM). Both the Mac agent and iPad app detect this interface and bind their sockets to it.

On the iPad side, USB NCM similarly creates a wiredEthernet-type interface.

**Detection approach (macOS, Objective-C using C API):**

```objc
// USBNetworkTransport.m
- (void)startMonitoringForUSBNCM {
    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(
        nw_interface_type_wired
    );
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
            const char *name = nw_interface_get_name(interface);
            // USB NCM interface names: en4, en5, en6 — check by type
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

**Detection approach (iPadOS, Swift):**

```swift
// USBNetworkTransport.swift
private func startMonitoringForUSBNCM() {
    let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    monitor.pathUpdateHandler = { [weak self] path in
        guard path.status == .satisfied else { return }
        // USB NCM is available — connect
        self?.connectOverUSBNCM(path: path)
    }
    monitor.start(queue: .main)
}
```

**Critical nuance:** The Mac-side NWListener for UDP (media) must bind to the NCM interface IP, not 0.0.0.0, because otherwise it will also accept Wi-Fi connections when Wi-Fi fallback is active simultaneously. The NCM interface has a link-local IPv6 address (`fe80::/10`) and optionally an IPv4 link-local address (`169.254.x.x`). Use IPv6 link-local for reliability — it's always present on USB NCM.

**When to use:** Always use NWPathMonitor for interface detection. Never hardcode interface names (`en4`, etc.) — they vary per system.

---

### Pattern 2: Zero-Copy ScreenCaptureKit → LZ4 Pipeline

**What:** ScreenCaptureKit delivers frames as `CMSampleBuffer` containing a `CVPixelBuffer` backed by an `IOSurface`. The hot path must avoid copying frame data. The correct approach: lock the IOSurface, get a read pointer, run LZ4 compress in-place, unlock, and send. No intermediate Data copy.

**Pixel format:** Use `kCVPixelFormatType_32BGRA` in `SCStreamConfiguration`. This matches the wire format (BGRA) the iPad expects for Metal texture upload, avoiding any color conversion on either side.

**SCStreamConfiguration (Objective-C):**

```objc
// ScreenCapture.m
- (SCStreamConfiguration *)buildStreamConfig {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.minimumFrameInterval = CMTimeMake(1, 120); // up to 120fps
    config.queueDepth = 3;          // 3 frames — low latency, don't buffer more
    config.showsCursor = YES;
    // For full display capture, width/height are set from SCDisplay dimensions
    config.width = display.width;
    config.height = display.height;
    return config;
}

// SCStreamOutput delegate
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    // Hand off to FrameCompressor — zero copy
    [self.compressor compressFrame:surface timestamp:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
}
```

**FrameCompressor.c zero-copy access:**

```c
// FrameCompressor.c
void compress_frame(IOSurfaceRef surface, uint64_t ts_us, CompressOutput *out) {
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    size_t bytes = IOSurfaceGetAllocSize(surface);
    // Compute delta vs previous frame, then LZ4 compress
    // ...
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}
```

**When to use:** Any time ScreenCaptureKit delivers a frame. Never call `CVPixelBufferCopyToByteBuffer` or similar copy helpers in the hot path.

---

### Pattern 3: Binary Protocol Framing (C structs, both sides)

**What:** The Shared/protocol.h defines C structs that are memory-layout compatible on both ARM64 (Mac M1, iPad M4) — both are little-endian 64-bit. Pack structs with `__attribute__((packed))` to prevent padding. The iPad's Protocol.swift uses `withUnsafeBytes` to parse the same layout.

**protocol.h:**

```c
// Shared/protocol.h
#pragma once
#include <stdint.h>

#define KEYDRD_MAGIC 0x4B44   // 'KD'
#define KEYDRD_SERVICE "_keydrd._tcp"
#define KEYDRD_MEDIA_PORT 14567   // UDP
#define KEYDRD_INPUT_PORT 14568   // TCP

typedef struct __attribute__((packed)) {
    uint16_t magic;      // 0x4B44
    uint8_t  flags;      // bit0: 0=LZ4 1=HEVC, bit1: keyframe, bit2: last_chunk,
                         // bit3-4: res_tier, bit5: eco, bit6: delta, bit7: reserved
    uint32_t seq;        // frame sequence number
    uint16_t chunk_idx;  // chunk index within frame (0-based)
    uint16_t chunk_total; // total chunks in frame
    uint32_t payload_size; // compressed payload bytes following this header
    uint64_t ts_us;      // capture timestamp microseconds
    uint32_t crc32;      // CRC32 of payload bytes
    // payload follows
} MediaFrameHeader;      // 24 bytes

typedef struct __attribute__((packed)) {
    uint8_t  type;       // 0x01 mouse_move, 0x02 click, 0x03 scroll, 0x10 key, 0x20 mode, 0x30 keepalive, 0xFF latency_probe
    uint64_t ts_us;      // event timestamp microseconds
    // payload follows (variable, type-specific)
} InputEventHeader;      // 9 bytes
```

**Protocol.swift (iPad mirror):**

```swift
// Protocol.swift
import Foundation

let KEYDRD_MAGIC: UInt16 = 0x4B44

struct MediaFrameHeader {
    let magic: UInt16
    let flags: UInt8
    let seq: UInt32
    let chunkIdx: UInt16
    let chunkTotal: UInt16
    let payloadSize: UInt32
    let tsUs: UInt64
    let crc32: UInt32

    // Flags accessors
    var isHEVC: Bool { flags & 0x01 != 0 }
    var isKeyframe: Bool { flags & 0x02 != 0 }
    var isLastChunk: Bool { flags & 0x04 != 0 }
    var isDelta: Bool { flags & 0x40 != 0 }

    static func parse(from data: Data) -> MediaFrameHeader? {
        guard data.count >= 24 else { return nil }
        return data.withUnsafeBytes { $0.load(as: MediaFrameHeader.self) }
    }
}
```

**When to use:** All frame parsing and packing. Never use JSON in the media or input data paths.

---

### Pattern 4: Wired LZ4 + Delta Frame Flow

**Data flow diagram (wired mode, <8ms target):**

```
Mac (ScreenCaptureKit callback thread)
  │
  │  IOSurface (zero-copy)
  ▼
FrameCompressor.c
  ├── Is this frame a keyframe?
  │   YES → LZ4_compress_default(surface_base, out_buf, frame_bytes)
  │   NO  → XOR(current_surface, prev_keyframe_buf) → delta_buf
  │          → LZ4_compress_default(delta_buf, out_buf, delta_bytes)
  │          If compressed_size > 0.6 * keyframe_size: send keyframe instead
  │
  ├── Pack MediaFrameHeader (24 bytes)
  │   flags: LZ4=0 or HEVC=1, keyframe bit, delta bit
  │   payload_size = compressed_size
  │   ts_us = capture timestamp
  │   crc32 = CRC32(out_buf, compressed_size)
  │
  └── Chunk if compressed_size > UDP MTU (~64KB safe for USB NCM)
      Send each chunk as separate UDP datagram
      Last chunk sets bit2 (last_chunk) in flags

Wire (USB NCM UDP, < 0.5ms)

iPad (NWConnection receive callback)
  │
  │  UDP datagram bytes
  ▼
Protocol.swift
  ├── Parse MediaFrameHeader (first 24 bytes)
  ├── Verify magic, crc32
  └── Accumulate chunks until last_chunk bit set

LZ4Decompressor.swift
  ├── If delta frame: LZ4_decompress_safe() → XOR(delta, prev_keyframe) → current_frame
  └── If keyframe: LZ4_decompress_safe() → current_frame (save as prev_keyframe)

MetalRenderer.swift
  ├── Upload current_frame bytes → MTLTexture (BGRA)
  └── MTKView draw: sample texture, P3 color transform in fragment shader
```

---

### Pattern 5: HEVC Wireless Flow

**Data flow diagram (wireless mode, <25ms target):**

```
Mac (ScreenCaptureKit callback thread)
  │
  │  CVPixelBuffer (IOSurface-backed)
  ▼
HEVCEncoder.m
  ├── VTCompressionSessionEncodeFrame(session, pixelBuffer, ts, duration, NULL, NULL, &flags)
  │   Properties set at session create:
  │     kVTCompressionPropertyKey_RealTime = kCFBooleanTrue
  │     kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse
  │     kVTCompressionPropertyKey_AverageBitRate = 50_000_000  (50 Mbps for 4K)
  │     kVTCompressionPropertyKey_ProfileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
  │
  └── Output callback: VTCompressionOutputCallback
      ├── CMSampleBuffer → get data buffer → get byte pointer
      ├── Pack MediaFrameHeader (flags bit0=1 for HEVC, bit1=keyframe from VTEncodeInfoFlags)
      └── Send as UDP datagram(s) over WirelessTransport

Wire (Wi-Fi UDP or AWDL, <5ms typical)

iPad (NWConnection receive callback)
  │
  │  UDP datagram bytes (HEVC NAL units)
  ▼
Protocol.swift
  └── Reassemble chunks, verify header

HEVCDecoder.swift
  ├── CMBlockBuffer from raw bytes
  ├── CMSampleBuffer wrapping block buffer
  └── VTDecompressionSessionDecodeFrame → CVPixelBuffer output callback

MetalRenderer.swift
  └── Same as wired: CVPixelBuffer → MTLTexture → draw
```

---

### Pattern 6: Transport Failover State Machine

**What:** Three transport modes with automatic cascade. State machine mirrors keyd v1.0's USB→AWDL FSM but adds Wi-Fi as intermediate step.

```
States: IDLE → USB_NCM → WIFI → AWDL → DISCONNECTED

USB_NCM:
  NWPathMonitor(.wiredEthernet).status == .satisfied
  Media: UDP over NCM interface
  Input: TCP over NCM interface
  Encode: LZ4+delta (wired mode)

WIFI (fallback):
  NWPathMonitor(.wiredEthernet).status != .satisfied
  NWPathMonitor(.wifi).status == .satisfied
  Media: UDP over Wi-Fi
  Input: TCP over Wi-Fi
  Encode: HEVC (wireless mode)
  Trigger: NWPathMonitor path update (fires within ~2 seconds of USB disconnect)

AWDL (last resort):
  NWPathMonitor(.wifi).status != .satisfied
  NWBrowser finds _keydrd._tcp peer
  Encode: HEVC (wireless mode)

Transitions:
  USB disconnect → immediately start WIFI connect attempt
  WIFI unavailable → start AWDL discovery
  USB reconnect → immediately promote back to USB_NCM
  Mode change also switches encode mode (LZ4 ↔ HEVC)
```

**Mac-side (Obj-C):** Transport state machine owned by `main.m`/AppDelegate. Starts all three transport listeners simultaneously; media is sent only on the active transport. NWPathMonitor callback triggers state transitions.

**iPad-side (Swift):** Same FSM as Swift actor. Owns the active NWConnection reference.

---

### Pattern 7: C + Objective-C Xcode Project (No Swift)

**What:** The macOS agent is C + Objective-C only. No Swift runtime. Xcode handles this cleanly — simply do not add any `.swift` files to the target.

**Xcode project setup:**

1. Create a new macOS project. Choose "App" template. Immediately delete the generated Swift files.
2. In Build Settings: set `SWIFT_VERSION` to nothing (leave blank or remove). Xcode will not invoke swiftc.
3. In Build Settings: set `GCC_C_LANGUAGE_STANDARD = c11`.
4. Add `.m` (Obj-C) and `.c` (pure C) files to the target. Xcode compiles them with Clang automatically.
5. For mixing C and Obj-C in the same target: no bridging header needed. `.m` files can `#import` `.h` files freely. `.c` files can `#include` `.h` files. Keep `.h` files as plain C headers (no Obj-C syntax) if they must be included from both `.c` and `.m` files.
6. Add vendored `lz4.c` and `lz4.h` from `../Shared/` to the macOS target's Compile Sources phase. Set their target membership.
7. Set Header Search Paths to include `../Shared/` so all targets can find `protocol.h`, `lz4.h`, `delta.h`.

**Info.plist required keys (macOS agent):**
```xml
<key>LSUIElement</key>
<true/>                          <!-- No Dock icon. Menu bar only. -->
<key>NSScreenCaptureUsageDescription</key>
<string>Remote Desktop requires screen capture to stream your Mac display to your iPad.</string>
<key>NSAppleEventsUsageDescription</key>
<string>...</string>
```

**Entitlements required (macOS agent, no App Sandbox):**
```xml
<!-- RemoteDesktopAgent.entitlements -->
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

No App Sandbox: required for CGEvent injection and unrestricted network socket binding to specific interfaces. Same rationale as keyd v1.0.

**Linking ScreenCaptureKit, VideoToolbox, Network.framework from Obj-C:**

Add to Link Binary With Libraries phase in Xcode:
- `ScreenCaptureKit.framework`
- `VideoToolbox.framework`
- `CoreMedia.framework`
- `CoreVideo.framework`
- `IOSurface.framework`

In `.m` files:
```objc
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Network/Network.h>   // C API for Network.framework
```

---

### Pattern 8: LZ4 Vendoring in iPadOS Swift Target

**What:** The iPadOS app uses LZ4 via a bridging header to call the C API.

**Setup:**
1. Copy `lz4.c` and `lz4.h` (and `delta.c`, `delta.h`) from `Shared/` into the iPadOS target's Compile Sources.
2. Create `SharedProtocol-Bridging-Header.h` in the iPadOS target:
   ```c
   #include "lz4.h"
   #include "delta.h"
   ```
3. Set `SWIFT_OBJC_BRIDGING_HEADER` build setting to point to this file.
4. Swift calls LZ4 directly:
   ```swift
   // LZ4Decompressor.swift
   func decompress(src: UnsafeRawPointer, srcSize: Int, dst: UnsafeMutableRawPointer, dstCapacity: Int) -> Int {
       return Int(LZ4_decompress_safe(src, dst, Int32(srcSize), Int32(dstCapacity)))
   }
   ```

---

### Pattern 9: ScreenCaptureKit Permission (macOS Sequoia)

**Critical macOS 15 behavior:** In macOS 15 Sequoia, apps using ScreenCaptureKit without `SCContentSharingPicker` receive a monthly re-authorization prompt. For a remote desktop agent that runs unattended, this is disruptive.

**Options (in order of preference):**

1. **`com.apple.developer.persistent-content-capture` entitlement** — intended for VNC/screen sharing apps. Bypasses monthly prompt. Apple grants it on application (form available). For a self-signed personal-use app: this entitlement can be added to the entitlements file and signed with a personal certificate. Apple's review is for App Store apps; self-signed does not require Apple approval. HIGH confidence: the entitlement key works when added to a self-signed binary.

2. **`SCContentSharingPicker`** — uses system picker UI, no TCC prompt needed. BUT: the system picker is interactive (user selects window/screen each time). Not suitable for an auto-start background agent.

3. **Accept monthly prompt** — simplest for personal use. The prompt is monthly in macOS 15 (reduced from weekly in beta). For a personal device, this is tolerable.

**Recommendation:** Add `com.apple.developer.persistent-content-capture` to the entitlements file. If it fails to suppress the prompt when self-signed, fall back to accepting monthly re-authorization.

**Permission check at agent startup (Objective-C):**
```objc
// main.m
if (!CGPreflightScreenCaptureAccess()) {
    CGRequestScreenCaptureAccess();
    // Show menu bar indicator: "Screen Recording permission required"
    return; // Don't start capture until permission granted
}
if (!AXIsProcessTrusted()) {
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}
```

---

## Data Flow

### Flow 1: Wired LZ4 + Delta (Primary Mode)

```
[Display content changes on Mac]
        ↓ hardware
ScreenCaptureKit (SCStream, hardware GPU pipeline)
        ↓ CMSampleBuffer (IOSurface-backed, zero-copy)
ScreenCapture.m delegate callback
        ↓ IOSurface pointer
FrameCompressor.c
  ├── XOR(current, prev_keyframe) → delta_buf (if delta frame)
  ├── LZ4_compress_default() → compressed_buf
  └── Pack MediaFrameHeader, CRC32, chunk split
        ↓ UDP datagrams (24-byte header + payload)
USBNetworkTransport.m (NWConnection UDP send over NCM interface)
        ↓ USB-C cable (USB 3.x / TB4, < 0.5ms)
USBNetworkTransport.swift (NWConnection UDP recv)
        ↓ raw datagram bytes
Protocol.swift (header parse, chunk reassembly)
        ↓ complete frame bytes
LZ4Decompressor.swift
  ├── LZ4_decompress_safe() → raw_frame
  └── If delta: XOR(raw_frame, prev_keyframe) → current_frame
        ↓ BGRA pixel data (width * height * 4 bytes)
MetalRenderer.swift
  ├── replaceRegion on MTLTexture (BGRA, full frame or dirty rect only)
  └── MTKView.draw() → fragment shader → ProMotion display
        ↓ photons
[User sees updated Mac screen on iPad, <8ms glass-to-glass]
```

### Flow 2: Wireless HEVC (Fallback Mode)

```
[Display content changes on Mac]
        ↓
ScreenCaptureKit → CMSampleBuffer (CVPixelBuffer)
        ↓
HEVCEncoder.m
  └── VTCompressionSessionEncodeFrame() [media engine, not CPU]
      Output callback → CMSampleBuffer (HEVC NAL units)
        ↓ UDP datagrams (24-byte header + HEVC payload)
WirelessTransport.m (NWConnection UDP send over Wi-Fi)
        ↓ Wi-Fi (< 5ms typical)
WirelessTransport.swift (NWConnection UDP recv)
        ↓ reassembled HEVC bytes
HEVCDecoder.swift
  └── VTDecompressionSessionDecodeFrame() [media engine] → CVPixelBuffer
        ↓
MetalRenderer.swift → MTLTexture → display
[User sees updated Mac screen, <25ms glass-to-glass]
```

### Flow 3: Input (iPad → Mac, Both Modes)

```
[User touches iPad screen or presses key]
        ↓
TouchToMouse.swift (UIPanGestureRecognizer, UITapGestureRecognizer)
  OR KeyboardCapture.swift (UITextInput / external keyboard)
        ↓ InputEvent struct (type + timestamp + payload)
Protocol.swift (pack 9-byte InputEventHeader)
        ↓
USBNetworkTransport.swift or WirelessTransport.swift
  NWConnection TCP send (reliable, ordered)
        ↓ USB NCM TCP or Wi-Fi TCP
USBNetworkTransport.m or WirelessTransport.m
  NWConnection TCP receive callback
        ↓ InputEventHeader parse
EventInjector.c
  ├── 0x01 mouse_move → CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft)
  ├── 0x02 click → CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft)
  ├── 0x03 scroll → CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, dy, dx)
  └── 0x10 key → CGEventCreateKeyboardEvent(NULL, keycode, keyDown)
  CGEventPost(kCGHIDEventTap, event)
[Input injected into frontmost macOS application]
```

### Flow 4: Transport Failover (USB → Wi-Fi)

```
[User unplugs USB-C cable]
        ↓ ~0-2 seconds
NWPathMonitor (wiredEthernet) fires path update: status = .unsatisfied
        ↓
TransportFSM: USB_NCM → WIFI
  ├── Mac: activate WirelessTransport (NWBrowser already advertising _keydrd._tcp)
  ├── Mac: switch HEVCEncoder (if not already started, create VTCompressionSession)
  ├── Mac: send mode-switch input event 0x20 (mode=HEVC) to iPad
  │
  ├── iPad: NWPathMonitor fires, USBNetworkTransport NWConnection terminates
  ├── iPad: WirelessTransport NWBrowser already discovered _keydrd._tcp peer
  └── iPad: connect WirelessTransport, switch to HEVCDecoder
        ↓ ~1-2 seconds total
[Streaming resumes over Wi-Fi with HEVC]
```

---

## Build Order (What Must Exist Before What)

```
1. Shared/protocol.h + Shared/lz4.c + Shared/delta.c
   — Defines all structs and compression functions. Both sides depend on this.
   — Write and test in isolation with FramingTests.c and LZ4RoundtripTests.c first.

2. RemoteDesktop/macOS — EventInjector.c only
   — CGEvent injection. Can be tested on macOS alone without any iOS code.
   — Smoke test: hardcoded synthetic mouse move and key press.

3. RemoteDesktop/macOS — USBNetworkTransport (TCP input listener only)
   — Accept a TCP connection, parse InputEventHeader, call EventInjector.
   — Test with netcat or a test client sending raw bytes.

4. RemoteDesktop/iPadOS — USBNetworkTransport (TCP input sender only)
   — TouchToMouse + KeyboardCapture → Protocol.swift → TCP send.
   — Run with step 3: touch iPad → observe CGEvent injection on Mac.
   — First physical device E2E milestone.

5. RemoteDesktop/macOS — ScreenCapture.m + FrameCompressor.c
   — SCStream capture → LZ4 compress → UDP send.
   — Test with USBSpeedTest.m on loopback first, then over USB NCM.

6. RemoteDesktop/iPadOS — USBNetworkTransport (UDP recv) + LZ4Decompressor + MetalRenderer
   — Receive LZ4 frames → decompress → render.
   — Second E2E milestone: see Mac screen on iPad over USB.

7. Transport failover: WirelessTransport on both sides + HEVCEncoder.m + HEVCDecoder.swift
   — Wi-Fi path with HEVC encode/decode.
   — FailoverTest.m: kill USB → verify Wi-Fi takeover.

8. QRPairing.swift + TLS/DTLS setup
   — Add encryption to all channels.
   — Verify TLS handshake does not add >2ms on USB NCM path.

9. Eco mode
   — Configuration knob: HEVC at 1080p/30Hz.
   — DegradationTest.m verifies mode switch behavior.

10. Polish: menu bar state, pairing UI, orientation handling, benchmark regression tracking
```

**Rationale for this order:**
- Input before video: verifying CGEvent injection works (step 2-4) proves the full round-trip without needing video. Video is more complex to debug. Catch input issues early.
- Loopback before physical USB: LZ4 pipeline testing on loopback (LoopbackSpeedTest.c) validates correctness and throughput before introducing USB NCM variables.
- Wired before wireless: USB NCM is deterministic and fast. Wireless adds HEVC, jitter, and connection variables. Validate the pipeline on wired first.
- Security last: TLS overhead is easier to measure and optimize after the pipeline is proven functional. Adding TLS first complicates debugging.

---

## Component Boundaries and Communication

| Boundary | Direction | Contract | Enforcement |
|----------|-----------|----------|-------------|
| ScreenCapture.m → FrameCompressor.c | Obj-C → C | IOSurfaceRef pointer + timestamp | FrameCompressor.h defines a pure C API; ScreenCapture.m calls it with `#import "FrameCompressor.h"` |
| FrameCompressor.c → USBNetworkTransport.m | C → Obj-C | Callback: `void (*on_frame_ready)(const uint8_t *buf, size_t len, uint64_t ts)` | Set as a function pointer on the compressor; transport calls `nw_connection_send` |
| HEVCEncoder.m output callback → WirelessTransport.m | Obj-C block → Obj-C | `VTCompressionOutputCallback`: CMSampleBufferRef | Both are Obj-C; direct method call |
| USBNetworkTransport.m → EventInjector.c | Obj-C → C | `void inject_input_event(const uint8_t *buf, size_t len)` | Pure C function call from the TCP receive handler |
| Protocol.swift → LZ4Decompressor.swift | Swift → Swift | `Data` (frame bytes after header stripped) | Swift function call |
| LZ4Decompressor.swift → MetalRenderer.swift | Swift → Swift | `UnsafeRawBufferPointer` (decoded BGRA pixels) or `CVPixelBuffer` | MTLTexture upload from raw bytes |
| TouchToMouse.swift → Protocol.swift | Swift → Swift | Swift struct: `InputEvent(type:, tsUs:, payload:)` | Direct call |
| Protocol.swift → USBNetworkTransport.swift | Swift → Swift | `Data` (packed binary frame) | `NWConnection.send` |

**Key invariant:** Pure C files (FrameCompressor.c, EventInjector.c, delta.c) have zero Obj-C runtime dependency. They can be tested with a pure C test runner (FramingTests.c, DeltaTests.c). They do NOT include any Obj-C or Swift headers.

---

## Integration Points: New vs Modified Components

### New Components (keyd-rd only)

| Component | Type | Language | Notes |
|-----------|------|----------|-------|
| RemoteDesktop/macOS/ | New Xcode project | C + Obj-C | Entirely new. No code from KeydAgent. |
| RemoteDesktop/iPadOS/ | New Xcode project | Swift | Entirely new. No code from KeydApp. |
| RemoteDesktop/Shared/ | New directory | C | Shared headers only. |
| RemoteDesktop/Tests/ | New test targets | C + Obj-C | New test suite. |

### Modified Components (keyd v1.0)

None. keyd v1.0 code is not modified. The spec is explicit: separate Xcode projects, separate bundle IDs, separate processes. The two products coexist in the same repo but are completely independent at build and runtime.

### Shared Infrastructure (Pattern-Copy, Not Code-Share)

| Pattern Reused | From | Into | Notes |
|----------------|------|------|-------|
| QR pairing + ECDH | macOS/KeydAgent/Pairing/PairingManager.swift | RemoteDesktop/iPadOS/Pairing/QRPairing.swift | Copy logic, adapt for new bundle ID and TLS identity setup |
| CGEvent injection | macOS/KeydAgent/Transport (various) | RemoteDesktop/macOS/Input/EventInjector.c | Rewrite in pure C; same CGEvent API calls |
| Transport failover FSM | macOS/KeydAgent/Transport/TransportManager.swift | USBNetworkTransport.m + WirelessTransport.m | Same state machine pattern, new transport implementations |
| Menu bar NSStatusItem | macOS/KeydAgent/App | RemoteDesktop/macOS/main.m | Same Obj-C NSApplication pattern |
| SMAppService login item | macOS/KeydAgent/App | RemoteDesktop/macOS/main.m | Same registration pattern |
| Bonjour service name | `_keyd._tcp` | `_keydrd._tcp` | New service name to avoid conflicts with v1.0 |

---

## Anti-Patterns

### Anti-Pattern 1: Copying Frame Data Before Compression

**What people do:** Call `CVPixelBufferCopyToByteBuffer` or create an intermediate `NSData` from the pixel buffer before calling LZ4.

**Why it's wrong:** A 4K BGRA frame is 33 MB. Copying before compression doubles peak memory and adds 3-5ms of memcpy on the M1 Max. This blows the <1ms compression budget.

**Do this instead:** Lock the IOSurface, get the base address with `IOSurfaceGetBaseAddress`, pass the pointer directly to `LZ4_compress_default`. Unlock after compression. Zero-copy.

---

### Anti-Pattern 2: Using Swift on the macOS Agent

**What people do:** Add `.swift` files to the macOS agent target for "convenience."

**Why it's wrong:** The Swift runtime adds 15-30 MB baseline RSS immediately. The Mac is resource-constrained (running LLMs). The constraint DC-2 is explicit and locked. Apple's ScreenCaptureKit, VideoToolbox, Network.framework, and CGEvent are all native C/Obj-C APIs — no Swift required.

**Do this instead:** Pure C + Obj-C. Obj-C runtime overhead is minimal (the frameworks themselves use it anyway). If a pattern feels difficult in Obj-C, use a pure C helper function.

---

### Anti-Pattern 3: Using usbmuxd for keyd-rd Transport

**What people do:** Reuse the existing keyd v1.0 usbmuxd TCP tunnel for the remote desktop media stream.

**Why it's wrong:** usbmuxd adds a multiplexing layer and tunneling overhead. keyd-rd needs direct socket access to the USB NCM network interface to achieve USB 3.x / TB4 throughput. A 4K@120Hz LZ4-compressed stream can require 1-3 Gbps — usbmuxd's TCP tunneling cannot sustain this. Additionally, usbmuxd uses TCP which adds per-packet acknowledgement overhead to a media stream that runs fine without reliability guarantees.

**Do this instead:** USB NCM direct sockets via Network.framework over the `.wiredEthernet` interface. UDP for media, separate TCP for input.

---

### Anti-Pattern 4: Building a Shared SPM Package for keyd-rd Protocol

**What people do:** Create a Swift SPM package for shared protocol types (mirroring SharedProtocol from keyd v1.0).

**Why it's wrong:** The macOS agent is C + Obj-C — it cannot use a Swift SPM package. The shared protocol must be expressed as C headers that both C/Obj-C (Mac) and Swift (iPad, via bridging header) can consume.

**Do this instead:** Shared/protocol.h with C structs. iPad side reads these via bridging header. Mac side includes them directly.

---

### Anti-Pattern 5: queueDepth > 3 in SCStreamConfiguration

**What people do:** Leave SCStreamConfiguration.queueDepth at its default (5) or increase it for "smoother" capture.

**Why it's wrong:** Each queued frame adds latency. At 120fps, one frame = 8.3ms. queueDepth=5 adds up to 41ms of buffering before the frame even reaches FrameCompressor. This alone exceeds the 8ms wired latency target.

**Do this instead:** Set `config.queueDepth = 3` (minimum that avoids stall without adding excessive latency). At 120fps this is 25ms max buffer — tight but acceptable given the rest of the pipeline's speed.

---

### Anti-Pattern 6: Hardcoding the USB NCM Interface Name

**What people do:** Hardcode `en4` or `en5` as the USB NCM interface name in socket bind calls.

**Why it's wrong:** The interface name varies by Mac configuration (number of Thunderbolt ports, existing Ethernet adapters). `en4` on one machine is `en6` on another.

**Do this instead:** Use `NWPathMonitor(requiredInterfaceType: .wiredEthernet)` to discover the interface, then use the `NWInterface` from the path to get the name for binding. On macOS with the C API: `nw_path_monitor_create_with_type(nw_interface_type_wired)` → enumerate interfaces in the update handler.

---

## Scaling Considerations

This is a single-user, two-device personal-use system. Traditional scaling does not apply. The relevant performance concerns are:

| Concern | Wired Mode | Wireless Mode | Eco Mode |
|---------|-----------|---------------|----------|
| Mac CPU (target) | <3% | <5% (HEVC is media engine) | <1% |
| Mac RSS (target) | <50 MB | <60 MB | <20 MB |
| Throughput required | 0.5-3 Gbps (LZ4+delta typical) | 30-80 Mbps (HEVC) | 5-15 Mbps |
| Transport capacity | USB NCM: 5-40 Gbps available | Wi-Fi 6: 1+ Gbps available | Either |
| iPad CPU (render) | <10% (M4 is fast) | <15% (HEVC decode + render) | <5% |
| iPad RAM (frame buffers) | ~100-200 MB | ~50 MB | ~30 MB |

**First bottleneck:** LZ4 compression throughput. At 4K@120Hz, a keyframe is ~33 MB. LZ4 at ~8 GB/s throughput compresses 33 MB in ~4ms — tight vs the 1ms budget. Mitigation: use delta frames (typical desktop content reduces compressed size to 1-5% of keyframe, so delta compression is 1 MB → <0.15ms). Keyframes are rare (1-2 per second).

**Second bottleneck:** UDP chunking overhead. If a compressed frame exceeds UDP MTU, it must be split into chunks. Each chunk is a separate datagram with a 24-byte header. For USB NCM, MTU is typically 1500 bytes (Ethernet standard) but can be set higher. Investigate jumbo frames (9000-byte MTU) on USB NCM for fewer chunk datagrams per frame — reduces header overhead.

---

## Sources

- Apple Developer Documentation: ScreenCaptureKit — `SCStream`, `SCStreamConfiguration`, `SCStreamOutput` protocol (HIGH confidence, official API docs)
- Apple Developer Documentation: VideoToolbox — `VTCompressionSession`, `VTDecompressionSession`, HEVC encoding (HIGH confidence, official API)
- Apple Developer Documentation: Network.framework — `NWPathMonitor`, `NWInterface.InterfaceType`, `NWConnection`, `NWListener`, DTLS via `NWParameters.dtls` (HIGH confidence, official API)
- Apple Developer Documentation: CGEvent — `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventPost` (HIGH confidence, stable since macOS 10.4)
- Apple Developer Documentation: IOSurface — `IOSurfaceLock`, `IOSurfaceGetBaseAddress` (HIGH confidence)
- Apple Developer Documentation: Metal — `MTKView`, `MTLTexture`, `MTKViewDelegate` (HIGH confidence)
- Apple Developer Forums: USB CDC ECM/NCM interface detection with NWPathMonitor — `https://developer.apple.com/forums/thread/769793` (MEDIUM confidence, forum discussion)
- Apple Developer Forums: Getting NWInterface for wiredEthernet — `https://developer.apple.com/forums/thread/128215` (MEDIUM confidence)
- mjtsai.com: Sequoia Screen Recording Prompts and Persistent Content Capture Entitlement — `https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/` (MEDIUM confidence, synthesized from forum discussions)
- LZ4 official repository: minimum required files (lz4.c, lz4.h) — `https://github.com/lz4/lz4/blob/dev/lib/README.md` (HIGH confidence)
- WWDC21: Explore low-latency video encoding with VideoToolbox — `https://developer.apple.com/videos/play/wwdc2021/10158/` (HIGH confidence)
- Synacktiv: iOS USB networking stack deep dive — `https://www.synacktiv.com/en/publications/ios-a-journey-in-the-usb-networking-stack` (MEDIUM confidence, research blog)

---

*Architecture research for: keyd-rd v2.0 — iPadOS-to-macOS remote desktop with keyd v1.0 integration*
*Researched: 2026-03-27*
