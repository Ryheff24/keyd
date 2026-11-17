# Live session findings (2026-11-16, run-apps, real screen)

The user drove a live session (real SCStream, AWDL, two USB plug-ins, two backgrounds) and
reported: slow handshakes and plug-in, a visible stutter at each switch, a soft picture, a
"5 fps" HUD that lies, Magic Keyboard trackpad gestures not reaching the Mac, sluggishness even
on USB, and lasting poor performance after backgrounding. Logs:
`scratchpad/live/keyd-run-{mac-oslog,ipad}.log` (copied from `/tmp/keyd-run-*`).

## 1. USB plug-in takes ~20 s: both apps wait for IPv4 link-local
macOS system log, second plug-in:

| time | event |
|---|---|
| 17:08:50-52 | USB attach (usbmuxd, Ethernet transport published) |
| 17:08:54.27 | `en13` link ACTIVE, **IPv6 link-local ready** (`RTADV en13: link-local address is ready`) |
| 17:08:54-17:09:11 | DHCP INIT retries (1.9, 2.0, 4.9, 8.7, 8.4 s back-off), no server |
| 17:09:13.40 | **IPv4 169.254.191.26 assigned** (`LINKLOCAL en13`) |
| 17:09:13.64 | agent `USB NCM interface detected` (getifaddrs, IPv4 only) |
| 17:09:14.77 | handshake + LZ4 key on USB |

19 s of the plug-in is DHCP giving up before IPv4 link-local. Both sides key the USB link on a
169.254 address. Using the IPv6 link-local (`fe80::%enN`, ready 0.2 s after link-up) would
remove it. The iPad also dials the previous plug's stale Mac address first (cancelled, then
redials). Unplug is fast (loss noticed, AWDL handshake in ~0.1 s).

## 2. Backgrounding pins the session to infrastructure Wi-Fi
After the last background the session dropped and redialled over **infrastructure Wi-Fi**
(Mac `PEER-ADDR=...%en0`, `Transitioned to: Wi-Fi`), the link with the 512 TU receive holds.
Rule in force (TransportConnections.tla): after a loss on AWDL the next dial is infra, and
READY clears the flag. There is no path back up to AWDL once on infra, so one background
means the rest of the session runs on the worse link. Cascade is meant to be USB > AWDL >
infra (last resort).

Also without any background: E2E 68e521e's first AWDL dial hit the 3 s connect watchdog
(`dial=awdl -> next=infra`), and the whole main test (182 of 230 s) ran on `%en0` at 35.4 fps.
The old suite passed `transport-wifi`; `e2e_strict.py` flags it. Same missing climb-back.

## 3. Stutter at each switch to HEVC: first keyframe fails to decode
USB -> AWDL after a background: the first HEVC key (seq 11728) is refused by
`VTDecompressionSessionDecodeFrame` (status goes to os_log only; not visible), FrameLoop
AwaitOnFail drops the next 10 deltas and re-asks; the next key arrives 546 ms later. Same
after the reconnect (seq 12023 -> 12041). Fits iPadOS invalidating the hardware decoder
session while backgrounded. Fix: on a session-invalid status rebuild the session and resubmit
the same keyframe at once (and print the status in `[CONSOLE]`).

Startup: capture waits for the DTLS media channel (~2 s after the handshake) though media
goes over TCP; the HEVC encoder start blocks the S lane ~1 s.

## 4. The HUD fps counts arrivals; a static screen reads as "5 fps"
`computedFPS` = frames received over the last 60 timestamps. SCStream sends only changed
frames, so an idle desktop gives 3-12 arrivals/s (RENDER-CADENCE `arrivals0` 110-118 of 120
ticks on USB) and the HUD shows a low number although nothing is wrong. Conversely a real
stall and an idle screen look the same. Needs: display rate, content-update rate, an explicit
"idle (no changes)" state from the Mac (SCFrameStatus idle), age of the shown frame, and the
link name (USB / AWDL / infra).

