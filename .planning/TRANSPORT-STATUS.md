# Transport & Pipeline Technical Status

Last updated: 2026-03-30

This document captures the current implemented state of the transport layer, encode/decode pipeline, and security model.

Evidence labels used below:
- **Verified in source**: directly traceable to current checked-in code
- **Measured**: observed by the current test suite or manually recorded runs
- **Inference**: plausible explanation, but not isolated/proven by targeted testing
- **Open question**: strong claim previously made, but not fully proven by source or primary platform documentation

---

## Transport Architecture

### USB NCM (Primary)
- **Media delivery**: TCP with 4-byte length-prefix framing (port 14568)
- **Input events**: TCP with 4-byte length-prefix framing (port 14568, same connection)
- **TCP_NODELAY**: Enabled on all TCP connections (both macOS and iPad)
- **HEVC bitrate**: 150 Mbps (0.38 bpp at 3600x2338)
- **Link speed**: USB 2.0 ~280 Mbps effective, USB 3.0 ~5 Gbps (device-dependent)
- **Transport RTT**: ~1-2ms median

Implementation note:
- **Verified in source**: SessionManager currently routes USB media through the TCP/TLS input channel on port 14568.
- **Verified in source**: DTLS/UDP USB media paths still exist in the transport classes, but they are not the path used by the current session wiring.

#### Why TCP, Not UDP for USB NCM
Current project testing found DTLS/UDP over USB NCM unreliable enough that the implementation was switched to TCP framing for USB media:

| Approach | Result |
|----------|--------|
| Rapid-fire UDP sends | ~29/30 frames dropped |
| `nw_connection_batch()` grouped sends | Same — frames still dropped |
| Completion-paced sequential sends (each chunk waits for prev completion) | Black screen — no frames delivered |

- **Open question**: the repo does not prove a driver/framework root cause. What is proven is narrower: the current DTLS-over-USB implementation did not reach reliable media delivery with the attempted pacing strategies.
- **Verified in source**: the active implementation therefore uses TCP with TCP_NODELAY for USB media.

TCP with TCP_NODELAY over the same USB NCM link gives 0% frame loss at 1ms RTT.

### WiFi (Fallback)
- **Media delivery**: UDP/DTLS with chunking (port 14567)
- **Input events**: TCP/TLS with length-prefix framing (port 14568)
- **HEVC bitrate**: 20 Mbps
- **Chunk MTU**: 1400 bytes (WiFi), 8000 bytes (USB, unused currently)
- **Reassembly**: UDPReassembler on iPad — max 32 concurrent sequences, 500ms timeout
- **Known issue**: Real-world WiFi usage has more stuttering than tests show (tests run briefly with controlled conditions)

#### Why UDP Is Fragile In The Current Implementation
- **Verified in source**: macOS currently chunks every wireless media frame and immediately sends every chunk as its own DTLS datagram. There is no pacing, congestion window, or backpressure-aware send loop in the active WiFi path.
- **Verified in source**: the iPad UDP reassembler is intentionally lossy under load: max 32 concurrent incomplete sequences, oldest-frame eviction at capacity, and 500ms timeout purge for incomplete frames.
- **Inference**: those two design choices together make burst loss disproportionately expensive. A brief burst of dropped or delayed chunks does not just damage one packet; it tends to discard the whole frame being reassembled.
- **Verified in source**: the current large-frame TCP fallback for wireless media is not actually wired into the active send path. Helper APIs and comments exist, but SessionManager always uses UDP chunking for wireless media.
- **Verified in source**: older comments still refer to a `>255 chunks` limit, but the protocol now uses `uint16_t` for `chunk_idx` and `chunk_total`, so that older threshold is stale.
- **Inference**: at the currently configured 20 Mbps wireless bitrate and observed ~47 fps native-resolution pipeline rate, average HEVC frame size is already large enough to require dozens of DTLS datagrams per frame, while keyframes can require roughly 70-140 datagrams. That burstiness is a plausible direct contributor to WiFi/AWDL stutter even if DTLS itself is functioning correctly.

Notes:
- **Open question**: the repo still does not prove whether Network.framework/DTLS itself is a bottleneck under sustained media load, because the checked-in DTLS tests are small-message connection/loopback validations rather than streaming stress tests.

### AWDL
- **Same protocol as WiFi** (UDP/DTLS media, TCP/TLS input)
- **Current test limitation**: the existing test runner skips AWDL when WiFi infrastructure is present
- **Peer-to-peer**: Enabled via `includePeerToPeer = true` on NWParameters

Notes:
- **Verified in source**: peer-to-peer discovery is enabled on browser/listener/connection parameters.
- **Open question**: "cannot be tested when WiFi infrastructure is present" is too strong as a platform claim. The current browsing logic connects to the first discovered service and does not select or pin the AWDL-discovered interface explicitly, so the limitation is partly in current connection strategy, not just the OS.
- **Verified in source**: the wireless UDP media path binds to the first interface seen on the connection path rather than an explicitly selected AWDL service result, which increases ambiguity when the same service appears on both WiFi and AWDL.

