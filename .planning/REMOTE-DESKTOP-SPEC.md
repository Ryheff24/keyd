# Remote Desktop Spec: keyd-rd

**Author:** Ryheff24
**Date:** 2026-03-27
**Status:** SPEC (pre-GSD)
**Repo:** Same repo as keyd (shared transport infrastructure)

## What This Is

An iPadOS-to-macOS remote desktop app. The iPad Pro (M4) becomes a full-resolution, low-latency remote display and input surface for the Mac (M1 Max). Communication runs over USB-C/Thunderbolt (USB NCM network interface) with automatic Wi-Fi fallback. Designed for personal use — self-signed, not distributed.

## Core Value

The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input (mouse + keyboard), hardware-accelerated, with near-zero Mac CPU cost. No cloud, no account, no subscription, no infrastructure.

## Hardware Targets

| Device | Chip | RAM | Notes |
|---|---|---|---|
| MacBook Pro | M1 Max (24-core GPU) | 32 GB | Resource-constrained — often running local LLMs, heavy apps. Minimal CPU/RAM available. |
| iPad Pro | M4 (10-core GPU) | 8 GB | Idle resources. Faster single-core than M1 Max (~36%). iPad does the heavy compute. |

## Design Constraints

### DC-1: Mac is resource-starved
The Mac frequently runs local LLMs and other memory/CPU-heavy workloads. The remote desktop agent MUST consume minimal CPU, RAM, and GPU. Target: <3% CPU, <50 MB RSS during steady-state streaming. Heavy compute (decompression, rendering, scaling) goes to the iPad.

### DC-2: No Swift runtime on macOS
Swift adds ~15-30 MB baseline memory + ARC overhead. The macOS agent is written in **C + Objective-C only**. Apple frameworks (ScreenCaptureKit, VideoToolbox, CGEvent, Network.framework) are native Objective-C/C APIs — no bridge needed.

### DC-3: Swift on iPad (V1), C rewrite (V2)
iPad V1 is Swift for development speed. V2 rewrites the iPad client in C + Objective-C for consistency and performance. V2 is a separate milestone, not part of the initial spec.

### DC-4: Two physical devices required for E2E testing
The test suite MUST support fully automated end-to-end testing across both physical devices. Tests are deterministic — both sides know exactly what to send and receive.

### DC-5: Reuse keyd infrastructure where applicable
Transport discovery (Bonjour), QR pairing, CGEvent injection, USB detection, failover patterns — reuse from keyd. Protocol layer is entirely new.

## Architecture

### Compute Distribution

```
Mac (minimal work)                    iPad (heavy lifting)
-----------------                    ----------------------
ScreenCaptureKit capture              Network recv
  |                                     |
IOSurface -> LZ4 compress             LZ4 decompress (or HEVC decode)
  (near-zero CPU)                       |
  |                                   Metal render + scale + color manage
UDP send over USB NCM ---------->       |
                                      Display
                                        |
Input capture (touch/keyboard) ---->
  <--------- UDP/TCP input events
CGEvent inject
```

### Transport Stack

#### USB NCM (Primary — Wired)
When an iPad is connected to a Mac via USB-C/Thunderbolt, macOS creates a **USB NCM (Network Control Model) network interface** — a real Ethernet-like link with a link-local IP. This is NOT usbmuxd. Over this interface:
- Standard UDP/TCP sockets at USB 3.x / Thunderbolt 4 link speeds (5-40 Gbps)
- Network.framework on both sides can target this interface explicitly via `NWPathMonitor` + `requiredInterface`
- No artificial throttling, no connection tunneling overhead

**Media stream:** UDP datagrams over USB NCM. UDP is the thinnest transport protocol available to non-jailbroken iPadOS apps (8-byte header, no retransmit, no congestion control). Over a lossless point-to-point USB cable, UDP's "unreliability" is irrelevant — packets don't drop.

**Input stream:** Separate TCP connection over USB NCM (input events MUST be reliable and ordered).

