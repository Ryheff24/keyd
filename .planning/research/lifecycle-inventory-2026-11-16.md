# keyd-rd connection and session lifecycle inventory (2026-11-16)

Factual basis for the end-to-end TLA+ lifecycle model. Read-only survey of the source as of `main` @ 5e0007b plus uncommitted tree.

**Tags.** [C] = read in source at the cited line. [I] = inferred (from code reading across sites, or from a run log; log-derived claims are always [I] because `/tmp` logs are overwritten). [U] = unknown, with what would resolve it.

**Paths.** All paths are relative to `RemoteDesktop/`. Short prefixes used in tables:

| Prefix | File |
|---|---|
| `mW` | `macOS/Transport/WirelessTransport.m` |
| `mU` | `macOS/Transport/USBNetworkTransport.m` |
| `mS` | `macOS/App/SessionManager.m` |
| `mF` | `macOS/Transport/TransportFSM.c` |
| `mP` | `macOS/Pairing/PairingManager.m` |
| `mA` | `macOS/App/AppDelegate.m` |
| `mJ` | `macOS/App/InputInjector.m` |
| `iS` | `iPadOS/App/SessionManager.swift` |
| `iW` | `iPadOS/Transport/WirelessTransport.swift` |
| `iU` | `iPadOS/Transport/USBNetworkTransport.swift` |
| `iF` | `iPadOS/Transport/TransportFSM.swift` |
| `iQ` | `iPadOS/Pairing/QRPairing.swift` |
| `iA` | `iPadOS/App/RemoteDesktopApp.swift` |
| `iI` | `iPadOS/App/InputSender.swift` |

**Queues.** Mac: `T` = wireless `transportQueue`; `UM` = USB `monitorQueue`; `UT` = USB `transportQueue`; `S` = session queue `com.ryheff.keyd.remote.agent.session`, a serial queue with no target set (mS:511-512) [C]; `M` = main; `J` = injector queue. iPad: `M` = main; `IT` = wireless `transportQueue`; `IUM` / `IUT` = USB monitor / transport queues.

**Log convention.** A quoted string in sections 2 and 5 is the full, exact format string at the cited line (Swift strings are copied raw, interpolations included). `…` appears only in the run-log excerpts in section 4.1, which quote emitted log text, not format strings. On the iPad, only `print("[CONSOLE] …")` reaches the devicectl capture; a handler whose only log is `Logger` (`log.info` / `Self.log` / `appLog`) is written **LOGGER ONLY** and counts as NO LOG for capture purposes (CLAUDE.md) [C].

---

## 1. State variables

### 1.1 Mac

| Name | Decl | Type / values | Writers (file:line, queue) | Decision readers |
|---|---|---|---|---|
| `sessionState` | mS:313 | enum `SESSION_AWAITING_PERMISSIONS, AWAITING_PAIRING, CONNECTING, STREAMING, RECONNECTING, STOPPED` (`SessionManager.h:16-22`) | init mS:493 = STOPPED (M). Every other write is `transitionTo` (mS:3657). Call sites [C]: mS:546 → AWAITING_PERMISSIONS (start, M); mS:595 → STOPPED (stop, M); mS:662 → STOPPED (failClosedNoIdentity, M); mS:682 → AWAITING_PAIRING (test mode), mS:687 → CONNECTING, mS:691 → AWAITING_PAIRING (onPermissionsGranted, M); mS:734 → CONNECTING (onPairingComplete block, M); mS:813 → AWAITING_PAIRING (resetPairing, M, **with transports still up**); mS:1197 → STREAMING (onTransportConnected, S); mS:3587 → RECONNECTING (startReconnection, S). No path leads from STREAMING back to CONNECTING [C] | handleTransportEvent fallback mS:1040 and gate mS:1053; reconnect timer block mS:3632; mediaChannelReady; delayed advertising mS:941 [C] |
| `transportState` | mS:314 | `TRANSPORT_IDLE, USB_NCM, WIFI, AWDL, DISCONNECTED` (`TransportFSM.h`) | mS:494 init; mS:1022 in handleTransportEvent (S) [C] | mS:1040, mS:1053, usb-input-ready mS:824-850 [C] |
| `awaitingMedia` | mS:330 | BOOL | mS:858 (usb lost, S), mS:898 (wireless down, S), mS:1000 (media ready, S), mS:1182 / mS:1224 (onTransportConnected, S) [C] | mediaChannelReadyOnSession mS:996 [C] |
| `viewportReceived` (`_viewportReceived`) | mS:355 | BOOL | mS:3078 = YES only. **Never reset** [C: single writer] | onTransportConnected mS:1176-1210 (start encoder or defer); handleViewportReport "redundant HEVC restart" skip mS:3096 [C] |
| `reconnectAttempt` | mS:337 | int 0..5 (`kReconnectMaxAttempts` mS:54) | mS:497 init, mS:1059 (=0), mS:3612 (=0), mS:3633 (++) [C] | scheduleReconnect mS:3617 [C] |
| `reconnectTimer` | mS:338 | NSTimer | mS:3626 (created on S), mS:1061 (nil), mS:569 (stop) [C] | none (fire only) |
| `tcpMediaSendsInFlight` (USB) | mS:369 | volatile int32 | mS:1183 (=0, S); ++ mS:1618 / mS:2018; -- in completions mS:1638 / mS:2038 (UT completion) [C]. No generation check in completions [C] | frame delivery gate mS:1387 [C] |
| `wifiTCPMediaSendsInFlight` | mS:370 | int32 | mS:1184 (=0), mS:1876 (++), mS:1924 (--) [C] | Wi-Fi pre-encode gate before first ack mS:1476 [C] |
| `wifiTCPSendGeneration` | mS:392 | uint | mS:1192 (+=1 in onTransportConnected) [C] | Wi-Fi completion check mS:1899-1919 [C] |
| `_wifiAckActive`, `_wifiAckHasSent`, `_wifiAckLastSentSeq`, `_wifiAckLastAckedSeq` | mS:443-464 | lock-protected; `unacked = (uint16)(lastSent - lastAcked)` or -1 if not active or nothing sent (mS:2584-2590) | reset mS:2573-2575 (`wifiAckResetWithReason`, only callers mS:1124 "hevc-mode" and mS:1193 "transport-connected"); sent mS:2604-2607 (`wifiAckNoteSentSeq`, frame path); ack mS:2641-2642 (handleWiFiFrameAck, T) [C] | gate `unacked >= kWiFiAckGateFrames (5)` mS:1475-1477; there is no time-based escape (comment mS:1472 "No stall reset (tla/WiFiSendLoop.tla NoBlindReset)") [C] |
| `compressorState` / `isEcoMode` / `resolutionChanged` | mS:333 / 344 / 359 | various | mS:588, 1129 / 496, 1097, 3363, 3373 / 499, 3053, 3480, 3580 [C] | encoder and display-mode paths (not modelled) |
| `permissionTimer`, `latencyProbeTimer`, `wirelessPerformanceTimer` | mS:341 / 364 / 365 | NSTimer | mS:628 (M); mS:2774 (S, see flags); mS:2120 (M) [C] | — |
| mW `isConnected` | mW:80 (readonly in `WirelessTransport.h:25`) | BOOL | mW:723 YES (READY, T); mW:791 NO (TCP end, non-degraded, T); mW:1206 NO (recovery timeout, T); mW:1294 NO (silent link loss); mW:1327 (tearDown); mW:1380 (media path loss) [C]. **Not** cleared on the degraded path mW:776-788 [C] | mS:1040-1047 fallback; mS:1057 gate; delayed advertising mS:941; mW duplicate logic mW:653 [C] |
| mW `inputConnection` | mW:79 | nw_connection_t or nil | mW:664 (replace: cancel old), mW:675 (accept new), mW:775 (TCP end), mW:1288, mW:1321, mW:1372 [C] | `isActiveConnection` guards mW:685ff, receive guard mW:1055, heartbeat tick mW:1252ff, send paths mW:550 / mW:588 [C] |
| mW `mediaConnection` | mW:78 | nw_connection_t (DTLS) or nil | mW:872 (new conn, no identity check), mW:909 / mW:925 (end, guarded), mW:1026 (recv error), mW:1198 (recovery timeout), mW:1285, mW:1317 [C] | degrade decision mW:776 (`hasMediaPath`); media path loss [C] |
| mW `isAWDL` | mW:81 | BOOL | mW:722 (READY, by interface name `awdl`/`llw` prefix), mW:1207, mW:1295, mW:1328, mW:1381 [C] | mS:888-903 event choice; mS:1041 [C] |
| mW `_allowReconnectTakeover` | mW:65 | BOOL | YES: mW:432 (beginReconnectWindow), mW:1144 (beginControlPathRecovery). NO: mW:668, 724, 792, 1202, 1290, 1323, 1376 [C] | duplicate decision `shouldReplace` mW:640-660 [C] |
| mW `_mediaReady` | mW:73 | atomic bool | mW:871 false, mW:890 true, mW:908 / 924 / 1025 / 1197 / 1284 / 1316 false [C] | mediaChannelReadyOnSession `mediaReadyNow` mS:1004; onTransportConnected mS:1221 [C] |
| mW `_controlPathRecoveryStartedAtTicks` | mW:64 | ticks, 0 = inactive | mW:1142 set, mW:1135 cleared [C] | evaluator mW:1183 / 1217; media gap grace mW:997ff [C] |
| mW `_advertisingRequested`, `bonjourListener` | mW:66 / mW:76 | BOOL / nw_listener_t | mW:306 YES, mW:439 NO / mW:334, 364, 390, 445, 736 [C] | listener restart decisions mW:368-414 [C] |
| mW input tick counters | mW:61-63 | `_inputAcceptedAtTicks`, `_inputReadyAtTicks`, `_lastInputActivityTicks` | accept mW:675ff, READY mW:725ff, recv mW:1041ff, reset on end mW:776-778 [C] | staleness `staleByIdle/NoInput/PendingConnect` mW:640-655; heartbeat silence mW:1252ff [C] |
| mU `isConnected` | mU:133 (readonly in `USBNetworkTransport.h:25`) | BOOL | mU:1056 YES (READY, **no identity guard**), mU:1067 NO (guarded end), mU:1010 NO (media end with no input), mU:441 NO (interface gone, UM), mU:462 NO (stopMonitoring) [C] | mS:824ff, mS:1046, mS:1057, mS:2062 [C] |
| mU `inputConnection` | mU:131 | nw_connection_t | mU:1046 (newConnection: cancels old first), mU:1066 (guarded end), mU:1240 (`tearDownListeners`, called from `bindToLocalIP` mU:945ff) [C] | end-state guard mU:1065; sends mU:535 / 618 [C] |
| mU `mediaConnection` | mU:130 | nw_connection_t | mU:997, 1008, 1070, 1236 [C] | — |
| mU `detectedLocalIP` / `activeInterface` | mU:125-137 (property block) | string / name | poll handler mU:412ff (UM) [C] | poll change detection [C] |
| `isPaired` (mP) | mP:46-57 | from keychain item "pairing" | completePairing mP:984-1056; resetPairing mP:1060-1077 [C] | onPermissionsGranted mS:666-693 [C] |
| Peer pin | keychain "peer-cert-fingerprint" | SHA-256 | mP:984-1056 writes with `kSecUseDataProtectionKeychain:@YES` [C]; read by mW:197-209 / mU:228-240 **without** that flag [C] | TLS verify mW:155-195 [C] |

### 1.2 iPad

