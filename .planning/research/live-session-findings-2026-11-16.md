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
