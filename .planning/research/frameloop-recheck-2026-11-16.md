# Frame-loop recheck against today's tree (2026-11-16, after the lifecycle fix)

Read-only audit. Nothing was edited, built or run. The base is `frameloop-inventory-2026-11-16.md` (§1, 4, 5, 6); its ids (FE/IE/FF/K) are used here. The tree is HEAD plus the uncommitted diff to `macOS/App/SessionManager.m`, `macOS/Transport/WirelessTransport.{h,m}`, `iPadOS/App/SessionManager.swift` and `iPadOS/Transport/WirelessTransport.swift`.

**Tags**
- [C] means read in source, or in a quoted log or SDK header.
- [I] means inferred; the reason is given.
- [U] means unknown; what would resolve it is given.

**Prefixes.** All paths are under `RemoteDesktop/`.

| Prefix | File |
|---|---|
| mS | `macOS/App/SessionManager.m` (3728 lines) |
| SC | `macOS/Capture/ScreenCapture.m` |
| FC | `macOS/Compress/FrameCompressor.c` |
| HE | `macOS/Encode/HEVCEncoder.m` |
| mU | `macOS/Transport/USBNetworkTransport.m` |
| mW | `macOS/Transport/WirelessTransport.m` |
| FSM | `macOS/Transport/TransportFSM.c` |
| iS | `iPadOS/App/SessionManager.swift` |
| iU / iW | iPad USB / wireless transport |
| UR | `UDPReassembler.swift` |
| HD | `HEVCDecoder.swift` |
| LD | `LZ4Decompressor.swift` |
| DC | `Shared/delta.c` |

**Log provenance.** No log on disk contains a ` LC ` line (grep count 0 in `/tmp/keyd-run-mac-oslog.log` and `/tmp/keyd-run-ipad.log`). Every log observation below therefore comes from builds **before** today's fix [C].
- `/tmp/keyd-run-mac-oslog.log` spans several builds. The `USB NCM TCP input ready` string gains `(hevcActive=%d eco=%d)` between pid 65617 and pid 67864, and the FE30 `LZ4 viewport: capture running` branch first appears in pid 69250.
- `/tmp/keyd-e2e-{mac,ipad}.log` existed at the start of this audit. They were gone when re-checked, presumably cleared by the new E2E run.

---

## What the lifecycle fix changed on the frame path [C, diff]

| Change | Location | Log |
|---|---|---|
| A wireless candidate becomes current only at TLS READY. The candidate is held in `_pendingInputConnections` (cap 4). At READY: clear current, cancel the replaced connection, then `_inputReady = true` and `_inputConnectionEpoch++`. | mW:686-750 (`handleNewConnection`); clear at mW:118-125 | `LC MacAccept cid=%u pending=%lu current=%u isConnected=%{public}d listener=%{public}d`; `LC MacReady cid=%u replaced=%u epoch=%u AWDL=%{public}d`; `LC MacCurrentCleared cid=%u reason=%{public}s`; `LC MacTlsFail ...`; `LC MacStaleReady ...`; `LC MacEnd cid=%u branch=%{public}s` |
| Every READY fires `onConnectionChanged(YES)` (mW:764), which calls `handleTransportEvent` on S. | mW:764 | — |
| **Restart on a new connection.** Fires when `STREAMING && _transportState ∈ {WIFI, AWDL} && wireless.isConnected && epoch != _sessionWirelessEpoch`; it then calls `onTransportConnected`. | mS:1059-1068 | `LC Restart reason=new-connection epoch=%u sessionEpoch=%u` |
| `onTransportConnected` records the epoch. | mS:1209-1210 | `LC Restart session=%u (handshake, gate reset, encoder restart)` |
| Immediate wireless fallback adopts the current epoch, so it does not restart. | mS:1048 | — |
| Pre-encode hold: with no ready wireless connection, encoding stops. | mS:1495-1502 (inside `onPixelBuffer`, wireless TCP branch, after the stale-age drop and before the ack gate) | `LC MacEncodeHold reason=no-ready-connection count=%d` (count ≤ 5 and every 100th) |
| `sendMediaFrameViaTCP` returns NO when `!conn \|\| !_inputReady`. It runs `completion(NO)` synchronously first. | mW:575-611 | — |
| The caller un-notes the seq when the send returns NO. | mS:1920, 1986-1992 → `wifiAckUnnoteSentSeq` mS:2654-2664 | `LC MacEncodeUnsent seq=%u uncounted=%{public}d unacked=%d (no ready connection at send)` |
| New iPad prints. | iS:828 / 934 | `[CONSOLE] LC IpadFrame from=\(state.rawValue) -> streaming (frame before handshake)` and `... (frame before handshake, HEVC/TCP)` |
| | iS:1072 | `[CONSOLE] LC IpadHandshake from=\(state.rawValue) -> streaming` |
| | iW | `LC IpadDial`, `LC IpadReady`, `LC IpadLoss` |