| Name | Decl | Type / values | Writers (file:line, queue) | Decision readers |
|---|---|---|---|---|
| `state` | iS:25 | `awaitingPairing, connecting, streaming, reconnecting, disconnected` (iS:16-22); `didSet` invalidates `connectingTimeoutTimer` when leaving `.connecting` (iS:32) and prints [C] | `.connecting` is written only at iS:198 (test auto-pair), iS:221 / iS:228 (start), iS:236 (onPairingComplete), iS:278 (resumeFromBackground), iS:402 (test hook) — all M. Other M writes: iS:290 (reconnecting), iS:342 (awaitingPairing), iS:379 (disconnected); iS:637 (handleTransportEvent, M); iS:829 / iS:934 (first frame → streaming, M); **iS:1070 (handleSessionHandshake, IT/IUT, off main)** [C] | connecting timeout iS:350ff; handleTransportEvent iS:606ff, iS:630ff; frame path [C] |
| `currentTransport` | iS:57 | iF states `idle, usbNCM, wifi, awdl, disconnected` | iS:340, 388, 401, 596 (M) [C] | handleTransportEvent [C] |
| `reconnectAttempt` | iS:110 | Int | iS:259, 279, 291, 304, 830, 935; timer iS:1479 block (+=1) [C] | delay calc iS:1470 [C] |
| `reconnectTimer` | iS:111 | Timer, one-shot | iS:1479 [C] | — |
| `connectingTimeoutTimer` | iS:114 | Timer 8 s | iS:352; invalidated iS:32 [C] | — |
| `framesAcked` | iS:106 | counter | sendFrameAck iS:1394ff [C] | logging only |
| iW `isConnected` / `isAWDL` | iW:83-84 | Bool | iW:594 / 593 (READY, IT); iW:632 / 655 / 661 (TCP failed/cancelled teardown); iW:1096-1097 (tearDown); iW:1231-1232 (recovery timeout); iW:1285-1286 (media loss); iW:1362-1363 (silent link) [C] | iS sendInputEventReturningLink iS:1433; connecting timeout iS:358; browse dedup iW:414ff [C] |
| iW `inputConnection` | iW:107 | NWConnection? | iW:553, 571 (connectToService), 620, 651, 1089, 1165 (watchdog), 1229, 1281, 1359 [C] | identity guards iW:574ff, 924ff, 1146ff, 1326ff [C] |
| iW `mediaConnection` | iW:106 | NWConnection? | iW:726, 749, 759, 1087, 1227, 1356 [C] | degrade decision iW:620ff [C] |
| iW `connectedServiceName` | iW:129 | String? latch | iW:458, 486, 631, 652, 1091, 1166, 1188, 1230, 1284, 1361 [C] | browse `.added` dedup / `.removed` latch iW:414-492 [C] |
| iW `avoidAWDL` / `nextDialAWDL` / `lastDialAWDL` | iW:147 / iW:149 (computed) / iW:147-152 | Bool | avoidAWDL iW:596, 634, 1161, 1238, 1292, 1364 [C] | TCP params iW:293-333 [C] |
| iW `browser` / `browsingRequested` | iW:97 / iW:100 | NWBrowser? / Bool | iW:382, 396, 405, 506, 1117 / iW:368, 500 [C] | browser restart iW:1102ff [C] |
| iW `controlRecoveryStartedAt` / `controlRecoveryWorkItem` | iW:104 / iW:103 | DispatchTime? / DispatchWorkItem? | iW:1181, 1186 / iW:1175, 1243 [C] | `.added` replacement allowance iW:430-445 [C] |
| iW `connectWatchdogWorkItem` | iW:102 | DispatchWorkItem? | iW:504, 549, 586, 617, 647, 1085, 1169, 1278, 1354 [C] | — |
| iU `isConnected` | iU:22 | Bool | iU:665, 784, 847 true (**READY, unguarded**); false at iU:438, 457, 523, 639, 643, 675, 742, 883 [C] | iS:1433; connecting timeout iS:358; retry skip iU:541 [C] |
| iU `inputConnection` / `mediaConnection` | iU:49 / iU:48 | NWConnection? | input iU:658, 674, 772, 799, 839, 878, 1082; media iU:627, 638, 642, 728, 741, 880, 1080 [C] | guards on failed only (iU:667, 787, 849) [C] |
| iU `detectedLocalIP` / `detectedMacIP` / `detectedMacLinkLocalIP` | iU:37 / iU:38 / iU:39 | String? | iU:413, 436, 455 / 574, 578, 582 / 573, 595 [C] | poll iU:406ff; `.waiting` retry iU:795 [C] |
| iU `usbBrowser` / `usbConnectRetryPending` | iU:42 / iU:43 | | iU:481, 490 / 531, 535 [C] | retry iU:529ff [C] |
| `isPaired` (iQ) | iQ:131-133 | computed from keychain "pairing" | iQ resetPairing iQ:1096-1107; pairing completion paths [C] | start iS:174ff [C] |

---

## 2. Events and handlers

Row key for scripts: column 3 is always `` `prefix:line` ``, the registration or entry line.

### 2.1 Mac