### Transport Priority
USB NCM > WiFi > AWDL (handled by TransportFSM)

### Transport Handoff
- **USB unplug**: FSM transitions to `.disconnected`, reconnection timer starts (0.5s backoff), WiFi browsing is always running as background fallback
- **WiFi to USB**: FSM fires `.wiredAppeared` which disconnects WiFi and binds USB
- **iPad side**: transport effects are implemented; `disconnectCurrent` tears down both transports, `bindUSBNCM`/`connectWiFi` start their respective monitoring/browsing
- **macOS side**: the FSM exists and drives encode/mode effects, but bind/connect/disconnect effects are effectively handled by transport setup outside the FSM rather than executed directly from FSM effect handlers

---

## Encode/Decode Pipeline

### HEVC Encoder (macOS, VideoToolbox)
- **Codec**: H.265/HEVC Main profile, hardware encoder
- **Rate control**: AverageBitRate (NOT ConstantBitRate — conflicts with low-latency mode)
- **MaxFrameDelayCount**: 0 (immediate output, no frame buffering)
- **Frame reordering**: Disabled (no B-frames)
- **Real-time priority**: Enabled
- **Keyframe interval**: 5 seconds
- **Target FPS**: 120
- **Measured output in current native-resolution test setup**: ~47fps at 3600x2338
- **Bitrate presets**:
  - USB: 150 Mbps
  - WiFi: 20 Mbps
  - Eco 1080p: 15 Mbps
  - Eco 720p: 8 Mbps

### HEVC Decoder (iPad, VideoToolbox)
- **Decode mode**: Synchronous with `._1xRealTimePlayback` flag
- **Output format**: BGRA 32-bit pixel buffers
- **Measured decode time**: ~7ms P-frames, ~15-47ms keyframes (at 3600x2338)
- **Session creation**: On first keyframe (extracts VPS/SPS/PPS)

### Metal Rendering (iPad)
- **Zero-copy**: CVMetalTextureCache maps decoder's IOSurface directly to MTLTexture (no CPU-GPU memcpy)
- **Display link**: CAMetalDisplayLink at 120Hz (ProMotion)
- **Triple buffering**: DispatchSemaphore(value: 3)
- **Pixel format**: BGRA8Unorm
- **Color space**: Display P3 wide gamut
- **Letterboxing**: Viewport computed from Mac/iPad aspect ratio

### Screen Capture (macOS)
- **Framework**: ScreenCaptureKit
- **Target FPS**: 120 (minimumFrameInterval = 1/120)
- **Measured FPS**: ~47 at native 3600x2338 in the current end-to-end setup
- **Pixel format**: BGRA
- **Queue depth**: 3

Notes:
- **Verified in source**: ScreenCaptureKit is configured for 120 fps capture with queueDepth 3.
- **Inference**: encoder throughput is a likely contributor to the ~47 fps ceiling, but the current repo does not isolate ScreenCaptureKit vs encode vs render as the sole bottleneck.

---

## Measured Latency (E2E Test, 2026-03-30)

### Pipeline Latency (capture-to-decode, wall clock)
| Metric | Value |
|--------|-------|
| Min | 49ms |
| Median | 51ms |
| Average | 51ms |
| P95 | 53ms |
| Max | 111ms |

### Latency Breakdown (estimated)
| Stage | Time |
|-------|------|
| Capture interval (47fps) | ~21ms |
| HEVC encode | ~5-10ms |
| TCP transfer (USB NCM) | ~1-2ms |
| HEVC decode (P-frame) | ~7ms |
| Display link wait (120Hz avg) | ~4ms |
| **Total estimated** | **~38-44ms** |
| **Measured median** | **51ms** |

- **Inference**: the ~7ms gap may be due to ScreenCaptureKit buffering/callback latency, but this has not been isolated by targeted instrumentation.

### Transport RTT (TCP echo only)
- USB NCM: ~1-2ms median
- WiFi: varies (not systematically measured in real conditions)

---

## Security Model

### Encryption
- **TCP**: TLS 1.3 (mandatory, no cleartext fallback)
- **UDP**: DTLS (mandatory, no cleartext fallback)
- **Certificate pinning**: SHA-256 fingerprint stored in Keychain during QR pairing

### Pen Test Results (E2E Suite, 4 tests)
| Test | Result | Detail |
|------|--------|--------|
| sec-cleartext-tcp | PASS | Plain TCP to TLS port silently dropped |
| sec-cleartext-udp | PASS | Plain UDP to DTLS port ignored |
| sec-untrusted-cert | **FAIL** | No mTLS — Mac accepts any TLS client without client cert verification |
| sec-pairing-port-closed | PASS | Port 14569 closed after pairing completes |