#### Wi-Fi (Fallback — Wireless)
When USB is disconnected, fall back to Wi-Fi (same network or AWDL).
- Media: UDP with optional QUIC (TLS 1.3 built-in, multiplexed streams)
- Input: TCP or QUIC stream
- Auto-switch to HEVC encoding (bandwidth-constrained)

#### Multi-Transport Bonding (Future/Optional)
Both USB NCM and Wi-Fi active simultaneously:
- Input always routes over lowest-latency link (USB when available)
- Media can stripe across both for extra bandwidth
- Instant failover — no reconnection gap

### Compression Strategy

#### Wired Mode: LZ4 + Delta Frames
**Why LZ4:**
- Compress throughput: ~8 GB/s (essentially free on CPU)
- Ratio: 2-3x on desktop content
- Mac CPU cost: near zero
- No hardware encoder needed = no media engine heat/power

**Why Delta Frames:**
- Desktop content is mostly static (cursor, text changes)
- XOR current frame vs previous frame, LZ4-compress the diff
- Typical desktop: 1-5% pixel change per frame -> delta compresses to <1% of raw size
- Fallback: if delta > 60% of full frame, send keyframe instead (scrolling/video content)

**Frame cadence:**
- Keyframe: every 1-2 seconds, or on scene change
- Delta frame: every other frame
- 4K@120Hz raw = ~24 Gbps -> LZ4+delta typical = ~0.5-3 Gbps

#### Wireless Mode: HEVC Hardware Encode
- VideoToolbox hardware encoder on Mac (dedicated media engine — NOT CPU/GPU)
- `kVTCompressionPropertyKey_RealTime = true`
- 30-80 Mbps for 4K@60Hz — fits over Wi-Fi
- Hardware decode on iPad via VideoToolbox

#### Eco Mode
- Resolution: drop to 1080p or 720p
- Framerate: 30Hz
- Encoding: HEVC even over wired
- Target: <1% Mac CPU, <20 MB RSS
- Use case: Mac running LLM inference, just need to see the screen

### Protocol: Binary Framing

#### Media Frame Packet (UDP)

```
Header (24 bytes):
+----------+----------+----------+----------+----------+----------+
| magic(2) | flags(1) | seq(4)   | chunk(2) | chunks(2)| size(4)  |
| 0x4B44   |          | frame #  | idx/N    | total/N  | payload  |
+----------+----------+----------+----------+----------+----------+
| ts_us(8) | crc32(4) | payload...                                |
| timestamp| checksum | [LZ4 or HEVC data]                        |
+----------+----------+-------------------------------------------+

Flags byte:
  bit 0: 0=LZ4, 1=HEVC
  bit 1: keyframe
  bit 2: last chunk in frame
  bit 3-4: resolution tier (0=native, 1=half, 2=quarter)
  bit 5: eco mode
  bit 6: delta frame (XOR against previous keyframe)
  bit 7: reserved
```

#### Input Event Packet (TCP)

```
+----------+----------+-------------------------------+
| type(1)  | ts_us(8) | payload (variable)            |
+----------+----------+-------------------------------+
| 0x01     | ts       | int16 x, int16 y (absolute)   |  mouse move
| 0x02     | ts       | uint8 btn, uint8 state        |  mouse click
| 0x03     | ts       | int16 dx, int16 dy, uint8 mod |  scroll
| 0x10     | ts       | uint16 keycode, uint8 flags   |  key event
| 0x20     | ts       | uint8 mode, uint8 quality     |  mode switch
| 0x30     | ts       | (empty)                       |  keepalive
| 0xFF     | ts       | uint32 echo_id                |  latency probe
+----------+----------+-------------------------------+
```

### Input Handling

**iPad -> Mac (input events):**
- Touch → mouse translation (UIPanGestureRecognizer, UIHoverGestureRecognizer on M4)
- iPad keyboard passthrough (external or on-screen)
- Pinch-to-zoom for resolution/viewport control
- Two-finger scroll → scroll events
- Input polling: 120-240Hz, batched and sent every ~4ms