| ID | Trigger | Where | Queue | Guard checked first | State writes | Sends | Triggers | Log |
|---|---|---|---|---|---|---|---|---|
| M01 | Bonjour listener state change | `mW:349` | T | `isActiveListener` (`_bonjourListener == listener`) [C] | failed: bonjourListener=nil (mW:364); cancelled: (mW:390) | — | M02 / M03 | `"TLS Bonjour listener ready (advertising %{public}s)"` mW:356; `"TLS Bonjour listener failed: %{public}@ (active=%{public}d isConnected=%{public}d inputConnection=%{public}p)"` mW:359; `"TLS Bonjour listener cancelled (active=%{public}d isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)"` mW:386 |
| M02 | listener-failed restart, `dispatch_after` 0.5 s | `mW:368` | T | re-checks listener, `advertisingRequested`, `isConnected` [C] | — | — | startAdvertising | `"Bonjour listener restart skipped (listener=%{public}p isConnected=%{public}d advertisingRequested=%{public}d)"` mW:373; `"Bonjour listener failure recovery skipped (advertisingRequested=%{public}d isConnected=%{public}d)"` mW:379 |
| M03 | listener-cancelled restart, `dispatch_after` 0.25 s | `mW:394` | T | same re-checks [C] | — | — | startAdvertising | `"Cancelled-listener restart skipped (listener=%{public}p isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)"` mW:399; `"Bonjour listener cancel treated as expected (isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)"` mW:405 |
| M04 | new wireless TCP connection (newConnectionHandler → `handleNewConnection` mW:621) | `mW:416` | T | if `_inputConnection != nil`: duplicate decision `shouldReplace = _allowReconnectTakeover \|\| staleByIdle \|\| staleByNoInput \|\| stalePendingConnect` [C] | replace: cancels old, `inputConnection`=new (mW:664), ticks reset, `_allowReconnectTakeover`=NO (mW:668); **does not touch `isConnected`, `mediaConnection`, heartbeat** [C]. Else ignore + cancel new. No dup: `inputConnection`=new (mW:675) | — | M05 / M06 on the new conn | `"TLS wireless connection accepted from iPad PEER-ADDR=%{public}s port=%u"` mW:628; `"Duplicate wireless candidate: existing inputConnection=%{public}p isConnected=%{public}d isAWDL=%{public}d hasInputActivity=%{public}d idle=%.2fs age=%.2fs pendingAge=%.2fs allowReconnectTakeover=%{public}d staleByIdle=%{public}d staleByNoInput=%{public}d stalePendingConnect=%{public}d shouldReplace=%{public}d"` mW:653; `"Replacing stale wireless input connection (%{public}s)"` mW:662; `"Ignoring duplicate wireless candidate while an existing session is active"` mW:670; `"Accepted wireless candidate as current input connection (inputConnection=%{public}p isConnected=%{public}d)"` mW:677 |
| M05 | input TCP READY | `mW:685` | T | `isActiveConnection` (`inputConnection == connection`) [C] | `isAWDL` (mW:722), `isConnected`=YES (mW:723), `_allowReconnectTakeover`=NO (mW:724), ready/activity ticks; cancelControlPathRecovery "tcp-ready"; Bonjour listener suspended (mW:736) | heartbeat start | **`onConnectionChanged(YES, AWDL)` mW:743-745 → M33**; scheduleInputReceive; establishMediaConnection (M09-M11) | `"Ignoring READY from stale wireless connection (activeInput=%{public}p staleConnection=%{public}p isConnected=%{public}d)"` mW:694; `"Connection interface: %{public}s (type=%d)"` mW:709; `"TLS wireless connection ready (AWDL=%d)"` mW:728; `"Suspending Bonjour listener while wireless session is active (inputConnection=%{public}p)"` mW:732 |
| M06 | input TCP failed / cancelled | `mW:754` | T | **NONE before `onInputStreamEnded()` mW:756** (fires for stale conns too); then `isActiveConnection` [C] | `inputConnection`=nil (mW:775), ticks=0. If `mediaConnection != nil && isConnected` → degraded: **`isConnected` kept YES, no `onConnectionChanged`** (mW:776-788). Else `isConnected`=NO (mW:791), `_allowReconnectTakeover`=NO (mW:792) | — | M32 (injector); degraded → M14; else startAdvertising + `onConnectionChanged(NO)` → M33 | `"Ignoring end-state from stale wireless connection (state=%{public}d error=%{public}@ activeInput=%{public}p staleConnection=%{public}p isConnected=%{public}d)"` mW:758; `"TLS wireless connection ended (state=%{public}d error=%{public}@ wasAWDL=%{public}d)"` mW:765; `"Control path loss decision=degraded reason=tcp-state-ended-media-active state=%{public}d error=%{public}@ action=preserve-session-and-recover-control"` mW:781; `"Wireless connection ended without media; re-enabling Bonjour listener for reconnect discovery"` mW:795 |
| M07 | `beginReconnectWindow` (called by M41) | `mW:426` | hops to T | NONE | `_allowReconnectTakeover`=YES (mW:432) | — | — | `"Reconnect window armed: allowReconnectTakeover=1 inputConnection=%{public}p isConnected=%{public}d isAWDL=%{public}d"` mW:433 |
| M08 | `stopAdvertising` (called from mS stop, M) | `mW:438` | **caller's queue (no hop to T)** [C] | NONE | `_advertisingRequested`=NO (mW:439), `bonjourListener`=nil (mW:445); tearDownConnections (M19) | — | — | `"stopAdvertising: advertisingRequested=0 (listener=%{public}p isConnected=%{public}d inputConnection=%{public}p)"` mW:440 |
| M09 | DTLS media listener state | `mW:852` | T | NONE | — | — | — | `"DTLS media listener ready on port %{public}s"` mW:855; `"DTLS media listener failed: %{public}@"` mW:857 |
| M10 | DTLS media new connection | `mW:862` | T | **NONE** (cancels any current `_mediaConnection` without checking which session it belongs to) [C] | `_mediaReady`=false (mW:871), `mediaConnection`=new (mW:872) | — | M11 | `"DTLS media connection accepted from iPad"` mW:866 |
| M11 | DTLS media conn state | `mW:875` | T | `_mediaConnection == conn` [C] | ready: `_mediaReady`=true (mW:890); failed/cancelled: `mediaConnection`=nil (mW:909 / mW:925), `_mediaReady`=false | — | ready → resetSendPacing, scheduleMediaReceive, `onMediaChannelReady` → M34; end → M20 | `"DTLS wireless media UDP connection ready"` mW:886; `"DTLS wireless media connection failed: %{public}@"` mW:905; `"DTLS wireless media connection cancelled"` mW:922; stale variants mW:881 / 899 / 917 |
| M12 | media receive completion | `mW:939` | T | `_mediaConnection == connection` [C] | error outside grace → `mediaConnection`=nil (mW:1026) | — | M20 | `"Dropping stale media receive callback (activeMedia=%{public}p staleConnection=%{public}p is_complete=%{public}d error=%{public}@)"` mW:949; `"Media path loss decision=ignored reason=transient-dtls-recv-gap detail=%{public}@ controlPathHealthy=%{public}d controlRecoveryActive=%{public}d controlRecoveryElapsedMs=%{public}llums controlRecoveryGraceMs=%{public}llums inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums"` mW:997; `"DTLS media receive error on active connection: %{public}@"` mW:1022 |
| M13 | input receive completion | `mW:1041` | T | `_inputConnection == connection` [C] | `_lastInputActivityTicks`; heartbeat count | — | heartbeat byte consumed; else `onInputReceived` → M38; error/EOF → `nw_connection_cancel` → M06 | `"Dropping stale input receive callback (activeInput=%{public}p staleConnection=%{public}p is_complete=%{public}d error=%{public}@)"` mW:1055; `"Link heartbeat received count=%lu"` mW:1088; `"TCP input receive error on active connection: %{public}@"` mW:1102; `"Control path loss decision=degraded reason=tcp-eof-media-active action=cancel-input-and-preserve-session"` mW:1110; `"Control path loss decision=reconnect-triggered reason=tcp-eof-no-media action=cancel-input"` mW:1113 |
| M14 | `beginControlPathRecoveryForReason` | `mW:1138` | T | NONE [C] | `_controlPathRecoveryStartedAtTicks` (mW:1142), `_allowReconnectTakeover`=YES (mW:1144); restarts advertising | — | M15 | `"Control recovery: enabling Bonjour listener for control-path replacement discovery"` mW:1146; `"Control path loss decision=degraded reason=awaiting-control-replacement detail=%{public}@ elapsedMs=%{public}llums deadlineMs=%{public}llums"` mW:1176 |
| M15 | control recovery evaluator, `dispatch_after` (poll 0.75 s, deadline 6 s) | `mW:1183`, `mW:1217` | T | recovery still active (startedAt ≠ 0) [C] | recovered: cancel. Timeout: `_mediaReady`=false (mW:1197), `mediaConnection`=nil (mW:1198), `_allowReconnectTakeover`=NO (mW:1202), `isConnected`=NO (mW:1206), `isAWDL` (mW:1207) | — | timeout → `onConnectionChanged(NO)` → M33 | `"Control path loss decision=preserved reason=control-path-recovered action=continue-session"` mW:1166; `"Control path loss decision=reconnect-triggered reason=control-recovery-timeout trigger=%{public}s detail=%{public}@ elapsedMs=%{public}llums mediaActive=%{public}d"` mW:1190 |
| M16 | `cancelControlPathRecoveryWithReason` | `mW:1123` | T | NONE | startedAt=0 (mW:1135) | — | — | `"Control recovery cancelled reason=%{public}s elapsedMs=%{public}llums"` mW:1130 |
| M17 | link heartbeat timer (dispatch source) | `mW:1233` | T | tick mW:1252: `inputConnection == connection && isConnected && lastActivity != 0` [C] | — | 0x31 on input TCP (mW:1262) | silence ≥ 4 s → M18 | `"Link heartbeat started intervalMs=%llu deadlineMs=%llu"` mW:1240; `"Link heartbeat stopped reason=%{public}s sent=%lu received=%lu"` mW:1248; `"Link quiet silentMs=%llu deadlineMs=%llu AWDL=%d"` mW:1268 |
| M18 | `handleSilentLinkLossAfterNs` | `mW:1275` | T | NONE | `mediaConnection`=nil (1285), `inputConnection`=nil (1288), `_allowReconnectTakeover`=NO (1290), `isConnected`=NO (1294), `isAWDL` (1295) | — | `onConnectionChanged(NO)` → M33; startAdvertising | `"Link silent decision=lost silentMs=%llu deadlineMs=%llu AWDL=%d heartbeatsSent=%lu heartbeatsReceived=%lu action=drop-and-advertise"` mW:1277 |
| M19 | `tearDownConnections` | `mW:1306` | caller | NONE | clears input/media/flags mW:1316-1328 | — | — | NO LOG |
| M20 | `handleActiveMediaPathLossWithReason` | `mW:1331` | T | NONE | if control healthy: degrade (keep); else `inputConnection`=nil (1372), `_allowReconnectTakeover` (1376), `isConnected`=NO (1380), `isAWDL` (1381) | — | `onConnectionChanged(NO)` → M33; advertising | `"Media path loss observed: reason=%{public}s detail=%{public}@ hadInputConnection=%{public}d wasConnected=%{public}d advertisingRequested=%{public}d"` mW:1348; `"Media path loss decision=degraded reason=control-path-healthy detail=%{public}@ inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums action=preserve-session-no-reconnect"` mW:1356; `"Media path loss decision=ignored reason=no-active-session mediaReason=%{public}s"` mW:1365; `"Media path loss decision=reconnect-triggered reason=%{public}s wasAWDL=%{public}d inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums"` mW:1383 |
| M21 | `sendMediaFrameViaTCP` | `mW:547` | caller → T | `_inputConnection == nil` → `completion(NO)` [C] | — | media frame on TCP | completion → mS:1899-1919 | nil-connection branch: **NO LOG**; `"TCP media frame send error: %{public}@"` mW:577 |
| M22 | wireless `sendInputEvent` | `mW:585` | caller | nil connection [C] | — | message on TCP | — | `"sendInputEvent: no input connection (len=%zu)"` mW:588 |
| M23 | USB poll timer (500 ms dispatch source) | `mU:412` | UM | NONE | new IP: `bindToLocalIP` mU:945 → `tearDownListeners` mU:1225 (nils `inputConnection` mU:1240 and `mediaConnection` mU:1236, **does not clear `isConnected`**); gone: `isConnected`=NO (mU:441) | — | `onInterfaceChanged(YES/NO)` → M31 | `"USB NCM interface detected: %{public}@ = %{public}@"` mU:424; `"USB NCM interface disappeared"` mU:436; `"Binding TLS/DTLS listeners to USB NCM local IP: %{public}s"` mU:949 |
| M24 | USB `stopMonitoring` | `mU:453` | caller | NONE | `isConnected`=NO (mU:462) | — | — | NO LOG |
| M25 | USB media listener state | `mU:978` | UT | NONE | — | — | — | `"DTLS media listener ready on port %s"` mU:980; `"DTLS media listener failed: %{public}@"` mU:982 |
| M26 | USB media new connection | `mU:987` | UT | NONE (cancels old) | `mediaConnection`=new (mU:997) | — | M27 | `"DTLS media connection accepted from iPad"` mU:991 |
| M27 | USB media conn state | `mU:1003` | UT | end states only: `mediaConnection == connection` (log fires before the guard) [C] | `mediaConnection`=nil (mU:1008); `isConnected`=NO if no input (mU:1010) | — | — | `"DTLS media connection ended"` mU:1005 |
| M28 | USB input listener state | `mU:1028` | UT | NONE | — | — | — | `"TLS input listener ready on port %s"` mU:1030; `"TLS input listener failed: %{public}@"` mU:1032 |
| M29 | USB input new connection | `mU:1037` | UT | NONE (cancels and replaces existing) | `inputConnection`=new (mU:1046) | — | M30 | `"TLS input connection accepted from iPad (starting TLS handshake)"` mU:1041 |
| M30 | USB input conn state | `mU:1050` | UT | **READY: NONE** (mU:1054); end: `onInputStreamEnded` first, then `inputConnection == connection` [C] | READY: `isConnected`=YES (mU:1056). End (current): `inputConnection`=nil (1066), `isConnected`=NO (1067), media cancelled (1070) | — | READY → `onInputConnectionReady` → M30a; end → M32 then `onInputConnectionLost` → M30b | `"TLS input connection READY (TLS handshake complete)"` mU:1055; `"TLS input connection ended (state=%d error=%@)"` mU:1062; `"TLS input connection state=%d"` mU:1077 |
| M30a | usb `onInputConnectionReady` → S "usb-input-ready" | `mS:824` | S | if `transportState != USB_NCM` → WIRED_APPEARED (M35); else proceed **regardless of `sessionState`** [C] | HEVC→LZ4 switch; `requestLZ4Keyframe` | — | M36 `onTransportConnected` | `"USB NCM TCP input ready — sending handshake (hevcActive=%d eco=%d)"` mS:833; `"RouteResync: USB input ready with HEVC active -> LZ4"` mS:841 |
| M30b | usb `onInputConnectionLost` → S "usb-input-lost" | `mS:852` | S | NONE | `awaitingMedia`=NO (mS:858) | — | M35 with `TRANSPORT_EVT_DISCONNECTED` (mS:859) | NO LOG (event logged in M35) |
| M30c | USB receive loops (media + input) | `mU:1089` | UT | **NONE** (no identity check) [C] | — | — | input data → `onInputReceived` → M38. **EOF / error: return, no cancel, no loss event** [C] | `"Input framing error: invalid length prefix (buffered=%lu), dropping connection"` mU:1149; EOF/error: **NO LOG** |
| M31 | usb `onInterfaceChanged` → S "usb-if-up/down" | `mS:864` | S | NONE | — | — | M35 WIRED_APPEARED / WIRED_DISAPPEARED | NO LOG |
| M32 | `onInputStreamEnded` (both transports) → injector | `mS:877` | J | NONE | releases all held keys/buttons | synthetic key/button ups | — | `"Input connection ended (%{public}s): releasing all"` mJ:180 |
| M33 | wireless `onConnectionChanged` → S "connection-up/down" | `mS:888` | S | NONE | down: `awaitingMedia`=NO (mS:898) | — | M35 with AWDL_/WIFI_AVAILABLE or _UNAVAILABLE | NO LOG (event logged in M35) |
| M34 | wireless `onMediaChannelReady` → `mediaChannelReadyOnSession` | `mS:906` (body mS:996) | S | `awaitingMedia` [C] | `awaitingMedia`=NO (mS:1000) | — | start capture | `"Media channel ready -- starting capture now"` mS:1001; `"Media channel ready ignored (awaitingMedia=%{public}d mediaReadyNow=%{public}d wifiOnly=%{public}d)"` mS:1004 |
| M35 | `handleTransportEvent` | `mS:1009` | S | NONE (no check of which connection raised the event) | `transportState` (mS:1022) | WIRED_APPEARED → peer address update (0x25) | DISCONNECTED+STREAMING → immediate fallback (re-enters M35) or M41; **else only if `sessionState` ∈ {CONNECTING, RECONNECTING} and some `isConnected` → M36 (mS:1053-1064)**; in STREAMING: nothing, no log | `"Transport event: %{public}s (current state: %{public}s)"` mS:1010; `"Transitioned to: %{public}s (%d effects)"` mS:1024; `"Immediate wireless fallback — wireless still connected (AWDL=%d), switching directly"` mS:1042; `"Immediate USB fallback — USB still connected, switching directly"` mS:1047; `"Transport state changed but no active TCP connection yet — waiting"` mS:1063 |
| M36 | `onTransportConnected` | `mS:1175` | S | NONE | in-flight=0 (1183-1184), `awaitingMedia` (1182 / 1224), `wifiTCPSendGeneration`+=1 (1192), `wifiAckReset("transport-connected")` (1193), → STREAMING | session handshake (M37) | encoder start or defer; configureFrameDelivery; capture or defer; latency timer M46 | `"Transport connected -- sending handshake (state=%{public}s transport=%{public}s usbConnected=%{public}d wifiConnected=%{public}d viewportReceived=%{public}d viewport=%ux%u hevcActive=%{public}d)"` mS:1176; `"HEVC encoder deferred — waiting for iPad viewport report after handshake"` mS:1210; `"Capture deferred until media channel ready"` mS:1225 |
| M37 | `sendSessionHandshake` | `mS:1327` | S | NONE | — | SESSION_HANDSHAKE | — | `"Sent session handshake: %ux%u @%.1fx, aspect=%.4f"` mS:1362 |
| M38 | `routeInputFromTransport` → `handleReceivedInputEvent` | `mS:972` (body mS:2793) | T/UT inline for realtime types (`session_lane_is_realtime` mS:258-270), else S | **NONE: no connection or session identity check** [C] | per type (Section 3) | responses | input → injector | `"Input test control ignored: not in test mode"` mS:2807; `"Unhandled input event type: 0x%02x"` mS:2863 (os_log_debug) |
| M39 | `handleWiFiFrameAck` | `mS:2620` | T (realtime) | length; ack must lie in (lastAcked, lastSent] [C] | `_wifiAckActive` (2641), `_wifiAckLastAckedSeq` (2642) | — | reopens gate | `"WiFi frame ack too short: length=%zu"` mS:2622; `"WiFi ack gate active: ack=%u lastSent=%u unacked=%d rtt=%lluus limit=%d"` mS:2684; `"WiFi frame ack ignored: ack=%u lastAcked=%u lastSent=%u (stale or outside window) count=%d"` mS:2687 |
| M40 | `handleViewportReport` | `mS:3065` | S | length [C] | `_viewportReceived`=YES (3078) | — | encoder (re)start or skip | `"iPad viewport report: %ux%u (previous: %ux%u, changed=%{public}d, Mac display: %ux%u, hevcActive=%{public}d, usbConnected=%{public}d)"` mS:3081; `"Skipping redundant HEVC restart on unchanged viewport during active wireless session (expected=%ux%u capture=%ux%u)"` mS:3096 |
| M41 | `startReconnection` | `mS:3585` | S | NONE | → RECONNECTING; `latencyProbeTimer`=nil (3590); `reconnectAttempt`=0 (3612); stop capture | — | M07, startAdvertising, M42 | `"Connection lost -- starting reconnection with exponential backoff"` mS:3586; `"Starting WiFi advertising for reconnection (may have been skipped earlier, state=%{public}s transport=%{public}s)"` mS:3604 |
| M42 | reconnect NSTimer (`scheduleReconnect`) | `mS:3626` | **scheduled from S (GCD, no run loop)** [C] | block: `sessionState == RECONNECTING` [C] | `reconnectAttempt`++ (3633) | — | reschedules self or `onTransportConnected` via S | `"Reconnection attempt %d in %.1fs"` mS:3623 (at schedule); `"Transport reconnected on attempt %d"` mS:3637; `"Max reconnection attempts reached -- waiting for transport event"` mS:3618 |
| M43 | permission poll NSTimer (3 s, repeating) | `mS:628` | M | NONE | — | — | onPermissionsGranted | `"Permission poll: Screen Recording=%{public}s, Accessibility=%{public}s"` mS:640; `"Both permissions now granted"` mS:650 |
| M44 | delayed wireless advertising, `dispatch_after` 3 s | `mS:936` | M | skip if wireless session already active [C] | — | — | startAdvertising | `"Skipping delayed WiFi advertising start: wireless session already active (state=%{public}s transport=%{public}s)"` mS:941; `"USB NCM not connected after 3s — starting WiFi advertising"` mS:951 |
| M45 | wireless performance NSTimer (test mode) | `mS:2120` | M | test mode | — | — | — | NO LOG |
| M46 | latency probe NSTimer | `mS:2774` | scheduled from S (no run loop) | — | — | — | callback is a no-op [C] | NO LOG |
| M47 | stress window timer (test mode) | `mS:1293` | — | test mode | — | — | — | `"Test mode: real-capture stress window active at %.0fx%.0f"` mS:1289 |
| M48 | `start` | `mS:534` | M | TLS identity (fail-closed mS:660) | → AWAITING_PERMISSIONS | — | M43 or onPermissionsGranted | `"Session start: Secure Enclave identity %{public}s"` mS:538; `"Session not started: Secure Enclave TLS identity unavailable (check signing: keychain-access-groups + provisioning profile)"` mS:661 |
| M49 | `stop` (applicationWillTerminate) | `mS:564` | M | NONE | timers invalidated (mS:569-576), → STOPPED | — | M08, usb stopMonitoring M24 | `"Session stopping"` mS:565 |
| M50 | `onPermissionsGranted` | `mS:666` | M | test mode / `isPaired` | → AWAITING_PAIRING or CONNECTING | — | startTransportMonitoring | `"Already paired -- proceeding to connect"` mS:684; `"Not yet paired -- awaiting QR pairing"` mS:690 |
| M51 | `onPairingComplete` block | `mS:728` | M | NONE | → CONNECTING | — | startTransportMonitoring (second call possible) | `"Pairing complete -- closing QR window and starting transport"` mS:731 |
| M52 | `showPairingQR` → `resetPairing` | `mS:697` / `mS:809` | M | NONE | deletes pairing + pin while sessions stay up | — | — | `"Resetting pairing"` mS:810 |
| M53 | `transitionTo` | `mS:3650` | caller | NONE | `sessionState` (3657) | — | — | `"Session state: %{public}s -> %{public}s"` mS:3653 |
| M54 | `sendInputEventToiPad` | `mS:2062` | caller | USB connected, else wireless connected, else drop [C] | — | message | — | drop: **NO LOG** |
| M55 | pairing listener state | `mP:1273` | M | NONE | — | — | — | `"Pairing listener ready on port %d"` mP:1276; `"Pairing listener failed: %{public}@"` mP:1279; `"Pairing listener cancelled"` mP:1282 |
| M56 | pairing new connection | `mP:1289` | M | NONE → `handlePairingConnection` replaces existing (mP:846) | `activePairingConnection` | — | M57 | `"Pairing listener: incoming connection from iPad"` mP:1292; `"handlePairingConnection: branch=replace-existing oldConn=%{public}p newConn=%{public}p"` mP:846 |
| M57 | pairing conn state | `mP:857` | M | `activePairingConnection == conn` [C] | on success `completePairing` (keychain) | pairing exchange | M51 | `"Pairing connection state conn=%{public}p state=%{public}s error=%{public}@"` mP:868; `"Pairing TLS connection ready -- awaiting iPad public key"` mP:871 |
| M58 | identity self-test listener / connection (test hook) | `mP:298`, `mP:306`, `mP:334` | — | — | — | — | — | NO LOG in mP:290-345 |
| M59 | SIGTERM dispatch source | `mA:28` | M | NONE | — | — | terminate → M49 | `"SIGTERM: terminating through NSApp"` mA:29 |
| M60 | test-mode QR, `dispatch_after` 1 s | `mA:141` | M | test mode | — | — | M52 | `"Test mode: auto-showing QR (writes payload to /tmp/keydrd-test-qr.json)"` mA:138 |
| M61 | `applicationWillTerminate` | `mA:148` | M | NONE | — | — | M49 | `"Agent terminating — stopping session"` mA:149 |
| M62 | injector silence timer | `mJ:146` | J | keys/buttons held [C] | release all | synthetic ups | — | `"Input silence %llums with keys/buttons held: releasing all"` mJ:151 |
| M63 | injector key-repeat timer | `mJ:452` | J | — | — | key repeat | — | NO LOG |

