# Latency Workup: Mac → iPad Remote Desktop Pipeline

**Date:** 2026-03-30
**Resolution:** 2752x1786 (iPad viewport-matched)
**Transport:** USB NCM / TCP+TLS

---

## End-to-End Pipeline Diagram

```
MAC                                                           iPAD
────────────────────────────────────────────────────────────────────

┌─────────────────┐
│ 1. SCStream     │  ScreenCapture.m:289
│    Capture      │  Queue: _captureQueue (USER_INTERACTIVE, serial)
│                 │  Config: 120fps, queueDepth=3, BGRA
│    ⏱ T0: stamp │  ScreenCapture.m:353 — keydrd_host_time_us()
│    captureTs    │
└────────┬────────┘
         │ SYNC (onPixelBuffer callback, same queue)
         ▼
┌─────────────────┐
│ 2. VTCompress   │  HEVCEncoder.m:204
│    EncodeFrame  │  ASYNC submit → VT internal hardware pipeline
│    (submit)     │  sourceFrameRefcon carries captureTs
│                 │  Properties: RealTime=YES, MaxFrameDelayCount=0,
│                 │  AllowFrameReordering=NO, EnableLowLatencyRateControl,
│                 │  AverageBitRate, MaxKeyFrameIntervalDuration=5s,
│    ⏱ +0ms      │  ExpectedFrameRate=120, Profile=HEVC_Main_AutoLevel
└────────┬────────┘
         │ ASYNC (VT internal hardware encode pipeline)
         │ ███████████████████████████  ← 18-67ms encode
         ▼
┌─────────────────┐
│ 3. VT Output    │  HEVCEncoder.m:264 (_hevcOutputCallback)
│    Callback     │  Queue: VT internal (not caller's queue)
│                 │  Extracts captureTs from sourceFrameRefcon
│    ⏱ +18-67ms  │  Prepends VPS/SPS/PPS on keyframes
└────────┬────────┘
         │ SYNC (onEncodedFrame block, same VT callback)
         ▼
┌─────────────────┐
│ 4. Build Packet │  SessionManager.m:724-756
│    + TCP Send   │  malloc + memcpy header + payload
│                 │  → sendMediaFrameToiPad → sendInputEvent
│    ⏱ +0ms      │  4-byte length prefix + frame data
└────────┬────────┘
         │ ASYNC (NWConnection.send, TCP_NODELAY)
         ▼
┌─────────────────┐
│ 5. NWConnection │  USBNetworkTransport.m:423-441 (send)
│    TCP Send     │  TLS 1.3 encrypted, TCP_NODELAY=true (line 185)
│                 │  Queue: _transportQueue (serial)
│    ⏱ +0ms      │  nw_connection_send with completion handler
└────────┬────────┘
         │
         │ USB NCM wire (~1ms RTT)
         │
         ▼                                          iPAD SIDE
┌─────────────────┐
│ 6. NWConnection │  SessionManager.swift:329-331
│    TCP Receive   │  onInputReceived callback
│                 │  4-byte length framing → complete frame
│    ⏱ +1-2ms    │  Dispatched on transport's NWConnection queue
└────────┬────────┘
         │ SYNC (handleInputReceived → handleReceivedFrame)
         ▼
┌─────────────────┐
│ 7. Parse Header │  SessionManager.swift:446-459
│    + Route      │  MediaFrameHeader.parse (25 bytes)
│                 │  Route to HEVC or LZ4 decoder
│    ⏱ +0ms      │  ⏱ LATENCY-PROBE: ipad-recv measured here
└────────┬────────┘
         │ SYNC
         ▼
┌─────────────────┐
│ 8. HEVC Decode  │  HEVCDecoder.swift:108-129
│                 │  VTDecompressionSessionDecodeFrame (sync)
│                 │  + WaitForAsynchronousFrames
│    ⏱ +5-7ms    │  Output: CVPixelBuffer (IOSurface-backed)
└────────┬────────┘
         │ SYNC
         ▼
┌─────────────────┐
│ 9. Metal Upload │  MetalRenderer.swift:222-268
│    (zero-copy)  │  CVMetalTextureCacheCreateTextureFromImage
│                 │  frameDirty=true, captureTs stored
│    ⏱ +<1ms     │  NSLock held for texture pointer swap only
└────────┬────────┘
         │ ASYNC (waits for next CAMetalDisplayLink tick)
         │ ░░░░░░  ← 0-8.3ms wait for 120Hz vsync
         ▼
┌─────────────────┐
│ 10. Display     │  MetalRenderer.swift:364-467
│     Link Render │  CAMetalDisplayLink callback at 120Hz
│                 │  inflightSemaphore.wait (triple buffer gate)
│                 │  Draw fullscreen quad with frame texture
│                 │  commandBuffer.present(drawable)
│    ⏱ +0-8.3ms   │  ⏱ GLASS-TO-GLASS: targetPresentationTimestamp
└────────┬────────┘
         │ GPU submit → display controller scanout
         ▼
┌─────────────────┐
│ 11. Photons     │  Physical display scanout
│                 │  ProMotion 120Hz OLED
│    ⏱ +~4ms      │  (scanout time for 120Hz refresh)
└─────────────────┘
```

---

## Measured Per-Stage Timing

### Mac Side (from os_log LATENCY-PROBE)

| Stage | Measured | Source |
|-------|----------|--------|
| Capture → encode-submit | **0ms** | HEVCEncoder.m:186 probe |
| Capture → encode-complete | **18-67ms** (varies by frame complexity) | HEVCEncoder.m:289 probe |
| Capture → tcp-send | **same ms as encode-complete** | SessionManager.m:735 probe |