**Mac injection:**
- CGEvent for mouse move, click, scroll, key events (same as keyd)
- Absolute positioning (iPad touch coordinates mapped to Mac screen coordinates)

### Security

- TLS 1.3 on all channels (TCP input, optionally DTLS on UDP media)
- QR pairing (reuse keyd flow): Mac shows QR, iPad scans, ECDH key exchange
- Certificate pinning after initial pairing
- No cleartext mode — even over USB

### Screen Capture (macOS)

- ScreenCaptureKit: `SCStream` with `SCStreamConfiguration`
- Full display or single window capture
- Retina resolution, up to 120fps
- `CMSampleBuffer` → `IOSurface` → LZ4 compress pipeline
- Minimal Mac CPU — ScreenCaptureKit is hardware-accelerated

### Rendering (iPadOS)

- Metal rendering pipeline
- `MTKView` displaying decompressed frames
- Color space management (P3 display on iPad Pro)
- ProMotion 120Hz adaptive refresh

## Latency Budgets

### Wired (LZ4 + Delta, target: <8ms glass-to-glass)

| Stage | Where | Target |
|---|---|---|
| Screen capture | Mac (hardware) | <3ms |
| LZ4+delta compress | Mac CPU | <1ms |
| UDP send over USB NCM | Wire | <0.5ms |
| LZ4 decompress + apply | iPad CPU | <1ms |
| Metal render | iPad GPU | <2ms |
| **Total** | | **<7.5ms** |

### Wireless (HEVC, target: <25ms glass-to-glass)

| Stage | Where | Target |
|---|---|---|
| Screen capture | Mac (hardware) | <3ms |
| HEVC encode | Mac media engine | <5ms |
| UDP send over Wi-Fi | Air | <5ms |
| HEVC decode | iPad media engine | <3ms |
| Metal render | iPad GPU | <2ms |
| **Total** | | **<18ms** |

### Mac Resource Budget

| Metric | Full Quality (wired) | Wireless | Eco |
|---|---|---|---|
| CPU | <3% | <5% (encode is media engine) | <1% |
| RSS | <50 MB | <60 MB | <20 MB |
| GPU | 0% (no GPU work) | 0% | 0% |
| Media Engine | Idle | Active (HEVC encode) | Active |

## Project Structure