**Un-note detail [C].** `wifiAckUnnoteSentSeq` only rolls `lastSent` back to `seq-1` if `lastSent == seq`. It does not clear `_wifiAckHasSent`.
- The HEVC seq was already consumed by the encoder (HE:697), so the iPad sees a **seq gap** on the next delivered frame [C+I]. UR then enters recovery unless that frame is a keyframe.
- Because sending now needs a new connection, LC Restart follows and restarts the encoder, which emits an IDR [I]. That IDR fast-forwards the reassembler.

---

## 1. Failure rows re-verified

| Row | Status | Current evidence | Log on the path | Tag |
|---|---|---|---|---|
| **FF1** post-compress `onFrame` drop | **Still present** | mS:1409-1416. `onFrame` returns when `sessionState != STREAMING` (1411) or `_hevcEncoder.isActive` (1413-1416). This is after `compress_frame` advanced the reference and `seq++` (FC:436). Reachable windows: (a) eco ON: HE start (mS:3413) before `configureFrameDelivery` (3416), so for a moment `onPixelBuffer` is nil while `isActive` is YES [I]; (b) a forced keyframe compressed before S writes STREAMING when the prior state was CONNECTING or RECONNECTING [I, low: capture is normally stopped in RECONNECTING, mS:3544/3634]. | NO LOG | [C] / [I] |
| **FF2** send with no transport | **Still present** | `sendMediaFrameToiPad` mS:1632 `if usb` / 1673 `else if wireless`, with no final else. `sendMediaFrameHeaderToiPad` mS:2052 → malloc → `sendMediaFrameToiPad` (2085ff). `sendInputEventToiPad` mS:2096-2102 has no else. **New:** with wireless `isConnected` YES but no ready connection, the wireless TCP branch now calls `wifiAckUnnoteSentSeq`. The HEVC frame is still lost after encode, so the seq gap remains. | NO LOG on the no-transport path. The no-ready path logs `LC MacEncodeUnsent ...`. | [C] |
| **FF3** USB send with nil connection or send error | **Still present** | mU:618-623 `USB media send skipped: no TCP input connection`; mU:788-792 `USB media split-send skipped: no TCP input connection (seq=%u)`; errors at mU:771 (`Media TCP send error: %{public}@ (seq=%u bytes=%zu elapsed=%llums)`) and mU:887 (`USB media split-send error: %{public}@ (seq=%u total=%zu payload=%zu elapsed=%llums)`). **Note:** the USB input listener still replaces `inputConnection` at **accept**, before TLS (mU:1043-1046). The old connection is cancelled but `isConnected` stays YES, because the old connection's end handler sees `inputConnection != connection`. Frames sent in that window are queued on the not-yet-ready connection. `nw_connection_send` "may be called before the connection is ready" (connection.h:524). | Yes (os_log_error) | [C] |
| **FF5** interface-appear → USB TCP ready freeze | **Still present** | `shouldCompressFrame` mS:1399-1403 returns NO with no USB. The FSM sets LZ4 on WIRED_APPEARED from WIFI/AWDL (FSM:50-55); `switchToLZ4Mode` stops HEVC (mS:1113). Measured windows in the old-build log: 293 ms (01:34:21.700 → .993) and 185 ms (01:51:35.235 → .420). | `LZ4 compress skipped: no USB connection (count=%u)` (every 120th) | [C] |
| **FF10 / K1** handshake zeroes the decompressor while deltas continue | **Still present, with a new sub-case** | iS:1022 `lz4Decompressor = LZ4Decompressor(frameBytes: macDisplay*4)` on every handshake. **New sub-case [C]:** the handshake sets `macDisplay*` to full display pixels (iS:1014-1016; Mac `sendSessionHandshake` mS:1346-1360, e.g. 3024x1964). On a reconnect the capture runs at viewport size (e.g. 2752x1786). Every LZ4 frame between the handshake and the next GEOMETRY_UPDATE is therefore decoded with `expectedBytes = 3024*1964*4`. `striped_decode` table validation fails with rc=-6 (DC:250, `r != frame_bytes`) before any stripe writes. **The FE1 forced keyframe is lost if it arrives in that window.** The reference is not torn. The FE30 geometry update (mS:3156) restores the right size; the decompressor is not shrunk (iS:1300-1307). Recovery: FE30 `requestLZ4Keyframe` (mS:3170), see §2. | iPad `[CONSOLE] LZ4 striped: decode FAILED rc=\(rc) seq=... key=... payload=... expected=... stripes=...` (LD:152). Mac: none specific. | [C] |
| **FF12** LZ4 over wireless dropped | **Still present** (narrower) | iS:1123-1127 (`fromWireless && !isHEVC`). Mac-side reachability: an LZ4 frame is admitted by the gate while USB is up, then routed after USB drops (`sendMediaFrameToiPad` checks `usb.isConnected` again at mS:2052/1632 → wireless branch mS:1673). It is also noted into the ack gate (mS:1916) with a discontinuity log. | `[CONSOLE] LZ4 over wireless dropped seq=\(mediaHeader.seq) key=\(mediaHeader.isKeyframe) bytes=\(data.count) total=\(wirelessLZ4Dropped)` | [C] / [I] |
| **FF13** HEVC recovery: one keyframe request, no retry | **Still present** | UR:469-483 notifies only on entry (`!awaitingKeyframeAfterLoss`). iS:507-512 hops to main. iS:1409-1433: `guard wireless.isConnected, !usb.isConnected else { return }` (silent, iS:1410), then the 500 ms cooldown (iS:104, 1413-1418). Mac: MODE_CHANGE goes through the S lane, not realtime (`session_lane_is_realtime` mS:258-270) → mS:3392-3395 → `requestKeyframe` HE:211-213 is a no-op when `!_isActive \|\| !_session`. **New escape:** LC Restart restarts the encoder (IDR) on a new wireless connection. | iPad `[CONSOLE] SessionManager: requesting immediate HEVC keyframe for recovery (ts_us=\(timestamp))` / `... keyframe request suppressed (cooldown ...)`; the silent USB return is NO LOG. Mac `Immediate HEVC keyframe requested by iPad recovery path`. | [C] |
| **FF15** HEVC decoder failures with no keyframe request | **Still present** | HD:110 (`ensureSession FAILED`), HD:121 (`no session (awaiting keyframe)`), HD:209 (decode-callback `status=error`), HD:217 / 522-523 (os_log only). iS:765-768 prints the first 5 `.failed` only. No caller of `requestImmediateKeyframe` on these paths (iS:510 is its only caller). | As listed; HD submit and session errors are os_log only (not captured) | [C] |
| **FF17 / K4** ack gate stuck | **Mostly fixed; residual paths remain** | See the K4 table below. | — | — |
| **FF18** iPad suppresses acks while `usbTransport.isConnected` | **Still present** | iS:1129-1131 (`isHEVC && chunkTotal<=1 && wireless.isConnected && !usb.isConnected`), global flags. Effect on the Mac: if the gate is already `_wifiAckActive`, unacked frames grow → FF17. Right after any reset the gate is in pre-ack mode (in-flight ≤ 3, mS:1503-1505), so suppression there only delays activation [C]. | NO LOG on the iPad | [C] |
| **FF19** capture start gated on DTLS `mediaChannelReady` | **Still present** | mS:1236-1243 (`Media channel already ready -- starting capture now` / `Capture deferred until media channel ready`); `mediaChannelReadyOnSession` mS:997-1008. **On the LC Restart path it is harmless if capture is already running:** `onTransportConnected` never stops capture, and `startCapture` returns early while capturing [I, SC:306ff per the inventory]. The deferral line can then print while capture continues. `_mediaReady` is reset only when a new DTLS connection is accepted (mW: `establishMediaConnection` ~mW:900), so at the restart it may read the old value [I]. | As quoted | [C] / [I] |
| **FF20 / K3** viewport report on `usbTransport`, no retry; `_viewportReceived` never reset | **Still present** | iS:1043 is the single call → `sendViewportReport` iS:491-499 → `sendInputEventToMac` → iS:1436-1446 (USB first by flag). iU:550-551 `guard let connection = inputConnection else { return }` (silent); send error at iU:560 is os_log only. Mac: `_viewportReceived = YES` only at mS:3124, and no writer sets NO (grep). | iPad NO LOG; Mac deferral lines mS:1227 / 1256 | [C] |
| **FF21** handshake dropped | **Still present** | mS:2096-2102 has no else (silent). In the degraded wireless state (`isConnected` YES, `_inputConnection` nil), mW `sendInputEvent` logs `sendInputEvent: no input connection (len=%zu)` (os_log_error) and returns. | NO LOG (no transport); the degraded case logs | [C] |
| **FF25** USB in-flight counter skew | **Still present: negative branch only** | Reset `_tcpMediaSendsInFlight = 0` at mS:1198. Completions at mS:1663-1672 and 2069-2078 carry no generation and no clamp. The gate is `inFlight < 2` (mS:1404-1405). Per the SDK header (§4) every completion fires exactly once, so the "never arrive → stuck at 2" branch is ruled out [C]. Old-connection completions that land after the FE9 reset drive the count negative → the gate over-admits [I]. In the 01:34:21 run the USB completion count shows no negative values [C, log]. | `USB split-send completion: seq=%u success=%{public}s inFlightNow=%d` (failures, and when left < 2) | [C] / [I] |
| **FF28** mixed-codec interleave after wireless→USB | **Still present** | WIRED_APPEARED from WIFI/AWDL → DISCONNECT_CURRENT is a no-op (mS:1101), so the wireless connection stays up. The HEVC encoder stops (mS:1113) and VT-flushed frames are dropped (HE:200; guard HE:584). Frames already in the wireless socket still arrive. On the iPad only LZ4-over-wireless is dropped (iS:1123); HEVC goes to UR (iS:1135-1138) → decode → hand-off → renderer, with no codec or route identity. HEVC arriving after USB is up is not acked (iS:1130). Whether these frames actually arrive after the first LZ4 frame depends on drain time versus the measured 185-293 ms window [I]. | NO LOG | [C] / [I] |
| **FF29** USB TCP reconnect without an interface event while STREAMING on wireless | **Still present** | FE1 first branch (mS:831-832) only calls `handleTransportEvent(WIRED_APPEARED)`. That gives FSM → USB_NCM + SWITCH_ENCODE_LZ4 (FSM:50-55). Afterwards `_transportState == USB_NCM`, so the new LC Restart condition (mS:1060-1062, WIFI/AWDL only) is false, and STREAMING is not CONNECTING/RECONNECTING (mS:1069). Result: no `onTransportConnected`, no handshake, no `requestLZ4Keyframe`, no `_tcpMediaSendsInFlight` reset. | Only `Transport event: ...` / `Transitioned to: ...` / `Switching to LZ4 mode ...` | [C] |