### 2.2 iPad

| ID | Trigger | Where | Queue | Guard checked first | State writes | Sends | Triggers | Log |
|---|---|---|---|---|---|---|---|---|
| P01 | `state` didSet | `iS:25` | **whatever queue wrote it** (IT for iS:1070) | NONE | invalidates `connectingTimeoutTimer` when leaving `.connecting` (iS:32) | — | — | `"[CONSOLE] SessionManager state: \(oldValue.rawValue) -> \(state.rawValue)"` iS:27 |
| P02 | scenePhase change | `iA:20` | M | NONE | — | — | active → P06; background → P07; inactive → nothing | **LOGGER ONLY** (`appLog.info`) |
| P03 | `start` (ContentView onAppear) | `iS:174` | M | `isPaired` | → connecting (iS:221 / 228) | — | startTransportMonitoring (P12), P09 | `"[CONSOLE] start(): isPaired=\(qrPairing.isPaired)"` iS:176 |
| P04 | `onPairingComplete` | `iS:233` | M | NONE | → connecting (iS:236) | — | P12, P09 | `"[CONSOLE] SessionManager.onPairingComplete() called, current state=\(state.rawValue)"` iS:234 |
| P05 | `retryNow` | `iS:256` | M | NONE | `reconnectAttempt`=0 (iS:259) | — | P12, P09 | `"[CONSOLE] retryNow: arming connecting timeout"` iS:261 |
| P06 | `resumeFromBackground` | `iS:267` | M | `isPaired` | disconnected/reconnecting → connecting (iS:278); streaming + no transports → reconnecting (iS:290) **with no timer armed** [C] | — | P12, P09 | `"[CONSOLE] resumeFromBackground: state=\(state.rawValue), usb=\(usbTransport.isConnected), wifi=\(wirelessTransport.isConnected)"` iS:269; `"[CONSOLE] resumeFromBackground: transports dead while backgrounded, reconnecting"` iS:288 |
| P07 | `pauseForBackground` | `iS:316` | M | NONE | invalidates timers only | — | — | **LOGGER ONLY** (`"App backgrounded -- pausing"` iS:317) |
| P08 | `resetPairingAndShowQR` | `iS:326` | M | NONE | `currentTransport` (iS:340), → awaitingPairing (iS:342) | — | transports stopped | `"[CONSOLE] resetPairingAndShowQR: clearing pairing and returning to QR"` iS:327 |
| P09 | connecting timeout Timer (8 s) | `iS:352` | M | `state == .connecting` [C] | link up: re-arm; link down: restart discovery | — | P12 | `"[CONSOLE] Connecting timeout: state=\(self.state.rawValue), nothing to do"` iS:355; `"[CONSOLE] Connecting timeout: link up but not streaming yet (usb=\(usbUp), wifi=\(wifiUp)) -- keeping pairing, re-arming"` iS:361; `"[CONSOLE] Connecting timeout: Mac not reached -- keeping pairing (pairedHost=\(self.qrPairing.pairedHost ?? "nil")), restarting discovery"` iS:364 |
| P10 | `disconnectSession` | `iS:376` | M | NONE | → disconnected (iS:379), `currentTransport` (iS:388) | — | transports torn down | **LOGGER ONLY** (`"Disconnecting session"` iS:377) |
| P11 | `handlePeerAddressUpdate` (0x25) | `iS:448` | IT/IUT | NONE | iU peer address | — | iU `setPeerAddress` (P45) | `"[CONSOLE] Peer address update from Mac: \(ipString)"` iS:456 |
| P12 | `startTransportMonitoring` (wires callbacks) | `iS:503` | M | NONE | — | — | iU poll start; Wi-Fi browse (P14) | `"[CONSOLE] Wireless-only mode — USB monitoring disabled"` iS:563 |
| P13a | iU `onInterfaceChanged` callback | `iS:518` | hops to M | NONE | — | — | P15 wiredAppeared / wiredDisappeared | `"[CONSOLE] USB NCM onInterfaceChanged: appeared=\(appeared), usbConnected=\(self.usbTransport.isConnected), wifiConnected=\(self.wirelessTransport.isConnected)"` iS:521 |
| P13b | iW `onConnectionChanged` callback | `iS:539` | hops to M | NONE | — | — | P15 awdl/wifi Available / Unavailable | NO LOG in callback (transport logs `"[CONSOLE] WirelessTransport: AWDL=\(detectedAWDL), calling onConnectionChanged"` iW:598) |
| P13c | iU / iW `onInputReceived` callbacks | `iS:534`, `iS:555` | IUT / IT (no hop) | NONE | — | — | P18 | NO LOG |
| P14 | delayed Wi-Fi browse, `asyncAfter` 0 or 1 s | `iS:569` | M | mode flags | — | — | iW startBrowsing | `"[CONSOLE] Starting WiFi browsing (background fallback)"` iS:574 |
| P15 | `handleTransportEvent` | `iS:585` | M | NONE (no check of which connection) | `currentTransport` (iS:596); disconnected+streaming → reconnecting (iS:637) | — | immediate fallback (re-enters P15); P21 | `"[CONSOLE] handleTransportEvent: \(event) (current: \(currentTransport.rawValue))"` iS:586; `"[CONSOLE] handleTransportEvent: no state change, skipping"` iS:590; `"[CONSOLE] Transport FSM: \(currentTransport.rawValue) -> \(transition.state.rawValue), effects=\(transition.effects)"` iS:594 |
| P16 | first media frame (LZ4 / HEVC decoded) | `iS:686` (writes iS:829), `iS:862` (writes iS:934) | M | `state` ∈ {connecting, reconnecting} | → streaming, `reconnectAttempt`=0 | — | — | via P01 only; per-frame `"[CONSOLE] handleReceivedFrame: seq=\(header.seq) flags=0x\(String(header.flags, radix: 16)) payload=\(payloadLength) isHEVC=\(header.isHEVC) isKey=\(header.isKeyframe)"` iS:738 (sampled) |
| P17 | `handleSessionHandshake` | `iS:1011` | **IT/IUT (off main)** | NONE | decompressor; **`state`=.streaming (iS:1070)** | VIEWPORT_REPORT (iS:491-499) | `inputSender.connectionEstablished`; probe + FPS timers (P19, P20) | `"[CONSOLE] Session handshake complete; forcing HUD visible"` iS:1072 (handshake details LOGGER ONLY iS:1012) |
| P18 | `handleInputReceived` | `iS:1101` | IT/IUT | NONE: no connection or session identity check [C] | per type | FRAME_ACK when HEVC, chunkTotal ≤ 1, wireless, `!usb` | P17; P16 via frame path | `"[CONSOLE] handleInputReceived: parsed as SESSION HANDSHAKE \(handshake.displayWidth)x\(handshake.displayHeight)"` iS:1105; `"[CONSOLE] LZ4 over wireless dropped seq=\(mediaHeader.seq) key=\(mediaHeader.isKeyframe) bytes=\(data.count) total=\(wirelessLZ4Dropped)"` iS:1122 |
| P19 | latency probe Timer | `iS:1181` | M run loop | — | — | LATENCY_PROBE (iS:1198) | — | `"[CONSOLE] startLatencyProbeTimer: scheduling on main run loop, state=\(self.state.rawValue), interval=\(Self.latencyProbeInterval)s"` iS:1180 |
| P20 | FPS Timer | `iS:1358` | M | — | — | — | — | `"[CONSOLE] fpsTimerTick: frameTimestamps=\(self.frameTimestamps.count), computedFPS=\(currentFPS), state=\(self.state.rawValue)"` iS:1361 |
| P21 | reconnect Timer (`scheduleReconnect`) | `iS:1479` | M | weak self only | `reconnectAttempt` += 1 | — | **one call to P12; never reschedules** [C] | **LOGGER ONLY** (`"Scheduling reconnect attempt \(self.reconnectAttempt + 1) in \(delay)s"` iS:1475) |
| P22 | `sendInputEventReturningLink` | `iS:1433` | caller | USB first, then wireless | — | message | — | drop: **NO LOG** |
| P23 | infra Wi-Fi path monitor | `iW:59` | IT | NONE | infra interface set | — | dial params | `"[CONSOLE] WirelessTransport: infra Wi-Fi interfaces=\(infra.map { $0.name }) status=\(path.status)"` iW:63 |
| P24 | browser state | `iW:384` | IT | `browser === newBrowser` [C] | `browser` (iW:396 / 405) | — | restart P34 | `"[CONSOLE] Bonjour browser ready for \(keydrdService)"` iW:388; `"[CONSOLE] Bonjour browser FAILED: \(error)"` iW:392 |
| P25 | browse results changed | `iW:414` | IT | dedup on `connectedServiceName` / `isConnected`; allows replacement during control recovery; `.removed` guarded by name latch [C] | `connectedServiceName` (iW:458 / 486) | — | connectToService (P27) | `"[CONSOLE] Bonjour service FOUND: \(result.endpoint.debugDescription) interfaces=\(result.interfaces.map { "\($0.name)/\($0.type)" })"` iW:421; `"[CONSOLE] Bonjour: ignoring control-path replacement duplicate while replacement already in-flight decision=preserve-current-attempt inputState=\(activeInput.state) serviceLatch=\(self.connectedServiceName ?? "nil") mediaActive=\(self.mediaConnection != nil) isConnected=\(self.isConnected)"` iW:439; `"[CONSOLE] Bonjour service LOST: \(result.endpoint.debugDescription)"` iW:466 |
| P26 | `stopBrowsing` | `iW:499` | **M (caller)** | NONE | `browsingRequested`=false (iW:500), `browser` (iW:506) | — | — | `"[CONSOLE] WirelessTransport: stopBrowsing entry hadBrowser=\(hadBrowser) connectedServiceName=\(connectedServiceName ?? "nil") isConnected=\(isConnected)"` iW:502 |
| P27 | input TCP state | `iW:574` | IT | `inputConnection === inputConn` [C] | ready: `isAWDL` (593), `isConnected`=true (594), `avoidAWDL`=false (596). failed: degraded (keep `isConnected`) or teardown (632-635). cancelled (651-661) | heartbeat | ready → `onConnectionChanged(true)` → P13b, media dial (P29) unless recovering; failed → `onConnectionChanged(false)`, browser restart; `.waiting` → log only (watchdog P35 is the exit) | `"[CONSOLE] WirelessTransport: TLS TCP connection READY"` iW:588; `"[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-failed-media-active action=preserve-session-and-recover-control detail=\(error)"` iW:625; `"[CONSOLE] WirelessTransport: TCP FAILED teardown branch isConnected=\(self.isConnected), mediaActive=\(hasMediaPath), wasAWDL=\(wasAWDL) -> next dial \(self.nextDialAWDL ? "awdl" : "infra")"` iW:635; `"[CONSOLE] WirelessTransport: stale TCP connection CANCELLED ignored"` iW:642 |
| P28 | TCP connect path update | `iW:684` | IT | NONE | — | — | — | `"[CONSOLE] WirelessTransport: TCP CONNECT-PATH status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name):\($0.type)" }) remote=\(String(describing: path.remoteEndpoint)) local=\(String(describing: path.localEndpoint))"` iW:685 |
| P29 | DTLS media state | `iW:728` | IT | `mediaConnection === conn` [C] | `mediaConnection` (749 / 759) | — | ready → P30; end → P38 | `"[CONSOLE] WirelessTransport: DTLS UDP media connection READY"` iW:738; `"[CONSOLE] WirelessTransport: stale DTLS media FAILED ignored: \(error)"` iW:743 |
| P30 | media receive completion | `iW:821` | IT | identity [C] | — | — | transient gap → P31; else P38 | `"[CONSOLE] WirelessTransport: stale media receive callback dropped (isComplete=\(isComplete), error=\(String(describing: error)))"` iW:827; `"[CONSOLE] WirelessTransport: UDP media recv error: \(error)"` iW:915 |
| P31 | transient-gap re-arm, `asyncAfter` | `iW:907` | IT | — | — | — | re-arm receive | NO LOG in callback (decision logged before, iW:894 / 901) |
| P32 | input receive completion | `iW:924` | IT | `inputConnection === conn` [C] | shared `tcpBuffer` | — | drainTCPBuffer (heartbeats consumed) → `onInputReceived`; error / EOF → cancel → P27 | `"[CONSOLE] WirelessTransport: stale TCP receive callback dropped (isComplete=\(isComplete), error=\(String(describing: error)))"` iW:933; `"[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-eof-media-active action=cancel-input-and-preserve-session"` iW:969 |
| P33 | `tearDownConnections` | `iW:1081` | caller | NONE | 1085-1097 | — | — | `"[CONSOLE] WirelessTransport: tearDownConnections reason=\(reason) clearServiceName=\(clearServiceName) connectedServiceName=\(connectedServiceName ?? "nil") isConnected=\(isConnected)"` iW:1082 |
| P34 | browser restart, `asyncAfter` | `iW:1127` | IT | `browsingRequested`, not connected [C] | `browser` (iW:1117) | — | startBrowsing | `"[CONSOLE] WirelessTransport: scheduling browser restart attempt=\(browserRestartAttempt) reason=\(reason) delay=\(String(format: "%.2f", delay))s connectedServiceName=\(connectedServiceName ?? "nil")"` iW:1124 |
| P35 | connect watchdog (3 s) | `iW:1170` | IT | stale-connection and already-connected checks [C] | `inputConnection`=nil (1165), `connectedServiceName`=nil (1166), `avoidAWDL` (1161) | — | browser restart | `"[CONSOLE] WirelessTransport: connect watchdog timeout; cancelling pending TCP connection and clearing latch (connectedServiceName=\(self.connectedServiceName ?? "nil")) dial=\(self.lastDialAWDL ? "awdl" : "infra") -> next=\(self.nextDialAWDL ? "awdl" : "infra")"` iW:1162 |
| P36 | control recovery evaluator, `asyncAfter` | `iW:1219` | IT | recovery active | timeout: 1227-1232 cleared | — | `onConnectionChanged(false)` | `"[CONSOLE] WirelessTransport: control path loss decision=preserved reason=control-path-recovered action=continue-session"` iW:1201; `"[CONSOLE] WirelessTransport: control path loss decision=reconnect-triggered reason=control-recovery-timeout action=drop-media-and-signal-disconnect trigger=\(reason) detail=\(detail) elapsedMs=\(elapsedNs / 1_000_000) mediaActive=\(hasMediaPath)"` iW:1224 |
| P37 | post-loss browser kick, `asyncAfter` | `iW:1244` | IT | — | `controlRecoveryWorkItem` (1243) | — | browse | `"[CONSOLE] WirelessTransport: loss on \(wasAWDL ? "awdl" : "infra") -> next dial \(self.nextDialAWDL ? "awdl" : "infra")"` iW:1239 |
| P38 | `handleActiveMediaPathLoss` | `iW:1247` | IT | NONE | 1281-1292 | — | `onConnectionChanged(false)` | `"[CONSOLE] WirelessTransport: media path loss observed reason=\(reason) detail=\(detail) hadInputConnection=\(hadInputConnection) wasConnected=\(wasConnected) browsingRequested=\(browsingRequested)"` iW:1265; `"[CONSOLE] WirelessTransport: media path loss decision=degraded reason=control-path-healthy detail=\(detail) action=preserve-session-no-reconnect"` iW:1267 |
| P39 | link heartbeat timer | `iW:1307` | IT | tick iW:1326: identity + connected [C] | silent ≥ 4 s: 1354-1364 cleared | 0x31 | `onConnectionChanged(false)` | `"[CONSOLE] WirelessTransport: link heartbeat started interval=\(linkHeartbeatInterval)s deadline=\(linkSilenceDeadline)s"` iW:1315; `"[CONSOLE] WirelessTransport: link silent decision=lost silentMs=\(Int(silentSec * 1000)) deadlineMs=\(Int(linkSilenceDeadline * 1000)) AWDL=\(wasAWDL) heartbeatsSent=\(linkHeartbeatsSent) heartbeatsReceived=\(linkHeartbeatsReceived) action=drop-and-redial"` iW:1349 |
| P40 | USB poll timer (dispatch source) | `iU:406` | IUM | NONE | `detectedLocalIP` (413 / 436), `activeInterface` (435); gone: teardown, `isConnected`=false (438) | — | new IP: startUSBBrowse; if link-local peer known: `connectOverUSBNCMByIP` + **`onInterfaceChanged(true)` before READY** → P13a | `"[CONSOLE] USB NCM interface detected: \(ncm.name) = \(ncm.ip)"` iU:411; `"[CONSOLE] USB NCM: have link-local peer \(linkLocal) — connecting and firing wiredAppeared"` iU:419 |
| P41 | iU `stopMonitoring` | `iU:449` | caller | NONE | `isConnected`=false (457), IP cleared (455) | — | — | NO LOG |
| P42 | USB browse state | `iU:471` | IUM | NONE | — | — | — | `"[CONSOLE] USB browse state: \(state)"` iU:472 |
| P43 | USB browse results | `iU:474` | IUM | `browser === usbBrowser` [C] | learns link-local; address change while connected → teardown + `isConnected`=false (iU:523) | — | `setPeerAddress` (P45) | `"[CONSOLE] USB browse: results from stale browser ignored"` iU:476; `"[CONSOLE] USB browse: address changed while connected — tearing down for re-dial"` iU:521 |
| P44 | USB connect retry, `asyncAfter` 1 s | `iU:533` | IUM | `usbConnectRetryPending`; skip if connected [C] | `usbConnectRetryPending` (531 / 535) | — | `connectOverUSBNCMByIP` | `"[CONSOLE] USB retry: scheduled in 1.0s reason=\(reason)"` iU:532; `"[CONSOLE] USB retry: re-dialing \(self.detectedMacLinkLocalIP!) from \(localIP)"` iU:544 |
| P45 | `setPeerAddress` | `iU:569` | **called from M, IT and IUM** [C] | link-local preference | `detectedMacIP` / `detectedMacLinkLocalIP` | — | dial + "notifying FSM" | `"[CONSOLE] USBTransport: link-local peer address set to \(ip)"` iU:571; `"[CONSOLE] USBTransport: link-local peer \(linkLocal) + USB NCM up — connecting and notifying FSM"` iU:587 |
| P46 | USB (interface variant) media state | `iU:629` | IUT | ready: NONE; failed/cancelled: identity [C] | `mediaConnection` (638 / 642); `isConnected`=false if no input (639 / 643) | — | scheduleMediaReceive | **LOGGER ONLY** (`"USB NCM DTLS media connection ready"` iU:633) |
| P47 | USB (interface variant) input state | `iU:660` | IUT | **ready: NONE**; failed: identity [C] | `isConnected`=true (665) | — | scheduleInputReceive | ready: **LOGGER ONLY** (`"USB NCM TLS input connection ready"` iU:664); failed `"[CONSOLE] USBTransport: TLS input FAILED (interface): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale"))"` iU:669 |
| P48 | USB (by-IP) media state | `iU:730` | IUT | ready: NONE; failed: identity | `mediaConnection` (741), `isConnected` (742) | — | — | `"[CONSOLE] USBTransport: DTLS media connection READY"` iU:734 |
| P49 | USB (by-IP) input state | `iU:774` | IUT | **ready: NONE** (iU:784); failed: `inputConn === inputConnection` (iU:787-790) [C] | ready: `isConnected`=true (784) | — | ready → scheduleInputReceive; failed → P52; `.waiting` → P50 | `"[CONSOLE] USBTransport: TLS input connection READY"` iU:782; `"[CONSOLE] USBTransport: TLS input FAILED: \(error) (connection=\(current ? "current" : "stale"))"` iU:788; `"[CONSOLE] USBTransport: TLS input WAITING: \(error) — will retry in 0.5s"` iU:793; `"[CONSOLE] USBTransport: TLS input CANCELLED (connection=\(inputConn === self.inputConnection ? "current" : "stale"))"` iU:804 |
| P50 | `.waiting` retry, `DispatchQueue.main.asyncAfter` 0.5 s | `iU:794` | **M** | `detectedLocalIP` and `detectedMacIP` non-nil and **whatever `inputConnection` is current is not `.ready`**. No identity check against the waiting conn [C] | cancels the current `inputConnection`, sets nil (799) | — | `retryTCPConnection` (P51) | `"[CONSOLE] USBTransport: retrying TCP connection"` iU:797 |
| P51 | `retryTCPConnection` input state | `iU:841` | IUT | **ready: NONE** (847) | `isConnected`=true (847) | — | — | `"[CONSOLE] USBTransport: TLS input READY (retry)"` iU:845; `"[CONSOLE] USBTransport: TLS input FAILED (retry): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale"))"` iU:850; `"[CONSOLE] USBTransport: TLS input still WAITING (retry): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale")) -> cancel and redial"` iU:858 |
| P52 | `usbInputLost` | `iU:875` | IUT | caller checked identity | `inputConnection`=nil (878), media cancelled (880), `isConnected`=false (883) | — | P44 retry. **No `onInterfaceChanged(false)`, no FSM event** [C] | `"[CONSOLE] USBTransport: USB link lost reason=\(reason) wasConnected=\(wasConnected) droppedMedia=\(hadMedia) -> isConnected=false, redialing"` iU:884 |
| P53 | USB receive loops | `iU:892` | IUT | **NONE** [C] | shared `tcpBuffer` | — | data → `onInputReceived`. **Error / EOF: log and return; no loss handling** [C] | `"[CONSOLE] USBTransport: media-recv error=\(error) count=\(self.mediaReceiveErrorCount)"` iU:903; `"[CONSOLE] USBTransport: media-recv complete count=\(self.mediaReceiveCompleteCount)"` iU:909 |
| P54 | iU `tearDownConnections` | `iU:1078` | caller | NONE | 1080-1082; `tcpBuffer` cleared asynchronously | — | — | NO LOG |
| P55 | test pairing connection state | `iQ:482` | — | — | — | pairing | — | `"[CONSOLE] test pairing connection state: \(state)"` iQ:484 |
| P56 | test pairing timeout, `asyncAfter` 10 s | `iQ:513` | — | — | — | — | — | `"[CONSOLE] test pairing TIMEOUT after 10s"` iQ:515 |
| P57 | pairing connection state | `iQ:892` | — | — | keychain writes (results ignored, iQ:1114-1124) | pairing | P04 | `"[CONSOLE] pairing connection state: \(state)"` iQ:894; `"[CONSOLE] TLS connection ready, starting ECDH exchange"` iQ:898 |
| P58 | pairing timeout, `asyncAfter` 30 s | `iQ:932` | — | — | — | — | — | `"[CONSOLE] pairing connection TIMEOUT after 30s"` iQ:934 |
| P59 | InputSender keepalive timer (while held) | `iI:190` | M | keys/buttons held | — | KEEPALIVE 0x30 (iI:195) | — | NO LOG |
| P60 | InputSender willResignActive observer | `iI:50` | M | — | cancel all held | HELD | — | `"[CONSOLE] input cancelAll reason=\(reason) keys=\(heldKeys.count) buttons=\(buttons)"` iI:129 |