```
keyd/
├── RemoteDesktop/
│   ├── macOS/                          # C + Objective-C (no Swift)
│   │   ├── main.m                      # Entry, menu bar agent
│   │   ├── Capture/
│   │   │   ├── ScreenCapture.m         # ScreenCaptureKit wrapper
│   │   │   └── FrameCompressor.c       # LZ4 + delta compress (pure C, hot path)
│   │   ├── Transport/
│   │   │   ├── USBNetworkTransport.m   # Network.framework USB NCM
│   │   │   ├── WirelessTransport.m     # Wi-Fi/QUIC fallback
│   │   │   └── protocol.c/h           # Binary framing (pure C)
│   │   ├── Input/
│   │   │   └── EventInjector.c         # CGEvent mouse+keyboard injection
│   │   ├── Encode/
│   │   │   └── HEVCEncoder.m           # VideoToolbox (wireless mode only)
│   │   └── RemoteDesktopAgent.xcodeproj
│   │
│   ├── iPadOS/                         # Swift (V1)
│   │   ├── App/
│   │   │   ├── RemoteDesktopApp.swift
│   │   │   └── ContentView.swift
│   │   ├── Render/
│   │   │   ├── MetalRenderer.swift     # MTKView frame display
│   │   │   └── Shaders.metal           # Metal shaders for frame display
│   │   ├── Decode/
│   │   │   ├── LZ4Decompressor.swift   # LZ4 decompress + delta apply
│   │   │   └── HEVCDecoder.swift       # VideoToolbox HEVC decode
│   │   ├── Transport/
│   │   │   ├── USBNetworkTransport.swift
│   │   │   ├── WirelessTransport.swift
│   │   │   └── Protocol.swift          # Binary framing
│   │   ├── Input/
│   │   │   ├── TouchToMouse.swift      # Gesture → mouse event translation
│   │   │   └── KeyboardCapture.swift   # Physical/virtual keyboard capture
│   │   ├── Pairing/
│   │   │   └── QRPairing.swift         # QR code scan + key exchange
│   │   └── RemoteDesktopApp.xcodeproj
│   │
│   ├── Shared/
│   │   ├── protocol.h                  # Binary protocol definitions (C header)
│   │   ├── lz4.c/h                     # LZ4 (vendored, single file)
│   │   ├── delta.c/h                   # Delta frame XOR (pure C)
│   │   └── crypto.h                    # Shared crypto constants
│   │
│   └── Tests/
│       ├── Protocol/
│       │   ├── FramingTests.c          # Known bytes → frame → deframe → verify
│       │   ├── DeltaTests.c            # Known frame pair → delta → apply → verify
│       │   └── ChunkReassemblyTests.c  # Split → reassemble → verify
│       │
│       ├── Compression/
│       │   ├── LZ4RoundtripTests.c     # Synthetic frames → compress → decompress → bitwise verify
│       │   ├── DeltaCompressionTests.c # Frame pairs → delta+LZ4 → decompress+apply → verify
│       │   └── ThroughputBenchmark.c   # 1000 frames → measure MB/s, report P50/P99
│       │
│       ├── Transport/
│       │   ├── LoopbackSpeedTest.c     # Both sides on lo0 → blast UDP → measure throughput
│       │   ├── USBSpeedTest.m          # Deterministic payload over USB NCM → measure Gbps
│       │   ├── WiFiSpeedTest.m         # Same over Wi-Fi → measure + compare
│       │   └── LatencyTest.m           # Timestamped ping-pong → report P50/P99/P999
│       │
│       ├── Integration/
│       │   ├── PipelineTest.m          # Synthetic frame → full pipeline → verify
│       │   ├── DegradationTest.m       # Bandwidth constraint → verify mode switch
│       │   ├── FailoverTest.m          # Kill USB → verify Wi-Fi takeover
│       │   └── InputRoundtripTest.m    # Send input → verify CGEvent injection → verify ack
│       │
│       └── Fixtures/
│           ├── test_frame_4k_desktop.raw
│           ├── test_frame_4k_scroll.raw
│           ├── test_frame_gradient.raw
│           └── test_payload_1mb.bin
```

## Requirements

### Transport

- **RD-TRANS-01**: iPad connects to Mac over USB NCM network interface (not usbmuxd)
- **RD-TRANS-02**: iPad connects to Mac over Wi-Fi (same network) as fallback
- **RD-TRANS-03**: Connection automatically falls back from USB to Wi-Fi when cable is unplugged
- **RD-TRANS-04**: Media stream uses UDP datagrams (8-byte header, no retransmit)
- **RD-TRANS-05**: Input stream uses separate TCP connection (reliable, ordered)
- **RD-TRANS-06**: Wire protocol uses binary framing (24-byte media header, 9-byte input header)
- **RD-TRANS-07**: Both devices detect USB NCM interface via NWPathMonitor + requiredInterface
- **RD-TRANS-08**: Transport supports simultaneous USB + Wi-Fi with intelligent routing
- **RD-TRANS-09**: Failover from USB to Wi-Fi completes within 2 seconds with no user action

### Screen Capture

- **RD-CAP-01**: macOS agent captures full display via ScreenCaptureKit at Retina resolution
- **RD-CAP-02**: Capture supports up to 120fps
- **RD-CAP-03**: Capture delivers IOSurface/CMSampleBuffer directly to compress pipeline (no copy)
- **RD-CAP-04**: Capture CPU usage <1% in steady state