### Known Security Gap: No Mutual TLS
The Mac's TLS listener does not require client certificate authentication (`sec_protocol_options_set_peer_authentication_required` is NOT set). Any TLS client can connect without presenting a valid certificate. The Mac sends the session handshake (30 bytes) to unauthenticated clients.

**Fix required**: Implement iPad client TLS identity:
1. iPad generates self-signed cert + private key during pairing
2. iPad stores identity in Keychain
3. iPad presents cert via `sec_protocol_options_set_local_identity` during TLS connections
4. Mac enables `sec_protocol_options_set_peer_authentication_required`
5. Mac's verify block checks iPad cert fingerprint against stored value

### Pairing
- QR code contains: host IP, port 14569, cert fingerprint, ECDH public key, display dimensions
- ECDH key exchange over TLS pairing connection
- Cert fingerprints stored bidirectionally in Keychain
- Pairing listener closed after successful pair
- **Auto-reconnect**: Disabled in dev builds because the Mac regenerates its TLS identity per launch

---

## Protocol

### MediaFrameHeader (25 bytes, packed)
```
Offset  Size  Field
0       2     magic (0x4B44 = "KD")
2       1     flags (HEVC=0x01, KEYFRAME=0x02, LAST_CHUNK=0x04, DELTA=0x40)
3       2     seq (frame sequence, wraps at 65535)
5       2     chunk_idx
7       2     chunk_total
9       4     payload_size
13      8     ts_us (wall clock microseconds since epoch)
21      4     crc32
```

### InputEventHeader (9 bytes, packed)
```
Offset  Size  Field
0       1     type (mouse=0x01, click=0x02, scroll=0x03, key=0x10, ...)
1       8     ts_us
```

### Ports
| Port | Protocol | Purpose |
|------|----------|---------|
| 14567 | UDP/DTLS | Media frames (WiFi only) |
| 14568 | TCP/TLS | Input events + media frames (USB NCM uses TCP for both) |
| 14569 | TCP/TLS | Pairing (closed after pair completes) |

### Bonjour Service
- Type: `_keydrd._tcp`
- Peer-to-peer enabled for AWDL discovery

---

## iPad HUD
- **Compact pill**: Always visible during streaming (transport icon + latency + FPS)
- **Expanded panel**: Tap pill to expand. Shows: eco toggle, resolutions, bitrate, "Match iPad Resolution" button, disconnect. Auto-collapses after 3s.
- **Reveal**: Swipe down from top 44pt of screen if dismissed

---

## Test Suite (24 tests)

### Core (9)
tls-connection, ecdh-exchange, bonjour-discovery, transport-detected, session-handshake, frame-reception, frame-decompression, latency-probe, keepalive

### Extended (7)
transport-assertion, resolution, fps, frame-loss, latency-tiered, throughput, pipeline-latency

### Multi-Transport (4)
transport-usb, transport-wifi, transport-awdl, multi-transport

### Security (4)
sec-cleartext-tcp, sec-cleartext-udp, sec-untrusted-cert, sec-pairing-port-closed

Notes:
- **Verified in source**: DTLS transport tests in the repo prove small-message localhost DTLS establishment and delivery.
- **Open question**: the current automated suite does not isolate sustained chunked DTLS media streaming behavior well enough to attribute WiFi/AWDL stutter to a single layer (encoder burstiness, sender pacing, DTLS overhead, interface selection, or receiver reassembly policy).

---

## What's Missing / Known Gaps

1. **Mutual TLS** — Biggest security gap. Any TLS client can connect.
2. **WiFi quality** — Tests pass briefly but real usage stutters. The current wireless path still sends bursty unpaced DTLS chunks into a lossy reassembler with small concurrency/timeout limits. Needs longer WiFi-only stress test plus targeted instrumentation.
3. **Auto-pair persistence** — Disabled in dev builds. Production needs stable Mac TLS identity.
4. **UDP over USB NCM** — Current DTLS media attempts were not reliable enough for use, so USB media currently uses TCP. Root cause is not yet proven at the platform/driver level.
5. **Wireless large-frame fallback mismatch** — Docs/comments mention TCP fallback for oversized wireless frames, but the active macOS SessionManager path currently always uses UDP chunking.
6. **AWDL/WiFi interface ambiguity** — Current browse/connect logic does not explicitly select the AWDL-discovered path when the same service appears on multiple interfaces.
7. **Resolution matching** — "Match iPad Resolution" exists but quality still looks sub-native. May need Metal shader filtering investigation.
8. **FPS ceiling** — Measured around ~47fps for 3600x2338 in the current setup. The dominant bottleneck is still an inference, not a proven single-stage limit.
9. **AWDL testing** — Current test flow skips AWDL when WiFi is available. Isolated environment or interface-aware browse/connection selection is still needed to prove actual AWDL behavior.
10. **Input injection** — Phase 3 (touch, keyboard, cursor) not yet implemented.
11. **FSM/doc mismatch risk** — Transport docs should not assume the FSM is the single source of truth yet; macOS and iPad encode-mode assumptions are not fully aligned during wireless→USB promotion.
