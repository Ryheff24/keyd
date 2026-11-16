# Frame-loop inventory (2026-11-16)

Factual basis for an end-to-end TLA+ model of the frame loop: capture, encode, send, receive, ack, decode, present. It is composed with the connection lifecycle. Read-only survey: no source, model or config file was changed, and nothing was built or run.

Companion: `.planning/research/lifecycle-inventory-2026-11-16.md` (the "lifecycle doc"). Lifecycle row ids (M.., P.., §4.1, U..) are cited, not redone. This document's ids are **FE*n*** (Mac frame events), **IE*n*** (iPad frame events) and **FF*n*** (frame-path failures). They do not collide with M/P.

## Conventions

**Tags**
- **[C]** means read in source at the cited line.
- **[I]** means inferred from code that was read; the reasoning is given.
- **[U]** means unknown. Each one says what would resolve it.

**Log strings.** Every quoted log format string is written as ``log:`<exact format string>` ``, copied from source. `NO LOG` means no print, os_log or NSLog on that path. `os_log only` on the iPad means the line is not in the `[CONSOLE]` capture, because CLAUDE.md says os_log does not stream over devicectl. For modelling it is effectively unlogged.

**Location prefixes.** All paths are under `RemoteDesktop/`.

| Prefix | File |
|---|---|
| `mS` | `macOS/App/SessionManager.m` |
| `SC` | `macOS/Capture/ScreenCapture.m` |
| `FC` | `macOS/Compress/FrameCompressor.c` |
| `HE` | `macOS/Encode/HEVCEncoder.m` |
| `mU` | `macOS/Transport/USBNetworkTransport.m` |
| `mW` | `macOS/Transport/WirelessTransport.m` |
| `FSM` | `macOS/Transport/TransportFSM.c` |
| `PH` | `Shared/protocol.h` |
| `DC` | `Shared/delta.c` |
| `iS` | `iPadOS/App/SessionManager.swift` |
| `iU` | `iPadOS/Transport/USBNetworkTransport.swift` |
| `iW` | `iPadOS/Transport/WirelessTransport.swift` |
| `UR` | `iPadOS/Transport/UDPReassembler.swift` |
| `HD` | `iPadOS/Decode/HEVCDecoder.swift` |
| `LD` | `iPadOS/Decode/LZ4Decompressor.swift` |
| `MR` | `iPadOS/Render/MetalRenderer.swift` |
| `CV` | `iPadOS/App/ContentView.swift` |

**Mac queues**

| Name | What it is |
|---|---|
| S | Session queue, serial (mS:511). |
| CQ | Capture queue `com.keydrd.capture` (SC:274). |
| ZQ | `_compressQueue` `com.keydrd.compress.sc` (SC:275). |
| KQ | The compressor's `compress_queue` `com.keydrd.compress` (FC:73). |
| VT | The VideoToolbox output-callback thread [U-Q1]. |
| UT | Mac USB transport queue. |
| WT | Mac wireless transport queue. |
| M | Main queue. |

**iPad queues**

| Name | What it is |
|---|---|
| IUT | USB `transportQueue` (receive and drain). |
| IWT | Wireless transport queue. |
| RQ | UDPReassembler `queue`. |
| RCB | UDPReassembler `callbackQueue`. |
| HQ | `hevcHandoffQueue` (iS:96). |
| DL | Display-link callback, on main: `link.add(to: .main)` at MR:242. Confirmed by `thread=main` on all 239 RENDER-CADENCE lines in `/tmp/keyd-e2e-ipad.log`. |
| GPU | Metal command-buffer completion thread. |
| IM | Main queue. |

---

## 1. Pipeline map

### 1.1 LZ4 / USB (lossless, striped XOR-delta)

| # | Stage | Location | Queue | Hand-off to next | Buffering depth |
|---|---|---|---|---|---|
| L1 | Capture tick | **Synthetic:** dispatch_source on CQ, SC:1209 [C]. The E2E harness uses the prores .mov through this source [I]. **SCStream:** sample-buffer delegate on CQ, with `queueDepth` 3 (SC:_setupStreamWithContent) [C]. | CQ | Synchronous call to `_handleCapturedSampleBuffer` (SC:1324) [C] | SCStream surface pool of 3 [C]. Synthetic: catch-up burst of up to 3 [C]. |
| L2 | Pending-compress admit | SC:1413-1417 | CQ | `dispatch_async(_compressQueue)` (SC:1419) [C] | 1. `_lz4CompressPending` admits at most 1 queued compress. Others are dropped silently (NO LOG) [C]. |
| L3 | Compressor resize / size check | SC:1419ff, inside the async block | ZQ | `dispatch_sync` to KQ [C] | 0 |
| L4 | Send-side gate `shouldCompressFrame` | mS:1374-1389, called before `compress_frame` | KQ | Return value | Admits while `_tcpMediaSendsInFlight < kUSBLZ4GateInFlight (2)` (mS:309) [C]. Returns NO when USB is not connected [C]. |
| L5 | `compress_frame` | FC:217-439 | KQ (asserted) | Returns 0, then `onFrame` is called synchronously on KQ [C] | 1 reference frame. The striped path flips the reference only after all 8 stripes succeed [C]. |
| L6 | `onFrame` | mS:1392-1415 | KQ | `sendMediaFrameHeaderToiPad` (mS:2007), synchronous [C] | 0. **The reference has already advanced (post-compress).** |
| L7 | USB split-send | mS:2007-2060, then mU:777 `sendMediaFrameWithHeader` | KQ, with the send completing on UT | `nw_connection_send` with the header and payload, copied [C] | Kernel socket buffer. The `_tcpMediaSendsInFlight` counter is incremented before the send [C]. |
| L8 | Wire | TLS/TCP on the USB *input* connection, 4-byte BE length prefix | — | — | TCP |
| L9 | iPad receive / drain | iU:923-1031 `drainUSBTCPBuffer` | IUT | `onInputReceived?(message)` (iU:1031) with a **Data slice** `tcpBuffer[msgStart..<msgEnd]` (iU:1027): not copied, not zero-based [C] | `tcpBuffer` with read offset [C] |
| L10 | Media dispatch | iS:1101-1140 `handleInputReceived` | IUT | Unchunked LZ4: `handleReceivedFrame` synchronously on IUT (iS:1137) [C]. Chunked: reassembler. | 0 |
| L11 | LZ4 decompress | iS:772-835, then LD | IUT | `metalRenderer.updateFrame`, synchronous [C] | 1 reference (`LZ4Decompressor`) [C] |
| L12 | Ring upload | MR:253-305 | IUT (copy outside the lock) | Enqueued under `textureLock` [C] | 4 ring slots (MR:82); queue cap **1**, newest wins (MR:87, 316-321) [C] |
| L13 | Present | MR:517-659 | DL (main) | `commandBuffer.present`, then commit [C] | `inflightSemaphore` 3 (MR:61); `maximumDrawableCount` 3 (MR:225) [C] |
| L14 | GPU complete | MR:626 / 650 | GPU | `gpuRefs -= 1`, semaphore signal [C] | — |

There is no ack on the LZ4 path [C]: `sendFrameAck` is HEVC-only (iS:1126).

### 1.2 HEVC / wireless (TCP media; the UDP/DTLS media path is dormant)

| # | Stage | Location | Queue | Hand-off | Buffering depth |
|---|---|---|---|---|---|
| H1 | Capture tick | As L1 | CQ | `onPixelBuffer` is called synchronously on CQ when set (SC:1324ff) [C] | As L1 |
| H2 | Pre-encode gates | mS:1421-1545 | CQ | `[_hevcEncoder encodePixelBuffer:]`, synchronous [C] | **Wireless-only (`wireless && !usb`)** [C]: stale-age drop (95/72/54 ms, 250 ms absolute); then the ack gate (unacked ≥ `kWiFiAckGateFrames` 5, mS:128) or, before the first ack, kernel in-flight ≥ `kMaxMediaSendsInFlightWiFi` 3 (mS:121) (mS:1475-1477) [C]. **If USB is connected (eco over USB) no gate applies** [C]. |
| H3 | Encoder saturation guard | HE:261-420 | CQ | `VTCompressionSessionEncodeFrame` (HE:467) [C] | Pending > 1 → up to 14 retries with an 800 µs usleep, then skip [C]. |
| H4 | VT encode | VideoToolbox | VT | `_hevcOutputCallback` (HE:538) [C] | RealTime, no reordering, MaxFrameDelayCount 0 [C]. Pending counter [C]. |
| H5 | Packetize | HE:538-714 | VT | `_onEncodedFrame` block (mS:1552), synchronous [C] | 0. VPS/SPS/PPS are prepended on keyframes. `seq = _seq++` (HE:697) [C]. |
| H6 | `onEncodedFrame` | mS:1552-1592 | VT | `sendMediaFrameHeaderToiPad`, then `sendMediaFrameToiPad` (mS:2007, 1597) [C] | 0 |
| H7 | Route select | mS:1604 / 2017 | VT | **By `_usbTransport.isConnected`, not by codec** [C] | — |
| H8a | Wireless TCP send | mS:1645-1891, then mW:547-583 | VT. Scheduler `usleep` is skipped when the ack gate is active [C]. | `nw_connection_send` with copied data [C] | `++_wifiTCPMediaSendsInFlight`; `wifiAckNoteSentSeq` runs **before** the send (mS:1888) [C]. |
| H8b | USB send (eco, or HEVC over USB) | mS:1604-1644 / 2007-2060, then mU:618/777 | VT, with the send completing on UT | `nw_connection_send`. HEVC over 512 KB is cut into 64 KB chunks (mU) [C]. | `++_tcpMediaSendsInFlight`; an over-limit (5) send is logged, never dropped [C]. |
| H9 | iPad receive / drain | iW:927-1037 `drainTCPBuffer` (wireless) or iU (USB) | IWT / IUT | `onInputReceived?(Data(copy))` (iW:1024, 1037) or a slice (iU:1027) [C] | `tcpBuffer` |
| H10 | Ack + route | iS:1126-1135 | IWT / IUT | Ack: `sendFrameAck` → `wirelessTransport.sendInputEvent` (iS:1394-1398). **The ack is sent before reassembly and decode**, and only if `isHEVC && chunkTotal<=1 && wirelessTransport.isConnected && !usbTransport.isConnected` [C]. Then `udpReassembler.processChunk(sourceIsOrdered: true)` [C]. | 0 |
| H11 | Reassemble / sequence | UR:121-124 → `processChunkLocked` → `deliverFrameData` UR:338-452 | RQ | `enqueueReassembledFrame`, then `callbackQueue.async` (UR:331) [C] | 128 concurrent seqs, out-of-order buffer up to 96, 2 s purge [C]. |
| H12 | Decode | iS:686 `handleReceivedFrame`, then iS:746 `hevcDecoder.decode` (HD:94-246) | RCB | `.decoded` → `scheduleDecodedHEVCFrame`. `.deferred` → async `onDecodedFrame` (HD:203, wired at iS:140). `.failed` → return [C]. | VT decoder. A 4 ms wait budget, then deferred [C]. |
| H13 | Hand-off | iS:837-860 | `hevcHandoffQueue.async` (iS:846) | `handleDecodedHEVCFrame` (iS:862), then `metalRenderer.updateFrameFromPixelBuffer` [C] | Unbounded serial queue [C]. |
| H14 | Enqueue | MR:329-376 | HQ | Zero-copy CVMetalTexture; `slot: nil` (MR:372), so **no ring slot and no GPU gating**. ARC holds the IOSurface [C]. | Queue cap 1, newest wins (MR:87, 316) [C]. |
| H15 | Present / complete | As L13-L14 | DL / GPU | — | As L13 |