**Rows: section 2 = 66 Mac + 62 iPad = 128** (M30a/b/c and P13a/b/c counted as separate rows).

### 2.3 Re-grep check

Pattern set: `nw_connection_set_state_changed_handler`, `nw_listener_set_state_changed_handler`, `nw_listener_set_new_connection_handler`, `stateUpdateHandler`, `newConnectionHandler`, `browseResultsChangedHandler`, `pathUpdateHandler`, `dispatch_source_set_event_handler`, `Timer`, `asyncAfter`, `dispatch_after`. Run fresh on 2026-11-16 over every file in the prefix table. Registration hits and their rows:

- mW: 349 M01, 368 M02, 394 M03, 416 M04, 685 M05/M06, 852 M09, 862 M10, 875 M11, 1183 / 1217 M15, 1233 M17.
- mU: 405-406 / 412 M23, 978 M25, 987 M26, 1003 M27, 1028 M28, 1037 M29, 1050 M30.
- mS: 628 M43, 936 M44, 1293 M47, 2120 M45, 2774 M46, 3626 M42.
- mP: 298 / 306 / 334 M58, 857 M57, 1273 M55, 1289 M56.
- mA: 28 M59, 141 M60.
- mJ: 146 M62, 452 M63.
- iS: 352 P09, 569 P14, 1181 P19, 1358 P20, 1479 P21.
- iU: 406 P40, 471 P42, 474 P43, 533 P44, 629 P46, 660 P47, 730 P48, 774 P49, 794 P50, 841 P51.
- iW: 59 P23, 384 P24, 414 P25, 574 P27, 684 P28, 728 P29, 907 P31, 1127 P34, 1170 P35, 1219 P36, 1244 P37, 1307 P39.
- iA: 20 P02.
- iQ: 482 P55, 513 P56, 892 P57, 932 P58.
- iI: 190 P59.

