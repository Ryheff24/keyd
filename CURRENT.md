# CURRENT

## Lane A Iteration 17 (Reconnect/liveness silent-stall guardrails)

- Timestamp: 2026-04-04 12:26:10 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" -only-testing:RemoteDesktopAgentTests/TransportNetworkTests -only-testing:RemoteDesktopAgentTests/TransportFSMTests test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - targeted transport tests ✅ (`52 tests, 0 failures`)
  - note: full macOS test run in this environment still reports pre-existing unrelated failures in compression/pairing/pipeline suites; reconnect-focused transport suites are green.
- Hypothesis: session can remain nominally connected while DTLS media silently dies (or stale callbacks race current state), leaving a 0fps wedge unless transport explicitly forces lifecycle recovery.
- Instrumentation/behavior added:
  - iPad `WirelessTransport`:
    - Added `handleActiveMediaPathLoss(...)` recovery path with explicit observed/ignored/recovery logs and state fields.
    - Active DTLS `.failed/.cancelled` now route to recovery only for active media connection; stale callbacks remain ignored.
    - Recovery clears stale TCP/media/session latch state, emits `onConnectionChanged(false, wasAWDL)`, then schedules browser restart.
  - macOS `WirelessTransport`:
    - Added `handleActiveMediaPathLossWithReason(...)` recovery path with explicit observed/ignored/recovery logs.
    - Active DTLS `.failed/.cancelled` and active media receive errors now force reconnect lifecycle (clear active input/session state, emit disconnect callback, restart listener when appropriate).
    - Preserved stale callback protections for DTLS/TCP state + receive callbacks.
    - Input receive EOF/error now logs and cancels active connection to ensure deterministic state transition instead of lingering stale-active state.
    - Media receive loop explicitly treats DTLS `is_complete` as datagram boundary (not close) and keeps receive loop armed.
- Next move: orchestrator E2E should confirm that when media path wedges, logs show `media path loss recovery triggered ... -> forcing reconnect` and stream re-establishes instead of persisting silent 0fps.
- Remaining reconnect/liveness risk:
  - Moderate residual risk remains for failures below NWConnection callbacks (e.g., no state/error callback from framework while link is unhealthy); this iteration closes explicit stale-callback and active-media-loss wedges but does not add synthetic heartbeat probes.

## Lane C Iteration 17 (Wi‑Fi TCP in-flight stall recovery hardening)