**Dormant UDP path.** `sendMediaFrameToiPad` UDP branch (mS:1962-2003), then `mW sendMediaFrame` (mW:450, paced on `_sendPacingQueue`). It is unreachable while `kWirelessUseTCPMedia == YES` (mS:111, `static const`) [C].

**Still reachable from the UDP/DTLS path**
- The DTLS media connection is still established.
- Its readiness still gates wireless capture start (`mediaChannelReady`, mS:996-1007 and 1219-1226) [C].
- The iPad still wires `wirelessTransport.onMediaReceived` → `udpReassembler` unordered (iS:503-581) [C]. With TCP media, nothing should arrive there [I].

---

## 2. State variables

Writers and readers that decide something. "S" etc. are the queues in Conventions.

### 2.1 Mac

| Variable | Decl | Values | Writers (loc, queue) | Deciding readers |
|---|---|---|---|---|
| `_sessionState` | mS | IDLE / CONNECTING / STREAMING / RECONNECTING… | init mS:493 (STOPPED); every other write goes through the state setter mS:3657, which is called from FE9, startReconnection mS:3585 and stop mS:564 (S). Lifecycle M36 etc. [C] | `onFrame` mS:1394 (KQ, **unsynchronized read**); `onPixelBuffer` guard (CQ); `onEncodedFrame` mS:1552 (VT); handleTransportEvent mS:1046/1053 (S) [C] |
| `_transportState` | mS | IDLE / USB_NCM / WIFI / AWDL / DISCONNECTED (FSM) | init mS:494; handleTransportEvent mS:1022 (S) [C] | usb-input-ready branch mS:829 (S) [C] |
| `_hevcEncoder.isActive` | HE | YES/NO | `start` HE:83; `stop` HE:192 (S, from switchTo*/eco/viewport) [C] | `onFrame` mS:1394 (KQ); usb-input-ready RouteResync mS:839 (S); handleViewportReport (S); onTransportConnected; `onEncodedFrame` HE callback early return (VT) [C] |
| `_isEcoMode` | mS | BOOL | init mS:496; switchToLZ4Mode mS:1097 (NO); eco mS:3363 (YES) / 3373 (NO) (S) [C] | Logging and the eco branches [C] |
| `_viewportReceived` | mS | BOOL | handleViewportReport mS:3065ff (YES). **No writer sets NO** (§6d) [C, grep] | onTransportConnected (S): start encoder or capture now vs defer [C] |
| viewport W/H | mS | u32 | handleViewportReport (S) [C] | `_startEncoderAtViewportResolution`, LZ4 capture size [C] |
| `_captureWidth/Height` | mS | u32 | mS:1109 (switchToLZ4Mode), 1139 (switchToHEVCMode), 1330/1341 (handshake), 3057 (resolution match), 3109 (viewport, LZ4), 3210 (encoder start), 3493 (display mode); all on S [C] | Skip-redundant-restart check mS:3096 [C] |
| `_awaitingMedia` | mS | BOOL | usb-input-lost mS:858; wireless down mS:898; mediaChannelReadyOnSession mS:1000; FE9 mS:1182 (NO) / mS:1224 (YES); all on S [C] | mediaChannelReadyOnSession mS:996 [C] |
| `_tcpMediaSendsInFlight` | mS | int32 | `++` mS:1604ff / 2017ff (KQ or VT); `--` in the completion (UT); `=0` in onTransportConnected (S) [C] | `shouldCompressFrame` mS:1374 (KQ); over-limit log [C]. **Completions carry no generation** (§6b). |
| `_wifiTCPMediaSendsInFlight` | mS | int32 | `++` mS:~1880 (VT); `--` in the completion, generation-checked (WT); `=0` onTransportConnected (S) [C] | Pre-ack gate mS:1477 (CQ) [C] |
| `_wifiTCPSendGeneration` | mS | u32 | `+= 1` onTransportConnected (S) [C] | Wireless completion mS:1892ff [C] |
| Ack state under `_wifiAckLock`: `_wifiAckActive`, `_wifiAckHasSent`, `_wifiAckLastSentSeq`, `_wifiAckLastAckedSeq` | mS:2566-2690 | bool, bool, u16, u16 | Reset: mS:2568 (S), called from `"hevc-mode"` (switchToHEVCMode) and `"transport-connected"` (onTransportConnected) only [C]. NoteSent mS:2598 (VT). FrameAck mS:2620 (T, realtime lane) [C]. | `wifiAckUnackedFrames` mS:2584 → gate mS:1476 (CQ); scheduler skip (VT) [C] |
| `_compressor` (`seq` u32, `force_keyframe`, reference) | SC:180-231, FC | — | `frame_compressor_init` on the **SCStream completion queue** (SC: `_setupStreamWithContent`); destroy in stopCapture (SC:451); `force_keyframe=1` via `requestLZ4Keyframe` (ZQ, SC:249); `seq++` and the reference in `compress_frame` (KQ) [C] | `compress_frame` keyframe decision FC:286 [C] |
| `_lz4CompressPending` | SC | 0/1 | CQ `++`, ZQ `--` [C] | SC:1413 admit [C] |
| HEVC `_seq` | HE:53 | u16 | `=0` only in `init` (HE:67); `++` HE:697 (VT) [C] | iPad reassembler continuity; Mac ack discontinuity [C] |
| HEVC `_pendingFrameCount` | HE | int | `++` encode (CQ); `--` callback (VT); `=0` in stop (S) [C] | Saturation guard (CQ). It can go negative after stop flushes callbacks [I]. |
| HEVC `_forceNextKeyframe` | HE | atomic bool | requestKeyframe HE:211 (S; **no-op when inactive**); stop/start reset [C] | encodePixelBuffer (CQ) [C] |
| `_capture.captureFPS` | SC | int | switchToLZ4Mode mS:1105 (120); `_startEncoderAtViewportResolution` mS:3169/3178; eco ON mS:3364 (`kEcoFPS`, with no capture reconfigure); `applyWiFiAdaptiveRateTargetsIfNeeded` mS:2751 (M) [C] | Synthetic timer interval, **read only at timer start** [C]; SCStream minimumFrameInterval [C] |
| encoder bitrate / fps | HE | — | start; `updateStreamingRateWithFPS` (M) [C] | VT |

### 2.2 iPad

| Variable | Decl | Values | Writers | Deciding readers |
|---|---|---|---|---|
| `state` | iS | awaitingPairing / connecting / streaming / reconnecting / disconnected… | Many. Frame-relevant writers: handleSessionHandshake `state = .streaming` **off main** (IUT/IWT, iS:1070); first frame iS:829/934 (IM); `.reconnecting` iS:637; `.disconnected` iS:379. Other writes (iS:198-402) are lifecycle. Lifecycle U6. [C] | `CV:50` shows the Metal view only for connecting/streaming/reconnecting [C]; first-frame transition [C] |
| `lz4Decompressor` (reference) | iS | nil or instance | New instance with a zero reference at the handshake (iS:1020, IUT/IWT) and on geometry grow or nil (iS:1300/1303) [C] | LZ4 decode iS:772ff (IUT) [C] |
| `macDisplayWidth/Height` | iS | Int | Handshake iS:1014; geometry iS:1286 [C] | LZ4 `frameBytes` (iS:~780) [C] |
| `hevcDecoder.session` / `formatDescription` | HD | — | `ensureSession` on a keyframe (HD:276-312): **same dims → keep the session and swap the format description**; changed → recreate. `handleSessionError` → invalidate (HD:522) [C] | decode (RCB) [C] |
| Reassembler `hasDeliveredFirstFrame`, `lastDeliveredSeq`, `awaitingKeyframeAfterLoss`, out-of-order buffer, pending | UR | — | `deliverFrameData` (RQ); `resetForNewStreamSession` (RQ, iS:318/329/366/378/396/409/417/1476 only) [C] | Delivery decisions UR:338-452 [C] |
| `lastKeyframeRequestUs` | iS | u64 | requestImmediateKeyframe (IM) [C] | 500 ms cooldown [C] |
| Renderer `ring`, `queue`, `shownFrame`, `backlogTicks` | MR:90-93 | — | updateFrame / updateFrameFromPixelBuffer (IUT/HQ), tick (DL), under `textureLock` [C] | Tick MR:553 [C]. **Never cleared by `stop()`** (MR:461-465) [C]. |
| `usbTransport.isConnected` / `wirelessTransport.isConnected` | iU / iW | Bool | Transport state handlers (lifecycle P-rows) | Ack condition iS:1127; viewport and keyframe send route iS:1434; requestImmediateKeyframe iS:1407 [C] |
| `hasRenderedFrameInCurrentSession` | iS | Bool | true: iS:819/924 (IM); false: iS:177/341 [C] | Connecting overlay CV:57 [C] |

---

## 3. Events and handlers

One row per handler. **Guard** is the first condition checked (NONE if there is none). **Msgs** are the messages sent to the peer. All locations are [C] unless tagged otherwise.

### 3.1 Mac