The other hits are not registrations: ivar or property declarations (mW:68, mJ:101 / 105), invalidate or cancel calls (mS:569-576, 1061, 1196, 1270, 2211-2223, 3590; mJ:160-161), helper calls (iS:295, 441, 1065, 1068), assignments of an already-created timer (mW:1238, iW:1313, iS:1185 / 1367, iU:445), and the guard at iU:398. TransportFSM.c / .swift have no hits.

The fresh run uses the brief's literal pattern list, plus `makeTimerSource`, `setEventHandler` and the `nw_listener_*` handler setters, over every file in the prefix table (180 hit lines). Each hit was checked mechanically against the citations in this document. These remaining hits are not registrations:
- **Timer block bodies of registrations already listed:** mS:630 (M43), mS:2122 (M45), mS:2776 (M46), mS:3628 (M42); iW:1309 (P39 `setEventHandler`); iI:193 (P59 `setEventHandler`).
- **Timer source creation and arming for listed handlers:** mU:393, mU:450 (M23); iU:403 (P40 `makeTimerSource`); mJ:142, mJ:143, mJ:155 (M62); mJ:447, mJ:448, mJ:459 (M63).
- **Cancel, invalidate or nil:** mW:1245-1247; mU:454-456; mS:568, mS:652, mS:1269, mS:2772, mS:3589; mJ:463; iS:31, iS:258, iS:319-322, iS:330-333, iS:351, iS:380-382, iS:399-400, iS:638, iS:1179, iS:1356, iS:1478, iS:1493-1495; iW:1319, iW:1321; iU:450-451.
- **Declarations, helper definitions and calls, logs:** mS:364, mS:365, mS:431, mS:1247-1248, mS:2103, mS:2109, mS:2114, mS:2211, mS:2217, mS:2771; mJ:105; iS:75, iS:101, iS:296, iS:441, iS:1065, iS:1068, iS:1177, iS:1354, iS:1357; iW:154; iU:36; iI:29. Also nil/invalidate: mS:1270, mS:2222-2223, mS:3590; timer assignment: iS:1367. After this list, the mechanical check finds 0 of 180 hit lines unaccounted for.

