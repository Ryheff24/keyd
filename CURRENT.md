# CURRENT

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