Encode time distribution (100 sampled frames):
- Small delta frames (2-5KB): **18-25ms**
- Medium frames (5-15KB): **40-50ms**
- Keyframes (400KB+): **63-85ms**

### iPad Side (from console LATENCY-PROBE, clock-sync corrected)

| Stage | Measured | Source |
|-------|----------|--------|
| Capture → iPad receive | **+1-2ms** after Mac tcp-send | SessionManager.swift:464 probe |
| Decode | **5-7ms** | SessionManager.swift:436 log |
| Display link wait | **0-8.3ms** | MetalRenderer 120Hz tick |

### End-to-End (from E2E test results, 1184 frames)

| Metric | Value |
|--------|-------|
| **Pipeline (capture → decode)** | min=22ms, **median=29ms**, avg=42ms, p95=75ms, max=92ms |
| **Glass-to-glass (capture → presented)** | min=40ms, **median=50ms**, avg=62ms, p95=96ms, max=113ms |
| **G2G overhead (render+display)** | **21ms** (median glass-to-glass − median pipeline) |
| **Transport RTT** | min=1ms, median=2ms |
| **Clock sync offset** | 391682912ms (Cristian's algorithm, 10 probes, RTT 1-5ms) |

---

## Async Boundaries (potential queuing points)

| # | Boundary | From → To | Impact |
|---|----------|-----------|--------|
| 1 | SCStream → _captureQueue | OS internal → serial queue | Negligible |
| 2 | **encodePixelBuffer → VT output callback** | _captureQueue → VT internal | **18-67ms** (hardware encode pipeline) |
| 3 | VT callback → onEncodedFrame | VT internal → same block | 0ms (sync) |
| 4 | onEncodedFrame → nw_connection_send | VT queue → NWConnection internal | 0ms (immediate submit) |
| 5 | **NWConnection send → iPad receive** | Mac kernel → iPad kernel | **1-2ms** (USB NCM wire) |
| 6 | iPad receive → handleReceivedFrame | NWConnection queue → same thread | 0ms (sync) |
| 7 | **updateFrameFromPixelBuffer → display link** | Main thread → CAMetalDisplayLink | **0-8.3ms** (next 120Hz tick) |

**The dominant latency contributor is boundary #2** (HEVC hardware encode). Everything else combined is <15ms.

---

## Locks & Synchronization

| Lock | Location | Held Duration | Risk |
|------|----------|---------------|------|
| textureLock (NSLock) | MetalRenderer.swift:44 | <1μs (pointer swap) | None |
| inflightSemaphore(3) | MetalRenderer.swift:39 | Per-GPU-frame (~8ms) | Blocks on 4th frame if GPU behind |
| VT internal pipeline | VTCompressionSession | 18-67ms per frame | **Primary latency source** |

---

## Buffers & Queues

| Buffer | Capacity | Location | Impact |
|--------|----------|----------|--------|
| SCStream frame queue | 3 frames | ScreenCapture.m:141 (queueDepth) | Drops oldest if backed up |
| VT encode input queue | Unbounded | VTCompressionSession | Frames queue if arriving faster than encode rate |
| NWConnection send buffer | OS-managed | TCP stack | TCP_NODELAY prevents Nagle batching |
| Triple buffer semaphore | 3 in-flight | MetalRenderer.swift:39 | GPU pipeline depth; blocks at 4 |
| CVPixelBuffer IOSurface | 1 current | MetalRenderer cvTextureRef | Retained until next frame replaces it |

---

## What Limits Latency Further

### Best-case path (small delta frame, no queue):
```
Encode: 18ms + Transport: 1ms + Decode: 5ms + Display: 4ms = 28ms
```
Matches measured min of 22ms pipeline + 40ms glass-to-glass.

### Median path (typical frame, some VT queue depth):
```
Encode: 29ms + Transport: 1ms + Decode: 5ms + Display: 8ms = 43ms → 50ms glass-to-glass
```

### P95 path (keyframe or queue buildup):
```
Encode: 75ms + Transport: 1ms + Decode: 7ms + Display: 8ms = 91ms → 96ms glass-to-glass
```

### Remaining optimization opportunities:

1. **Encoder resolution** — Currently 2752x1786 (viewport-matched from 3600x2338). Further reduction to 1920x1246 (1080p-like) would cut encode time ~50%.
2. **Frame skipping** — Drop frames at encoder input if VT queue depth >1. Prevents queue buildup on keyframes. Trades FPS for latency consistency.
3. **Keyframe interval** — Currently 5s. Longer interval = fewer expensive keyframes. Trade-off: longer recovery on packet loss.
4. **Display mode matching** — Change Mac display mode to iPad viewport size so Mac renders at target resolution natively. Eliminates SCStream downscale blur.
5. **Bitrate** — Currently 150Mbps target but actual output is 6.1Mbps. AverageBitRate undershoots on low-complexity content. Consider quality-based encoding (CRF) for consistent visual quality.

---

## Historical Comparison

| Metric | Before viewport match (3600x2338) | After viewport match (2752x1786) | Δ |
|--------|-----------------------------------|----------------------------------|---|
| Encode pixels | 8.42M | 4.92M | -42% |
| Pipeline latency (median) | 120ms | 29ms | **-76%** |
| Glass-to-glass (median) | 140ms | 50ms | **-64%** |
| FPS | 41 fps | 50 fps | +22% |
| Frame size (raw) | 33.7 MB | 19.7 MB | -42% |