---

## 3. Protocol messages

Two levels of "does the receiver check which connection it came on":

- **Transport level**: a stale-callback drop on the receive loop. Mac wireless and iPad wireless have it (mW:1055, iW:933). **Mac USB and iPad USB do not** (mU:1089-1168, iU:892-960) [C].
- **Message level**: a check inside the handler against session, link or generation. Only the injector's session/seq guard (mJ:209-218) does this, and only for input types [C].

Note: input type 0x01 (MOUSE_MOVE) and `KEYDRD_MSG_SESSION_HANDSHAKE` 0x01 share the byte. They are told apart by the 0x4B44 magic that prefixes the handshake and the MediaFrameHeader; the iPad tries handshake parse first (iS:1103-1105) [C].

| Type | Name | Dir | Sender | Receiver dispatch | Receipt changes | Message-level check |
|---|---|---|---|---|---|---|
| magic 0x4B44 + 0x01 | SESSION_HANDSHAKE | Mac→iPad | mS:1327-1368 (struct mS:1348) | iS:1103-1105 → iS:1011 | decompressor; VIEWPORT_REPORT sent; **`state`=.streaming off main (iS:1070)**; `inputSender.connectionEstablished`; probe + FPS timers [C] | NONE, accepted in any state on any link [C] |
| magic 0x4B44 (25-byte MediaFrameHeader) | media frame (LZ4 or HEVC, chunked) | Mac→iPad | mS:1597-2005 (USB mS:1618ff; Wi-Fi TCP mS:1876-1919 via mW:547); header-only mS:2007 | iS:1108-1140 → iS:686 / iS:862 | first frame: connecting/reconnecting → streaming (iS:829 / 934); FRAME_ACK emitted | LZ4 on wireless dropped (iS:1122); no session check [C] |
| 0x01, 0x02, 0x03, 0x10, 0x11, 0x12 | MOUSE_MOVE, CLICK, SCROLL, KEY, HELD, TEXT | iPad→Mac | iI (via iS:1433) | mS:972 inline → mS:2793 → injector | injector state; HELD resyncs the held set [C] | session + seq guard mJ:209-218 [C] |
| 0x20 | MODE_CHANGE (sub 0x02 ECO, 0x03 REQUEST_KEYFRAME) | both | iPad iS:1378, iS:1418; Mac mS:1167 | Mac mS:2841 → mS:3331 / 3359; iPad iS:1158 | eco mode; keyframe request; codec mode notice [C] | NONE |
| 0x21 | RES_MATCH_REQUEST | iPad→Mac | iS:430 | mS:2837 → mS:3392 | display mode switch, `resolutionChanged` [C] | NONE |
| 0x22 | RES_MATCH_RESPONSE | Mac→iPad | mS:3521 | iS:1161 | iPad resolution state [C] | NONE |
| 0x23 | GEOMETRY_UPDATE | Mac→iPad | mS:3544 | iS:1164 → iS:1275 | geometry [C] | NONE |
| 0x24 | VIEWPORT_REPORT | iPad→Mac | iS:492 (from P17) | mS:2845 → mS:3065 | `_viewportReceived`=YES; encoder start or "redundant restart" skip [C] | NONE |
| 0x25 | PEER_ADDRESS_UPDATE | Mac→iPad | mS:2888 (on WIRED_APPEARED) | iS:1167 → iS:448 | iU peer address → dial (P45) [C] | NONE |
| 0x26 | TEST_CONTROL | iPad→Mac | DeviceTestRunner (test) | mS:2805 | test only | test-mode flag (mS:2807) |
| 0x27 | TEST_REPORT | Mac→iPad | mS:2824, mS:3276 | iS:1149 | test only | NONE |
| 0x28 | TEST_FILLER | Mac→iPad | mS:3290 | iS:1146 | test only | NONE |
| 0x30 | KEEPALIVE | iPad→Mac | iI:195; DeviceTestRunner.swift:659 | mS:2858 | injector silence timer reset [I] | session guard [I] |
| 0x31 | LINK_HEARTBEAT (wireless TCP only) | both | Mac mW:1262; iPad heartbeat tick iW:1326ff | Mac mW:1085 (in receive loop); iPad drainTCPBuffer iW:982-1065 | activity ticks only; never reaches SessionManager [C] | transport-level identity only |
| 0x32 | FRAME_ACK | iPad→Mac | iS:1395 | mS:2793 → mS:2620 (realtime, T) | ack gate state [C] | window check only (lastAcked < ack ≤ lastSent); no link or generation check [C] |
| 0xFE | CLOCK_SYNC_REQ | iPad→Mac | DeviceTestRunner.swift:730 | mS:2849 → mS:3227 | responds | NONE |
| 0xFD | CLOCK_SYNC_RESP | Mac→iPad | mS:3245 | iS:1155 | clock offset [C] | NONE |
| 0xFF | LATENCY_PROBE | iPad→Mac, echoed | iS:1198; DeviceTestRunner.swift:603, 1566 | Mac mS:2853 echo; iPad iS:1152 | latency stats | NONE |

**Rows: section 3 = 18.**

---

## 4. Takeover and replacement paths

### 4.1 Mac wireless (the AWDL takeover bug)

There are three entry points by which a new wireless TCP connection becomes `inputConnection` while the session stays up.

**Path A: degraded, then a fresh accept** (the observed bug).
1. Old TCP ends (EOF / error → cancel). mW:756 fires `onInputStreamEnded` (injector releases). mW:775 sets `inputConnection`=nil. Because `mediaConnection != nil && isConnected` (mW:776-778), it takes the degraded branch mW:780-788: **`isConnected` stays YES and `onConnectionChanged(NO)` is not called** [C]. The DTLS media connection is UDP and gives no signal when the peer dies, so it keeps `hasMediaPath` true [I].
2. The Mac keeps sending frames. `wifiAckNoteSentSeq` (mS:1888) runs before `sendMediaFrameViaTCP` returns `completion(NO)` for a nil connection (mW:550-553, NO LOG), so unsent frames count as sent and `unacked` climbs to 5 [C].
3. iPad redials (possibly on another link). mW:621: `_inputConnection == nil` so no duplicate check; accepted at mW:675 [C].
4. READY (mW:692-752) → `onConnectionChanged(YES, AWDL)` (mW:743-745) → M33 → M35 `handleTransportEvent(AWDL_AVAILABLE)`.
5. FSM: WIFI + AWDL_AVAILABLE is a no-op (mF:97-99) [C]. Same-link events (WIFI+WIFI_AVAILABLE, AWDL+AWDL_AVAILABLE) are no-ops in the default branch [C]. AWDL + WIFI_AVAILABLE transitions to WIFI with no HEVC effect [C].
6. **The line that keeps the old session state is mS:1053:** `if (_sessionState == SESSION_CONNECTING || _sessionState == SESSION_RECONNECTING)`. The session is STREAMING, so `onTransportConnected` is skipped, which skips the handshake (mS:1200 → M37), `wifiAckReset("transport-connected")` (mS:1193), the in-flight reset (mS:1183-1184) and the generation bump (mS:1192) [C]. Nothing is logged for this skip [C].
7. DTLS media to the new connection comes up → M34 → `"Media channel ready ignored (awaitingMedia=0 …)"` [C for the code path].
8. The ack gate stays shut: `unacked`=5 ≥ 5 with no time-based escape (mS:1472-1477, `NoBlindReset`). The only resets are mS:1124 and mS:1193 [C]. The iPad sends FRAME_ACK only for frames it receives (iS:1101ff), and it receives none, so **the stall is permanent until a mode switch or a new `onTransportConnected`** [I, from code].

Log evidence (from `/tmp/keyd-run-mac-oslog.log`, 2026-11-16 02:35, overwritten on the next run) [I]:
- 47.541 `"TCP input receive error on active connection: Connection reset by peer"`, then `"TLS wireless connection ended (state=5 …)"` and `"Control path loss decision=degraded reason=tcp-state-ended-media-active …"`.
- seqs 640 and 641 complete with `success=no`.
- 49.610: accept on `awdl0`, `"Transport event: AWDLAvailable (current state: Wi-Fi)"`, `"Transitioned to: Wi-Fi (0 effects)"`, `"Media channel ready ignored (awaitingMedia=0 …)"`.
- All of the above is agent pid 98733 (started 02:35:21). In that pid, after 02:35:47 there is no `"WiFi ack gate reset"`, no `"Transport connected"` and no `"Session state:"` line until `STREAMING -> STOPPED` at 02:38:29.635 (agent stopped by the harness). `"WiFi pre-encode drop: reason=ack-gate …"` lines run to 02:38:27.137, with `totalDropped=7900` on the last one. So the stall lasted about 2 min 40 s and ended only when the process was stopped.
- Separate episode, pid 99751: TCP ended at 02:39:59.363 → degraded. Ack-gate drops ran 02:40:00-02:40:04. No replacement arrived, so M15 timed out at 02:40:05.633 → `WiFiUnavailable` → RECONNECTING. This is Path A **without** a takeover; it recovered as designed.

iPad counterpart. `/tmp/keyd-run-ipad.log` has no timestamps. In order, it shows:
1. `start(): isPaired=true` (fresh process) and `awaitingPairing -> connecting`.
2. `handleTransportEvent: awdlAvailable (current: idle)`.
3. 21× `"[CONSOLE] Connecting timeout: link up but not streaming yet (usb=false, wifi=true) -- keeping pairing, re-arming"`.
4. Control path loss, then the recovery timeout, then `awdlUnavailable`.
5. `wifiAvailable (current: disconnected)`, then `parsed as SESSION HANDSHAKE 3024x1964` and `connecting -> streaming`.

[I] This lines up with pid 98733:
- The Mac's "Connection reset by peer" at 02:35:47 fits the old iPad process dying (relaunch).
- The new iPad process dialled AWDL; the Mac accepted it at 02:35:49.610.
- 21 re-arms × 8 s = 168 s, which ends at about 02:38:37.7. The Mac pid 99751 sent its handshake (Wi-Fi, en0) at 02:38:37.129.
- This rests on timing arithmetic, not timestamps.

**Cross-side pairs for the model.** A takeover leaves the Mac in the same state each time: `sessionState = STREAMING`, `transportState` unchanged, `isConnected = YES`, a new `inputConnection`, no handshake sent, and the ack gate closed with `unacked = 5`. The iPad side depends on how it reached the redial. `.connecting` is written only at start, onPairingComplete, resumeFromBackground and test hooks (Section 1.2); `handleTransportEvent` only writes `reconnecting` (iS:637) [C].

