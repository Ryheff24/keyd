# RemoteDesktop end-to-end model plan (2026-10-29)

The goal is to model every lifecycle on the iPad (client), on the Mac (host), and across the boundary
between them. TLC checks bounded instances. TLAPS proves the safety invariants end to end. Method:
`METHOD.md`.

## Lifecycle inventory `[C]` (read from source on 2026-10-29)

### Mac host

| id | lifecycle | source | states / events |
|---|---|---|---|
| H1 | session | `macOS/App/SessionManager.h:16-21`, `.m:378-627, 897-917, 3044-3106` | AWAITING_PERMISSIONS → AWAITING_PAIRING → CONNECTING → STREAMING ↔ RECONNECTING → STOPPED; reset pairing → AWAITING_PAIRING |
| H2 | pairing | `macOS/Pairing/PairingManager.m:76-142, 428-846, 1015-1080`; QR window `SessionManager.m:509-620` | identity loaded; QR shown/hidden; listener open/closed; active pairing connection; stored peer fingerprint |
| H3 | transport FSM + fallback | `macOS/Transport/TransportFSM.c`; `SessionManager.m:737-790` | IDLE, USB_NCM, WIFI, AWDL, DISCONNECTED × 9 events; immediate fallback re-injects WIFI/WIRED events |
| H4 | media pipeline | `SessionManager.m:2610` (viewport), capture and encoder start/stop, `revertDisplayMode` | encoder deferred until the viewport report arrives; capture runs only while streaming |
| H5 | input | `InputInjector.m`, `InputSender.swift` | **Implemented 2026-11-15** to `InputPath.tla`: seq guard, release on connection end, release-only `HELD` resync, iPad-side cancel, silence deadline, release on stop. Hardware E2E (Wi-Fi, run e304223): 12/12 input tests pass with real CGEvents into an agent-owned test window (click, keys+shift, double-click, drag, right-click, scroll phases, Unicode text, `HELD` release, stale seq dropped, Mac-driven repeat); iPad event → Mac app median 6.8 ms, p95 24.5 ms. Not exercised on hardware: the silence deadline (a live link keeps resetting it) and loss/relaunch release |
| H6 | permissions | `SessionManager.m:483-506` | Accessibility / Screen Recording granted, or revoked while streaming |

### iPad client

| id | lifecycle | source | states / events |
|---|---|---|---|
| C1 | session | `iPadOS/App/SessionManager.swift:16-21, 170-400` | awaitingPairing → connecting → streaming ↔ reconnecting → disconnected; connecting timeout → awaitingPairing |
| C2 | pairing | `iPadOS/Pairing/QRPairing.swift` | scanned; Mac fingerprint pinned; client identity stored |
| C3 | transport FSM + fallback | `iPadOS/Transport/TransportFSM.swift:58-130`; `SessionManager.swift:568-630`; peer address update `:431` | same table as H3, a separate implementation |
| C4 | scene phase | `iPadOS/App/RemoteDesktopApp.swift:20-34` | active / inactive / background → pause and resume |
| C5 | decode and render | `SessionManager.swift:668-909` | first frame → streaming |

### Across the boundary

| id | protocol | properties |
|---|---|---|
| B1 | first pairing (QR or USB) | only the owner's iPad becomes paired; no private key on the wire; the listener exists only while the QR is shown |
| B2 | connect handshake | mutual TLS (pinned) → session handshake → viewport report → encoder start → frames |
| B3 | transport agreement and failover | both sides converge on the same best available link; USB unplug falls back to Wi-Fi or AWDL |
| B4 | input delivery | input reaches CGEvent only from the paired peer, only while streaming, in order |
| B5 | teardown | stop or reset releases capture and the encoder, reverts the display mode, and closes every listener |

## Owner decisions (2026-10-29)

- **Pair over USB only.** QR pairing over Wi-Fi is gone from the design. It stays in the model only as
  the as-built config and as controls.
- **Daily use moves back and forth between USB and Wi-Fi.** The worst bugs in the past were state bugs
  in transport switching: Wi-Fi→USB, wireless↔wireless (Wi-Fi↔AWDL, network change), wireless↔wired
  and wired↔wired (re-plug, NCM address change). B3 is therefore the next model, and it must cover
  every one of those transitions in both directions, on both sides at once, with messages in flight.

