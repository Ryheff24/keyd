# CURRENT

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