| Id | Trigger | Location | Queue | Guard | State writes | Msgs | Log |
|---|---|---|---|---|---|---|---|
| FE1 | USB TCP input connection ready. Lifecycle M30a. | mS:823-849 | UT → S via `onSession` | `_transportState != USB_NCM` → FE6(WIRED_APPEARED). **Else:** if `isActive`, `switchToLZ4Mode` (RouteResync); `requestLZ4Keyframe`; `onTransportConnected`. | Via FE7, FE35, FE9 | Handshake (FE10) | log:`USB NCM TCP input ready — sending handshake (hevcActive=%d eco=%d)`; log:`RouteResync: USB input ready with HEVC active -> LZ4`. The WIRED_APPEARED branch logs only FE6's lines. |
| FE2 | USB input connection lost. Lifecycle M31/M32. | mS:852-860 | UT → S | NONE | `_awaitingMedia = NO`; then FE6(DISCONNECTED) | — | Only FE6's lines |
| FE3 | Wireless TCP connection changed. Lifecycle M33/M35. | mS:888-903 | WT → S | NONE | connected: FE6(AWDL/WIFI_AVAILABLE); down: `_awaitingMedia = NO`, then FE6(*_UNAVAILABLE). A takeover (new READY while STREAMING) is an FSM no-op plus the mS:1053 skip, so there is **no FE9** (lifecycle §4.1 Paths A/B/C, lines 299-350). | — | Only FE6's lines |
| FE4 | DTLS media channel ready | mS:906 → `mediaChannelReadyOnSession` mS:996-1007 | WT → S | `_awaitingMedia && ready && wireless && !usb` | `_awaitingMedia = NO`; `_beginCapture` | — | log:`Media channel ready -- starting capture now` / log:`Media channel ready ignored (awaitingMedia=%{public}d mediaReadyNow=%{public}d wifiOnly=%{public}d)` |
| FE5 | Any input message from either transport | mS:972 `routeInputFromTransport`; `session_lane_is_realtime` mS:258-270 | UT/WT. Realtime types run inline, including **FRAME_ACK**; the rest are copied → S. | Type switch | — | — | LANE-BLOCK logs (lifecycle doc) |
| FE6 | `handleTransportEvent` | mS:1009-1068 | S | NONE. WIRED_APPEARED → `sendPeerAddressUpdate`. | `_transportState` (mS:1020); FSM effects → FE7/FE8; immediate fallback (mS:1033-1044); onTransportConnected **only if CONNECTING/RECONNECTING** (mS:1053) | Peer address; MODE_CHANGE notify (EFFECT_NOTIFY) | log:`Transport event: %{public}s (current state: %{public}s)`; log:`Transitioned to: %{public}s (%d effects)` |
| FE7 | EFFECT_SWITCH_ENCODE_LZ4 (FSM:47/54), or RouteResync | mS:1095-1120 `switchToLZ4Mode` | S | NONE | `_isEcoMode = NO`; `[_hevcEncoder stop]`; `captureFPS = 120`; capture resize and geometry if the viewport is known; `configureFrameDelivery`. **No `requestLZ4Keyframe`, no ack reset.** | Geometry update | log:`Switching to LZ4 mode (lossless, <1ms encode — wired USB only)` |
| FE8 | EFFECT_SWITCH_ENCODE_HEVC (FSM:65/70/135/140) | mS:1122-1162 `switchToHEVCMode` | S | NONE | `wifiAckResetWithReason("hevc-mode")`; encoder start at the viewport size, or deferred; `configureFrameDelivery` | — | log:`Switching to HEVC mode (encoder deferred until iPad viewport report)`; log:`HEVC encoder deferred — waiting for iPad viewport report` |
| FE9 | `onTransportConnected`. Lifecycle M36. | mS:1175-1249 | S | NONE | `_awaitingMedia`; both in-flight counters = 0; scheduler fields; `_wifiTCPSendGeneration += 1`; ack reset (`"transport-connected"`); adaptive state reset; STREAMING; handshake; encoder start or defer; `configureFrameDelivery`; capture start or defer | Handshake | log:`Transport connected -- sending handshake (state=%{public}s transport=%{public}s usbConnected=%{public}d wifiConnected=%{public}d viewportReceived=%{public}d viewport=%ux%u hevcActive=%{public}d)`; log:`USB LZ4 mode — no HEVC encoder needed, capture at native %ux%u`; log:`HEVC encoder deferred — waiting for iPad viewport report after handshake`; log:`Media channel already ready -- starting capture now`; log:`Capture deferred until media channel ready`; log:`USB LZ4: viewport known (%ux%u), starting capture now`; log:`USB LZ4: deferring capture until viewport report (avoids size mismatch crash)` |
| FE10 | `sendSessionHandshake` | mS:1327-1365 | S | NONE | `_captureWidth/Height` = display pixels | SESSION_HANDSHAKE via `sendInputEventToiPad` (USB first, else wireless, **else a silent drop**, mS:2062) | log:`Sent session handshake: %ux%u @%.1fx, aspect=%.4f` |
| FE11 | `configureFrameDelivery` | mS:1370-1593 | S | NONE | Installs `shouldCompressFrame`, `onFrame`, `onPixelBuffer` (nil unless HEVC is active, mS:1548) and `onEncodedFrame` blocks. **Block swap is not synchronized with CQ/KQ/VT** [I]. | — | NO LOG |
| FE12 | Synthetic timer tick | SC:1209 (`dispatch_source_set_event_handler`) | CQ | Per-tick catch-up logic | Emits 1-3 sample buffers → `_handleCapturedSampleBuffer` | — | log:`Synthetic timer catch-up: expected=%llu emitted=%llu backlog=%llu emitNow=%llu cap=%u lagUs=%llu catchup[events=%llu frames=%llu capped=%llu]` (and the related steady / failure strings at SC:1241-1296) |
| FE13 | SCStream sample buffer | SC:1324 `_handleCapturedSampleBuffer` | CQ | Frame status != complete → skip (NO LOG) | — | — | — |
| FE14 | HEVC capture hand-off: `onPixelBuffer` | mS:1421-1545 | CQ | `_sessionState == STREAMING && isActive`, else return (NO LOG). Then wireless-only gates: stale age, then ack / in-flight. | Drop counters; `wifiAckNoteGateHold` | — | log:`WiFi pre-encode drop: reason=stale-age age=%llums threshold=%llums absThreshold=%llums inFlight=%d slow=%d maxCompletion=%dms totalDropped=%d sampled=%{public}s`; log:`WiFi pre-encode drop: reason=%{public}s unacked=%d ackLimit=%d inFlight=%d limit=%d totalDropped=%d` (sampled: first 10, every 100); log:`WiFi pre-encode admit: reason=%{public}s unacked=%d inFlight=%d limit=%d age=%llums staleThreshold=%llums` |
| FE15 | LZ4 capture hand-off | SC:1413-1419 (`dispatch_async(_compressQueue)`) | CQ → ZQ | `_lz4CompressPending > 1` → drop (NO LOG) | Pending count; compressor resize when the surface equals the capture size | — | log:`LZ4 compressor resized for live capture size: %zu -> %zu bytes (%zux%zu)` |
| FE16 | `shouldCompressFrame` | mS:1374-1389 | KQ | `!_usbTransport.isConnected` → NO | — | — | log:`LZ4 compress skipped: no USB connection (count=%u)` (every 120); caller: log:`LZ4 gate: skipped frame before compress (sender saturated), totalSkips=%llu nextSeq=%u` |
| FE17 | `compress_frame` | FC:217-439 | KQ | Size mismatch → -2 | Reference (per stripe, all-or-none); `seq++`; `force_keyframe = 0` | — | log:`compress_frame: surface %zux%zu stride=%zu does not match compressor frameBytes=%zu, frame skipped count=%d`; log:`LZ4 forced keyframe seq=%u (connect)`; caller on < 0: log:`compress_frame failed for seq %u` |
| FE18 | `onFrame` | mS:1392-1415 | KQ | `_sessionState != STREAMING \|\| isActive` → return. **NO LOG, after the reference advanced.** | — | Media (FE22/FE26) | log:`LZ4 frame #%d: %zu bytes compressed (%s), seq=%u` (sampled) |
| FE19 | `encodePixelBuffer` | HE:261-500 (VTCompressionSessionEncodeFrame HE:467) | CQ | `!isActive \|\| !session` → skip | `_pendingFrameCount++`; force-keyframe consumed | — | log:`encodePixelBuffer: saturation guard branch=skip pendingBefore=%d pendingAfter=%d mode=%{public}s waitedUs=%llu totalSkipped=%d hitStreak=%d skipStreak=%d budgetUs=%llu hardReliefGraceEligible=%{public}s hardReliefGraceApplied=%{public}s`; log:`VTCompressionSessionEncodeFrame failed: %d` |
| FE20 | VT output callback | HE:538-714 | VT | Status error → log, return. `!isActive \|\| !onEncodedFrame` → silent return (no seq consumed). | `_pendingFrameCount--`; `_seq++` (HE:697) | — | log:`HEVC encode callback error: %d` |
| FE21 | `onEncodedFrame` | mS:1552-1592 | VT | `_sessionState != STREAMING` → return (NO LOG) | Perf counters | Media | log:`HEVC onEncodedFrame: seq=%u len=%zu flags=0x%02x, sending via UDP chunks` (first 3; the text is stale and says UDP); log:`LATENCY-PROBE tcp-send: %llu ms since capture (seq=%u, %zu bytes)` |
| FE22 | `sendMediaFrameToiPad`, USB branch | mS:1604-1644 | KQ/VT | `_usbTransport.isConnected` (**not** the codec) | `++_tcpMediaSendsInFlight` | MEDIA over USB input TCP | log:`USB send queued: seq=%u inFlight=%d bytes=%zu`; log:`USB send over in-flight limit (gate missed): seq=%u inFlight=%d total=%d — sending, not dropping` |
| FE23 | USB send completion | mS:~1636-1642 | UT | **NONE** (no generation) | `--_tcpMediaSendsInFlight` | — | log:`USB send completion: seq=%u success=%{public}s inFlightNow=%d` |
| FE24 | `sendMediaFrameToiPad`, wireless TCP branch | mS:1645-1891 | VT | `kWirelessUseTCPMedia && wireless connected` | `sendGeneration` captured; scheduler fields; `++_wifiTCPMediaSendsInFlight`; `wifiAckNoteSentSeq` **before the send** (mS:1888) | MEDIA over wireless input TCP | log:`WiFi media via TCP: seq=%u bytes=%zu`; log:`WiFi TCP send queued: seq=%u inFlight=%d bytes=%zu scheduler[delay=%lluus gap=%lluus target=%lluus reason=%{public}s burstCount=%d]`; log:`WiFi ack gate seq discontinuity: prevSent=%u seq=%u active=%d -> counting from seq` |
| FE25 | Wireless TCP send completion | mS:1892-1958 | WT | `sendGen != activeGen` → ignore | `--_wifiTCPMediaSendsInFlight` (clamped at 0) | — | log:`WiFi TCP stale completion ignored: seq=%u success=%{public}s elapsed=%llums sendGen=%u activeGen=%u sampled=%{public}s sampleCount=%d`; log:`WiFi TCP in-flight underflow clamp: seq=%u success=%{public}s left=%d action=reset-to-zero`; log:`WiFi TCP send slow completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d`; log:`WiFi TCP send completion: seq=%u success=%{public}s elapsed=%llums inFlightNow=%d sampled=%{public}s sampleCount=%d` (failures are always logged) |
| FE26 | `sendMediaFrameHeaderToiPad`, USB split-send, and its completion | mS:2007-2060 | KQ/VT; completion on UT | `usb connected`; else malloc → FE22/FE24 | `++/--_tcpMediaSendsInFlight`; the completion has no generation | MEDIA | log:`USB split-send queued: seq=%u inFlight=%d bytes=%zu payload=%zu`; log:`USB split-send over in-flight limit (gate missed): seq=%u inFlight=%d total=%d — sending, not dropping`; log:`USB split-send completion: seq=%u success=%{public}s inFlightNow=%d` |
| FE27 | Mac USB transport media send | mU:618 `sendMediaViaTCP`, mU:777 `sendMediaFrameWithHeader` | caller → UT | `_inputConnection == nil` → completion(NO) (an **unsynchronized read**) | — | nw_connection_send (mU:698/753/843/883) | log:`USB media send skipped: no TCP input connection`; log:`USB media split-send skipped: no TCP input connection (seq=%u)`; log:`Media TCP send error: %{public}@ (seq=%u bytes=%zu elapsed=%llums)`; log:`USB media split-send error: %{public}@ (seq=%u total=%zu payload=%zu elapsed=%llums)` |
| FE28 | Mac wireless TCP media send | mW:547-583 | caller → WT | `_inputConnection == nil` → completion(NO). NO transport log; FE25 logs the failure. | — | nw_connection_send (mW:574) | log:`TCP media frame send error: %{public}@` |
| FE29 | FRAME_ACK received | mS:2620-2690 `handleWiFiFrameAck` | UT/WT inline (realtime lane) | Length; window `1 <= ack-lastAcked <= lastSent-lastAcked`. **No connection or generation check.** | `_wifiAckActive = YES`; `lastAcked`; RTT/delivery samples | — | log:`WiFi frame ack too short: length=%zu`; log:`WiFi ack gate active: ack=%u lastSent=%u unacked=%d rtt=%lluus limit=%d`; log:`WiFi frame ack ignored: ack=%u lastAcked=%u lastSent=%u (stale or outside window) count=%d` |
| FE30 | VIEWPORT_REPORT received. Lifecycle M40. | mS:3065-3142 | S | NONE | `_viewportReceived = YES`; viewport; skip redundant; LZ4+USB: capture size, `requestLZ4Keyframe` if capturing (mS:3124), else `_beginCapture`; otherwise FE31 | Geometry update | log:`iPad viewport report: %ux%u (previous: %ux%u, changed=%{public}d, Mac display: %ux%u, hevcActive=%{public}d, usbConnected=%{public}d)`; log:`Skipping redundant HEVC restart on unchanged viewport during active wireless session (expected=%ux%u capture=%ux%u)`; log:`LZ4 mode (USB) — setting capture to viewport %ux%u, then starting capture`; log:`LZ4 viewport: capture running at %ux%u -> reconfiguring to %ux%u` |
| FE31 | `_startEncoderAtViewportResolution` | mS:3144-3223 | S | NONE | Encoder start (USB: 100 Mbps at 120 fps; wireless: link target at 60 fps); capture resize; `configureFrameDelivery`. **No ack reset**; the seq continues (HE `_seq`). | Geometry update | log:`Wireless HEVC start: link=%{public}s bitrate=%.1fMbps`; log:`Starting HEVC encoder: %ux%u @%dfps bitrate=%dMbps (capture: %ux%u, viewport: %ux%u)`; HE: log:`HEVC encoder started: %dx%d @ %dfps, bitrate=%d, quality=%.2f` |
| FE32 | MODE_CHANGE / REQUEST_KEYFRAME | mS:3331-3350 | S (**not** the realtime lane) | Subtype | `_forceNextKeyframe` (a no-op when the encoder is inactive, HE:212) | — | log:`Immediate HEVC keyframe requested by iPad recovery path` |
| FE33 | Eco mode request | mS:3359-3390 | S | NONE | ON: encoder 1920x1080 at 30 fps, 8 Mbps; `configureFrameDelivery`. **No ack reset, capture resize or geometry.** OFF: restart at the viewport. | — | log:`Eco mode request: %{public}s`; log:`Eco OFF but no viewport — cannot restart encoder` |
| FE34 | Resolution match request | mS:3392ff | S | Length | Display mode; capture stop/start (compressor re-init, LZ4 seq → 0) | Response, geometry | log:`Resolution match request: iPad wants %ux%u` |
| FE35 | `requestLZ4Keyframe` | SC:246-253 (`dispatch_async` SC:249) | caller → ZQ | NONE | `_compressor.force_keyframe = 1` | — | log:`LZ4 keyframe requested (initialized=%d)` |
| FE36 | Wireless perf timer tick | mS:2103-2187 (scheduled via `dispatch_async(main)` mS:2106) | M | **`!_testMode` → return (mS:2114)** | Adaptive rate state; FE37 | — | log:`WiFi ack 1s: active=%d acks=%d stale=%d gateHolds=%d unackedNow=%d unackedPeak=%d rttAvg=%.1fms rttMax=%.1fms limit=%d delivery[samples=%d max=%.1fMbps]`; log:`WiFi ack rate: branch=%{public}s target=%.1fMbps prev=%.1fMbps fps=%d applied=%dfps/%.1fMbps deliveryMax=%.1fMbps` |
| FE37 | `applyWiFiAdaptiveRateTargetsIfNeeded` | mS:2692-2767 | M | Changed targets | `captureFPS`; `updateCaptureResolution`; `updateStreamingRateWithFPS` | — | log:`WiFi adaptive apply: reason=%{public}s requested=%dfps/%dMbps applied=%dfps/%dMbps prev=%dfps/%dMbps floor=%dfps floorGuard=%{public}s smoothDelta=%+dfps/%+dKbps` |
| FE38 | `updateCaptureResolution` | SC:539-606 | caller (S or M) | `!_isCapturing \|\| !_stream` → store only. **Synthetic `_stream` is nil, so SC:548-583 is dead.** | Stored dims, SCStream config | — | log:`updateCaptureResolution: not capturing, storing %ux%u for next start`; log:`Updating capture resolution to %ux%u @%ufps (live reconfigure)` |
| FE39 | `startCapture` / `stopCapture` | SC:306-359 (global-queue `dispatch_async` SC:328) / SC:451-537 | S → global → SCStream completion | Per lifecycle doc | Compressor init (completion queue) / destroy (seq → 0); `_isCapturing` | — | log:`Synthetic capture started: %lux%lu @%dfps (%{public}s)` (other start/stop lines: lifecycle doc) |
| FE40 | Capture watchdog | SC:1491 | global | Frame age > 2 s | — | — | log:`Watchdog: no frames for %.1fs, display awake — re-authorization may be needed` |
| FE41 | HEVC encoder `stop` | HE:192-209 | caller (S) | NONE | `isActive = NO`; pending = 0; **`_onEncodedFrame = nil` before `CompleteFrames`**, so flushed frames are dropped in FE20 | — | log:`HEVC encoder stopped` (os_log_info) |
| FE42 | `startReconnection` / `scheduleReconnect`. Lifecycle M4x and U5. | mS:3585 / 3616 | S (NSTimer on S) | Lifecycle doc | `stopCapture` | — | Lifecycle doc |
| FE43 | Delayed Wi-Fi advertising start | mS:936 (`dispatch_after` 3 s, main) | M | `_wirelessTransport.isConnected` → skip | — | — | Lifecycle doc. Not on the frame path. |