- Timestamp: 2026-04-04 12:25:23 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests -destination "platform=macOS,arch=arm64" -only-testing:RemoteDesktopAgentTests/TransportFSMTests test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - targeted macOS transport FSM tests ✅ (32 passed, 0 failed)
- Hypothesis: Wi‑Fi pre-encode gate can deadlock source feed when TCP in-flight accounting remains saturated after stale/failed send paths, causing prolonged 0fps starvation despite renderer queue being empty.
- Instrumentation/behavior added (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added Wi‑Fi TCP stall detector + bounded unwedge:
    - Detect sustained saturation + no-completion dwell (`kWirelessTCPStallSaturationThresholdMs`, `kWirelessTCPStallNoCompletionThresholdMs`).
    - Recover via guarded in-flight reset + generation bump (`wifiTCPSendGeneration`) with cooldown (`kWirelessTCPStallRecoveryCooldownMs`) to prevent flapping.
  - Hardened completion path accounting:
    - Ignore stale completions from pre-recovery generation (`WiFi TCP stale completion ignored`).
    - Clamp underflow if decrement goes negative and log explicit error branch.
    - Track last valid completion timestamp to drive stall causality.
  - Added explicit stall observability without hot-path spam:
    - `WiFi TCP saturation enter|observe`, `WiFi TCP stall recovery hold`, `WiFi TCP stall recovery`.
    - Added `tcpStallRec` counter to 1s `WiFi perf` line.
  - Kept adaptive behavior conservative after recovery:
    - post-recovery hold window (`kWirelessTCPPostRecoveryAdaptiveHoldMs`) blocks immediate healthy upshifts to avoid burst/oscillation rebound.
  - User floor preserved:
    - all adaptive logic still enforces `kWirelessAdaptiveMinFPS = 30` and this patch does not reduce below floor.
- Expected effect on sustained-stream collapse/stutter:
  - Prevent long source-starvation plateaus caused by stuck in-flight saturation.
  - Restore forward progress after stalled send accounting while keeping bitrate/FPS recovery smooth and continuity-first.
- Residual risk:
  - In-flight reset may briefly over-admit before transport naturally re-stabilizes; mitigation is generation guard + recovery cooldown + post-recovery adaptive hold.
  - If underlying transport repeatedly fails completions at high rate, collapses may recur but now should surface as explicit `stall recovery` telemetry instead of silent starvation.

## Lane A Iteration 16 (Reconnect callback stale-guard hardening)

- Timestamp: 2026-04-04 12:05:53 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" -configuration Debug build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" -configuration Debug build`
- Result:
  - iPadOS build ✅
  - macOS build ⚠️ blocked by pre-existing compile error in untouched file: `RemoteDesktop/macOS/Transport/USBNetworkTransport.m:597` (`sampledEntryLog` undeclared)
- Hypothesis: restart churn can still surface stale Network.framework callbacks from superseded media/input connections; without explicit stale callback guards those callbacks can race current session state and produce reconnect instability.
- Instrumentation/behavior added:
  - iPad `WirelessTransport`:
    - Added active-media guards for DTLS `.ready/.failed/.cancelled` with explicit stale-vs-active branch logs.
    - Added stale callback guards in `scheduleMediaReceive` and `scheduleInputReceive` to drop superseded callbacks safely, with concise completion/error logs.
    - Active DTLS failure/cancel branches now explicitly clear `mediaConnection` to avoid stale session residue.
  - macOS `WirelessTransport`:
    - Added active-media guards for DTLS `.ready/.failed/.cancelled` with explicit stale-vs-active logs.
    - Added stale callback guards in media/input receive loops (`scheduleMediaReceive`, `scheduleInputReceive`) to prevent stale receive completions from mutating live session assumptions.
- Next move: orchestrator reconnect churn validation should confirm stale callback logs appear only during teardown/replacement windows and no false disconnect transitions (`onConnectionChanged(false, ...)`) occur while the active path remains healthy.
- Remaining reconnect risk:
  - Low-to-moderate residual risk remains around higher-level cross-transport timing during USB↔WiFi transitions, but direct wireless reconnect lifecycle surfaces now have explicit stale guards on both state and receive paths.

## Lane A Iteration 15 (Reconnect churn hardening)

- Timestamp: 2026-04-04 11:53:05 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination "platform=macOS,arch=arm64" -quiet build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -configuration Debug -destination "generic/platform=iOS" -quiet build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests -configuration Debug -destination "platform=macOS,arch=arm64" -only-testing:RemoteDesktopAgentTests/TransportFSMTests -quiet test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - targeted transport FSM tests ✅
- Hypothesis: transient `.failed/.cancelled/.removed` churn can still trigger avoidable teardown/reconnect loops if one channel flaps while the other remains healthy, or if listener cancellation occurs unexpectedly during restart churn.
- Instrumentation/behavior added:
  - iPad `WirelessTransport`: guarded TCP `.failed/.cancelled` teardown so active media path does not emit false disconnect; explicit branch logs for preserve-vs-teardown outcomes with state fields.
  - macOS `WirelessTransport`: explicit advertising intent latch (`_advertisingRequested`) to distinguish expected listener cancellation from failure; restart on unexpected idle cancellation and detailed success/failure/skip logs.
- Next move: orchestrator reconnect churn run should verify no false `onConnectionChanged(false, ...)` during healthy media continuity and confirm listener restart only fires when advertising is expected and session is idle.

## Lane C Iteration 15 (Wi‑Fi anti-oscillation + render catchup hysteresis)

- Timestamp: 2026-04-04 11:51:10 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" -derivedDataPath .build/DerivedData build`
- Result:
  - macOS build ✅
  - iPadOS build ✅
- Hypothesis: 1s Wi‑Fi controller is still over-correcting (60/6 ↔ 45/30 thrash) and renderer soft/hard catchup is too eager, causing stale-frame drop churn that hurts 1% lows.
- Instrumentation/behavior added:
  - macOS Wi‑Fi adaptive controller now uses hysteresis streak gates (`healthyStreak`, `mildStreak`) before up/down changes.
  - Upshift strategy made gentler (fps +5 step, bitrate +125kbps step, longer recovery hold) to reduce burst/backpressure re-entry.
  - Adaptive apply now smooth-clamps per-interval deltas and logs `requested` vs `applied`, `prev`, `smoothDelta`, and `floorGuard` status.
  - Explicit 30fps floor guard engagement logging/counters retained and surfaced in 1s perf line with streak context.
  - iPad renderer catchup now requires deeper + sustained queue delay before soft catchup (depth>=3 + delay streak), with higher delay thresholds and branch logs including streak/depth gates.
- Next move: orchestrator Wi‑Fi full-profile run should verify fewer adaptive flips, reduced renderer stale-drop churn, improved 1% low/maxGap, and no floor violations below 30fps under load.

## Lane C Iteration 16 (Wi‑Fi stutter + 1% low stabilization, non‑E2E)

- Timestamp: 2026-04-04 12:04:39 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData build -quiet`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" -derivedDataPath .build/DerivedData build -quiet`
- Result:
  - iPadOS build ✅
  - macOS build ❌ blocked by pre-existing unrelated compile error in `RemoteDesktop/macOS/Transport/USBNetworkTransport.m` (`sampledEntryLog` undeclared, line 597)
- Hypothesis: sustained-stream tail collapse is primarily controller/renderer oscillation (aggressive upshifts + depth-trigger hard catchup), not packet loss; constraining Wi‑Fi operating envelope and requiring stronger catchup evidence should lift 1% low and reduce stutter while preserving >=30fps floor.
- Instrumentation/behavior added:
  - macOS `SessionManager` Wi‑Fi adaptive loop tightened for anti-oscillation:
    - Baseline/cap narrowed to stability operating point: `55fps / 3.5Mbps` start, cap `55fps / 5.0Mbps` (floor unchanged at 30fps).
    - Recovery/upshift made more conservative: hold `3600ms`, healthy streak `5`, mild streak threshold `3`, fps upstep `+3`, bitrate upstep `+100kbps`.
    - Smooth upshift clamp tightened to `+3fps / +100kbps` per apply.
  - iPad `MetalRenderer` catchup refined so depth alone no longer repeatedly forces hard stale drops:
    - Hard catchup now requires sustained hard-delay streak (>=2 ticks over 58ms), with effective disable of depth-only hard trigger.
    - Soft catchup requires deeper persistence (delay threshold 32ms, streak 3).
    - Added hard-delay trigger/streak telemetry to dequeue branch and render dequeue logs.
  - Hot-path log spam reduced while preserving signal:
    - Wi‑Fi TCP send queued log sampling relaxed (every 30, not every 10).
    - Slow completion logs sampled with forced logs for severe/failure (`elapsed>=45ms` or failure).
    - Normal completion logs sampled every 80 with forced failure logging.
- Next move: have orchestrator run canonical Wi‑Fi full profile and compare against iter15:
  - `adaptive[...] up/down/hold` churn rate,
  - `tcpSlow`/`tcpMaxCompletion` tails,
  - renderer `catchup-hard-*` vs `catchup-soft-*` frequency and stale-drop totals,
  - sustained 1% low / maxGap movement with floor maintained >=30fps.

## Lane B Iteration (USB copy-churn + stall telemetry)

- Timestamp: 2026-04-04 11:12:06 EDT
- Command:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination "platform=macOS,arch=arm64" build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -configuration Debug -destination "generic/platform=iOS" build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests -configuration Debug -destination "platform=macOS,arch=arm64" test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - macOS tests: 1 failure (`TransportNetworkTests/testConnectionDropDetection` timeout), unrelated to touched USB code paths.
- Hypothesis: USB regression still has residual copy/allocation churn on iPad decode ingress and overly chatty success logs on macOS USB send completions that can hide slow-send outliers.
- Instrumentation/behavior added:
  - iPad receive pipeline now avoids `subdata` copy before decode (passes payload offset/length through to HEVC/LZ4 decoders).
  - iPad USB frame pipeline sampled telemetry: `USBTransport: frame-pipeline ... decodeMs=...`.
  - macOS USB send success logs now sampled + slow-path forced logging (`elapsed >= 12ms`) for both full-frame and split-send paths.
- Next move: orchestrator USB run should check for lower decode-path allocation pressure and use new sampled logs to confirm whether remaining stalls are send-completion (mac) vs decode/render (iPad).

## Lane C Iteration (Wi‑Fi backpressure hole mitigation)

- Timestamp: 2026-04-04 09:46:31 EDT
- Command: `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData build && xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -configuration Debug -destination "generic/platform=iOS" -derivedDataPath .build/DerivedData build`
- Result: macOS + iPadOS builds ✅
- Hypothesis: Wi‑Fi TCP media backpressure drops create irrecoverable ordered sequence holes; those holes force iPad recovery waits for keyframe and inflate p95 tails / 1% low stalls.
- Instrumentation/behavior added:
  - Wi‑Fi pre-encode gate for TCP media path: drop before encode when `tcpInFlight >= limit` (prevents creating encoded frames that will immediately be dropped in send path).
  - Wi‑Fi TCP send-drop branch now logs action and cooldown state, and requests immediate HEVC keyframe on drop with cooldown guard.
  - 1s Wi‑Fi perf telemetry extended with `tcpDropKeyReq` and `tcpDropKeySupp`.
- Next move: run orchestrator Wi‑Fi loop and confirm reduced `WiFi TCP backpressure drop` + `UDPReassembler entering recovery` pairing frequency, with improved p95 pipeline/glass tails and higher 1% low.

## Lane A Iteration (Reconnect lifecycle hardening)

- Timestamp: 2026-04-04 03:07:00 EDT
- Command: `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" -configuration Release clean build && xcodebuild -workspace RemoteDesktop/RemoteDesktop.xcworkspace -scheme RemoteDesktopApp -destination "id=00000000-0000-0000-0000-00000000000A" -configuration Release clean build`
- Result: macOS + iPadOS builds ✅
- Hypothesis: reconnect instability risk remained in wireless advertise/browse lifecycle when listener/browser failures happen off the happy path; add guarded recovery + explicit branch logging.
- Instrumentation/behavior added:
  - macOS WirelessTransport: active-listener-aware failed/cancelled logs with connection state, explicit active listener nil-ing, and safe advertising restart (only when disconnected and still active/stale-safe).
  - iPad WirelessTransport: explicit logs for duplicate `startBrowsing`, active-vs-stale browser failure branch, stopBrowsing entry/exit context, TCP cancel exit state.
- Next move: run orchestrator reconnect/run-apps validation and confirm listener restart path appears only on failure and duplicate browse attempts remain benign.

## Lane B Iteration (USB hardening)

- Timestamp: 2026-04-04 02:19:10 EDT
- Command: `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData build && xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -configuration Debug -destination "generic/platform=iOS" -derivedDataPath .build/DerivedData build`
- Result: macOS + iPadOS builds ✅
- Hypothesis: harden USB TCP framing safety and improve USB receive-loop failure observability without changing wire behavior.
- Instrumentation added:
  - iPad USB media receive: explicit error/complete branch logs + counters.
  - iPad USB TCP receive: explicit error/complete branch logs + counters + buffer/readOffset context.
  - Mac USB TCP sends: explicit oversized payload guard logs before 32-bit length framing.
- Next move: validate new USB logs under orchestrator-run traffic to confirm whether failures are transport-close churn vs parse/backlog pressure.

## Active Objective

- Lane: wifi (lane C Objective-C)
- Goal: reduce persistent Wi-Fi tail latency/jitter and stabilize FPS pacing without running E2E in this loop.

## Latest Run

- Timestamp: 2026-04-04 01:49:10 EDT
- Command: `xcodebuild -workspace keyd.xcworkspace -scheme KeydAgent -configuration Debug -destination 'platform=macOS' build`
- Notes: lane-C Wi-Fi bottleneck iteration only; E2E script intentionally not run per constraint.
- Result: macOS build ✅

## Instrumentation Added This Iteration

- Surface touched:
  - `RemoteDesktop/macOS/App/SessionManager.m`
- New log signals:
  - `WiFi TCP send queued: seq=... inFlight=... bytes=...`
  - `WiFi TCP backpressure drop: seq=... inFlight=... limit=... totalDropped=...`
  - `WiFi TCP send slow completion: seq=... success=... elapsed=...ms inFlightNow=...`
  - `WiFi TCP send completion: seq=... success=... elapsed=...ms inFlightNow=...`
  - Expanded 1s telemetry: `tcpInFlight`, `tcpInFlightPeak`, `tcpSlow`, `tcpMaxCompletion`
- Why needed: existing logs showed encode is mostly ~11ms while iPad pipeline p95 is ~155ms, indicating likely queue buildup in Wi-Fi TCP send path; new counters isolate kernel-send backlog and completion tails.

## Key Metrics (Latest)

- External evidence used (no new E2E run):
  - iPad: sustained/fps/pacing/pipeline/glass failures with p95 pipeline ~155-156ms and jitter ~28ms.
  - Mac: `encodePixelBuffer: SKIPPED frame (pending=2)` observed; final skip counter `4`.
  - Mac: repeated `LATENCY-PROBE encode-complete: ~11ms` indicates encode itself is not dominant tail contributor.
- Build status:
  - macOS `KeydAgent`: **BUILD SUCCEEDED**

## Current Hypothesis

- Dominant residual bottleneck for lane C is Wi-Fi TCP send-queue tailing (in-flight backlog/completion delays), not pure encode cost.
- Unbounded/weakly bounded Wi-Fi TCP media in-flight depth likely converts transient link variance into long queueing delay, inflating p95 pipeline/g2g and causing low 1% FPS.

## Next Change

- Run next Wi-Fi validation loop externally and triage:
  - whether `tcpInFlightPeak` clips at 3,
  - whether `tcpSlow`/`tcpMaxCompletion` correlate with pipeline p95 spikes,
  - whether `tcpSendDrop` reduction/increase aligns with 1% low FPS and jitter movement.

## Validation Plan

- Do not run E2E script in this lane.
- Use orchestrator-provided Wi-Fi test run and compare:
  - iPad: sustained/fps/frame-pacing/pipeline/glass metrics,
  - Mac: `WiFi TCP send*` and `WiFi perf 1s` TCP fields.
- Confirm no reconnect/security regressions and that latency/FPS move in expected direction.
