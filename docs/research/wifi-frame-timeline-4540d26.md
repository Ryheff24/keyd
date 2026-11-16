# Wi-Fi per-frame timeline: first run (4540d26, 2026-11-15)

Instrumentation: Mac `FT-M` lines (SessionManager.m `ft_mac_record`) and iPad `FT-I`/`FT-IRX` lines
(Protocol.swift `FrameTimeline`), joined on capture `ts_us`. Analysis script:
`RemoteDesktop/scripts/ft_analyze.py MAC_LOG IPAD_LOG` (pass an iPad log cut to the sustained window to scope it).

Run: canonical Wi-Fi E2E, verified infrastructure link (`PEER-ADDR=…%en0`), Continuity left on.
Result: 27.0 fps overall, sustained window 17.3 fps. **Network conditions were poor and not caused by
the stream:** with no stream running afterwards, Mac→router ping averaged 45 ms (max 514 ms) and
Mac→iPad 100 ms (max 463 ms), against router medians of 6–7 ms earlier the same day. The building
network is shared and its 5 GHz channel is crowded. One run only; repeat before generalising.

All figures below are the 90 s sustained window (2,453 iPad frames) unless noted.

## Where stalls start

iPad frame-completion gaps ≥ 50 ms, classified by comparing each gap with the Mac's timing for the same frames:

| Class | Count | Meaning |
|---|---:|---|
| link-bigxfer | 149 | Mac submitted on time; the next frame's own transfer (first→last byte at iPad) took most of the gap |
| link-queue | 111 | Mac on time; the previous frame was already ≥ 50 ms late (standing queue) |
| link-hold | 86 | Mac on time; no queue, small frame, bytes simply stopped arriving |
| mac-capture | 60 | Capture timestamps themselves had the gap (adaptive fps cuts / pre-encode drops) |
| mac-encode | 10 | Encoder output gap |
| mac-scheduler | 5 | Scheduler sleep before submit |

- **Every one of the 382 presentation gaps ≥ 50 ms follows an arrival gap.** None start in the renderer.
- 864 of 2,453 frames were replaced before presentation; 757 of those had the next frame arrive within 8.3 ms (burst delivery).
- Mac encode-output → submit: p50 0.1 ms. Scheduler sleeps reach 45 ms on ~10% of frames but explain only 5 gaps.

## The amplifier: a recovery spiral that builds a seconds-long queue

Excess one-way delay (Mac submit → iPad last byte, relative to its floor) in the sustained window:
p50 171 ms, p90 803 ms, max 2.9 s. Idle pings never exceeded ~0.5 s, so most of that is queue the
sender builds, not the radio alone.

The per-second series shows the cycle:
1. Delivery slows (hold or low throughput).
2. The Mac's in-flight gate saturates → backpressure drops (`D`, 327 in the run) → keyframe requests;
   the iPad's recovery path also requests keyframes (44).
3. Keyframes are large (median 84 KB, p90 177 KB vs 2.7 KB median P-frame). Bad seconds carry 2–4 keyframes.
4. Stall recovery resets the in-flight count and generation without draining TCP (`X` completions: 126),
   so new frames are admitted behind seconds of old data.
5. Excess delay climbs to 1–2.9 s; the iPad shows 3–7 frames/s until the queue drains.

Calm seconds (e.g. 10 s, 44 s, 80–84 s) deliver 59–61 frames with excess delay p50 3–73 ms.

Big frames (≥ 100 KB) arrived at an effective p50 7 Mb/s (p10 2 Mb/s), measured first→last byte at the iPad.

## Secondary

- iPad complete → decode submit: p50 6.4 ms, p99 85 ms, max 141 ms (reassembler/queue hop). App-side; not yet investigated.
- TCP receive-callback silences ≥ 50 ms on the iPad: 463 in 90 s, max 2.06 s.

## Implication

The initiating impairment is the network path (bad tonight, independent of our load). The app turns
each impairment into a multi-second stall: TCP keeps stale video in order, and the recovery path adds
keyframes and admits more data into an undrained queue. Fixes that address this, in order of evidence:
stop the keyframe/queue spiral (bounded queue age, coalesced recovery, no gate reset without a drain),
then deadline-aware media transport (see `wifi-stutter-research.md` step 5). Loop/lifecycle changes go
through TLA+ first.