### 3.2 iPad

| Id | Trigger | Location | Queue | Guard | State writes | Msgs | Log |
|---|---|---|---|---|---|---|---|
| IE1 | USB input TCP bytes | iU:923-960 receive → `drainUSBTCPBuffer` iU:983-1075 | IUT | Length `0 < msgLen < tcpMaxFrameLength`, else clear the buffer | `tcpBuffer`, offset | — | log:`[CONSOLE] USBTransport: invalid TCP frame length \(msgLen), clearing buffer`; recv error / complete prints at iU:948/954. **The message is a Data slice (iU:1027).** |
| IE2 | Wireless input TCP bytes | iW:927-980 → `drainTCPBuffer` iW:982-1066 | IWT | Same | Same | — | Tcp-drain prints iW:1012/1063. The message is a copy (iW:1024). |
| IE3 | `handleInputReceived` | iS:1101-1173 | IUT/IWT | Handshake parse first | `wirelessLZ4Dropped` | **FRAME_ACK** when `isHEVC && chunkTotal<=1 && wireless.isConnected && !usb.isConnected` (global flags, not the arrival link) | log:`[CONSOLE] LZ4 over wireless dropped seq=\(mediaHeader.seq) key=\(mediaHeader.isKeyframe) bytes=\(data.count) total=\(wirelessLZ4Dropped)`. The ack itself: IE6. |
| IE4 | SESSION_HANDSHAKE | iS:1011-1078 | IUT/IWT (**off main**) | NONE | `macDisplay*`; **new `LZ4Decompressor` with a zero reference** (iS:1020); renderer size; `state = .streaming` (off main). **No reassembler or decoder reset.** | VIEWPORT_REPORT (IE5) | os_log only: `Session handshake: ...` (iS:1012); log:`[CONSOLE] Session handshake complete; forcing HUD visible` |
| IE5 | `sendViewportReport` | iS:491-499 → `sendInputEventReturningLink` iS:1433-1442 | caller (IUT/IWT) | `usbTransport.isConnected` first, else wireless, else nil. **Not the link the handshake came on.** | — | VIEWPORT_REPORT. Sent once per handshake; **no retry**. | **NO LOG** at the sender. iU `sendInputEvent` (iU:550): `inputConnection == nil` → silent return; a send error is **os_log only** (`Input send error: \(error)`). |
| IE6 | `sendFrameAck` | iS:1394-1404 | IUT/IWT | NONE | `framesAcked` | FRAME_ACK (u16 LE) on `wirelessTransport` always | log:`[CONSOLE] SessionManager: frame ack sent seq=\(seq) count=\(framesAcked)` (first 5, every 600) |
| IE7 | `processChunk` | UR:121-124 (`queue.async`) → `deliverFrameData` UR:338-452 | RQ | Awaiting keyframe → drop non-keys; first frame must be a key; **stale: distance 0 or > 32768 → drop (UR:386), checked before the keyframe fast-forward (UR:418)**; ordered gap → fast-forward on a key, else recovery | `lastDeliveredSeq`, `awaiting...`, out-of-order buffer | — | log:`[CONSOLE] UDPReassembler: dropping seq=\(seq) while waiting for keyframe (dropped=\(droppedUntilKeyframeCount))`; log:`[CONSOLE] UDPReassembler: stale-frame-drop seq=\(seq) last=\(lastDeliveredSeq) distance=\(distance) reason=\(staleReason) count=\(staleFrameDropCount) source=\(sourceLabel)` (first 10, every 50); log:`[CONSOLE] UDPReassembler: ordered-gap fast-forward on keyframe seq=\(seq) source=\(sourceLabel) distance=\(distance)`; log:`[CONSOLE] UDPReassembler: recovered on keyframe seq=\(seq)` |
| IE8 | Frame delivery | UR:331 (`callbackQueue.async`) → `onFrameReassembled` → `handleReceivedFrame` iS:686 | RCB | Magic / size (iS:688/694) | — | — | log:`[CONSOLE] handleReceivedFrame: magic mismatch` |
| IE9 | Recovery needed | UR:469-484 `enterRecoveryMode` → UR:480 → iS:509 (main) → IE23 | RQ → RCB → IM | Notifies only on entry (`!awaitingKeyframeAfterLoss`); **no retry while awaiting** | `awaitingKeyframeAfterLoss = true` | Possibly REQUEST_KEYFRAME | log:`[CONSOLE] UDPReassembler: entering recovery, waiting for keyframe (\(reason), missing seq=\(missingSeq), buffered=\(outOfOrderBuffer.count), pending=\(pendingFrames.count))` |
| IE10 | `resetForNewStreamSession` | UR:158-180 | RQ | NONE | All sequencing state | — | log:`[CONSOLE] UDPReassembler: reset-for-new-session entry reason=\(reason) hasBaseline=\(hadBaseline) lastSeq=\(lastSeqBefore) pending=\(pendingBefore) ooo=\(outOfOrderBefore) awaitingKeyframe=\(awaitingBefore)` |
| IE11 | Purge timer (2 s) | UR:526 (`setEventHandler`) | RQ | Age | Pending chunks purged | — | log:`[CONSOLE] UDPReassembler: PURGED seq=\(seq) (\(received)/\(total) chunks, age=\(String(format: "%.0f", (now - (pending?.createdAt ?? now)) * 1000))ms, total purged=\(framesPurged))` |
| IE12 | HEVC decode dispatch | iS:742-770 | RCB | — | — | — | log:`[CONSOLE] handleReceivedFrame: HEVC decode FAILED for seq=\(header.seq)` (**first 5 only**) |
| IE13 | `HEVCDecoder.decode` | HD:94-246 (VTDecompressionSessionDecodeFrame HD:182) | RCB | Keyframe → `ensureSession` (same dims: keep the session); no session → `.failed` | session, formatDescription | **None** (no keyframe request) | log:`[CONSOLE] HEVCDecoder: no session (awaiting keyframe)`; log:`[CONSOLE] HEVCDecoder: ensureSession FAILED for keyframe (data=\(payloadLength) bytes)`; decode-submit failure is **os_log only** `VTDecompressionSessionDecodeFrame failed: %d` → `Session error %d -- will recreate on next keyframe` (HD:216-219, 522-525) |
| IE14 | VT decode output callback | HD:~186-211 | VT decoder thread | Status | — | — | log:`[CONSOLE] HEVCDecoder: decode-callback seq=\(header.seq) status=error code=\(decodeStatus) ...` (sampled; **no invalidate, no recovery**) |
| IE15 | Decoded hand-off | iS:837-860 (`hevcHandoffQueue.async` iS:846) → iS:862 | HQ | NONE | First frame → `state = .streaming` (main) | — | log:`[CONSOLE] SessionManager: hevc-handoff queue-enter seq=\(header.seq) source=\(source) queueWait=\(String(format: "%.2f", queueWaitMs))ms state=\(self.state.rawValue)` (sampled) |
| IE16 | LZ4 decode | iS:772-835 | IUT | Decompressor nil (os_log only); `frameBytes > bufCap` → skip; decompress nil → skip | Decompressor reference; first frame → `.streaming` (iS:826, main) | **None** (no seq check, no keyframe request) | log:`[CONSOLE] LZ4: skipping frame, frameBytes=\(frameBytes) bufCap=\(decompressor.frameBytes) macDims=\(macDisplayWidth)x\(macDisplayHeight)`; log:`[CONSOLE] LZ4: decompress returned nil, frameBytes=\(frameBytes) payload=\(payloadLength) seq=\(header.seq)` |
| IE17 | `MetalRenderer.updateFrame` | MR:253-305 | IUT (or HQ on fallback) | Ring rebuilt if the size changed; no free slot → steal the oldest queued, else drop | ring, queue | — | log:`[CONSOLE] MetalRenderer: ring (re)built slots=\(ring.count) size=\(width)x\(height)`; log:`[CONSOLE] MetalRenderer: no free ring slot, display drop (gpuRefs=\(refs))`. Cap drops: counters only (RENDER-CADENCE). |
| IE18 | `updateFrameFromPixelBuffer` | MR:329-376 | HQ | Texture cache, else the copy fallback | queue (slot nil) | — | NO LOG (counters only) |
| IE19 | Display-link tick | MR:517-659 (CAMetalDisplayLink MR:230) | DL (main) | `inflightSemaphore.wait()` (**blocks the main thread**, MR:521) | `shownFrame`, `backlogTicks`, `gpuRefs++` | — | log:`[CONSOLE] RENDER-CADENCE ticks=\(cadTicks) late=\(cadLateTicks) ...` (1/s) |
| IE20 | Command buffer complete | MR:626 / 650 (`addCompletedHandler`) | GPU | NONE | `gpuRefs--`; semaphore signal | — | NO LOG |
| IE21 | First decoded frame | iS:818-833 / 920-936 (writes at 829/934) | IUT/HQ → IM | `state == .connecting \|\| .reconnecting` | `state = .streaming`; `hasRenderedFrameInCurrentSession` | — | NO LOG at the transition (the HUD is shown) |
| IE22 | GEOMETRY_UPDATE | iS:1275-1320 | IUT/IWT | Parse | `macDisplay*`; **a decompressor that grows is re-created with a zero reference** (iS:1300); renderer size | — | log:`[CONSOLE] Geometry update: \(oldW)x\(oldH) -> \(macDisplayWidth)x\(macDisplayHeight)@\(macScaleFactor)x`; log:`[CONSOLE] LZ4 decompressor: growing buffer \(existing.frameBytes) -> \(newFrameBytes)` |
| IE23 | `requestImmediateKeyframe` | iS:1406-1426 | IM | **`wireless.isConnected && !usb.isConnected`, else a silent return**; 500 ms cooldown | `lastKeyframeRequestUs` | MODE_CHANGE/REQUEST_KEYFRAME, USB first (iS:1434) | log:`[CONSOLE] SessionManager: keyframe request suppressed (cooldown \(timestamp - lastKeyframeRequestUs)us < \(Self.keyframeRequestCooldownUs)us)`; log:`[CONSOLE] SessionManager: requesting immediate HEVC keyframe for recovery (ts_us=\(timestamp))` |
| IE24 | `MetalRenderer.stop` | MR:461-465 (called at iS:337, 385) | IM | NONE | The display link is invalidated. **queue / shownFrame are not cleared.** | — | NO LOG |
| IE25 | USB teardown buffer clear | iU:1078-1090 (`transportQueue.async`) | IUT | NONE | `tcpBuffer` cleared | — | NO LOG |
| IE26 | Wireless control-path replacement | iW:545-562 | caller queue [U-Q5] | `preserveMediaPathForControlRecovery` | `tcpBuffer` cleared **synchronously, not on IWT** | — | log:`[CONSOLE] WirelessTransport: control-path replacement cancelling stale/pending input connection before reconnect` |