### FF17 / K4 after the fix: what still leaves the gate stuck

The gate is cumulative. `handleWiFiFrameAck` mS:2666ff accepts any `1 <= ack-lastAcked <= lastSent-lastAcked`, so one lost frame in the middle is covered by any later ack [C]. A stuck gate therefore needs `_wifiAckActive`, unacked ≥ 5, and **no later frame acked**.

| Path | Status | Evidence |
|---|---|---|
| Takeover (new READY) while STREAMING, label WIFI/AWDL | **Fixed** | Every READY → mW:764 → mS:896 → `handleTransportEvent` → LC Restart → FE9 → `wifiAckResetWithReason("transport-connected")` (mS:1208) and a generation bump (mS:1207) [C]. |
| **Takeover while STREAMING on wireless under the USB_NCM label** | **Still open** | FSM USB_NCM + WIFI/AWDL_AVAILABLE is a no-op (FSM:76-89 `default: noop`), so the label stays USB_NCM and the LC Restart condition fails (mS:1060-1061). The state is reachable: old-build log pid 61916, 01:35:56: `Transport event: AWDLAvailable (current state: USB-NCM)`, then `transport=USB-NCM usbConnected=0 wifiConnected=1`. Its HEVC encoder starts via FE30 → `_startEncoderAtViewportResolution` (not USB), so the wireless ack gate is in use (mS:1444-1505) [C]. A takeover there gets no handshake and no ack reset, which is K4 as before [C+I]. (Pre-encode holds stop encoding while there is no ready connection, but the old connection's unacked frames stay counted after the new READY.) |
| Encoder restart FE31 (`_startEncoderAtViewportResolution` mS:3190) or eco FE33 (mS:3405-3430) with no ack reset | **Not a stuck path by itself** | HE `_seq` is not reset (HE:67 only). Frames inside VT at stop are dropped before `_seq++` (guard HE:584 precedes HE:697), so there is no seq gap. Frames already sent are still delivered and acked [C+I]. |
| Send fails after `noteSent`, immediate | **Fixed** | `submitted == NO` → un-note (mS:1986-1992) [C]. |
| Send fails after `noteSent`, asynchronous (completion error) | **Not stuck by itself** | A TCP send error means the connection ends. mW end → `clearCurrent` → `_inputReady = false` → `LC MacEncodeHold`. A new READY → LC Restart → reset [C/I]. If no new connection becomes current: either the control-recovery hard deadline (6 s, mW `kControlRecoveryHardDeadlineNs`) → `onConnectionChanged(NO)` (mW:1239) → DISCONNECTED → reconnect, or the gate holds until then [I]. |
| USB→wireless immediate fallback | **Reset happens** | FE2 → DISCONNECTED → mS:1041-1050 adopts the epoch → AWDL/WIFI_AVAILABLE from DISCONNECTED → SWITCH_ENCODE_HEVC (FSM:132-143) → `switchToHEVCMode` → `wifiAckResetWithReason("hevc-mode")` (mS:1139) [C]. `_wifiTCPSendGeneration` is not bumped and `_wifiTCPMediaSendsInFlight` is not zeroed on this path [C]. |
| Wireless→USB | **N/A** | The gate applies only when `wireless && !usb` (mS:1444-1445) [C]. |
| FF18 while active | **Still open** (narrow) | The iPad stops acking (its `usb.isConnected` is true) while the Mac still sends HEVC on wireless with the gate active [I; the window is the iPad-USB-READY vs Mac-USB-READY skew, or the FF29 label case]. |
| Old-connection acks | Benign | FE29 has no connection check. After a reset, `hasSent = NO` → the ack is counted stale (mS:2678ff) [C]. |

---

## 2. Ordering: handshake versus the first frame of a new stream (same connection)

**Mechanism [C].** Every send function calls `nw_connection_send` directly on the caller's thread. None of them hops to the transport queue:
- mU `sendInputEvent` mU:535-566 (caller S);
- mU `sendMediaFrameWithHeader` mU:777-905 and `sendMediaViaTCP` mU:618ff (caller KQ for LZ4, VT for HEVC);
- mW `sendInputEvent` (~mW:617-650, caller S);
- mW `sendMediaFrameViaTCP` mW:575-611 (caller VT/KQ).

All use `NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT`, `is_complete=true`.

The SDK header says TCP "will only start processing a new context once the prior context has been marked complete", and that ordering properties "take effect when enqueuing data into the stream's send buffer" (connection.h:540-560). With no priority or antecedent set, wire order is **the order of the `nw_connection_send` calls** [I: FIFO enqueue across threads is implied, not stated]. **No lock, queue or barrier orders a call on S against a call on KQ or VT.** The only orderings are:
1. Program order on S.
2. Causality through `dispatch_async(ZQ)`. ZQ is serial; it reaches KQ by `dispatch_sync` (SC:1450); `_lz4CompressPending` caps it at one queued compress (SC:1411-1416).
3. CQ reading encoder state that S wrote (an unsynchronized read).

On the iPad, each transport delivers messages in arrival order, synchronously on one queue (IUT drain → `handleInputReceived`). Processing order equals wire order per connection [C, inventory IE1/IE3].

### 2a. USB, FE1 (USB TCP input ready), step by step

| # | Queue | Step | Line |
|---|---|---|---|
| 1 | UT | New connection accepted. The old one is cancelled; `inputConnection = new` **at accept** (TLS pending). | mU:1043-1046 |
| 2 | UT | READY → `isConnected = YES` **on UT**, then `onInputConnectionReady()`. | mU:1054-1058 |
| 3 | UT→S | `onSession("usb-input-ready")` = `dispatch_async(S)` | mS:828, 962-970 |
| — | KQ | **Race window A:** from step 2, `shouldCompressFrame` (mS:1399) sees USB connected. If LZ4 delivery is installed (`onPixelBuffer == nil`) and capture is running, ZQ→KQ can compress a **delta** and send it on the new connection **before the handshake** [C code; not observed in the two logged replugs]. | |
| 4 | S | If `_transportState != USB_NCM`: WIRED_APPEARED only. No handshake, no keyframe. This is FF29. | mS:831-832 |
| 5 | S | Else (`USB NCM TCP input ready — sending handshake (hevcActive=%d eco=%d)`): if HEVC is active, `RouteResync: USB input ready with HEVC active -> LZ4`, and `switchToLZ4Mode` (geometry update **before** the handshake, mS:1126). | mS:834-844 |
| 6 | S | `requestLZ4Keyframe` = `dispatch_async(ZQ, force_keyframe = 1)`. Log: `LZ4 keyframe requested (initialized=%d)`. | mS:847; SC:246-253 |
| 7 | S | `onTransportConnected`: counter and gate resets, `LC Restart session=%u ...`, `transitionTo STREAMING`, then `sendSessionHandshake` → `nw_connection_send` on S (`Sent session handshake: %ux%u @%.1fx, aspect=%.4f`). | mS:1190-1217, 1344-1380 |
| 8 | ZQ→KQ | The request block runs **after** any compress block already queued in ZQ. That queued block yields an un-forced **delta**. The next admitted capture is compressed as the keyframe (`LZ4 forced keyframe seq=%u (connect)` FC:288), and `onFrame` → send on KQ. | SC:1411-1468; FC:284-290 |
| — | | **Race window B:** step 8's keyframe send versus step 7's handshake send. Nothing orders them. The keyframe needs a new capture tick (≥ 0-8 ms at 120 Hz) plus an 8-stripe compress of about 3-8 ms. The handshake is a few S-side calls away. **Usually the handshake comes first [I], but it is not guaranteed.** | |
| 9 | iPad IUT | Handshake → zero-reference decompressor sized to **display** dims (iS:1014-1022) → viewport report. | |
| 10 | | Any LZ4 frame between the handshake and the FE30 geometry update fails `striped_decode` rc=-6 (size), see FF10. **So even a correctly ordered FE1 keyframe is lost when display dims ≠ viewport dims [C].** | |

**Can a frame compressed before the handshake be sent after it?**
- Yes: the delta already queued in ZQ ahead of the request block (step 8) [C]. Observed in the old build, pid 60821, 01:34:21: handshake `.993`, `USB split-send queued: seq=1869` `.994` (a delta), `LZ4 keyframe requested` `.995`, `LZ4 forced keyframe seq=1870` `22.003` [C, log].
- On the iPad it lands after the handshake. It decodes against the zero reference, or (when dims differ) fails rc=-6.

**Can the forced keyframe be sent before the handshake?** Yes. That is window B [C: nothing orders it; I: unlikely]. Not observed in either logged replug.
- 01:34:21: handshake `.993`, forced keyframe `22.003`.
- 01:51:35: handshake `.420`, forced keyframe `.429`, queued `.433`.

### 2b. Viewport report → FE30

| # | Queue | Step | Line |
|---|---|---|---|
| 1 | UT→S | VIEWPORT_REPORT goes through the S lane (not realtime). | mS:258-270, 2891-2892 |
| 2 | S | `!hevc && usb.isConnected` → `sendGeometryUpdate` (`nw_connection_send` on S) **then** `updateCaptureResolution` and `requestLZ4Keyframe` if capturing (log `LZ4 viewport: capture running at %ux%u -> reconfiguring to %ux%u`). | mS:3150-3171 |
| 3 | ZQ→KQ | The keyframe compress is causally after the geometry send. **Geometry-before-keyframe is ordered [C]:** S's send call → S's `dispatch_async(ZQ)` → ZQ → KQ send. | |

`force_keyframe` is a flag, so FE1's and FE30's requests **coalesce** when FE1's has not yet been consumed. The single resulting keyframe is still after the FE30 geometry send [C]. Observed (old build, pid 69250, 01:51:35):
- requested `.420` (FE1) and `.423` (FE30);
- one `LZ4 forced keyframe seq=16326` at `.429`;
- that frame was the first USB send (`.433`), after the handshake (`.420`) and the geometry update (`.423`) [C, log].

**FE30 therefore always yields one keyframe that arrives after the right geometry.** That holds if all of the following are true [C+I]:
- (a) the viewport reaches the Mac (FF20);
- (b) `_capture.isCapturing`;
- (c) the keyframe's capture is not dropped in `onFrame` (FF1);
- (d) a capture frame arrives at all (§3).

### 2c. HEVC (LC Restart or first wireless session)

| # | Queue | Step | Line |
|---|---|---|---|
| 1 | WT | READY → `_inputConnection = new`, `_inputReady = true`, epoch++ → `onConnectionChanged(YES)` → `dispatch_async(S)` | mW:703-765 |
| — | VT | **Window C:** until S restarts the encoder, the *old* encoder's frames pass the pre-encode hold (it sees the new ready connection) and are sent on the **new** connection **before the handshake**. Gate accounting still uses the old counts. Witness: iPad `[CONSOLE] LC IpadFrame ... (frame before handshake, HEVC/TCP)` (iS:934, printed only if the iPad state is connecting/reconnecting). | mS:1495, 1916-1920 |
| 2 | S | `onTransportConnected` → handshake `nw_connection_send` on S (mS:1217) → `_startEncoderAtViewportResolution` (mS:1225, only if `!usb && _viewportReceived`) → HE `start` stops the old session (`_onEncodedFrame = nil`, `CompleteFrames`, HE:83-86, 192-208), creates the new one, `isActive = YES` (HE:186) → `configureFrameDelivery` installs `onEncodedFrame` (mS:3260 → 1580). | |
| 3 | CQ→VT | The first encode on the new session is submitted after step 2's start, so its send is causally after the handshake send. **Handshake-before-IDR is ordered by S program order**, with the cross-thread visibility of `_session` assumed [I]. | |
| — | VT | **Window D [I]:** between HE `start` (`isActive = YES`, `onEncodedFrame` nil) and `configureFrameDelivery`, a CQ capture can be encoded into the new session. If its VT callback fires before the block is installed, it is dropped silently at HE:584 with no seq consumed. If that frame was the new session's IDR, the following P-frames reference an IDR the iPad never saw. There is no seq gap, so UR does not recover. HD decode errors go to FF15: no keyframe request; the 300 s IDR is the only escape. Narrow window (encode latency usually exceeds the S-side gap). | — |
| — | VT | **Window E [I]:** an old-session callback that passed the HE:584 guard just before `stop` nils the block can still send after the handshake. The same race could call a nil block (HE:584 reads it, HE:702 calls it). | — |

The iPad reassembler is not reset on a handshake [C, inventory]. The new IDR with a continuing seq is either in order or a forward gap → keyframe fast-forward (UR:418) [I].

---

## 3. Capture on a static screen

| Item | Finding | Tag |
|---|---|---|
| SCStream non-complete buffers | `_handleCapturedSampleBuffer` SC:1325-1355 reads `SCStreamFrameInfoStatus`; anything other than `SCFrameStatusComplete` → `return`. That covers idle, blank, suspended **and `started`**. Log: `Skipping non-complete frame (status=%lld, idle_count=%d)`, `os_log_info`, **first 3 only for the process lifetime**. Not visible in a default `log stream`, effectively NO LOG. | [C] |
| Apple docs (apple-docs MCP; `scripts/xcode-docs.sh` failed: "This agent isn't approved to use Xcode's tools yet") | `SCFrameStatus.idle`: "the system didn't generate a new frame because the display didn't change". `.started`: "the frame is the first one sent after the stream starts". `.complete`: "successfully generated a new frame". | [C docs] |
| Does any frame reach the compressor or encoder on a static screen? | **No.** Only complete frames pass, and SCK sends idle, not complete, when nothing changed (docs). So a forced LZ4 keyframe (flag waits in `force_keyframe`), an HEVC `requestKeyframe` (flag waits in `_forceNextKeyframe`), an encoder-restart IDR, and the periodic keyframes (LZ4 every 600 frames, FC:25, frame-count based; HEVC 300 s, HE:171) are **all emitted only at the next content change**. | [C+I] |
| `.started` frame skipped | Whether it carries a pixel buffer, and whether SCK sends a complete frame right after start or after `updateConfiguration` on an unchanged screen, is **[U]**. If not, a fresh capture on a static screen sends nothing until something changes. *Resolve:* log status plus `CMSampleBufferGetImageBuffer != NULL` per buffer for the first second after start. (`showsCursor` in the stream config would affect what counts as a change; not checked.) | [U] |
| Watchdog | No complete frames for > 2 s on an awake display → `Watchdog: no frames for %.1fs, display awake — re-authorization may be needed` (SC:1505-1509, once until frames resume). `onReauthorizationNeeded` has no setter outside SC (grep), so it is log-only and fires on any static screen. | [C] |
| Synthetic source (E2E) | A `dispatch_source` timer on CQ (SC:1201-1295) ticks at `captureFPS` (read once at start), emitting 1-3 frames per tick. `_emitSyntheticFrameAtIndex` (SC:1100-1162) builds a sample buffer with **no `SCStreamFrameInfo` attachment**, so the status check (`CFDictionaryGetValueIfPresent`, SC:1340) is skipped and **every tick is processed regardless of content**. Video input loops (reader reset, SC:822-832); stress mode is procedural per frame. **The E2E harness never exercises the static-screen case.** | [C] |
| LZ4 identical frames | `compress_frame` never skips an identical frame ("Zero-frame skip disabled", FC:343); there is no `return 1`. Every admitted capture yields output. | [C] |

---

## 4. U-Q3: `nw_connection_send` completions

`scripts/xcode-docs.sh "nw_connection_send completion cancelled"` was not run successfully: the same script failed for item 3 ("not approved"). The apple-docs MCP page has no discussion. **The SDK header resolves it** (`MacOSX27.2.sdk/.../Network.framework/Headers/connection.h`):
- :436 "A send completion is invoked exactly once for a call to nw_connection_send()."
- :443-444 "An error will be sent for any outstanding sends when the connection is cancelled."
- :281 (`nw_connection_cancel`) "Outstanding sends and receives will receive errors before the state changes to cancelled."

**[C]** Completions always fire. On cancel they fire with an error, before the cancelled state.

Peer death without a local cancel is covered by "exactly once" plus "error if the content could not be fully sent" (:441-442) [C]. *Timing* after peer death, before the local stack notices, is not stated [U; resolve by logging completion times after a cable pull].

Consequences:
- FF25's "never arrive" branch is ruled out.
- Negative skew after the FE9 reset remains [I].
- Wireless completions are generation-guarded (mS:1928-1946), so not affected.

---

## 5. U-Q4 (K1): logs

| Log | What it holds |
|---|---|
| `/tmp/keyd-run-mac-oslog.log` (112 MB, 01:33-02:40) | Old builds, no `LC` lines. **Two replugs while STREAMING on AWDL with full Mac lines:** pid 60821 at 01:34:21 and pid 69250 at 01:51:35 (sequences quoted in §2a/2b). One USB reconnect after AWDL loss (pid 61916, 01:41:43; forced keyframe `seq=0`, a fresh compressor). Pid 65617 at 01:43:58 is a K2 case (`hevcActive=1, usbConnected=1`) followed by a disconnect. |
| `/tmp/keyd-run-ipad.log` | One session only (the last launch, an AWDL pairing): one `Session handshake complete`, **zero** `LZ4 striped: decoded` lines, no USB interface lines. |
| `/tmp/keyd-e2e-{mac,ipad}.log` | At first read: Wi-Fi run, 0 forced keyframes, 2 iPad handshakes, 0 LZ4 decodes. They were removed during this audit. |
| `.planning/**/*.log` | None. |
| `/tmp/keyd*` dirs | No other file contains `LZ4 striped: decoded` or `LZ4 forced keyframe`. |

**What can be determined [C]**
- Mac-side order, at ms resolution and in old builds: READY → handshake send → keyframe request (same ms) → viewport report (+2 to +4 ms) → forced keyframe (+9 to +10 ms).
- The forced keyframe was compressed after the handshake send in both replugs.
- At 01:34:21 a delta (seq 1869) was queued after the handshake and before keyframe 1870.
- At 01:51:35 FE1's and FE30's requests coalesced into one keyframe, so **FE1's and FE30's keyframes cannot be told apart** there.
- The 01:34:21 build lacked the FE30 keyframe branch (it logged `LZ4 mode (USB) — setting capture to viewport ... then starting capture` and no `LZ4 viewport: capture running`).

**What cannot be determined [U]**
- iPad-side arrival order (no iPad log of a replug exists, and iPad lines have no timestamps);
- whether the iPad decoded the keyframe or failed it with rc=-6;
- what the user saw.

*Resolve:* one replug with `ipad-debug.sh` capture, correlating these iPad lines by arrival order in the single IUT stream:
- `LC IpadHandshake`;
- `Geometry update: ...`;
- `LZ4 striped: decoded seq=... key=true` / `decode FAILED rc=-6`.

Seq numbers tie them to the Mac `LZ4 forced keyframe seq=%u`.

---

## 6. Which connection the iPad keyframe request and acks use

| Message | Route decision | Lines | Tag |
|---|---|---|---|
| FRAME_ACK | Condition by **global flags**: `isHEVC && chunkTotal<=1 && wirelessTransport.isConnected && !usbTransport.isConnected` (iS:1129-1131). It does **not** use `fromWireless`, the arrival link. Sent with `wirelessTransport.sendInputEvent` always (iS:1397-1407) → iW `sendInputEvent` iW:511-524 on whatever `inputConnection` is now. Silent `guard` on nil; errors are os_log only (`Wireless input send error`). The iPad assigns `inputConnection` at **dial** (iW:~570-571, before READY), so an ack for a frame from the old connection can be queued on a not-yet-ready replacement (`nw_connection_send` queues until ready). | iS:1129-1131, 1397-1407; iW:511-524, ~570 | [C] / [I] |
| REQUEST_KEYFRAME | Guard `wireless.isConnected && !usb.isConnected` (iS:1410), global flags, else silent. Sent with `sendInputEventToMac` → `sendInputEventReturningLink` (iS:1436-1446): USB first, else wireless. Given the guard, that is effectively wireless. Runs on main (iS:507-512); not tied to the link the lost frames came on. | iS:1409-1446 | [C] |
| VIEWPORT_REPORT | `sendInputEventToMac`: USB first by flag, else wireless. Not the handshake's link. | iS:491-499, 1043, 1436-1446 | [C] |
| Mac receive | FRAME_ACK on either transport's realtime lane (`routeInputFromTransport` mS:973-981), with no connection check. REQUEST_KEYFRAME and VIEWPORT_REPORT take the S lane. | mS:258-270, 973-993 | [C] |

---

## Aside (out of scope, found while reading)

**Eco OFF over USB does not return to LZ4.** It calls `_startEncoderAtViewportResolution` (mS:3420-3424), which runs HEVC at 100 Mbps over USB. The return to LZ4 happens only via FSM or RouteResync [C].