### Compression

- **RD-COMP-01**: Wired mode uses LZ4 compression on full keyframes
- **RD-COMP-02**: Wired mode uses XOR delta frames between keyframes, LZ4-compressed
- **RD-COMP-03**: Keyframes sent every 1-2 seconds or when delta exceeds 60% of keyframe size
- **RD-COMP-04**: Wireless mode uses VideoToolbox HEVC hardware encoder (realtime, low-latency profile)
- **RD-COMP-05**: Eco mode uses HEVC at reduced resolution (1080p or 720p) and framerate (30Hz)
- **RD-COMP-06**: LZ4 compress completes in <1ms per 4K frame
- **RD-COMP-07**: Mode switching (LZ4 ↔ HEVC) triggered automatically by transport change or manually by user

### Rendering

- **RD-REND-01**: iPad renders frames via Metal (MTKView)
- **RD-REND-02**: Rendering supports P3 wide color gamut (iPad Pro display)
- **RD-REND-03**: Rendering supports ProMotion 120Hz adaptive refresh
- **RD-REND-04**: LZ4 decompression + delta apply + Metal render completes in <3ms per frame on iPad

### Input

- **RD-INPUT-01**: Touch gestures on iPad translate to mouse move events on Mac
- **RD-INPUT-02**: Tap translates to mouse click (single tap = left click, two-finger tap = right click)
- **RD-INPUT-03**: Two-finger pan translates to scroll events
- **RD-INPUT-04**: Physical keyboard connected to iPad passes keystrokes to Mac
- **RD-INPUT-05**: On-screen iPad keyboard passes keystrokes to Mac
- **RD-INPUT-06**: Input events polled at 120Hz minimum, sent every ~4ms
- **RD-INPUT-07**: Mac injects all input via CGEvent (mouse move, click, scroll, key up/down)
- **RD-INPUT-08**: iPad touch coordinates map to absolute Mac screen coordinates
- **RD-INPUT-09**: Pinch-to-zoom adjusts viewport/resolution on iPad (does not zoom Mac)

### Security

- **RD-SEC-01**: All channels encrypted with TLS 1.3 (TCP) / DTLS 1.3 (UDP)
- **RD-SEC-02**: Initial pairing via QR code (Mac displays, iPad scans) with ECDH key exchange
- **RD-SEC-03**: Certificate pinning after initial pairing (reject unknown certs)
- **RD-SEC-04**: No cleartext mode — encryption mandatory even over USB

### Performance

- **RD-PERF-01**: Glass-to-glass latency <8ms over wired (LZ4+delta path)
- **RD-PERF-02**: Glass-to-glass latency <25ms over wireless (HEVC path)
- **RD-PERF-03**: Mac agent CPU usage <3% during wired streaming
- **RD-PERF-04**: Mac agent RSS <50 MB during wired streaming
- **RD-PERF-05**: Mac agent CPU usage <1% in eco mode
- **RD-PERF-06**: Mac agent RSS <20 MB in eco mode
- **RD-PERF-07**: Mac agent uses 0% GPU in all modes (no GPU work on Mac)
- **RD-PERF-08**: Input-to-screen latency <12ms (input event sent → result visible on iPad)

### Agent

- **RD-AGENT-01**: macOS agent runs as menu bar app (no dock icon)
- **RD-AGENT-02**: macOS agent written in C + Objective-C only (no Swift runtime)
- **RD-AGENT-03**: macOS agent starts at login via SMAppService (or launchd)
- **RD-AGENT-04**: macOS agent prompts for Screen Recording permission via system alert
- **RD-AGENT-05**: macOS agent prompts for Accessibility permission (for CGEvent injection)
- **RD-AGENT-06**: Menu bar shows connection state (USB/Wi-Fi/disconnected) and current mode (quality/eco)

### iPad App