### 3.3 Re-grep check

The patterns were re-grepped over the scope files:
- Mac: mS, SC, FC, HE, mU, mW.
- iPad: iS, UR, HD, LD, MR, iU, iW.

Every hit is accounted for in the table below.

| Pattern | Hits | Where it is covered |
|---|---|---|
| `dispatch_async` | mS:963, 1257, 2106, 2214 | 963 = the `onSession` lane, FE1-FE4 / FE5. 1257 = test-mode stress-scene UI (not relevant: main-thread NSScreen lookup). 2106 = FE36 timer start. 2214 = perf-timer stop hop (FE9 teardown, not relevant). |
| | SC:249, 328, 1419 | FE35, FE39, FE15 |
| | mU:1218 | Monitor queue (interface polling; lifecycle doc, not frame) |
| | mW:303, 429, 481, 522 | Advertising / reconnect window (lifecycle doc); 481/522 are the dormant UDP pacing queue (§1.2) |
| `dispatch_after` | mS:936 | FE43 |
| | mW:368, 394, 1183, 1217 | Lifecycle (advertise retry, control recovery poll); not frame |
| `asyncAfter` | iS:569 | Wi-Fi browse start delay (lifecycle); not frame |
| `dispatch_source_set_event_handler` / `setEventHandler` | SC:1209 | FE12 |
| | SC:1491 | FE40 |
| | mU:412 | Lifecycle (USB interface poll) |
| | mW:1233 | Lifecycle (control recovery timer) |
| | UR:526 | IE11 |
| `CAMetalDisplayLink` | MR:230 | IE19 |
| `CADisplayLink` | none | — |
| `addCompletedHandler` | MR:626, 650 | IE20 |
| `VTCompressionSessionEncodeFrame` | HE:467 | FE19 |
| `VTDecompressionSessionDecodeFrame` | HD:182 | IE13 |
| `nw_connection_send` | mU:477, 520 | `sendMediaFrame` / `sendMediaFramePaced` / `_sendChunkAtIndex` (mU:465-534) on the USB media socket. **No caller in mS** (grep: only `sendMediaViaTCP` mS:1635, `sendMediaFrameWithHeader` mS:2035 and `sendInputEvent` mS:2064), so this is dead code [C]. |
| | mU:560, 597 | `sendInputEvent` (mU:535) and `_sendTCPFramedChunkAtIndex` (mU:569): input events (FE10 path) and TCP framing [C] |
| | mU:698, 753, 843, 883 | FE27 |
| | mW:511 | Dormant UDP |
| | mW:574 | FE28 |
| | mW:611 | Input events |
| `stateUpdateHandler` / `nw_connection_set_state_changed_handler` | None in the frame files; they live in the iU/iW/mU/mW connection setup | All owned by the lifecycle doc (P-rows / M-rows) |
| `DispatchQueue.main.async` (iS) | 509 | IE9 |
| | 519, 540, 610, 618, 646 | Lifecycle / HUD |
| | 818, 828, 923, 933 | IE21 |
| | 1046, 1055, 1071 | Handshake side effects (IE4) |
| | 1178, 1218, 1318, 1333, 1355, 1362 | Probe / HUD / FPS timers (not relevant to frame identity) |
| `queue.async` / `callbackQueue.async` / `hevcHandoffQueue.async` | UR:122, 160, 331, 480; iS:846 | IE7, IE10, IE8, IE9, IE15 |
| iU: `setEventHandler`, `stateUpdateHandler`, `asyncAfter`, `monitorQueue.async` | iU:406, 452, 471, 533, 629, 660, 730, 774, 794, 841, 885 | Lifecycle doc (USB browse, connection state, retry). Not frame rows. |
| iU: `connection.send` | iU:558 | IE5/IE6 (input events: viewport, ack, keyframe request) |
| iU: `connection.send` | iU:605 | `sendMediaData` (iU:603): iPad→Mac media socket. No caller in iS [C, grep]. |
| iU: `transportQueue.async` | iU:1085 | IE25 |
| iW: `stateUpdateHandler`, `asyncAfter`, `setEventHandler` | iW:384, 574, 728, 907, 1127, 1170, 1219, 1244, 1309 | Lifecycle doc |
| iW: `mediaProcessingQueue.async` / `transportQueue.async` | iW:852/855 | The dormant UDP media receive → `onMediaReceived` → reassembler unordered (§1.2) |
| iW: `connection.send` | iW:519/529 | Input events (IE6 acks, IE5 when USB is down) |
| TransportFSM.c, LZ4Decompressor.swift, delta.c | No hits; pure functions | FE6/FE7/FE8 cite FSM lines |