## 5. Pointer feels sluggish everywhere: the cursor is in the video
`config.showsCursor = YES`: every pointer move goes iPad -> Mac -> capture -> encode -> link
-> decode -> display before it shows. A local cursor drawn on the iPad (Mac sends cursor
image + position, as Phase 3's cursor overlay planned) makes the pointer immediate on any link.

## 6. Soft picture (every transport)
The Mac renders 3024x1964; the iPad panel is 2752x1786. USB is soft too: 3024 -> 2752 rescale
plus the bilinear sampler; Wi-Fi adds the 2496 encode cap and HEVC 4:2:0. SCStream rescales to the frame size
(2752 on USB, 2496x1620 on Wi-Fi under the link cap), HEVC 4:2:0 blurs coloured text, and the
iPad stretches 2496 -> 2752 with a bilinear sampler. Every step is a non-integer resample of
text. Only a matched source size fixes it properly (a Mac display mode or virtual display at
the iPad's size, 1376x893 @2x); a sharper upscale filter helps a little.

## 7. Trackpad gestures stay on the iPad
`InputCaptureView` forwards hover and two-finger scroll only. No pinch, rotate, smart zoom or
three-finger swipes are forwarded; iPadOS system gestures (app switcher, multitasking) are
owned by the system and cannot be fully taken. A feature, not a regression (Phase 3 input).

## 8. Tests and metrics miss all of this
The E2E streams an always-moving synthetic video, so it never sees an idle screen, the cursor
path, a plug-in, a background, link pinning, or sharpness. It needs scenario tests with
honest numbers: time from cable attach to first USB frame; fps and link for 30 s after a
background/foreground; link stays AWDL; pointer latency (input -> frame showing the move);
text sharpness vs source (PSNR/SSIM on a text scene); HEVC first-key decode failures.

## Strict whole-run baseline (`scripts/e2e_strict.py`, canonical capture video, Wi-Fi)
Every second of the run, no exclusions, against the METRICS goals:

| run | worst s | s < 60 fps | interval p99.9 | g2g p99.9 | capture->decode p99.9 | link | gates |
|---|---|---|---|---|---|---|---|
| 6e079b6 | 0 fps | 221/235 | 367 ms | 1137 ms | 1115 ms | awdl | 2/9 |
| 20d1ea9 | 0 fps | 210/232 | 275 ms | 752 ms | 820 ms | awdl | 2/9 |
| 68e521e | 0 fps | 229/230 | 442 ms | 1748 ms | 1655 ms | en0 182 s | 1/9 |

The Mac encodes p50 46-58 frames/s: the source is emitted at 60 fps, so the 120 fps goal is
unreachable by construction. The existing suite also passes weak checks: frame-reception on 4
frames, resolution at 0.907x scale, latency-probe at 131 ms. FT-I (per-frame iPad timeline) was
test-mode only; now always on, so manual sessions can be judged the same way.

## Ranked plan (each through the TLA+ gate where it crosses the iPad<->Mac boundary)
1. Background -> stays on AWDL and climbs back (TransportConnections: an upgrade path from
   infra to AWDL). Biggest lasting harm.
2. USB on IPv6 link-local (TransportConnections: link-up event = IPv6 LL ready; drop the stale
   peer address). Cuts ~19 s from every plug-in.
3. HEVC decoder rebuild-and-resubmit on an invalid session (FrameLoop DecodeFail variant).
4. Honest HUD (idle state from the Mac, content vs display rate, frame age, link).
5. Scenario E2E: plug-in time, background recovery, link pinning, pointer latency, sharpness.
6. Local cursor overlay.
7. Sharpness: matched-size source (Mac display mode / virtual display); needs the user's call.
8. Trackpad gestures (pinch/rotate/swipes) as Phase 3 input work.

## Background-recovery scenario (E2E phase, devicectl cycle, 15 s away, AWDL)
No UI automation: XCUITest asks for the iPad passcode on every run. The harness opens Settings
(`--payload-url prefs:root=General`) to background the app and relaunches it to resume. Calculator
does not work (it opens as a window beside ours; the app is never backgrounded). Goals are mine,
not METRICS: first frame <= 250 ms after resume; 90% of the reference rate held 3 s within 1 s;
steady >= 90% of reference. Reference = max(5 s before Home, sustained-stream average).

| run | first frame | 90% held 3 s | per-second fps after resume (first 8 s) | dial->ready |
|---|---|---|---|---|
| bg7 150e9f2 | 218 ms | 2010 ms (replayed) | 24,43,48,56,55,56,55,61 | 177 ms |
| bg8 cf8305c | 293 ms | 6602 ms (replayed) | 42,28,20,22,19,20,34,60 | 331 ms |
| bg10 0380171 | 592 ms | 592 ms | 18,56,51,51,54,54,57,57 | 569 ms |

bg8's sag was the link, not the iPad: decode stayed 6-8 ms, capture->first byte rose to 140-220 ms,
AWDL carried about 15-20 Mbps (RTT 150-225 ms) for 6 s, then 190 Mbps at 15 ms. A fresh AWDL link
at session start and after the rotation's reconnect did not do this. Settings may have opened on its
Wi-Fi page (scanning); bg8 and earlier did not pin the page. Unproven: one clean run since. The old
check ("one 1 s window at 90%") passed bg8 at 293 ms; it now must hold for 3 s.
First frame after resume = wake + 0.25 s browser-restart delay + Bonjour ~75 ms + AWDL TCP/TLS
177-569 ms + handshake + first key ~150 ms, minus the ~0.6 s between process wake and `.active`.

## AWDL ceiling (2026-11-16 evening)
Canonical run 0380171 by test phase: the 90 s heavy video on AWDL has 10 s below 30 fps, 22 s below 45,
30 s with a gap > 100 ms. The iPad radio holds packets 100-150 ms at a time (see the wifi-stutter
memory/research), and a hold is a visible gap of at least that length whatever the sender does, so
interval p99.9 <= 12.5 ms is not reachable over AWDL as the radio behaves now. Checked: Apple's
WiFiAware framework (real-time performance modes) is `@available(macOS, unavailable)` on every
symbol in the MacOSX27.2 SDK, so it is not an option for a Mac peer. USB is where the strict goals
are physically reachable; USB has not been run since 061f6a0 (2026-11-15, ~95-100 fps).

## USB: the Mac drops its own packets (2026-11-16 night; runs 85e0378, 6673290, 82059b6, f9c82b2, 7890dae)
First USB runs since 061f6a0. Strict whole-run analysis (now with nettop + interface-queue gates):
- 85e0378: 89 fps; s23-31 at 4-13 fps, frames 2.4-11 MB arriving 230-690 ms apart, link carrying 74-216
  Mb/s, then climbing back 275 -> 3622 Mb/s over 6 s (congestion-window recovery). Repeat 6673290 did not
  collapse (94 fps, interval p99.9 41.7 ms): intermittent.
- Cause, measured: the Mac's USB NCM interface queue (en13, FQ_CODEL, 2048 pkts ~ 3 MB, class BE)
  overflows: `netstat -I en13 -q` "drop overflow" 1482 packets in one control run (f9c82b2), matching
  ~2.4 MB of TCP retransmits in 118 of 233 s (nettop re-tx). "flow control: 0": the TCP flow gets no
  flow-advisory before the drop. Every drop shrinks the window; a burst of drops is the collapse.
  The iPad's advertised window is ~4 MB (nettop tx_win), more than the queue holds, and the queue
  still overflows when paced at 2.5 Gb/s, so the iPad side pauses taking packets for >10 ms at times.
- Pacing (`nw_tcp_set_max_pacing_rate`, macOS 27) is not the fix: 4000 Mb/s 1.7 MB re-tx; 2500 Mb/s
  426 queue drops (vs 1482) but mean 76 fps vs 87, g2g p99.9 141 vs 84 ms. Default left off;
  `-usb-pacing-mbps N` / harness `--usb-pacing-mbps N` for experiments.
- Fix direction: bound the agent's own TCP backlog below the queue (nw_tcp_get_available_send_buffer,
  submit large frames in pieces while unacked + piece <= budget ~1.5 MB). Send-loop change: model first.
- Also seen: a frame captured 0.45 s after Home was presented on wake 14 s later (USB, 7890dae seq 257),
  before scenePhase .active; frames older than the clock-synced present time by > ~1 s should be dropped.
- Analyser fixes: USB capture->decode used ~60 HEVC frames only (p50 "55 ms"); now LZ4 frames use the
  ready time (p50 ~10 ms). Mac encode-rate gate is n/a on LZ4/USB (no FT-M there).

## AWDL at 120 fps: the Mac's HEVC encoder is the ceiling (2026-11-16, M1 Max)

Every number below is p99.9 unless marked. Source: the scratch bench `encbench` (VTCompressionSession set up
like `HEVCEncoder.m`, fed 90 real frames from the E2E ProRes video at a fixed rate) and E2E a698b19.

- **E2E a698b19 (`--mac-default wireless-fps=120`, ack gate 5) vs fc7ad53 (60 fps):**

  | Metric | 60 fps (fc7ad53) | 120 fps (a698b19) |
  |---|---|---|
  | Frame interval p99.9 | 166.7 ms | 208.3 ms |
  | Glass-to-glass p99.9 | 510 ms | 580 ms |
  | Capture→decode p99.9 | 492 ms | 561 ms |
  | Mac encode latency p99 | 20 ms | 40 ms |
  | Ack-gate pre-encode drops | 942 | 6680 |
  | Mac encoded per second p50 | 60 | 76 |
  | Seconds below 60 fps | 218 | 79 |

  The 120 fps run had more seconds at 60 fps or better, but it is worse at every p99.9.
- **The encoder in low-latency mode (`EnableLowLatencyRateControl`) runs one frame at a time:**

  | Frame size | Max fps | Latency at 120 fps | Latency at 60 fps |
  |---|---|---|---|
  | 2752×1786 (panel) | 67–69 | 80–87 ms (queueing) | 22 ms |
  | 2496×1620 | 74–80 | 74–76 ms | 21 ms |

  None of these change it: 420 instead of BGRA input, the H.264 codec, RealTime off, ReferenceBufferCount 1,
  or MaxFrameDelayCount on or off. PrioritizeEncodingSpeedOverQuality and SpatialAdaptiveQPLevel both return
  -12900.
  Buffer properties ruled out:
  - Real 420v frames copied into fresh buffers with no attachments run at 68 fps, p99.9 80 ms.
  - Real frames with their attachments removed run at 67 fps.
  - Only synthetic noise written into 420v buffers reaches 120 fps, and tagging that noise 709 keeps it at
    120 fps.

  So encode time depends on content. Real clips at 2 s, 20 s, 35 s, 50 s and 68 s of the E2E video all run
  at 64–69 fps at panel size, and the E2E itself encoded 76 frames/s at 2496×1620.
- **Normal rate control (low-latency off):** 120 fps at panel size, but it buffers about 4 frames. Latency
  p99.9 is 45–47 ms at 120 fps and 72–81 ms at 60 fps, so it cannot be used.
- **Two low-latency sessions at once, each encoding half the frame (2752×893):** both encode engines run
  (~115 fps each), but a half frame still costs ~8.8 ms (per-frame fixed cost ~3 ms). Each half sits at its
  limit, so latency p99.9 is ~51 ms at 120 fps. Estimated best with two halves is ~113 fps; four quarters would
  be worse.
- **What this means:**
  - With HEVC low-latency on this Mac, AWDL cannot reach 120 fps at panel size. The limit is about 68 fps for
    one stream, or about 113 fps with a two-session split (protocol change).
  - What sets the p99.9 interval and glass-to-glass is still open: radio holds, resume/disconnect frames,
    and stale frames on resume are all candidates. One 120 fps run against two 60 fps runs is within run noise
    for the p99.9 rows. Encode latency, gate drops (6680 vs 942–1813) and replaced-before-present (2079 vs
    586–761) are clearly worse at 120.
  - Default stays 60. `-wireless-fps` / `-wifi-ack-gate` remain as measurement overrides
    (`run-e2e-tests.sh --mac-default KEY=VALUE`).

## AWDL p99.9 glass-to-glass: slow-link seconds, two kinds (2026-11-16)

The worst seconds by max g2g (480–780 ms) are mostly in the video phases. In those seconds the Mac encoded
only 9–20 frames, about the same as the iPad presented, so the delay is on frames that were sent, not on
frames that were skipped.

Retransmits don't explain it (`retx_align.py`, run a698b19): the worst seconds carry 0–53 KB of
retransmitted data, and seconds with no retransmit still reach 623 ms.

The Mac's `WiFi ack 1s` and `WiFi perf 1s` lines show two kinds of slow second:

1. **Oversized frames (a feedback loop):**

   | Run | Seconds | Delivered | Encoded | Gate drops | Avg frame | ack RTT avg / max |
   |---|---|---|---|---|---|---|
   | fc7ad53 | 19:46:35–37 | 17–24 Mb/s | 10–16 /s | 44–50 /s | 130–178 KB | 312–458 / 594 ms |
   | 0380171 | 19:01:03 | 70 Mb/s | 10 /s | 50 /s | 170 KB | 399 / 674 ms |
   | 0380171 | 19:02:46 | 26 Mb/s | 14 /s | 46 /s | 171 KB | 358 / 432 ms |
   | a698b19 | 20:54:09–10 | 21–25 Mb/s | 13–19 /s | 101–107 /s | 113–147 KB | 303–320 / 502 ms |

   - VT's AverageBitRate is per second. When the gate drops captures, the frames that are encoded share the
     whole 30 Mb budget, so each gets 2–3 times the normal size (normal is ~62 KB at 60 fps).
   - The gate counts frames, not bytes. Five ~170 KB frames is ~850 KB in flight, which takes ~400 ms to
     clear at ~17 Mb/s. That matches the measured ack RTT.
   - The rate controller treats gate holds as pacing (WiFiRateControl.tla), so the bitrate stays at
     30 Mbps and the loop never breaks.
2. **Link stalls with small frames:**
   - 0380171 19:03:46 and 19:03:50: 17–31 KB frames, delivery 14 Mb/s, ack RTT avg 400–642 ms, max 1.1–1.3 s.
   - a698b19 20:54:26: 50 KB frames, RTT avg 452 ms.
   - Frame size cannot fix these.

**Fix for kind 1 (needs the WiFiRateControl / WiFiSendLoop TLA+ models first):** keep each frame's size
bounded by the admitted frame rate. Lower the encoder bitrate while the gate is dropping captures, and/or gate
on bytes in flight against the measured delivery rate.

A delivery-following bitrate was rejected before (run ddfd000: radio-burst samples after holds read
40–460 Mb/s). This differs: the trigger is the gate's own drop count, and the cap is per frame.

## Congestion QP floor: E2E results, and the 1 s silences (2026-11-16)

**What the floor is:** `--mac-default wifi-congestion-minqp=30` sets the encoder's MinAllowedFrameQP from the
first ack-gate drop until the gate has admitted captures for 500 ms with no drop. On the bench it bounds
frame size (p99.9 190 → 74 KB); AverageBitRate and DataRateLimits do not bound a single low-latency frame.

**How the runs are scored:** the strict analyser now leaves the test-only `bw-probe` seconds out of every
gated number and reports them on their own line. That phase floods the media TCP connection with 64 KB
filler for 3 s; in qp30a it produced 931–997 ms g2g while TCP RTT was 11–35 ms with no retransmits.

| Run | Config | g2g p99.9 | g2g p99 | Capture→decode p99.9 | Interval p99.9 | fps/s p5 |
|---|---|---|---|---|---|---|
| 0380171 | 60 fps | 540 ms | 284 ms | 521 ms | 258 ms | 13 |
| fc7ad53 | 60 fps | 510 ms | 242 ms | 518 ms | 167 ms | 19 |
| 8c945f4 | QP floor 30 | 457 ms | 195 ms | 450 ms | 242 ms | 28 |
| 51b9edb | QP floor 30 | 499 ms | 209 ms | 500 ms | 217 ms | 22 |

**Reading:** g2g p99 is lower in both floor runs (195–209 vs 242–284 ms), and p99.9 a little lower
(457–499 vs 510–540). Two runs each is not conclusive. The interval p99.9 did not improve.

**What remains at the top of p99.9 and max:**
- The iPad receives nothing at all for 1.0–1.2 s at a time:

  | Run | Silences |
  |---|---|
  | 0380171 (baseline, no floor) | 1211, 1023, 1055 ms |
  | 8c945f4 | 1043, 1030 ms |
  | 51b9edb | 1092, 1019 ms |

- During these, frames are small (3–9 KB) and a few KB is retransmitted.
- The mechanism is unproven: a radio absence, or TCP timer recovery while only a few small frames are in
  flight. Frame size cannot fix it.

## AWDL 1 s stalls: tail loss behind a closed ack gate; fixed with a 50 ms heartbeat (2026-11-16 late)

**Evidence.** The harness now pings the iPad's awdl0 address every 100 ms during E2E
(`/tmp/keyd-e2e-awdl-ping.txt`). `e2e_strict.py` judges each iPad receive silence ≥0.5 s against the
pings, skipping windows outside ping coverage.
- **Run 8ab4123** (interactiveVideo only). Two silences, 903 ms and 1359 ms, were **TCP-only**: pings
  answered at 26–36 ms throughout.
  - At 22:17:41.75 the Mac queued five frames (~300 KB), then the ack gate stayed closed for 1.15 s
    with no app ACKs. nettop shows +16.6 KB retransmitted in that second.
  - The radio was up. A tail segment was lost while the gate was stopping all new data, so nothing
    could trigger SACK or fast retransmit. Recovery waited for an RTO or for the 1 s link heartbeat or
    latency probe, the next data on the connection.
  - Codex's review of runs bg10/qp30a/qp30b (docs/research/awdl-1s-silence-codex.md) found the same
    pattern in the reverse direction. Six silences began after all media was parsed. The stalled data
    was the iPad's frame ACKs, and the recovery callbacks were 26-byte control messages.
- **Separate effect: AWDL latency depends on load.** Ping RTT was 100–170 ms in seconds where we sent
  only 0.3–2 Mb/s, against 5–9 ms on an idle link. Correlation of ping max/s with Mb/s: −0.40 (run
  1c199bd). App-ACK RTT follows ping RTT (corr 0.59), so ack-gate depth 5 caps frame rate near 5/RTT.

**Changes**, now defaults on both sides, with overrides kept:
- `wifi-service-class` (Mac default) / `--wifi-service-class=` (iPad): **interactiveVideo**.
- `wifi-heartbeat-ms` / `--wifi-heartbeat-ms=`: **50 ms**, up from 1000. The heartbeat is the new data
  that sits behind a lost tail segment. The link quiet and lost thresholds are unchanged (2 s / 4 s).
- `wifi-disable-ack-stretching` / `--tcp-disable-ack-stretching`: added, not yet measured.
- Harness: `--ipad-arg ARG` passes extra arguments to the iPad app.

**Results.** p99.9 / max over the whole run; "excl" leaves out the deliberate-disconnect and background
windows.

| run | config | g2g p99.9 / max | interval p99.9 | >100 ms intervals | g2g worst seconds excl | fps p1 / p5 excl | silences ≥0.5 s |
|---|---|---|---|---|---|---|---|
| 1c199bd | baseline | 391 / 468 | 192 | 168 | 468, 463, 441 | 25 / 37 | 1 (no ping coverage) |
| 8ab4123 | interactiveVideo | 381 / 1409 | 167 | 79 | 1409, 1230, 393 | 22 / 45 | 2 TCP-only |
| 5fd537d | + 50 ms heartbeat | 289 / 1375 (disconnect resume) | 150 | 48 | 414, 309, 290 | 42 / 47 | 0 |
| e4143de | same (repeat) | 254 / 360 | 150 | 30 | 360, 320, 298 | 39 / 49 | 0 |
| 7bfa804 | new defaults, no overrides | 251 / 388 | 158 | 62 | 388, 334, 295 | 42 / 46 | 0 |

No second below 30 fps in any of the three heartbeat runs; baseline had 4. The single-variable effect of
the heartbeat alone (without interactiveVideo) was not run.