| Pair | iPad state at takeover | What blocks progress | Status |
|---|---|---|---|
| T1 | `connecting`: iPad process relaunched, resumed, or re-paired | The iPad needs SESSION_HANDSHAKE **or** a first frame (P16 accepts frames in `connecting`). The Mac sends neither: no handshake (mS:1053), and frames are held by the ack gate. P09 re-arms forever while the link is up [C] | **Observed** (pid 98733 plus the iPad log) [I] |
| T2 | `streaming`, wireless degraded/preserved (iW:620-626) and the replacement dialled during recovery | No handshake is needed. The ack gate alone blocks: no frames are sent, so no FRAME_ACK comes back, so the gate never reopens [C for each step] | Not observed; follows from code [I] |
| T3 | `reconnecting` after a teardown (P15 → iS:637), then a redial from the one-shot P21 or a browse | Same as T2. P16 would move to `streaming` on the first frame, but no frame is sent [C] | Not observed [I] |

In every pair, no timer on either side breaks the stall. P09 re-arms when the link is up (and only runs in `connecting`). The Mac has no watchdog for STREAMING without progress, and the ack gate has no time escape (mS:1472) [C].

**Path B: duplicate-replace** (mW:640-668). If `inputConnection` is still set and `shouldReplace` holds (`_allowReconnectTakeover` from M07 / M14, or a staleness test), mW:664 cancels the old connection and installs the new one.
- It does not reset `isConnected`, `mediaConnection`, the heartbeat or session state [C].
- The old connection's cancel arrives at M06. It fires `onInputStreamEnded` (mW:756), then is dropped as stale [C].
- The new READY → M33 → M35 has the same FSM no-op and the same mS:1053 skip as Path A [C].

**Path C: control recovery succeeds** (M14 / M15). The replacement arrives inside the 6 s window. READY cancels recovery ("tcp-ready") and the session is "preserved" [C]. This is the same as Path A from step 4 on: no handshake and no ack reset [C].

**What does reset state:** M15 timeout or M18 / M20 → `onConnectionChanged(NO)` → *_UNAVAILABLE → DISCONNECTED (if no other link) → M41 RECONNECTING. The next AVAILABLE then reaches `onTransportConnected` through mS:1053 [C]. In Path A, `isConnected` stays YES only until M15's 6 s deadline. But a new accept within those 6 s cancels recovery (M05), so the deadline never fires [I].

### 4.2 Mac USB

- **New input connection** (M29): cancels the old connection and replaces it. The old one's cancel → M30 end branch fails `inputConnection == connection`, so no loss event, but `onInputStreamEnded` still fires [C].
- **New READY** (M30): no identity guard. `isConnected`=YES → M30a → `onTransportConnected` **unconditionally of sessionState** when the FSM is already USB_NCM [C]. So a USB takeover does re-handshake, unlike wireless [C].
  - A stale READY (from a connection already replaced) would also fire M30a [I].
- **IP change** (M23): `bindToLocalIP` → `tearDownListeners` nils `inputConnection` and `mediaConnection` without clearing `isConnected` (mU:1225-1241) [C]. The cancelled conn's end-state then fails the identity check, so **`isConnected` stays YES with no connection** until interface loss (mU:441) [I].
- **Silent loss:** receive EOF / error (M30c) is not acted on, and USB has no heartbeat. Death is detected only if Network.framework moves the connection to failed/cancelled ([U2]), or on interface disappearance [C].

### 4.3 iPad wireless

- P25 allows a `.added` replacement during control recovery. Otherwise it dedups on `connectedServiceName` / `isConnected` [C].
- P27 READY always fires `onConnectionChanged(true)` → P15. iF mirrors the C FSM, so WIFI→AWDL and same-link are no-ops [C].
- The iPad does not need a re-handshake to keep streaming; it moves to streaming on any frame or handshake (P16 / P17) [C].
- The degraded branch on TCP failure (iW:620-626) keeps `isConnected` true, as on the Mac [C].

### 4.4 iPad USB

- Dial entry points: P40 (poll), P43 / P45 (browse / peer address), P44 (retry), P50 (`.waiting` retry), P51.
- Each creates a new `inputConnection`. READY handlers are unguarded (iU:665 / 784 / 847), so a superseded connection reaching READY sets `isConnected`=true and starts a receive loop on itself [C].
- P50 runs on main and cancels the current `inputConnection` if it is not `.ready`, which may be a newer dial than the one that was waiting [C].
- `usbInputLost` (P52) emits no FSM event, so `currentTransport` stays `usbNCM` while `isConnected`=false [C].
  - The session stays `streaming`; P15's fallback is never consulted [I].
  - Recovery is the 1 s redial (P44). If the redial succeeds, no handshake is needed on the iPad. On the Mac the new READY fires M30a → `onTransportConnected` [C].

---

## 5. Flags

### (a) Transitions with no log line

1. mS:1053-1066: STREAMING + any AVAILABLE event → silently does nothing (only the generic M35 lines) [C].
2. mW:550-553: Wi-Fi TCP media send with nil `inputConnection` → `completion(NO)`, NO LOG [C].
3. mS:2062-2068 `sendInputEventToiPad` drop; iS:1433-1442 `sendInputEventReturningLink` drop; iU / iW `sendInputEvent` with nil connection [C].
4. mU:1089-1168 USB receive EOF / error: return, no log [C].
5. mW:1306 / iU:1078 `tearDownConnections`; mU:453 / iU:449 `stopMonitoring`; mU:1225 `tearDownListeners` [C].
6. iPad LOGGER ONLY (invisible in capture):
   - scenePhase (P02), `pauseForBackground` (P07), `disconnectSession` (P10);
   - reconnect Timer schedule (P21);
   - interface-variant USB READY (P46 / P47);
   - handshake details (iS:1012) and viewport report sent (iS:1052) [C].
7. M30b / M31 / M33: Mac session-side callbacks log nothing themselves (the event shows in M35) [C].
8. M42 when superseded: the block returns silently if the state changed [C].

### (b) Async callbacks with no identity or generation guard

1. mU:1054 USB input READY (M30) [C].
2. mU:1089-1168 USB receive loops (M30c) [C]; iU:892-960 (P53) [C].
3. mW:862 DTLS media newConnection cancels the current media connection without any session match (M10) [C].
4. mW:756 and mU:1064: `onInputStreamEnded` fires before the stale check (M06, M30) [C]. If a stale conn ends while keys are held on the new one, held input is released [I].
5. iU:665, iU:784, iU:847 USB READY (P47, P49, P51) [C].
6. iU:794 `.waiting` retry cancels whichever connection is current (P50) [C].
7. mS:1638 / mS:2038 USB completion decrements `_tcpMediaSendsInFlight` with no generation check. It is zeroed at mS:1183, so it can go negative [C for code; I for occurrence].
8. M35 / P15 `handleTransportEvent`: events carry no connection id, so a late event from a dead connection is applied to the current FSM [C].
9. M38 / P18: no message-level session check for any control or handshake type (Section 3) [C].
10. iS:1070: the handshake writes `state` off main, racing main-queue writers (P09, P15, P16) [C].

### (c) Failure paths that end silently

1. **Mac reconnect timer never fires** (M42, mS:3626).
   - [C]: an `NSTimer scheduledTimer…` is created on S, a plain GCD serial queue with no run loop (mS:511-512).
   - [I] from logs: at 01:43:58.736 the log shows `"Reconnection attempt 1 in 0.5s"`. RECONNECTING then held until `RECONNECTING -> STOPPED` at 01:46:50, about 3 min, with no "attempt 2", no "Transport reconnected" and no state change. The same thing happened at 02:26:46 → 02:28:30.
   - Every recovery from RECONNECTING in the log came through M35 instead (for example 01:56:30 → 01:56:36).
   - The latency probe NSTimer (M46, mS:2774) has the same defect but is a no-op.
2. The iPad reconnect Timer is one-shot (P21, iS:1479): one `startTransportMonitoring` and no reschedule [C].
3. P06: streaming with no transports → reconnecting with no timer [C]. P09 only acts in `.connecting`, so nothing drives this state out except transport events [I].
4. The takeover stall (Section 4.1, pairs T1-T3). The ack gate has no escape and mS:1053 skips the reset [C]. In the observed case (pid 98733) it lasted until the agent was stopped, about 2 min 40 s [I, log].
5. USB receive EOF / error on both sides (M30c, P53) [C].
6. P52 `usbInputLost` emits no FSM event [C].
7. iQ:1114-1124 iPad keychain `SecItemAdd` results are ignored [C].
8. Wi-Fi TCP input `.waiting` (P27) logs only. The 3 s watchdog P35 is the only exit [C].

### (d) State set on one path and never reset on another

1. `_viewportReceived` (mS:3078): YES only, never reset across sessions, reconnects or `stop` [C]. A new iPad session can skip the HEVC restart (mS:3096) or start the encoder at a stale viewport in onTransportConnected [I].
2. Wireless `isConnected`: kept YES on the degraded paths (mW:776-788, mW:1110, mW:1356) and on duplicate-replace (mW:664). It is cleared only by M15 timeout, M18, M20 or a non-degraded M06 [C].
3. USB `isConnected` after `bindToLocalIP` (mU:945 → mU:1225-1241): not cleared [C].
4. Ack gate `_wifiAckLastSentSeq` advances for unsent frames (mS:1888). It is reset only at mS:1124 / mS:1193 [C].
5. `_tcpMediaSendsInFlight` zeroed (mS:1183) while old completions are still outstanding [C].
6. iPad `currentTransport` stays `usbNCM` after `usbInputLost` (P52) [C].
7. Pairing reset (M52) deletes the pin while live sessions continue [C]. The next TLS verify on reconnect fails until pairing completes [I].
8. iPad `tcpBuffer` is shared across successive connections and cleared asynchronously in teardown (iU:1078ff, iW:1081ff) [C]. Bytes from an old connection can prefix a new one [I].

### (e) Unknowns

- **[U1]** Does the Mac pin read (mW:197-209, mU:228-240, no `kSecUseDataProtectionKeychain`) reach the item that mP writes to the data-protection keychain? It works in practice: the log shows `"Certificate verify: peer cert fingerprint matches stored -- trusted"` [I]. The mechanism is unknown. *Resolve:* SecItemCopyMatching probe with and without the flag, or Apple docs on macOS keychain fallback for apps with keychain-access-groups.
- **[U2]** Does an NWConnection / nw_connection over USB NCM move to `failed`/`cancelled` after a receive EOF or error when the code does not cancel it? *Resolve:* a device run with logs on USB unplug and agent kill, watching M30 / P49 state lines.
- **[U3]** Does a brief USB unplug always kill TCP (open in `tla/PLAN.md`)? *Resolve:* the same device run with sub-second unplugs.
- **[U4]** When, if ever, does the Mac tear down the DTLS media connection after the iPad dies? UDP gives no signal; the candidates are DTLS alert, ICMP, or never. This decides whether Path A's degraded state can persist past the iPad's death. *Resolve:* log the DTLS state after an iPad app kill.
- **[U5]** Can the S-queue NSTimer ever fire (for example if S work happens to run on the main thread)? The logs show it did not in 2 long RECONNECTING windows. *Resolve:* code inspection is enough to model it as "never fires"; confirm by logging in the block.
- **[U6]** The iPad's queue for `handleSessionHandshake` on USB versus wireless (IUT vs IT), and whether SwiftUI observation of `state` tolerates off-main writes. *Resolve:* `dispatchPrecondition` logging.
- **[U7]** iPad log timestamps. The T1 correlation in Section 4.1 rests on 21 × 8 s timing arithmetic, not timestamps. *Resolve:* add a timestamp to `[CONSOLE]` prints, or rerun the takeover repro with both logs captured. Not blocking.