## 4. Frame identity

### 4.1 Fields a frame carries

`MediaFrameHeader` (PH:25-34) is 25 bytes, and the iPad agrees (`static let size = 25`, Protocol.swift:74) [C]. Note: the comment at UR:120 says "24-byte"; it is stale.

| Field | Meaning |
|---|---|
| `magic` | 0x4B44 |
| `flags` | HEVC 1<<0, KEYFRAME 1<<1, LAST_CHUNK 1<<2, STRIPED 1<<3, DELTA 1<<6 |
| `seq` | u16 |
| `chunk_idx`, `chunk_total` | Chunking |
| `payload_size` | Payload length |
| `ts_us` | Capture host time |
| `crc32` | LZ4: a crc32 of the payload (FC). HEVC: always 0 (HE:~700). |

The seq differs by codec:
- **LZ4:** `seq` is the low 16 bits of the compressor's u32 `seq`. It resets to 0 on every compressor init: capture start, resize (SC:1434), resolution match [C].
- **HEVC:** `seq` is `_seq++` (HE:697). It resets only when the Mac process starts (HE:67) [C].
- The two seq spaces are independent and can overlap [C].

### 4.2 Ties to connection, route, codec configuration or generation

**None in the header** [C]. The only codec information is the HEVC flag, and the only configuration hint is a keyframe carrying VPS/SPS/PPS.

What the Mac does have, sender-side only:
- `_wifiTCPSendGeneration` (wireless completions only, mS:1892ff) [C].
- Seq-discontinuity detection in the ack gate (mS:2598) [C].

USB completions, acks, and anything on the iPad carry no generation [C].

### 4.3 What the receiver checks

| Check | Location | Codec |
|---|---|---|
| Length prefix bounds | iU:998, iW | Both |
| Handshake discriminator first | iS:1104 | Both |
| `magic` and size | iS:688/694, UR:188/193 | Both |
| **DropOldLink**: LZ4 arriving on wireless is dropped | iS:1120 | LZ4 |
| Reassembler: chunk-total consistency, seq continuity (stale / duplicate / gap / out-of-order), keyframe-await | UR | HEVC, and chunked LZ4 |
| Decoder session exists; keyframe → `ensureSession` dims | HD | HEVC |
| Decompressor buffer capacity vs `macDisplay*4` | iS:~780 | LZ4 |
| Striped table validation | DC:228-257 | LZ4 |

Not checked by the receiver:
- **crc32 is never verified on the iPad**: a grep for `crc` in iS/HD/LD/UR finds only the pass-through at UR:308 [C].
- **LZ4 seq continuity is never checked** [C].
- The arrival link vs the current route is not checked for HEVC [C].
- The connection or generation is not checked for anything [C].

### 4.4 Frames in flight across each transition

| Transition | Mac side | iPad side |
|---|---|---|
| **Link switch USB → wireless** (unplug; immediate fallback mS:1033-1037; lifecycle §4.1) | Frames in the USB kernel buffer are lost with the connection. USB completions (FE23/FE26) decrement `_tcpMediaSendsInFlight` with **no generation**; FE9 is not run on this path (STREAMING; mS:1053), so the counter is not reset [C]. HEVC is started via FE8 (ack reset `"hevc-mode"`) [C]. LZ4 frames compressed while USB was up, if they reach `sendMediaFrameToiPad` after USB drops, take the **wireless branch** (route by `isConnected`, mS:1604/1645). They are counted by `wifiAckNoteSentSeq` as if HEVC, producing a discontinuity log [I]. | A partial message in the iU buffer is cleared (IE25) [C]. LZ4 arriving over wireless is dropped (DropOldLink) [C]. The decompressor reference is kept [C]. HEVC starts with a keyframe? The encoder starts fresh, so its first frame is an IDR [I]. The reassembler is **not reset**: the HEVC seq continues from the previous encoder in the same Mac process, so the first frame is a forward gap → fast-forward on the keyframe (UR:418) [I]. |
| **Link switch wireless → USB** (replug; FE1 / FSM WIRED_APPEARED) | WIRED_APPEARED from WIFI/AWDL → DISCONNECT_CURRENT + SWITCH_ENCODE_LZ4 (FSM:50-55) [C]. The encoder stops: frames still in VT are dropped by FE41/FE20 (no seq consumed). HEVC frames already in the wireless kernel buffer continue to drain over wireless until that connection closes [I]. LZ4 compression is gated off until USB TCP is up (FE16), **so nothing is sent on any link between interface-appear and USB TCP ready** [C+I]. On FE1: force an LZ4 keyframe, then FE9 (counters = 0, generation += 1, ack reset, handshake) [C]. | HEVC frames that arrive over wireless after USB connects are **not acked** (usb connected) but still reassembled, decoded and **enqueued**. They interleave with LZ4 frames in a renderer queue that has no codec or route identity (MR:315) [I]. The handshake makes a zero-reference decompressor (iS:1020) [C]. |
| **Codec switch HEVC → LZ4** (FE7, RouteResync) | `stop` sets `_onEncodedFrame = nil`, so flushed frames are dropped silently [C]. Between `stop` and `configureFrameDelivery`, the old `onPixelBuffer` block calls `encodePixelBuffer` on an inactive encoder → `encodePixelBuffer: skipped` (HE:265) [C]. The compressor reference is whatever it was **at the last LZ4 frame** (it does not advance during HEVC) [C]. FE7 itself does **not** request a keyframe; only FE1 (mS:846) and FE30 (mS:3124) do [C]. | Same as the row above. If no forced keyframe reaches the iPad after its last reference change, deltas apply to a reference that differs from the Mac's. The result is garbage until the 600-frame keyframe (FC: `keyframe_interval` 600) [I]. |
| **Codec switch LZ4 → HEVC** (FE8) | Ack reset; encoder starts (if the viewport is known) → IDR [C]. LZ4 frames already in the USB socket drain or die with USB [I]. | The reassembler is not reset (continuity from the previous HEVC session in the same Mac process) → forward gap → keyframe fast-forward [I]. |
| **Resize** (viewport change, geometry, resolution match) | LZ4: `updateCaptureResolution` live-reconfigures. Old-size frames are skipped by `compress_frame` (-2, logged). The compressor is re-initialized on the first new-size surface (SC:1431-1444) → seq 0 → keyframe [C]. HEVC: FE31 restarts the encoder (IDR); **no ack reset**; the HEVC seq continues [C]. FE33 eco ON changes the encoded size without a geometry update [C]. | The decompressor is re-created with a zero reference on **grow** only (iS:1300) [C]. LZ4 frames decode with `frameBytes = macDisplay*4` from the latest handshake or geometry; old-size frames in flight mismatch → skip or nil (logged) [C]. HEVC: a keyframe with different dims recreates the session; same dims keeps it (HD:286-293) [C]. |
| **Encoder restart** (eco on/off, viewport) | `stop`: frames inside VT dropped (callback guard) [C]. `_seq` continues → no discontinuity; `_pendingFrameCount` may dip below 0 between stop and start [I]. | No gap is seen. A changed parameter set at the same dims keeps the session [C] → [U-Q2]. |
| **Takeover** (new wireless connection replaces old; lifecycle §4.1 Paths A/B/C) | If FE9 runs: generation bump, counters reset, ack reset `"transport-connected"` [C]. If it does not (STREAMING, and the FSM state does not change): **no ack reset, no generation bump** [C]. Frames sent on the old connection never reach the iPad, so they are never acked. Once unacked ≥ 5 the gate closes and nothing new is encoded → no acks → **no escape** (FF17) [I]. | The reassembler is not reset by a takeover [C]. A new handshake (if sent) makes a zero-reference LZ4 decompressor but leaves HEVC state alone [C]. |
| **Mac agent restart** (iPad survives) | HEVC `_seq` restarts at 0 [C]. | Reassembler `lastDeliveredSeq = L` is kept unless a reset path ran (iS:318-1476). If L < 32768, every new frame is `behind-last-seq` and stale-dropped until seq > L (L/60 s at 60 fps). If L ≥ 32768, it is a forward gap → keyframe fast-forward [C, UR:384-392 + arithmetic]. Acks are still sent (iS:1126, before the reassembler), so the Mac gate is satisfied [C]. |
| **iPad relaunch** (Mac survives) | Lifecycle doc. RouteResync (FE1) covers HEVC still being active when USB TCP comes up [C]. | Fresh reassembler, decoder and decompressor [C]. |

---

## 5. Failure paths

"Lost" is what the user would see. "Logged" means visible in the logs the harness actually captures: Mac os_log, iPad `[CONSOLE]`.