## Status

| module | TLC | TLAPS |
|---|---|---|
| `Pairing.tla` | `make pairing`: 10/10 rows. The design passes; as built, Outside pairs in 3 steps (open window → connect → accept); each control fires | `make pairing-proofs`: 41/41 obligations; control (no USB, no confirm) 1/41 unproved |
| `SecureSession.tla`: the abstract security lifecycle (pairing as a proved assumption, pin check then readiness on every link, link drops seen per side, non-atomic revocation, re-pairing, input and control to the Mac, frames and control to the iPad). It covers safety only, with no progress and no real transport FSMs yet | `make secure`: 22/22 rows (MaxConn 3, MaxEpoch 1). The design passes (14,798,876 states). As built: Outside's input acted on, plaintext test traffic, leaks, and frames still sent after "Pair iPad" revokes the pin. Witnesses: owner input is acted on over a session opened after a used session's link dropped, in each direction (wired→Wi-Fi, Wi-Fi→wired, Wi-Fi→AWDL, AWDL→Wi-Fi, re-plug) | `make secure-proofs`: 80/80 obligations for any MaxConn and MaxEpoch; each of 6 controls fails at exactly its mechanism's steps (`proof-steps.py`) |
| `TransportAgreement.tla` (B3, H3, C3): both transport FSMs as built, the session-layer fallback, the USB peer-address update, each side noticing link changes on its own schedule, messages queued on connections that can die, plugs, unplugs, Wi-Fi/AWDL changes and USB address changes. Convergence is stated at rest (`Rest == ~ENABLED SysNext`) under bounded flapping, with `<>[]Rest` checked under weak fairness of the system | `make transport`: 22/22 rows. The design passes every property (56,715 states at 4 flaps; also 6 flaps, MaxGen 3, MaxAttempts 2). As built: 6 switching bugs (table below). Witnesses: the design settles in good order across wired→Wi-Fi, Wi-Fi→wired, Wi-Fi→AWDL, AWDL→Wi-Fi, re-plug, and re-plug onto a new address. Each of 4 mechanisms has a control | `make transport-proofs`: 329/329 obligations for any bounds: `LabelsMatch` (exact link, AWDL apart from Wi-Fi), `StreamOnlyWithRoute`, `CodecMatches` hold at every step. Controls RouteResync, DerivedState fail at exactly their steps. Convergence is TLC only |
| `DeltaSync.tla` (H4 x C5, 2026-11-15): lossless XOR-delta frames over USB TCP; serial compressor (T1), reliable ordered TCP (T2), garbage persists until a keyframe (T3). Found from a garbled picture: the Mac dropped compressed deltas when more than 5 USB sends were in flight (`SessionManager.m` USB send branches), 11,000 drops in one run | `make delta`: 7/7 rows. Design (`GateBeforeCompress`, never drop after compression) passes. As built violates `NoCorruption` (also with periodic keyframes) and `QueueIsChain`; no gate and no drop violates `QueueBounded`; the gate alone suffices; witness delivers. Code: `ScreenCapture.shouldCompressFrame` gate at 2 in flight, drops removed. **Reconnect added 2026-11-16** (USB replug showed ~5.5 s black: deltas compressed before the new connection, the switch keyframe among them, went over AWDL): T4 a reconnect strands the old link's queue; `KeyOnConnect` (forced keyframe at USB input ready, `FrameCompressorState.force_keyframe`) and `DropOldLink` (the iPad drops LZ4 arriving on wireless) — `make delta`: 11/11 rows, the reconnect design passes, as built and each control violate `NoCorruption`. Mac also compresses LZ4 only while USB is connected | none (not a security lifecycle). Receiver-side skips (`LZ4: skipping frame`) are not modelled |
| `StripeSync.tla` (H4 x C5, 2026-11-15): striped parallel LZ4 over the DeltaSync path; serial frames on each end (S1), all stripes in one in-order payload (S2), disjoint byte ranges (S3), wrong base or missing stripe is garbage (S4). Motivated by 49 ms single-threaded compress on heavy frames (1% low 29 fps at 52cd800) | `make stripe`: 6/6 rows. Design (K stripes, `MacJoin`, `IpadJoin`) passes; as built (K = 1) passes. No Mac join violates `NoCorruption` and `MacRefUniform`; no iPad join violates `NoTornPublish`; witness publishes. Code: `dispatch_apply` (Mac) and `concurrentPerform` (iPad), both synchronous joins | none (not a security lifecycle). GPU tile/dirty-mask variant not modelled |
| `FrameRing.tla` (C5 x C6, 2026-11-15): iPad present path; decode upstream always advances the reference (R1), one producer and one consumer under one lock (R2), GPU completes in order (R3). Motivated by RENDER-CADENCE at d328f4f: display link on time (120 ticks/s, late ~0) but ~18 ticks/s get 2+ frames, so newest-wins drops them (pacing CV 0.53) | `make frame`: 7/7 rows. Design (4-slot ring, `WaitForGPU`, `Fifo`, K = 2 drain) passes; shipped `QCap = 1` (FR-newest, newest wins on the ring) passes. FIFO `QCap = 2` raised glass median 23-27 → 30 ms at c7db83b and was backed out. As built (one texture) violates `NoWriteWhileRead`; no GPU wait violates `NoWriteWhileRead`; no drain violates `BoundedBacklog`; newest-first violates `InOrder`; witness shows a frame | none. Zero-copy decode into a slot not modelled (separate run) |
| `Framing.tla` (input path, 2026-11-15): iPad → Mac messages on one TCP connection; TCP delivers in order but cuts regions anywhere (F1); one connection, fresh buffer (F2) | `make framing`: 4/4 rows. Design (length prefix, buffer keeps the partial tail) passes. As built (region = message) violates `NoTornMessage`; dropping the tail violates `AllDelivered`; witness dispatches | none |
| `KeyCustody.tla` (2026-11-15): who can sign as the Mac the iPad pins; discharges SecureSession A5's precondition. File modes enforced (K1), /tmp writable by any account (K2), Secure Enclave keys not exportable and usable only by the access group (K3) | `make custody`: 6/6 rows. Design (Secure Enclave, no file, **no fallback: failure state**, owner decision 2026-11-15) passes, and with the Secure Enclave unavailable it fails closed and never pairs. As built (/tmp p12) violates `OnlyAgentSigns`; a 0600 file in ~/Library violates it; a file fallback violates it; witness pairs. Pairing state (shared secret, pinned iPad fingerprint) moved to the same data-protection keychain group 2026-11-15. Checked on hardware: E2E `sec-identity-secure-enclave` (iPad's pinned fingerprint = Secure Enclave self-test fingerprint); an ad hoc copy without the entitlement gets -34018, never serves, shows the menu-bar failure | none |
| `InputPath.tla` (H5, 2026-11-15): iPad keys/buttons → Mac CGEvents across link switches, drops (abrupt or half-open, each side noticing on its own schedule), iPad relaunch, iPad-side cancels (resign active, presses/touches cancelled) and agent stop. TCP per link (I1), late detection (I2), authorization is SecureSession's (I3), sessions do not interleave on the Mac (I5, timing), heartbeat period < silence deadline (I6, timing) | `make input`: 9/9 rows. Design (`<<session, seq>>` guard, release-all when any input connection ends, release-only `HELD` on every connect and switch, `HELD = {}` on iPad-side cancel, Mac silence deadline while anything is held, release on stop) passes (41,621 states; 1.59M states at 3 keys, MaxSeq 6 before cancel/deadline were added). No seq guard violates `InOrder`; no release on loss violates `HeldNeedsLink`; no resync violates `NoStuckKey` (Mac has not noticed the old link died); no cancel sync violates `NoStuckKey`; no stop release violates `StopReleasesAll`; no deadline violates `DeadLinkReleases` (liveness, half-open link); witness holds a key. Accepted costs: a press racing a `HELD` can be lost; any link loss releases keys held through the other link | none |
| `SessionLanes.tla` (H1 x H4 x H5, 2026-11-15): which Mac queue runs what. Realtime input (pointer, key, probe, clock sync, keepalive, test control) on the transport queue T; session work (FSM, handshake, encoder and capture start, viewport, mode change) on one serial session queue S; injector queue J. Motivated by hardware LANE-BLOCK holds on Wi-Fi T at 558ac03: viewport 323 ms, media-ready capture 102 ms, mode change 47 ms, during which pointer moves waited (input-during-reconfig p95 79.9 ms). Assumes T and J serial and FIFO (L1-L2), a hop preserves order (L3), media-ready may be stale when S runs it (L4) | `make lanes`: 10/10 rows. Design (forward every non-realtime message and transport callback to S in order; media-ready registered once and re-checked on S against `_awaitingMedia` and an atomic `mediaChannelReady`) passes (110,752 states). As built (everything on T) violates `RTNotBehindHeavy`; keeping control inline violates it too; a naive one-shot hop loses capture (temporal); no once violates `CaptureAtMostOnce`; no fresh check violates `CaptureOnlyWhenReady`; concurrent S violates `CtlInOrder`; concurrent J violates `RTInOrder`; witness streams. **Implemented 2026-11-15** (02f587c, bc6e7d8): `SessionManager.routeInputFromTransport`, `onSession:`, `mediaChannelReadyOnSession`; `WirelessTransport.mediaChannelReady` (atomic, cleared at every media-connection change); `startAdvertising`/`beginReconnectWindow` hop to the Wi-Fi queue. Hardware (Wi-Fi): pointer moves during eco on/off wire+queue p95 79.9 → 3.6 / 2.9 ms, max 103 → 12.6 / 13.9 ms; the viewport (304-344 ms), media-ready (99-119 ms) and connection holds now show on S, Wi-Fi T holds ≤ 3.9 ms. Not discharged: `stop`, `resetPairing` and the permission timer still touch session state from main, not S; non-realtime and realtime messages no longer keep their relative order; `REQUEST_KEYFRAME` runs on S | none (TLC only; scheduling, not a security lifecycle) |
| `PairingPersistence.tla` (C1 x C2, 2026-11-15): does the iPad keep its pairing while the Mac is unreachable, and reconnect by itself. Found on hardware 22:38: the Mac agent was down ~8 s, the iPad's connecting timeout deleted its client key and the Mac's pin, the owner had to re-pair (the Mac still said paired). Only the owner, a new pairing or the timeout change credentials (P1); discovery can stall silently (P3) | `make persist`: 5/5 rows. Design (`KeepCreds`: the timeout never deletes credentials; `RestartOnTimeout`: it restarts USB monitoring and Bonjour browsing and re-arms) passes. As built and the forget control violate `CredsOnlyOwnerForgets`; no restart loses `Reconnects` after a stall (temporal); witness streams. **Implemented 2026-11-15**: `SessionManager.swift startConnectingTimeout` | `make persist-proofs`: 42/42 obligations; control (no KeepCreds) fails at exactly the Timeout step |
| `TransportConnections.tla` (wireless lane of 4a, 2026-11-15): which link a wireless connection rides, whether silence is noticed, whether the iPad redials. Found on hardware 22:50-22:57 (USB→Wi-Fi unplug showed nothing): one dial raced en0 and awdl0, the Mac kept awdl0, both sides labelled it Wi-Fi (awdl0 reports type wifi), the AWDL link went quiet without an error, both sides stayed streaming 113 s until TCP timed out, then the iPad never redialled (an `.added` seen while connected is never replayed; a running browser is never restarted). Candidates in any order (W1), silent links (W2), TCP timeout not fair (W3), heartbeat time (W4) | `make conn`: 15/15 rows. **Revised 2026-11-16 to AWDL first** (user decision): on infrastructure the iPad's receive holds two ~100 ms windows every 512 TU (37-45% of the time, with or without our peer-to-peer), capping ~40 fps; pinned to AWDL 18%, then the product policy (5dd5a0f) 14%, 53.6 fps, g2g 52/100/60 ms. Design now `OneLink` (one link per dial) + `AwdlFirst` (AWDL unless the last loss or failed dial was on AWDL, then infrastructure; READY clears it), property `PreferAwdl`; the 2026-11-15 infrastructure-first build is the `AwdlFirst` control; witness reaches the fallback; test-mode `AwdlPin` (`--awdl-only`) rows. Original design (`InfraFirst`: dial infrastructure only, AWDL only after an infrastructure dial failed; `ExactLabel`: AWDL by interface name; `SilenceDetect`: 1 s heartbeat both ways, 4 s deadline; `RedialOnLoss`: a restart replaces the running browser) passes (671 states; 3,951 at 4 silences, 5 flaps). Four as-built rows reproduce the four defects (`PreferInfra`, `LabelExact`, `DetectDeadline`, `Recovers`); each control violates exactly its property; witness streams. **Implemented 2026-11-15** (iPad and Mac `WirelessTransport`, `KEYDRD_LINK_HEARTBEAT` 0x31, immediate fallback passes the real link). Hardware: unplug hands over to Wi-Fi in 0.4 s at ~55 fps, standby link on en0, heartbeats both ways; replug back to USB, also from a session started on Wi-Fi | `make conn-proofs`: 47/47 obligations for any bounds; controls OneLink and AwdlFirst fail at Dial, ExactLabel at Establish, SilenceDetect at Tick. iPad AWDL dial: peer-to-peer on, infrastructure Wi-Fi interfaces (path monitor + Bonjour result) prohibited. USB unplug/replug onto AWDL checked on hardware 2026-11-16: standby link awdl0, unplug hands over to AWDL, replug forced keyframe 13 ms after USB ready, then ~108 fps |
| `WiFiSendLoop.tla` (Wi-Fi HEVC send loop, 2026-11-16): what gates encoding and what it counts. As built the gate counts nw send completions, which fire when the kernel takes the bytes (run 8148018: p50 1 ms after submit; the iPad's last byte p90 161 ms, max 794 ms after completion), so the real queue sits in the socket buffer unseen; post-encode drops leave seq gaps, each asks for a keyframe; the stall reset zeroes the count without draining and asks again; the iPad asks once per recovery, never retries. FIFO reliable TCP (S1), kernel takes bytes while its buffer has room (S2), bounded holds (S3), encoder depth P (S4), reset timing unfair (S5) | `make sendloop`: 10/10 rows. Design (`AckGate`: the iPad acks each frame, cumulative seq 0x32, the Mac encodes only while unacked < 3; `NoPostDrop`; `NoBlindReset`) passes (435 states; 1,127 at L=3, SockCap 6). As built: `QueueBounded` (socket queue past the gate), `NoGap`, `OneKeyframe` (two IDRs queued), `Flows` (a lost IDR leaves the iPad waiting while P frames flow). Each control violates exactly its property; witness shows frames. **Implemented 2026-11-16** (Mac `SessionManager.m` ack gate, scheduler sleeps skipped under the gate; iPad acks on the transport queue before decode) | `make sendloop-proofs`: 117/117 obligations for any bounds (keyframe bound on ghost `kq`, which TLC checks against the real count); controls AckGate, NoPostDrop, NoBlindReset fail at exactly Capture/EncodeOut/Deliver, EncodeOut, StallReset |
| `WiFiRateControl.tla` (Wi-Fi adaptive rate loop, 2026-11-16): under the ack gate every gate hold counted as a pre-encode drop, so the 1 s controller saw severe congestion each window and latched 30 fps (capture too: `applyWiFiAdaptiveRateTargets` sets `captureFPS`) / 5 Mbps for all of run cfe6597, while the link moved 36 Mb/s on big frames; 598 of 980 delivery gaps were link holds on small frames, whatever the bitrate. Holds in any window (H1), overload causes holds (H2), bounded capacity changes (H3). A first design followed half the ack-measured delivery rate; run ddfd000 refuted its premise (the estimate tracks capacity): after link holds frames arrive at burst speed, samples read 40-460 Mb/s, the bitrate ran 20-30 Mbps and fps fell 40 -> 29. | `make ratecontrol`: 7/7 rows. Design (`IgnoreHolds`: bitrate steps toward a fixed target T = 10 Mbps, overload absorbed by the gate; `KeepFps`: 60 fps under the gate) passes (120 states; 576 at N=8). As built: `FpsKept`, `Settles` (latched at the floor). Each control violates exactly its property; witness settles above the floor while the link holds. **Implemented 2026-11-16** (`evaluateWiFiAckRateControlNowUs`, `WiFi ack rate:` log) | `make ratecontrol-proofs`: 19/19 obligations; control KeepFps fails at exactly Window |

## Findings from the GPT 6.1 sol review (2026-10-29), checked against code `[C]`

Report: `.planning/research/keyd-refresh/05-gpt-review-pairing-and-wire.md`. Each point below was
re-read in the source before it was accepted.

| finding | evidence | where it goes |
|---|---|---|
| "Pair iPad" deletes the pin and leaves open sessions running; revocation is not atomic | `SessionManager.m:510-512`; `PairingManager.m:847-864` | **Modelled**: `Revoke` no longer closes sessions; `EpochGuard` is the fix; `SE-asbuilt-revoke` shows the bug |
| `stop` never closes the pairing listener or its connection | `SessionManager.m:391-420` | code fix (B5); `HostSession.tla` |
| Pairing receive callback has no generation or current-connection check | `PairingManager.m:632-715` | `Pairing.tla`: split `Accept` into receive and complete, add a `CurrentConnGuard` switch |
| Input receive passes raw TCP regions to the parser, with no length framing | `USBNetworkTransport.m:1089-1112`, `WirelessTransport.m:982-1006` | **Fixed 2026-11-15**: `Framing.tla` (`make framing`), 4-byte BE prefix on the iPad (`sendInputEvent`), per-connection reassembly on the Mac (`Shared/framing.h`). Cross-connection order: `InputPath.tla` |
| Production DTLS sets minimum TLS 1.3; the negotiated DTLS version is unverified | `WirelessTransport.m:230-234` | `[U]`, check on device; media UDP is gated off today |
| Keychain write results are ignored on both sides | `PairingManager.m:874-883`, `QRPairing.swift:1038-1070` | code fix; `Pairing.tla` iPad persistence |
| The Mac's receive path hands bytes to one dispatcher with no session identity; control messages (resolution change, viewport, clock) act with no pin or epoch check | `SessionManager.m:665, 2376-2409, 2650, 2785, 2930` | **Modelled**: control is delivered and guarded like input (`Deliver`); code fix is to carry connection id and epoch into the dispatcher |
| USB receive callbacks have no current-connection check and process content before looking at cancellation | `USBNetworkTransport.m:1091`; wireless has one at `WirelessTransport.m:988` | code fix, same guard |
| Pin check and readiness are separate callbacks; a revocation can land between them | `USBNetworkTransport.m:251` (verify), `:1027` (ready) | **Modelled**: `MacReady` is its own step; the epoch is taken at the pin check |
| Proof controls accepted any failed obligation, and later an error in another file | `Makefile`, `proof-steps.py` | **Fixed**: controls must fail at named steps; any other error, or a count mismatch, is BACKEND |
| TLC rows reported an early progress count, not the final state count | `Makefile` `tlc_rows` | **Fixed** |
| `NeverSwitched` was met by two simultaneous connections | `SecureSession.tla` | **Fixed**: switching witnesses need a link drop first |
| The pairing theorem assumes its key predicates (`Reach`, `ConfirmOK`) | `Pairing.tla:109-128` | these are deployment obligations, see below |

**Deployment obligations for USB-only pairing** (what makes `Reach(A) = FALSE` true in code). The
pairing listener is bound to the USB NCM interface (`nw_parameters_require_interface`), not `::`.
Every accepted pairing connection is re-checked to be on that interface. The listener exists only
while the pairing window is open. Code that does not meet all three cannot cite `PairingProofs`.

## Transport switching (2026-10-30)

### As-built switching bugs `[C]`, each a TLC counterexample

| bug | code | row |
|---|---|---|
| First launch on USB alone never connects: the iPad dials only a stored link-local address, which it learns over Wi-Fi | `iPadOS/Transport/USBNetworkTransport.swift:388-480` (`:406`) | `TA-asbuilt-no-addr` |
| The Mac's USB address differs from the stored one (re-plug, or since the last session): a failed connect is never retried and nothing re-learns the address; a connect still *waiting* is re-dialled every 0.5 s to the same address | `USBNetworkTransport.swift:670-686` | `TA-asbuilt-addr-change` |
| A quick re-plug between polls kills the USB TCP connection with no FSM event and no retry; the session stays off USB with the cable in. Whether a brief unplug always kills TCP is `[U]` | iPad USB loss `USBNetworkTransport.swift:672-675`; polling `:337, :401` | `TA-asbuilt-replug` |
| The USB interface appearing switches the codec to LZ4 before any USB connection exists; if the connection never comes, the Mac sends LZ4 over Wi-Fi | `macOS/App/SessionManager.m:745, :822` | `TA-asbuilt-codec`. **Partly fixed 2026-11-16**: LZ4 is compressed only while USB is connected (`shouldCompressFrame`), the iPad drops LZ4 arriving on wireless (`DeltaSync` DropOldLink), and USB input ready switches an active HEVC encoder to LZ4 (RouteResync at that event; seen: HEVC sent over USB after an iPad relaunch because the FSM already read USB_NCM). The interface-appear label itself is unchanged |
| Labels drift: interface appearance labels USB before a connection; fallback always fires Wi-Fi availability (AWDL shown as Wi-Fi); USB input loss fires an untagged DISCONNECTED | `SessionManager.m:648, :768`; `iPadOS/App/SessionManager.swift:589` | `TA-asbuilt-labels` |
| The Mac's session stays STREAMING with no route: after the USB label is taken, `WIFI_UNAVAILABLE` is ignored and no reconnect starts | `SessionManager.m:737-795` | `TA-asbuilt-idle` |

### Found in the GPT review, checked in code `[C]`, not yet in a model

| finding | code | where it goes |
|---|---|---|
| **The iPad's 8 s connecting timeout resets pairing** and returns to the QR screen. With USB-only pairing, any connect slower than 8 s (slow Wi-Fi TLS, USB with no stored address) forces re-pairing over the cable | `SessionManager.swift:111, :344-360` | **Done 2026-11-15**: `PairingPersistence.tla` (TLC + TLAPS) and `startConnectingTimeout` keeps credentials and restarts discovery |
| A failed iPad USB input connection clears `isConnected` only if there is no media connection, so the iPad keeps routing to a dead USB; the failed branch has no current-connection check | `USBNetworkTransport.swift:672-675` | **Fixed 2026-11-16** to match `TransportAgreement` T7: `usbInputLost` (current connection only) drops the DTLS media socket, clears `isConnected`, redials every 1 s while the cable is in; a retry left `.waiting` (refused) is cancelled and redialled; media handlers check identity. Found on hardware: after a Mac agent restart the iPad sent its viewport report into the dead USB connection, the Mac never started encoding (black). Now: agent restart with the cable in, last frame to new keyframe 1.76 s, on USB |
| The Mac's USB READY callback has no current-connection check (its loss branch has one): a late READY of a replaced connection marks USB connected and starts the session handshake on the current pointer | `macOS/Transport/USBNetworkTransport.m:1023-1031` | next model; composition with `SecureSession` (connection identity) |
| Wireless control (TCP) and media (DTLS) fail separately; a TCP failure with media alive keeps `isConnected` and suppresses the disconnect event | `macOS/Transport/WirelessTransport.m:716`; `iPadOS/Transport/WirelessTransport.swift:507` | partly: `TransportConnections` ends a *silent* control connection on both sides within 4 s; the control-recovery grace (6 s with media alive) is still unmodelled |
| Delayed handshake or geometry from the old channel can overwrite newer geometry | `SessionManager.swift:989, :1223` | next model (versioned messages) |
| **Wireless takeover keeps the old session (hardware, 2026-11-16 02:35):** a new iPad instance connected over awdl0 while the Mac streamed to a dead instance on en0. The Mac took over the connection but sent no handshake and kept the ack gate (unacked 5, never acked), so it dropped every capture; the iPad sat in connecting with heartbeats flowing. Restarting the agent recovered. Any takeover of the wireless connection must restart the session on it (handshake, ack-gate reset, keyframe) | macOS `WirelessTransport.m` accept/takeover, `SessionManager.m` onTransportConnected | next model: `TransportConnections` (takeover as a new Establish that must re-handshake) or `SessionLanes` |
| Eco mode runs HEVC on USB by request | `SessionManager.m:2818` | intentional; excluded by assumption T6 |

### Design mechanisms, as code obligations

Code that does not meet these cannot cite `TransportAgreementProofs` or the design rows.

- **DerivedState.** Each side computes its transport state, HUD label (the exact link: USB, Wi-Fi
  or AWDL, from the live connection's path) and session reaction from its *current* live
  connections after every callback. No event-fed FSM is kept beside them. A callback from a
  connection that is not current is ignored.
- **RouteResync.** One serial queue owns the route. In the same handler that changes it, the Mac
  sets that route's codec and re-sends the session handshake on the new route. The model makes
  this one atomic step (T8). The code obligation is a linearization point: every frame carries
  the route and configuration generation it was encoded for, and is dropped if that generation is
  no longer current.
- **IpadResync** (found by TLC on 2026-10-30: the viewport report went out on a dead USB the iPad
  had not yet noticed, and the Mac never learned the viewport). When the iPad's route changes
  mid-session, it re-sends its viewport report on the new route.
- **AddrOnLink.** The iPad learns the Mac's current address on the USB link itself, and retries
  while the cable is in. A candidate is DNS-SD scoped to the NCM interface index (publish, browse
  and resolve on that interface). Whether that works over this NCM deployment is `[U]`: check it
  on the device. The model abstracts discovery as one step that cannot fail (T8).
- **Composition with SecureSession (next model).** Every routed send and every accepted callback
  maps to one current connection id, its authenticated peer and a permitted pairing epoch. This
  holds through buffering, replacement, revocation and resumption. Channel availability alone
  never discharges authentication.

Review reports: `.planning/research/keyd-refresh/07-gpt-review-transport.md`. Accepted and fixed
in the model: exact labels (AWDL apart from Wi-Fi); a fresh handshake and the viewport required at
rest; the scenario rows' wording; the scope assumptions T6-T8; `proof-steps.py` labelling a failure
in an unnumbered step (`<1> QED`) by the numbered step above it (now labelled `<1>QED`).

**Still open in the models:** the iPad's own pairing and persistence states; device versus
credential identity (today the Mac generates the client key); TLS resumption policy (A5); a
refinement from `Pairing` into `SecureSession`'s `PairMac` (TLAPS); the connection layer under
`TransportAgreement` (connection identities, control and media failing apart, framing, the iPad's
timeout and background lifecycle) and its composition with `SecureSession`.

## Modules (built in this order)

1. **`Pairing.tla`** (B1, H2, C2). Done (see Status). Design: `USBPairing`, `CloseWithWindow`,
   `ClientKeygen`, `SingleAttempt`, `ConfirmOnMac`.
2. **`Channels.tla`** (layer 2): the public-Wi-Fi contract with `Outside`, plus weakness controls.
   `Pairing` is then restated over it.
3. **`TransportFSM.tla`**: the shared table, plus a conformance script against the C and Swift
   implementations.
4. **`TransportAgreement.tla`** (B3, H3, C3). Done (see Status and Transport switching). The
   liveness question is answered: as built, no. After the USB label is taken, a wireless loss is
   ignored, and the session can sit STREAMING with no route (`TA-asbuilt-idle`).
4a. **`TransportConnections.tla`** (next): refines the channels of `TransportAgreement` into
   connection identities, with control and media separate, whole-message framing as an explicit
   mechanism, the iPad's connecting timeout and background lifecycle, and the map from each
   connection to `SecureSession`'s authenticated session and epoch. TLAPS for the authorization
   invariants across that map.
5. **`HostSession.tla`, `ClientSession.tla`** (H1, H4-H6, C1, C4, C5).
6. **`EndToEnd.tla`**: the composition, with invariants `InputOnlyFromPaired`,
   `InputOnlyWhileStreaming`, `EncoderOnlyAfterViewport` and `StopReleasesAll`, and liveness at
   `Quiet`. **`EndToEndProofs.tla`** is the TLAPS safety proof of the composition.
7. **Trace validation** of a recorded E2E run against `EndToEnd.tla`.