- **RD-APP-01**: iPad app displays remote Mac screen at full Retina resolution
- **RD-APP-02**: iPad app shows connection status (USB/Wi-Fi/disconnected, latency, FPS)
- **RD-APP-03**: iPad app provides mode toggle (full quality / eco)
- **RD-APP-04**: iPad app supports landscape and portrait orientation
- **RD-APP-05**: iPad app supports iPad Pro 11" and 13" screen sizes

### Testing

- **RD-TEST-01**: Protocol-level unit tests: known bytes in → framed → deframed → bitwise verify
- **RD-TEST-02**: Compression roundtrip tests: synthetic frames → compress → decompress → bitwise identical
- **RD-TEST-03**: Throughput benchmarks: measure actual Gbps over each transport, report P50/P99
- **RD-TEST-04**: Latency benchmarks: timestamped ping-pong, report P50/P99/P999 RTT
- **RD-TEST-05**: Loopback tests run on single machine (lo0) for CI — no hardware required
- **RD-TEST-06**: E2E device tests: full pipeline (capture → compress → send → recv → decompress → render) with deterministic synthetic frames across 2 physical devices
- **RD-TEST-07**: Failover tests: kill USB mid-stream → verify seamless Wi-Fi takeover
- **RD-TEST-08**: Input roundtrip tests: send known input → verify CGEvent injection → verify ack
- **RD-TEST-09**: Both devices use same PRNG seed for deterministic payloads — each side knows exactly what the other should send and receive
- **RD-TEST-10**: Benchmark results saved to JSON for regression tracking across runs

## Bundle Identifiers

- macOS agent: `com.ryheff.keyd.remote.agent`
- iPadOS app: `com.ryheff.keyd.remote.app`
- iPadOS tests: `com.ryheff.keyd.remote.app.tests`

## Locked Decisions

These decisions are final and MUST NOT change:

1. **UDP for media over USB NCM** — thinnest protocol available to non-jailbroken iPadOS apps
2. **TCP for input** — input events must be reliable and ordered
3. **LZ4 + delta for wired** — near-zero Mac CPU cost, sufficient compression for TB4 bandwidth
4. **HEVC for wireless** — hardware media engine, not CPU/GPU
5. **C + Objective-C on macOS** — no Swift runtime, minimal footprint
6. **CGEvent for input injection** — same rationale as keyd (AX writes fail in Safari/Firefox)
7. **ScreenCaptureKit for capture** — Apple's modern, hardware-accelerated capture API
8. **Metal for iPad rendering** — hardware-accelerated, P3 color, ProMotion
9. **QR pairing with ECDH** — reuse keyd pattern
10. **TLS 1.3 mandatory** — no cleartext, even over USB
11. **Heavy compute on iPad** — Mac is resource-starved, iPad has idle capacity
12. **Binary protocol** — no JSON, no text encoding in the data path

## Open Questions

1. **AWDL vs infrastructure Wi-Fi**: Should wireless fallback use AWDL (peer-to-peer, no router needed, like keyd) or infrastructure Wi-Fi (faster, more reliable, requires same network)? Or both with preference order?
2. **Audio streaming**: Is audio needed? If so, Opus or AAC-LC, separate UDP stream.
3. **Multi-monitor**: Support multiple Mac displays? If so, user selects which display or capture all.
4. **Clipboard sync**: Bidirectional clipboard between iPad and Mac?
5. **File drag-and-drop**: Drag files from iPad to Mac desktop or vice versa?

## Relationship to keyd

keyd and keyd-rd share this repo. They are separate products with separate Xcode projects and bundle IDs. Shared infrastructure:
- QR pairing flow (copy, adapt for new bundle IDs)
- CGEvent injection patterns
- USB device detection via IOKit
- Bonjour service discovery patterns
- Transport failover state machine pattern
- Menu bar agent architecture

The keyd transport protocol (JSON over usbmuxd TCP) is NOT reused. keyd-rd has its own binary protocol over USB NCM UDP.