| Id | Trigger | What is lost | Recovery | Logged |
|---|---|---|---|---|
| FF1 | `onFrame` returns because not STREAMING or HEVC is active (mS:1394-1399), **after** `compress_frame` advanced the Mac reference | One LZ4 delta → the iPad reference diverges → **garbage** | Next keyframe: forced (FE1/FE30) or periodic every 600 frames (FC). None targeted. | **NO** |
| FF2 | `sendMediaFrameToiPad` / `sendInputEventToiPad` with neither transport connected (mS:1604-2004 has no final else; mS:2062) | LZ4: a delta after compress → garbage. HEVC: a seq gap → reassembler recovery (wireless) or nothing (USB). Handshake: see FF21. | As FF1 / FF13 | **NO** |
| FF3 | USB media send with a nil connection or a send error (mU:621/791/771/889) | A delta after compress → garbage | As FF1 | Yes (os_log) |
| FF4 | `_lz4CompressPending > 1` (SC:1413-1417), or `!_compressorInitialized \|\| !_isCapturing` (SC:1420-1424) | A capture before compress (no desync) | Next capture | **NO** |
| FF5 | `shouldCompressFrame` NO: no USB, or in-flight ≥ 2 (mS:1374-1389) | A capture before compress. **During the interface-appear → USB-TCP-ready window, every capture** (FSM switched to LZ4; no wireless HEVC) → **frozen picture** | USB TCP ready (FE1) | Sampled (every 120) |
| FF6 | `compress_frame` size mismatch (FC:252) | A capture before the reference changes | Compressor re-init on a matching surface (SC:1431) | Yes |
| FF7 | LZ4 compressor resize init fails (SC:1434-1441) | `_compressorInitialized = NO` → **every later frame dropped silently** (FF4) → **frozen** | None until capture restart (FE39) | One os_log_error: `LZ4 compressor resize failed: %zu -> %zu bytes (%zux%zu)`, then silent |
| FF8 | Striped decode stripe failure -7 (DC:258-268) | **Torn reference** (some stripes updated) → garbage | Next keyframe | Yes: log:`[CONSOLE] LZ4 striped: decode FAILED rc=\(rc) seq=\(header.seq) key=\(header.isKeyframe) payload=\(payloadLength) expected=\(expectedBytes) stripes=\(stripes)` |
| FF9 | iPad LZ4 `frameBytes > bufCap` skip, or decompress nil (iS:~780-795) | A delta the Mac thinks was delivered → garbage | Next keyframe | Yes (sampled) |
| FF10 | **Handshake re-creates a zero-reference decompressor (iS:1020)** while the Mac keeps sending deltas: capture already running (takeover / replug), or a forced keyframe that preceded the handshake on the wire | XOR deltas on zero → **near-black picture** with changed regions as noise [I] | FE30's `requestLZ4Keyframe` (mS:3124), one RTT, **only if** the viewport report reaches the Mac and the LZ4+USB+capturing branch runs. Else periodic: 600 frames ≈ 5 s at 120 fps [I]. | Not as such (only the handshake and keyframe lines) |
| FF11 | Geometry grow re-creates a zero-reference decompressor (iS:1300) with no following keyframe (e.g. FE7's geometry update) | As FF10 | As FF10 | `[CONSOLE] LZ4 decompressor: growing buffer ...` |
| FF12 | LZ4 over wireless dropped (DropOldLink, iS:1120) | If the dropped frame was the forced keyframe, the keyframe is lost → garbage on USB | Next forced or periodic keyframe | Yes |
| FF13 | HEVC reassembler recovery (UR:469) | **Frozen picture.** Non-key frames are dropped until a keyframe. | `requestImmediateKeyframe` **once per entry** → returns silently if USB is connected (iS:1407), is suppressed by the 500 ms cooldown, and is a no-op on the Mac if the encoder is inactive (HE:212). **No retry.** Fallback: periodic IDR every 300 s (HE:171-173). | Entry yes; the silent USB return NO |
| FF14 | HEVC stale-drop after a Mac process restart without a reassembler reset (UR:386). **Reachability [I]: low.** A Mac restart drops both links; an iPad in `.streaming` that sees `.disconnected` runs `scheduleReconnect` → reset (iS:636-639, 1476). This applies only if the iPad redials without a `.disconnected` transition (e.g. the iW control-path replacement, iW:545-560). | **Frozen or black** until seq > the old last (if last < 32768) | Seq catches up, or a reset path. Acks still flow, so the Mac sees health. | Sampled (first 10, every 50) |
| FF15 | HEVC decoder: no session, decode-submit error → invalidate, decode-callback error (HD:118-125, 216-219, 186-211) | **Frozen** (P-frames fail until an IDR) | **No keyframe request** from the decoder path. Periodic IDR every 300 s, unless the reassembler happens to enter recovery. | iS: first 5 FAILED only; HD submit error and session error are **os_log only** |
| FF16 | Same-dims keyframe with a changed VPS/SPS/PPS keeps the session (HD:286-293) | Possibly decode errors → FF15 | — | [U-Q2] |
| FF17 | **Ack gate stuck**: unacked ≥ 5 with no acks arriving (mS:1476). Frames lost on an old connection; the iPad not acking (FF18); `wifiAckNoteSentSeq` counted a send that failed (mS:1888) | **Frozen.** No capture is encoded, so nothing new can be acked. | Only `wifiAckResetWithReason` (FE8 `"hevc-mode"`, FE9 `"transport-connected"`). By design (NoBlindReset) there is no timeout. | Sampled drop line (first 10, every 100); `WiFi ack 1s` only in test mode |
| FF18 | iPad does not ack because its `usbTransport.isConnected` is true (stale or real) while HEVC arrives over wireless (iS:1127) | Nothing directly. The Mac gate (if already active) → FF17. | As FF17 | **NO** on the iPad |
| FF19 | Wireless capture start gated on DTLS media ready (mS:1219-1226; FE4) while media actually uses TCP | **Black.** No capture ever starts. | DTLS becoming ready | One line: `Capture deferred until media channel ready` |
| FF20 | **Viewport report lost**: IE5 sends on `usbTransport` whenever `isConnected`, even if the handshake came over wireless or the USB connection is dead; iU `sendInputEvent` returns silently on a nil connection; no retry | Mac (only if `_viewportReceived` is still NO, i.e. the first viewport in this Mac process): USB LZ4 capture deferred (mS:1239) or HEVC encoder deferred (mS:1210) forever → **black** | None (no retry; one viewport per handshake) | Mac deferral line only; iPad **NO LOG** (send error os_log only) |
| FF21 | Handshake dropped: no transport (mS:2062, silent) or a dead connection | iPad: no new decompressor or viewport → FF20 | Next onTransportConnected | **NO** |
| FF22 | Encoder saturation skip, stale-age drop, ack-gate drop (pre-encode) | One capture, no desync | Next capture | Sampled |
| FF23 | VT encode failure or callback error (HE:482/581) | One frame (no seq consumed on a callback error) | VT's own reference chain [U-Q6] | Yes |
| FF24 | Encoder stop with frames inside VT (FE41) | Those frames, silently (no seq consumed) | Encoder restart IDR | **NO** |
| FF25 | USB in-flight counter skew: FE9 sets it to 0 while old-connection completions are pending (no generation, mS:~1638/2038) | Negative count → the LZ4 gate over-admits (no clamp on USB) [I]; or completions that never arrive → the gate stuck at 2 until FE9 [U-Q3] | FE9 on the next connect | Completion line only |
| FF26 | Renderer queue-cap or no-slot drop (MR:316-321, 277-283) | Display only (decode state intact) | Next frame | Cap: counters in RENDER-CADENCE; no-slot: yes |
| FF27 | GPU never completes a command buffer → `inflightSemaphore.wait()` on main (MR:521) | **Main thread hangs** | None | **NO** (RENDER-CADENCE stops) [I] |
| FF28 | Mixed-codec interleave after wireless → USB (§4.4) | Brief flashes of older HEVC frames between LZ4 frames [I] | Old wireless connection drains or closes | **NO** |
| FF29 | USB TCP reconnects **without** a prior interface event while STREAMING on wireless (e.g. USB TCP lost → immediate wireless fallback mS:1033-1037, interface still up, then the iPad redials USB) → FE1 first branch → WIRED_APPEARED → LZ4, then mS:1053 skips FE9 [C] | No handshake, no forced keyframe, no `_tcpMediaSendsInFlight` reset. The LZ4 deltas continue from the Mac reference of before the drop, so any FF1/FF3 loss during the drop → **garbage until the 600-frame keyframe** (~5 s at 120 fps) [I] | Periodic keyframe | Only FE6's lines |
| FF30 | Mac USB `isConnected` stays YES with a nil `inputConnection` after an IP rebind (lifecycle M23, mU:1225-1241) | `shouldCompressFrame` admits; every send fails (FF3) → deltas lost, garbage, then nothing | Interface loss (mU:441) | Yes (`USB media split-send skipped: no TCP input connection (seq=%u)`, every frame) |

### 5.1 Known hardware failures traced

**K1. USB replug black screen of about 5.5 s**
- (a) [C] Interface appear (mS:864-872) → WIRED_APPEARED → from WIFI/AWDL: `switchToLZ4Mode`; HEVC stops (FSM:50-55, FE7). STREAMING, so mS:1053 skips FE9. `executeEffect` ignores DISCONNECT_CURRENT (mS:1086-1090), so the wireless connection stays up.
- (b) [C] LZ4 is gated off until USB TCP is up (FE16) → no frames on any link (FF5). The iPad keeps redrawing `shownFrame` (MR:569) only if its state stays in connecting, streaming or reconnecting (CV:50).
- (c) [C] USB TCP ready → FE1 else-branch (the state is already USB_NCM): `requestLZ4Keyframe`, then FE9: handshake. Capture is already running: `startCapture` returns early when `_isCapturing` (SC:307-309), so the compressor is not re-initialized.
- (d) [C] iPad IE4 creates a zero-reference decompressor (iS:1020). If the forced keyframe was compressed and sent before the handshake bytes (ZQ/KQ vs S race [I]), the following deltas decode against zero → a near-black frame (FF10) [I].
- (e) [C] The viewport report → FE30 → `requestLZ4Keyframe` (mS:3124) should recover in one RTT.
- (f) [I] 5.5 s is close to 600 frames (`keyframe_interval`) at ~110 fps, which suggests the FE30 keyframe did not take effect and the periodic keyframe ended it.
- Status: mechanism [I]; no covering code found. FE7 sends no keyframe and IE4 zeroes the reference [C].
- [U-Q4] says what would discriminate the cause.

**K2. HEVC sent over USB after an iPad relaunch**
- [C] Fixed by RouteResync in FE1's else-branch (mS:835-842).
- It runs only when `_transportState` is already USB_NCM. The other branch relies on FSM WIRED_APPEARED → SWITCH_ENCODE_LZ4.
- Still uncovered:
  - [C] Routing is by `_usbTransport.isConnected`, not by codec (mS:1604), so any HEVC-active-while-USB state sends HEVC on USB. This is intended for eco (FE33), but FE30 also falls through to FE31 at 100 Mbps when USB is up and HEVC is active.
  - [C] The iPad never acks HEVC over USB and never requests a keyframe for it (iS:1407).

**K3. Viewport report sent into a dead USB connection, so the encoder never started**
- [C] FF20: IE5 routes by `usbTransport.isConnected` (iS:1434), not by the link the handshake arrived on.
- [C] iU:551 returns silently on a nil connection.
- [C] There is no retry.
- [C] The Mac defers the encoder or capture until the viewport arrives (mS:1210/1239).
- Status: **not fixed. No viewport re-send exists (single caller, iS:1041).**
- Masked when `_viewportReceived` is already YES from an earlier session (it is never reset) [C].

**K4. Ack gate stuck at 5 after a wireless takeover**
- [C] FF17: no reset unless FE9 or FE8 runs.
- [C] Takeover in STREAMING with the FSM staying WIFI/AWDL does not run FE9 (mS:1053).
- [I] Old-connection frames are never acked.
- Contributing: [C] FF18 (the iPad suppresses acks while it believes USB is up); [C] the mS:1888 note-before-send.
- [C] Per lifecycle §4.1 (lines 299-350), Paths A (degraded, then a fresh accept), B (duplicate-replace, mW:640-668) and C (control recovery succeeds) all leave STREAMING with an unchanged FSM state → the mS:1053 skip → no FE9.
- [C, from the lifecycle doc's log] The stall in run pid 98733 lasted until the agent was stopped.
- Status: mechanism [C]; no covering code found. NoBlindReset forbids a timeout, and none of the three paths resets the gate.

**K5. iPad SIGTRAP on HEVC parameter-set extraction from a Data slice**
- [C] iU:1027 still passes a non-zero-based slice.
- [C] HD uses `zeroBased` (HD:266-270) for VPS/SPS/PPS and NAL extraction (HD:342-344, 495). **Fixed.**
- [C] `MediaFrameHeader.parse` uses `withUnsafeBytes` (Protocol.swift:79ff).
- [C] No other `data[...]` subscripting was found in iS/UR/LD/HD/Protocol.swift by grep.
- [C] iW copies the message (iW:1024), so only USB delivers slices.

---

## 6. Flags

### (a) Transitions with no log
- [C] Post-compress `onFrame` drop (mS:1394-1399) (FF1).
- [C] No-transport media, handshake or input drop (mS:1604-2004, 2062) (FF2/FF21).
- [C] `_lz4CompressPending` and `!_compressorInitialized` drops (SC:1413-1424).
- [C] Encoder-stop flush drops (HE:200 + callback guard).
- [C] `requestImmediateKeyframe` silent return while USB is connected (iS:1407).
- [C] `sendViewportReport` (iS:491); iU `sendInputEvent` nil-connection return (iU:551).
- [C] `configureFrameDelivery` block swap (mS:1370).
- [C] First-frame `state = .streaming` (iS:826/933).
- [C] `MetalRenderer.stop` (MR:461).
- [C] HEVC `.failed` after the 5th (iS:767).
- [C] HD session error and submit error are os_log only, so they are not in the iPad capture.
- [C] Renderer cap drops appear only in aggregate counters.

### (b) Async callbacks with no identity or generation guard
- [C] USB send completions FE23/FE26 (mS:~1638, ~2038): no generation.
- [C] FRAME_ACK FE29 (mS:2620): the seq window only; no connection or generation, and an ack from an old connection inside the window is accepted.
- [C] VT encode callback FE20: guarded by `isActive` and the block only, not by a session generation. A callback from a stopped session that arrives after a restart would be emitted with the new block.
- [C] Reassembler delivery `callbackQueue.async` (UR:331) and recovery (UR:480): no session id. A frame queued before `resetForNewStreamSession` still reaches `handleReceivedFrame`.
- [C] `hevcHandoffQueue.async` (iS:846) and HD async `onDecodedFrame` (HD:203): no session id. Decoded frames from before a takeover or codec switch are enqueued to the renderer.
- [C] iW control-path buffer clear (iW:557) runs off IWT [U-Q5].
- [C] The FE36 perf timer reads S-owned state on M without locks.

### (c) Stalls with no escape
- FF17, the ack gate (by design). Plus FF18 as a cause.
- FF7, the compressor resize failure.
- FF20, the lost viewport on the first session.
- FF19, DTLS never ready.
- FF13/FF15, HEVC recovery with no retry; the only escape is the 300 s IDR. Over USB-eco it has no request path at all.
- FF27, a GPU hang blocking main.
- FF14 is bounded but long (up to ~9 min at 60 fps for L near 32767), and of low reachability (see FF14).

### (d) State not reset on reconnect, takeover, codec switch or resize
- [C] `_viewportReceived`: never reset.
- [C] HEVC `_seq`: never reset in the process.
- [C] Reassembler: not reset on handshake, takeover or codec switch (only iS:318/329/366/378/396/409/417/1476).
- [C] `hevcDecoder`: never reset on handshake.
- [C] Ack gate: not reset on FE31 (encoder restart), FE33 (eco) or a takeover without FE9.
- [C] `_tcpMediaSendsInFlight` and the generation: not reset on the immediate-fallback path (no FE9).
- [C] Renderer `queue` / `shownFrame`: never cleared (MR:461).
- [C] Compressor reference: not keyed on FE7 (no forced keyframe).
- [C] `lz4Decompressor`: reset (zeroed) on *every* handshake. This is the opposite problem: it is reset when the Mac reference is not.
- [C] iPad `lastKeyframeRequestUs`: survives sessions.

### (e) Model vs code mismatches

| Model (line) | Code (line) | Mismatch |
|---|---|---|
| WiFiSendLoop.tla:76 `L \* gate limit (kMaxMediaSendsInFlightWiFi = 3)`; WiFiSendLoop.cfg `L = 2` | mS:128 `kWiFiAckGateFrames = 5` (ack gate); mS:121 `kMaxMediaSendsInFlightWiFi = 3` (pre-ack fallback) | The constant mapping is stale. The code claims "TLAPS covers any depth". The pre-first-ack fallback gate is a second mode the model does not name [C]. |
| WiFiSendLoop.tla:8-17 as-built header (pre-encode gate at mS:1402-1417, post-encode check :1795-1832, stall reset :2448-2523) | mS:1470-1477 (no stall reset, NoBlindReset), mS:1888 | The as-built text describes removed code [C]. |
| WiFiSendLoop.tla:49 `AckGate: the iPad acknowledges each media frame it receives` | iS:1126-1129: ack **before** reassembly/decode, only when `wireless && !usb` (global flags) | The ack means "received by TCP drain", not "decoded". Acks can be suppressed while HEVC still arrives [C]. |
| WiFiRateControl.tla:30 "10 Mbps on infrastructure, 20 Mbps on AWDL" | mS:69 `kAWDLHEVCBitrate = 30000000` | T on AWDL is 30 Mbps [C]. |
| WiFiRateControl.tla:3, 9 (`evaluateWiFiAdaptiveRateControl` once per second) | mS:2114 `!_testMode → return` | **Rate control runs only in test mode.** Production stays at the encoder start rate [C]. |
| WiFiRateControl.tla:30-31 (a link change "is a new connection and restarts the encoder") | mS:1053 (no FE9 when STREAMING); FE31 has no ack reset | A link change does not always run FE9 [C]. |
| WiFiRateControl.tla:3 (the loop picks the encoder/capture rate) | SC:540/548 + the synthetic timer interval set at start | `updateCaptureResolution` is a no-op for the synthetic source, so fps changes never reach the E2E capture rate [C]. |
| StripeSync.tla:8 "As built … K = 1" | SC:30 `kLZ4Stripes` = 8; SC:1434 | K = 8 [C]. |
| FrameRing.cfg `QCap = 2` | MR:87 `kQueueCap = 1` | With cap 1 the drain branch (MR:554, `queue.count >= 2`) is unreachable and FIFO is newest-wins [C]. |
| FrameRing.tla:15-17 (each frame is copied into a slot) | MR:372 HEVC frames are enqueued with `slot: nil` | HEVC bypasses the ring and its GPU-gated reuse. IOSurface lifetime comes from ARC (`cvRef`) [C]. |
| FrameRing.tla:23 R1 (decode is upstream and always advances the reference) | FF1/FF2/FF3 (Mac side), FF9 (iPad skip) | The reference *can* diverge before the ring. DeltaSync covers the Mac post-compress drop as GateBeforeCompress, but FF1 (a STREAMING/HEVC guard after compress) is a remaining post-compress drop [C]. |
| DeltaSync.tla:44, 140 KeyOnConnect (the first frame after a (re)connect is a keyframe) | mS:846 only in FE1's else-branch; FE7 none; IE4 zeroes the iPad reference per handshake | The handshake reset of the iPad reference is not modelled. A keyframe is forced only on FE1's *else*-branch (mS:846) and on FE30 (mS:3124). FE1's first branch (`_transportState != USB_NCM` → WIRED_APPEARED) while STREAMING skips FE9 (mS:1053): no handshake, no forced keyframe, no counter or ack reset [C]. |
| DeltaSync.tla:46 DropOldLink | iS:1120 [C] | Matches. The Mac still *routes* LZ4 over wireless when USB drops after compress (mS:1645), and that branch also feeds the ack gate (mS:1888) [C]. |
| UR comment "24-byte MediaFrameHeader" (UR:120) | PH / Protocol.swift:74 = 25 | A comment only [C]. |

### (f) Unknowns

- **[U-Q1]** (non-blocking) Which thread or queue VT runs the compression output callback on, and whether it is serial with respect to `stop` and `start`. *Resolve:* log `pthread_self` / `dispatch_get_current_queue` label in HE:538, or check Apple docs (`scripts/xcode-docs.sh "VTCompressionOutputCallback thread"`).
- **[U-Q2]** (non-blocking) Whether `VTDecompressionSession` decodes correctly after `formatDescription` is swapped at the same dims (HD:290) when the parameter sets differ (eco, bitrate restarts). *Resolve:* a decode test with two encoder configurations at equal dims; or `VTDecompressionSessionCanAcceptFormatDescription` docs.
- **[U-Q3]** (**BLOCKING** (FF25 and the USB in-flight counter semantics)) Whether `nw_connection_send` completions always fire (with an error) after the peer dies or the connection is cancelled, or can be dropped. This decides FF25 and the in-flight counters. *Resolve:* Network.framework docs, or log completions after a cable pull.
- **[U-Q4]** (**BLOCKING** (K1 attribution)) For K1: which happens first on the iPad, the forced LZ4 keyframe or the handshake? And did FE30's `requestLZ4Keyframe` fire? *Resolve:* correlate Mac `LZ4 forced keyframe seq=%u (connect)` and `LZ4 viewport: capture running ...` timestamps with iPad `Session handshake complete` and `LZ4 striped: decoded seq=… key=true` in one replug run.
- **[U-Q5]** (non-blocking) The queue that `connectToService` (iW:540-562) runs on. If not IWT, the `tcpBuffer` clear races the drain. *Resolve:* read the iW call sites of `connectToService`.
- **[U-Q6]** (non-blocking) Whether a VT encode error leaves the HEVC reference chain valid for the next P-frame. *Resolve:* Apple docs.
- **[U-Q7]** (non-blocking: the last E2E iPad log has 0 `status=error`) How often IE14 decode-callback errors happen in practice (they trigger no recovery). *Resolve:* grep E2E iPad logs for `status=error`.
- **[U-Q8]** (non-blocking: the last E2E Mac log has 1 `Capture deferred until media channel ready` and 2 media-ready lines, so the gate opened in that run) Whether the DTLS media connection still reliably reaches ready (FF19). *Resolve:* E2E Mac logs; count `Capture deferred until media channel ready` against `Media channel ready -- starting capture now`.
- **[U-Q9]** (**BLOCKING** (U5, U6)) Inherited from the lifecycle doc and blocking here:
  - U5 (NSTimer on S never fires: the latency-probe timer and `scheduleReconnect`);
  - U6 (iPad `state` written off main by IE4);
  - U2 (USB EOF semantics);
  - U4 (DTLS teardown).
