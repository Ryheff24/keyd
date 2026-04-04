# CURRENT

## Lane WiFi Iteration 33 (iteration11 canonical run triage + HEVC saturation budget escalation)

- Timestamp: 2026-04-04 19:42:40 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration11 hevc pending saturation retry guard to reduce starvation tails"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metric deltas vs iteration10:
  - sustained-stream `1% low 9.2 -> 7.5` (regressed).
  - fps test `maxGap 175ms -> 242ms` (regressed tail).
  - iPad starvation signals `916 -> 443` (`starvationSignal=true`, improved count but severe tails remain).
  - HEVC saturation guard behavior: `retry=10`, `admit=1`, `skip=7` (skip count worse than iter10 skip total `5`).
- Highest-impact bottleneck evidence:
  - Saturation skips still cluster during transient burst/catch-up windows:
    - startup burst at `19:37:48` skipped 3 frames in ~31ms,
    - catch-up burst at `19:40:26` skipped 2 frames near `maxFrameKB=424` burst density `52.08x`,
    - media restart at `19:41:00` skipped 2 more frames immediately after DTLS ready.
  - Retry budget is currently too short (`2 x 800us = 1.6ms`) relative to observed encode completion windows (`13-65ms`) in these spikes, so retries often expire before pending drains.
- Hypothesis tested:
  - The current retry guard reduced starvation event frequency but still drops clustered frames when saturation persists beyond 1.6ms, creating cadence holes that worsen `1% low` and `maxGap`.
- Instrumentation + behavior change (`RemoteDesktop/macOS/Encode/HEVCEncoder.m`):
  - Added saturation branch planning telemetry:
    - `encodePixelBuffer: saturation guard branch=plan ... hitStreak skipStreak attempts sleepUs budgetUs`
  - Added adaptive retry budget escalation on repeated saturation/skip:
    - default `2` retries, escalated `6` retries when hit streak or skip streak indicates persistent pressure.
  - Expanded branch-complete logs:
    - `branch=retry` now includes `budgetUs`,
    - `branch=admit` and `branch=skip` include budget + streak context,
    - `branch=recovered` logs streak reset when pending pressure clears.
  - Preserved existing drop/skip semantics and fidelity/resolution behavior (no threshold/reporting changes).
- Validation:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination 'platform=macOS,arch=arm64' build` ✅
- Next immediate move:
  - Re-run canonical WiFi command and verify:
    - fewer clustered `branch=skip` events during startup/catch-up/restart windows,
    - more `branch=admit` recoveries under the escalated retry budget,
    - improved `sustained-stream 1% low` and `fps maxGap` without transport pressure or fidelity regression.

## Lane WiFi Iteration 32 (iteration10 canonical run triage + HEVC saturation retry guard)

- Timestamp: 2026-04-04 19:36:24 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration10 tcp completion-guard spacing to prevent saturation starvation"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs iteration9:
  - heavy-load: `fps 59.3` (`-0.3`), `pipe p95 106ms` (`+1ms`).
  - sustained-stream: `avg/1%low 57.6/9.2` (`+0.7/flat`), `pipe p95 110ms` (`+2ms`), `glass p95 133ms` (`+3ms`).
  - fps test: `avg 58.0` (`+0.5`), `jitter 22.5ms` (`flat`), `maxGap 175ms` (`+8ms` regression).
  - starvation signal: `916` events (`-16` vs iteration9 `932`) while low-FPS tails persist.
- Highest-impact bottleneck evidence:
  - TCP completion saturation hypothesis is largely resolved this run (`preDrop=0`, `tcpMaxCompletion<=29ms`, `tcpInFlightPeak=2`, no `tcp-backpressure` drops); completion guard applied once and prevented escalation.
  - Remaining stutter is upstream cadence starvation: iPad logs still show repeated `starvationSignal=true` with empty downstream queues (`rendererDepth=0`, `reasmPending=0`), so transport/reassembly is not the active limiter.
  - Mac logs show transient encoder saturation on burst windows (`encodePixelBuffer: SKIPPED frame ... pending=2`, total skipped `5`) including synthetic catch-up moments, matching starvation-like delivery holes without network pressure.
- Hypothesis tested:
  - Current highest-impact limiter is transient HEVC pending saturation during burst/catch-up windows; immediate frame skip on `pending>1` creates avoidable cadence holes that depress `1% low` and pacing even after TCP pressure is controlled.
- Instrumentation + behavior change (`RemoteDesktop/macOS/Encode/HEVCEncoder.m`):
  - Added branch-complete saturation-guard telemetry:
    - `encodePixelBuffer: saturation guard branch=retry ...`
    - `encodePixelBuffer: saturation guard branch=admit ...`
    - `encodePixelBuffer: saturation guard branch=skip ...`
  - Added bounded completion wait before skip on `pending>1` (2 attempts × 800µs) to absorb transient encoder backlog instead of immediate drop.
  - Preserved existing encode success/failure logs and skip counter semantics.
- Validation:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination 'platform=macOS,arch=arm64' build` ✅
- Next immediate move:
  - Re-run canonical WiFi command and verify:
    - lower `saturation guard branch=skip` counts and more `branch=admit` recoveries,
    - reduced starvation windows (`starvationSignal=true`) with unchanged transport loss/fidelity,
    - improved `1% low`, `frame-pacing`, and latency tails without reintroducing TCP pressure.

## Lane WiFi Iteration 31 (iteration9 canonical run triage + TCP completion-guard pacing)

- Timestamp: 2026-04-04 19:29:58 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration9 synthetic emit-accounting guard for failed frame emission"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs iteration8:
  - heavy-load: `fps 59.6` (`+0.2`), `pipe p95 105ms` (`flat`).
  - sustained-stream: `avg/1%low 56.9/9.2` (`+0.4/-0.8`), `pipe p95 108ms` (`+5ms`), `glass p95 130ms` (`+4ms`).
  - fps test: `avg 57.5` (`+0.5`), `jitter 22.5ms` (`+2.4ms` regression), `maxGap 167ms` (`better than iter8 375ms`).
- Highest-impact bottleneck evidence:
  - `/tmp/keyd-e2e-ipad.log`: starvation remains dominant (`starvationSignal=true` count `932`) while downstream remains empty (`rendererDepth=0`, `reasmPending=0`, `evicted=0`, `purged=0`) during many low-observed windows (`26–40fps` telemetry spikes).
  - `/tmp/keyd-e2e-mac.log`: synthetic emit-accounting shows no failure storm (no dominant `Synthetic timer emit failure`/partial backlog growth), but WiFi TCP path still hits transient saturation:
    - `WiFi pre-encode drop: reason=tcp-backpressure ... totalDropped=1..5`
    - paired slow completions `elapsed=36/41/47/59/79ms`
    - bursts of large payloads (`95KB`, `56KB`, `47KB`) preceding saturation.
  - Recovery spacing is underpowered in these episodes: `WiFi TCP scheduler recovery decision: branch=apply ... recoveryTarget=4500/8500us` while send gaps are already ~`12–20ms`, so delay branch often remains effectively inactive.
- Hypothesis tested:
  - Primary remaining limiter is completion-tail saturation on WiFi TCP media path; current recovery spacing is too small to prevent in-flight pileups under large-frame bursts, causing source starvation windows despite clean receive/render queues.
- Instrumentation + behavior change (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added completion-latency scheduler guard constants:
    - `kWirelessTCPSchedulerCompletionGuardModerateSpacingUs = 14000`
    - `kWirelessTCPSchedulerCompletionGuardSevereSpacingUs = 24000`
  - Added completion-guard decision branch with full apply/hold logging:
    - `WiFi TCP scheduler completion guard: branch=apply ...`
    - `WiFi TCP scheduler completion guard: branch=hold ...`
  - Guard triggers only under active pressure indicators (`inFlightBefore>=1` plus slow completions/pre-drops/max completion signals), then can override weaker spacing to keep in-flight depth from saturating.
- Next immediate move:
  - Run canonical WiFi command next iteration and verify:
    - fewer `WiFi pre-encode drop: reason=tcp-backpressure` and fewer `inFlight=3` spikes,
    - reduced starvation events with `rendererDepth=0/reasmPending=0`,
    - improved `1% low`, `frame-pacing`, and latency tails without fidelity/resolution regressions.

## Lane WiFi Iteration 30 (iteration8 canonical run triage + synthetic emit-accounting fix)

- Timestamp: 2026-04-04 19:20:21 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration8 synthetic timer catch-up after capture cadence lag"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs iteration7:
  - heavy-load: `fps 59.4` (`+0.4`), `pipe p95 105ms` (`-2ms`).
  - sustained-stream: `avg/1%low 56.5/10.0` (`-0.7/+0.8`), `pipe p95 103ms` (`-5ms`), `glass p95 126ms` (`-4ms`).
  - fps test: `avg 57.0` (`-0.9`), `jitter 20.1ms` (`-2.3ms`), `maxGap 375ms` (`+225ms` regression).
- High-signal evidence:
  - `/tmp/keyd-e2e-ipad.log`: low-FPS windows occur with empty downstream queues (`renderer depth=0`, `pending=0`, `reasm pending=0`, `evicted=0`, `purged=0`) → starvation originates upstream of iPad render/reassembly.
  - `/tmp/keyd-e2e-mac.log`: no dominant WiFi pressure during starvation windows (`tcpSendDrop=0`, `preDrop≈0`, `tcpInFlightPeak<=2` in low-encoded windows), while synthetic timer shows only small catch-up events (`backlog=2`, no capped events), indicating schedule accounting can drift from actual emitted frames.
  - Existing instrumentation: `encodePixelBuffer: SKIPPED frame` reached `total skipped=5`.
- Hypothesis tested:
  - Current highest-impact bottleneck is synthetic capture emission accounting: the timer advances schedule state even when synthetic frame emission fails, masking real undersupply and preventing backlog recovery during starvation windows.
- Instrumentation + behavior change (`RemoteDesktop/macOS/Capture/ScreenCapture.m`):
  - `_emitSyntheticFrameAtIndex` now returns success/failure; all failure exits log explicit reason (`invalid-dimensions`, `video-source-unavailable`, `create-pixelbuffer-failed`, `create-samplebuffer-failed`).
  - Synthetic timer now tracks `emit[attempts/failures/consecutive]`, logs branch-complete failure + partial-tick diagnostics, and **only** advances `frameIndex`/`_syntheticEmittedFrames` on successful emission.
  - Added recovery log when emission resumes after failures, plus stop-summary log with catch-up + emit counters for run-to-run causality.
- Validation:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination 'platform=macOS,arch=arm64' build` ✅
- Next immediate move:
  - Re-run canonical WiFi command and confirm:
    - non-zero/diagnostic `Synthetic timer emit failure` signals only when source truly fails,
    - lower starvation windows with `renderer depth=0 & reasm pending=0`,
    - improved `fps avg`, `1% low`, and `maxGap` without fidelity/transport regressions.

## Lane WiFi Iteration 29 (iteration7 canonical run triage + synthetic catch-up recovery)

- Timestamp: 2026-04-04 19:12:08 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration7 fast adaptive recovery ramp after transient completion-tail"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs iteration6 baseline:
  - Overall: unchanged pass/fail (`26/33`, same 7 failures).
  - heavy-load: `fps 59.0` (slight regression from iteration6 `59.5`), `pipe p95 107ms`.
  - fps test: `avg 57.9`, `1% low 9.2` (still poor), `jitter 22.4ms`, `maxGap 150ms`.
  - sustained-stream: `avg/1%low 57.2/9.2`, `pipe p95 108ms`, `glass p95 130ms`.
- High-signal evidence:
  - `/tmp/keyd-e2e-ipad.log`: no transport loss (`frame-loss PASS loss=0.0%`), but persistent cadence/latency failures.
  - `/tmp/keyd-e2e-mac.log`: adaptive path largely healthy (`downshift-severe-soft` once, immediate `recovery-upshift-fast`), and low-FPS windows occurred with no network pressure (`tail=0`, `tcpSlow=0`, `preDrop=0`, `scheduler delays=0`).
  - Low encoded windows (`encoded 25-49`) point to capture-side cadence undersupply during transient timer lag, not transport backpressure.
- Hypothesis tested:
  - Dominant bottleneck moved upstream to synthetic capture pacing under transient scheduling stalls; adaptive transport recovery is no longer the principal limiter for 1% low.
- Instrumentation + behavior change (`RemoteDesktop/macOS/Capture/ScreenCapture.m`):
  - Added synthetic capture schedule telemetry with explicit steady + catch-up branches:
    - `Synthetic timer steady: ...`
    - `Synthetic timer catch-up: ...`
    - `Synthetic timer catch-up capped: ...`
  - Added bounded fast catch-up emission path (`kSyntheticCatchUpBurstMax=3`) so delayed timer ticks can recover emitted-frame cadence instead of dragging multi-second low-FPS tails.
  - Added counters for emitted frames and catch-up activity; reset on start/stop for run-to-run causality.
- Next immediate move:
  - Run canonical WiFi command next iteration and verify:
    - reduced low-encoded windows without transport pressure,
    - improved `1% low` and `frame-pacing` CV,
    - no regression in latency tails, resolution, or frame-loss.

## Lane WiFi Iteration 28 (iteration6 completion-tail run triage + recovery ramp fix)

- Timestamp: 2026-04-04 19:02:59 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration6 tcp-scheduler recovery spacing under completion-tail pressure"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs prior run (iteration5 at 18:52):
  - heavy-load: `fps 55.8 -> 60.1`, `pipe med/p95 65/328ms -> 34/104ms` (improved, still fails latency targets).
  - fps test: `avg 55.4 -> 57.4`, `1% low 9.2 -> 9.2`, `jitter 26.6ms -> 22.6ms`, `maxGap 558ms -> 167ms` (tails improved, headroom still insufficient).
  - pipeline-latency: `med/p95 44/141ms -> 37/106ms` (improved, still over target).
  - glass-to-glass: `med/p95 77/159ms -> 69/129ms` (improved, still over target).
- High-signal evidence:
  - `/tmp/keyd-e2e-ipad.log`: no transport loss (`frame-loss PASS loss=0.0%`) but pacing/latency still fails (`fps avg=57.4`, `1% low=9.2`, `pipeline p95=106ms`, `g2g p95=129ms`).
  - `/tmp/keyd-e2e-mac.log` telemetry now shows completion-tail pressure is reduced versus iteration5:
    - `max preDrop=2` (was burst windows up to `47`),
    - `max tcpMaxCompletion=66ms` (was `380ms`),
    - `windows tcpMaxCompletion>=120ms: 0`,
    - scheduler still inactive (`scheduler[delays=0 ...]` throughout).
  - Adaptive controller still downshifted early (`downshift-severe-soft` to `54fps`) and climbed back slowly (`54 -> 56 -> 58 -> 60` over ~33s), aligning with persistent avg-FPS deficit.
- Hypothesis tested:
  - Primary bottleneck shifted from completion-tail meltdown to **overly conservative post-downshift recovery cadence**: transient early pressure recovers, but adaptive hysteresis/hold keeps capture below 60fps too long, depressing average FPS and latency headroom.
- Instrumentation + behavior change (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added fast healthy-recovery lane when pressure is truly clear (`inFlight=0`, `slow=0`, `maxCompletion<=16ms`, no drops, no burst-tail risk).
  - New fast recovery gates + logs:
    - `WiFi adaptive hold: reason=recovery-fast-cooldown ... metrics[...]`
    - `WiFi adaptive hold: reason=recovery-fast-hysteresis ... metrics[...]`
  - Added fast upshift reason + step:
    - `reason=recovery-upshift-fast`
    - allows up to `+4fps` smoothing step for this reason only (default remains `+2fps`).
  - Kept existing severe/mild/tail-risk paths unchanged.
- Validation:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination 'platform=macOS,arch=arm64' build` ✅
- Next immediate move:
  - Run canonical WiFi command again and verify:
    - early transient downshift recovers to 60fps faster via `recovery-upshift-fast`,
    - reduced time spent at 54/56/58fps,
    - improved `fps avg`, `sustained avg`, and latency p95 without reintroducing preDrop/completion-tail spikes.

## Lane WiFi Iteration 27 (iteration5 burst-severe escalation guard follow-up)

- Timestamp: 2026-04-04 18:54:21 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration5 burst-severe escalation guard"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Failing signals: `heavy-load`, `sustained-stream`, `fps`, `frame-pacing`, `pipeline-latency`, `glass-to-glass-latency`, `sec-identity-file-permissions` (known C3).
- Key metrics + deltas vs most recent available WiFi full run (18:44, same lane history):
  - heavy-load: `fps 58.6 -> 55.8`, `pipe med/p95 28/135ms -> 65/328ms` (regressed).
  - fps test: `avg 56.9 -> 55.4`, `1% low 10.6 -> 9.2`, `jitter 20.8ms -> 26.6ms`, `maxGap 283ms -> 558ms` (regressed tails).
  - pipeline-latency: `med/p95 28/101ms -> 44/141ms` (regressed).
  - glass-to-glass: `med/p95 50/134ms -> 77/159ms` (regressed).
  - throughput/frame-loss remained non-blocking (`2.8 Mbps`, `0.0%` frame loss).
- High-signal evidence:
  - `/tmp/keyd-e2e-ipad.log`: long-tail stalls with no transport loss (`frame-loss PASS 0.0%`) but severe pacing collapse (`frame-pacing FAIL cv=1.475`, `fps FAIL maxGap=558ms`, sustained `1% low=8.6fps`).
  - `/tmp/keyd-e2e-mac.log`:
    - repeated pressure spikes with large pre-encode drops and slow TCP completions:
      - `WiFi perf 1s ... preDrop=47 tcpSlow=7 tcpMaxCompletion=380ms`
      - `WiFi perf 1s ... preDrop=35 tcpSlow=3 tcpMaxCompletion=314ms`
    - scheduler shaping remained effectively inactive during failures:
      - `scheduler[delays=0 ... burstSends=0]` across spike windows.
    - burst escalation mostly held until pressure was already severe (`WiFi adaptive burst escalation: branch=hold ...` then delayed `branch=trigger`).
- Hypothesis tested:
  - Current dominant bottleneck is not packet loss; it is WiFi TCP completion-tail pressure causing pre-encode drop bursts and starvation gaps, while existing send scheduler spacing is too weak to engage under this workload.
- Instrumentation + behavior change (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added recovery-aware scheduler escalation branch with explicit decision logs:
    - `WiFi TCP scheduler recovery decision: branch=apply|hold ... preDrop slow maxCompletion baseTarget recoveryTarget reason`.
  - Added moderate/severe recovery spacing tiers driven by measured pressure in current 1s window:
    - moderate: `4500us` when `preDrop>0` or `slow>=2` or `maxCompletion>=45ms`
    - severe: `8500us` when `preDrop>=3` or `maxCompletion>=120ms`
  - Increased scheduler max sleep cap `4000us -> 9000us` so recovery spacing can actually apply.
  - Kept existing drop/error/success path logs intact (`pre-encode drop`, `send queued`, `send slow completion`, `backpressure drop`) for causality.
- Validation:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination 'platform=macOS,arch=arm64' build` ✅
- Next immediate move:
  - Re-run canonical WiFi command and verify:
    - scheduler recovery branches activate during pressure windows,
    - `scheduler[delays]` becomes non-zero when `preDrop/tcpMaxCompletion` spikes,
    - reductions in `preDrop` burst windows and tail metrics (`fps maxGap`, sustained `1% low`, pipeline p95) without resolution/fidelity changes.

## Lane WiFi Iteration 26 (orchestrator run blocked at iPad launch tunnel/provider failure)

- Timestamp: 2026-04-04 18:39:33 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration3 build-watchdog diagnostics"`
- Pass/Fail:
  - Build blocker cleared (`e2e-ipad-build success attempt=1`), but run blocked before `[TEST]` execution during iPad launch.
- High-signal evidence:
  - `/tmp/e2e-results.log`: `=== [6/6] Launching iPad in test mode ===` then `=== Waiting for test results (timeout: 360s) ===` with no `[TEST]` lines.
  - `/tmp/keyd-e2e-ipad.log`:
    - `CoreDeviceError Code=1002 "No provider was found."`
    - `Network.NWError error 32 - Broken pipe`
- Hypothesis tested:
  - The dominant blocker moved from iPad build destination timeout to transient CoreDevice tunnel/provider failure during `devicectl device process launch`, and missing launch-failure detection causes timeout-only verdicts.
- Instrumentation + behavior change (`RemoteDesktop/scripts/run-e2e-tests.sh`):
  - Added `e2e-ipad-launch` branch-complete telemetry:
    - `entry` (attempt/device/profile/rotation),
    - `success` (attempt/pid/probeSec),
    - `failure` (reason/probeSec),
    - `decision` (retry/no-retry + wait),
    - `exit` (failed/retry-exhausted).
  - Added bounded iPad launch retry (2 attempts) for transient `broken-pipe` / `no-provider` failures.
  - Added active wait-loop early-abort branch when iPad launch stream dies before `[TEST] COMPLETE`, with reasoned diagnostic output.
- Outcome:
  - Improved blocker-layer observability and recovery without touching test thresholds/assertions/reporting semantics or streaming fidelity.
- Next immediate move:
  - Let current orchestrator run finish; then use the same canonical WiFi command in the next iteration to validate launch retry behavior and recover `[TEST]` execution so WiFi stutter/bitrate bottleneck work can resume.

## Lane WiFi Iteration 25 (orchestrator run blocked at iPad build destination timeout)

- Timestamp: 2026-04-04 18:33:19 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: baseline stutter+bitrate investigation for >=45fps no res loss"`
- Pass/Fail:
  - Blocked before `[TEST]` execution (Step `[1/6]` build stage failed on iPad destination availability).
- High-signal evidence from `/tmp/e2e-results.log`:
  - `xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available`
  - `{ platform:iOS, arch:arm64, id:00000000-00000000000000A2, ... error: ... may need to be unlocked ... }`
- Hypothesis tested:
  - Current highest-impact bottleneck for this iteration is harness/device-prep instability (destination availability timeout), which prevents collecting WiFi stutter/bitrate metrics at all.
- Instrumentation + behavior change (`RemoteDesktop/scripts/run-e2e-tests.sh`):
  - Added branch-complete iPad build telemetry with stable events:
    - `entry` (attempt/device/derivedData)
    - `success` (attempt)
    - `failure` with `destinationTimeout=true|false`
    - `decision` (`retry` vs `no-retry`, reason)
    - `exit` for retry-exhausted / non-timeout failures
  - Added one bounded retry path for destination-timeout failures (10s wait, attempt 2) while preserving existing failure semantics if retry also fails.
  - Appended retry boundary markers into iPad build log for causality across attempts.
- Outcome:
  - Unblocked observability for intermittent destination-timeout prep failures without touching test thresholds/assertions/reporting semantics.
- Next immediate move:
  - Re-run the same canonical WiFi command and use new build-branch telemetry to verify whether destination timeout self-recovers; if build proceeds, resume WiFi stutter/bitrate bottleneck work from `[TEST]` + iPad/Mac logs.

## Lane WiFi Iteration 24 (burst-density starvation correlation + adaptive burst guard)

- Timestamp: 2026-04-04 17:30:55 EDT
- Commands:
  - Baseline: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: burst-density starvation correlation"`
  - Validation: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate burst/starvation fix"`
- Pass/Fail:
  - Baseline: `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Validation: `[TEST] COMPLETE: 26/33 passed, 7 failed`
- Hypothesis tested:
  - Long-tail stutter is dominated by burst-density arrival starvation (transport->decode side), not renderer dequeue policy.
- Instrumentation added/refined:
  - `RemoteDesktop/iPadOS/App/SessionManager.swift`
    - Added `frame-arrival` correlation logs with `seqDelta`, `interArrival`, `payload`, renderer pending/depth, UDP reassembly pending/ooo, and explicit `starvationSignal`.
  - `RemoteDesktop/macOS/App/SessionManager.m`
    - Added burst-density telemetry per 1s window: `burst[tail,severe,density]`.
    - Added adaptive eval logging fields: `burstTail`, `burstSevere`, `burstDensity`, `maxFrameKB`, `avgFrameKB`.
- Evidence-backed root cause:
  - iPad starvation windows now show repeated `starvationSignal=true` with no queue buildup:
    - `interArrival=83.67ms`, `109.27ms`, `151.31ms` while `rendererDepth=0` and `reasmPending=0`, `seqDelta=1`.
  - Mac simultaneously reports bursty frame density spikes:
    - `max=424KB`, `burstDensity=49.35x`, `burst[tail=1 severe=1]`, with adaptive `tailRisk=yes` triggers.
  - This confirms source burstiness / sparse delivery windows starving render input (not packet loss/reassembly backlog).
- Behavior change (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Fed burst-density signals into adaptive WiFi controller (`tailRiskCongestion` + stronger burst-aware bitrate downshift steps).
- Metric deltas (validation vs baseline):
  - heavy-load: `fps 57.5 -> 59.7`, `pipe avg/p95 54/149ms -> 48/103ms` (improved)
  - video-playback: `fps 56.5 -> 59.8`, `maxGap 250ms -> 142ms` (improved)
  - sustained-stream: `fps avg/1%low 54.7/6.0 -> 56.8/10.0`, `jitter 27.9ms -> 18.2ms`, `pipe med/avg/p95 37/63/170ms -> 32/44/105ms`, `glass med/avg/p95 60/89/200ms -> 56/69/131ms` (improved, still failing)
  - fps test: `avg 55.4 -> 57.0`, `jitter 27.0ms -> 20.7ms`, but `maxGap 283ms -> 417ms` (regression tail remains)
- Outcome:
  - Improving but not done; objective not achieved yet (FPS and long-tail thresholds still failing).
- Next immediate hypothesis:
  - Add burst-window shaping at the send scheduler surface (per-frame pacing budget tied to measured burst density) so oversized frames cannot create 80-150ms inter-arrival starvation gaps downstream.

## Lane WiFi Iteration 23 (renderer dequeue/catchup policy probe, reverted)

- Timestamp: 2026-04-04 17:14:51 EDT
- Commands:
  - Baseline: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: baseline renderer dequeue oscillation confirm"`
  - Validation: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate renderer dequeue/catchup policy"`
- Pass/Fail:
  - Baseline: `[TEST] COMPLETE: 26/33 passed, 7 failed`
  - Validation: `[TEST] COMPLETE: 26/33 passed, 7 failed`
- Hypothesis tested:
  - pending-depth (4-5) hard catchup oscillation was the dominant render tail and could be reduced with depth-trigger hysteresis/cooldown.
- Instrumentation added/refined (`RemoteDesktop/iPadOS/Render/MetalRenderer.swift`, `RemoteDesktop/iPadOS/App/SessionManager.swift`):
  - Pending-depth transition logs (`low/mid/high`) on enqueue/dequeue with reason and stale-drop count.
  - Dequeue aging telemetry (`oldestDelay`, `queueDelay`, `dequeueAgeDelta`) and catchup branch reason fields.
  - Session handoff present telemetry now includes `pending`, `dequeueToPresent`, `postDequeuePipeline`, plus dequeue/present correlation by capture timestamp.
- Evidence:
  - Baseline showed hard-depth catchup oscillation at shallow age: `pending=5->2`, `oldestDelay≈25ms`, repeated `mode=catchup-hard-depth`.
  - Validation still showed severe tail bursts despite reduced tail hard-depth events:
    - `STREAM-TELEMETRY t=141.0s ... observed=90fps rendered=74fps ... pipeline ... p95=779ms ... glass ... p95=816ms ... overwrites+12 pending=0`
    - `STREAM-TELEMETRY t=140.0s ... observed=17fps rendered=19fps ... glass p95=733ms`
  - Worst dequeue queueDelay in validation remained FIFO and low-depth (`pending=2->1`, `queueDelay=36.44ms`), indicating dominant spikes are not depth-4/5 dequeue policy alone.
- Metric deltas (validation vs baseline):
  - heavy-load: `fps 59.5 -> 58.1`, `pipe med/p95 37/110ms -> 77/237ms` (worse)
  - sustained-stream: `fps avg 56.3 -> 54.9`, `1% low 9.2 -> 8.6`, `maxGap 292ms -> 617ms`, `pipe med/avg/p95 41/55/111ms -> 42/60/126ms` (worse)
  - fps test: `avg 56.8 -> 56.0`, `maxGap 292ms -> 617ms` (worse), `jitter 22.8ms -> 22.0ms` (slightly better but still failing)
- Outcome:
  - Non-improving; renderer policy change reverted.
  - Telemetry refinements retained for next hypothesis.
- Next move:
  - Instrument and correlate renderer overwrite bursts with upstream arrival burst windows (sequence burst density + enqueue overflow + render starvation windows) to distinguish transport burstiness vs render tick starvation before any next policy change.

## Lane WiFi Iteration 22 (renderer early-catchup + present telemetry)

- Timestamp: 2026-04-04 16:45:46 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate renderer early catchup + cadence telemetry"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
- Key metrics (vs iteration 21 baseline run):
  - sustained-stream: `pipe[med/avg/p95] 37/54/113ms -> 33/45/105ms`, `glass[med/avg/p95] 66/80/134ms -> 58/70/127ms`
  - fps tails: `maxGap 392ms -> 225ms`, `p95 frame 92ms -> 67ms`, `jitter 22.4ms -> 20.3ms`
  - fps avg unchanged: `57.9 -> 57.8` (still below 60 target)
  - glass overhead vs decode: `30ms -> 25ms`
- Hypothesis tested:
  - iPad render queue was carrying persistent 2-5 frame backlog (~26-35ms queue delay) without triggering catchup, inflating present/display-link tails.
- Instrumentation/behavior added (`RemoteDesktop/iPadOS/Render/MetalRenderer.swift`):
  - Added branch/error/success timing logs for render tick skip, commandBuffer/encoder abort, dequeue with `displayLead`, and render completion (`gpuRoundtrip`, `submitLag`).
  - Lowered adaptive catchup activation thresholds for depth+delay backlog to purge stale queued frames earlier.
- Evidence:
  - Renderer telemetry now shows catchup activation (`catchupBranchLogs=70`, `modes=fifo:742, catchup-hard-depth:46, catchup-soft-single:24`).
  - Dequeue queueDelay dropped to `median=20.26ms` (from prior `~26.04ms`) and `p95=26.70ms` (from prior `~34.87ms`).
- Outcome:
  - Improving but incomplete; commit-worthy improvement retained for next loop.
- Next move:
  - Remaining dominant bottleneck is capture->decode latency tail (`pipeline p95 105-106ms`) plus sub-60 avg fps. Next hypothesis: instrument decode submit→callback + session handoff timing in `SessionManager`/`HEVCDecoder` to isolate decode queue stalls vs upstream delivery jitter.

## Lane WiFi Iteration 21 (adaptive severe-threshold probe, reverted)

- Timestamp: 2026-04-04 16:31:41 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate less aggressive severe-downshift thresholds"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
- Key metrics:
  - sustained-stream: `fps[avg/1%low]=57.8/6.7`, `pipe[med/avg/p95]=31/51/147ms`, `glass[med/avg/p95]=53/76/174ms`
  - fps: `avg=58.1`, `1%low=6.7`, `maxGap=242ms`, `jitter=20.6ms`
  - wifi baseline: `wifi-fps=41.5`, `wifi-latency median/p95=42/114ms`
- Hypothesis tested:
  - Soften severe congestion triggers in macOS adaptive controller to avoid unnecessary 54fps downshift from short TCP pressure bursts.
- Instrumentation added:
  - Added `severeTriggers[...]` reason fields to `WiFi adaptive eval` logging in `RemoteDesktop/macOS/App/SessionManager.m`.
- Outcome:
  - Non-improving vs prior run; change reverted with commit `718f6d0`.
- Next move:
  - Keep revert, shift to iPad render/present cadence tail bottleneck (high jitter + high glass latency with zero frame loss).

## Lane WiFi Iteration 20 (transient DTLS receive-gap spin guard)

- Timestamp: 2026-04-04 16:26:00 EDT
- Command:
  - `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate transient DTLS recv-gap backoff+rate-limited logging"`
- Pass/Fail:
  - `[TEST] COMPLETE: 26/33 passed, 7 failed`
- Key metrics (vs baseline run started by orchestrator):
  - sustained 1% low: `6.7 -> 9.2`
  - fps maxGap: `267ms -> 192ms`
  - pipeline p95: `143ms -> 106ms`
  - glass p95: `170ms -> 129ms`
  - wifi baseline fps: `41.6 -> 47.3`
  - resolution preserved (`2496x1620`, PASS)
- Hypothesis tested:
  - iPad WiFi receive loop was repeatedly spinning on transient DTLS `No message available on STREAM`, adding CPU/log pressure and tail stalls.
- Instrumentation/behavior added (`RemoteDesktop/iPadOS/Transport/WirelessTransport.swift`):
  - Added transient-gap streak tracking, suppressed-count tracking, and recovery summaries.
  - Kept branch visibility with stable events (`ignored`, `ongoing`, `recovered`) while rate-limiting hot-loop detail logs.
  - Added bounded receive re-arm backoff (`1-4ms`) for transient DTLS gap branch.
- Residual blocker:
  - sustained avg fps remains below target (`57.9`) and jitter still high (`22.4ms`); pipeline avg still ~`52ms`.
- Next move:
  - instrument render/present cadence at `MetalRenderer` + iPad session orchestration to isolate display-link/present tail spikes from transport effects.

## Lane A Iteration 19 (Wi‑Fi control-path grace recovery, non‑E2E)

- Timestamp: 2026-04-04 12:57:20 EDT
- Scope: eliminate sustained-stream reconnect dip from transient TCP control-path EOF/cancel while media path remains healthy; preserve legitimate dead-path recovery.
- Commands:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath .build/DerivedData build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -configuration Debug -destination "generic/platform=iOS" -derivedDataPath .build/DerivedData build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests -configuration Debug -destination "platform=macOS,arch=arm64" -only-testing:RemoteDesktopAgentTests/TransportFSMTests -only-testing:RemoteDesktopAgentTests/TransportNetworkTests test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - targeted transport tests ✅ (`52 executed, 0 failed`)
- Hypothesis: control-channel interruptions (EOF/cancel/fail) should enter a bounded degraded mode if DTLS media is still active, allowing in-session control replacement instead of immediate disconnect/reconnect churn.
- Instrumentation/behavior added:
  - `RemoteDesktop/macOS/Transport/WirelessTransport.m`
    - Replaced unconditional TCP EOF teardown behavior with decision logging:
      - `decision=degraded` when media is active.
      - `decision=reconnect-triggered` when media is not active.
    - Added bounded control recovery loop (poll `750ms`, hard deadline `6s`) with explicit logs:
      - `decision=degraded reason=awaiting-control-replacement`
      - `decision=preserved reason=control-path-recovered`
      - `decision=reconnect-triggered reason=control-recovery-timeout`
    - During degraded window:
      - preserve `isConnected` and media session,
      - arm reconnect takeover + Bonjour discovery for replacement control socket,
      - only emit disconnect (`onConnectionChanged(NO, ...)`) on hard timeout/no-media path.
    - Added explicit recovery cancel logs on ready/teardown/media-loss.
  - `RemoteDesktop/iPadOS/Transport/WirelessTransport.swift`
    - Mirrored bounded control recovery strategy for `.failed/.cancelled` and TCP receive EOF/error:
      - transient control loss + active media => degraded preserve path + replacement attempts.
      - no media or timeout => reconnect-triggered teardown.
    - Added matching decision logs (`preserved` / `degraded` / `reconnect-triggered`) with reason/detail/elapsed context.
    - Added cancellation/reset points for control recovery on TCP ready, teardown, and media-path loss.
- Next move:
  - Run canonical Wi‑Fi full-profile E2E on orchestrator lane and verify around t~190s:
    - control-path events should show degraded/preserved instead of immediate disconnect chain,
    - no `WiFiUnavailable -> Disconnected -> DisconnectCurrent` cascade unless recovery timeout/no-media condition is hit.

## Lane C Iteration 19 (Wi‑Fi stale-frame tail guard, non‑E2E)

- Timestamp: 2026-04-04 12:54:29 EDT
- Scope: reduce sustained 1% low collapse and tail latency spikes by preventing stale frames from entering Wi‑Fi HEVC pipeline under transient load; continuity-first and floor-safe (>=30fps); no E2E run per constraint.
- Commands:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination 'platform=macOS,arch=arm64' -configuration Debug build`
  - `swift build --package-path SharedProtocol`
  - `swift test --package-path SharedProtocol`
- Result:
  - SharedProtocol build ✅
  - SharedProtocol tests ✅ (`76 passed, 0 failed`)
  - macOS agent build ⚠️ blocked by pre-existing unrelated compile errors in `RemoteDesktop/macOS/Transport/WirelessTransport.m`:
    - missing selectors `cancelControlPathRecoveryWithReason:` and `beginControlPathRecoveryForReason:detail:wasAWDL:`
- Hypothesis: sustained p95/p99 spikes with 0% frame-loss and low send-drop pressure are dominated by source-side frame age tails feeding encoder after transient scheduling delays; age-aware pre-encode dropping should cut long-tail pipeline latency and improve 1% lows by favoring freshness over stale throughput.
- Instrumentation/behavior added (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added Wi‑Fi pre-encode stale-age guard (TCP media path only):
    - dynamic stale thresholds (base/congested/severe): `90ms / 65ms / 48ms`
    - hard absolute stale cut: `220ms`
    - drops happen pre-encode with explicit reasoned log:
      - `WiFi pre-encode drop: reason=stale-age age=... threshold=... absThreshold=...`
  - Added frame-age telemetry (sampled) in pre-encode path:
    - per-window counters for stale drops, max age, age sample count, age sum
    - 1s perf log now includes:
      - `stalePreDrop=... preAgeAvg=...ms preAgeMax=...ms`
  - Added continuity-first anti-oscillation hold after stale events:
    - track `wifiAdaptiveLastStaleDropUs`
    - block healthy upshifts for `3200ms` after stale drops (`post-stale-recovery`)
    - tail/severe classifiers now consider stale-drop and stale-max-age signals.
- Expected effect:
  - Reduce long-tail pipeline age bursts by refusing outdated frames before encode.
  - Improve 1% low consistency via fresher frame admission and delayed rebound upshifts after stale events.
  - Keep floor guard unchanged (`kWirelessAdaptiveMinFPS = 30`) and continuity-first behavior preserved.
- Residual risk:
  - Overly aggressive stale thresholds could reduce effective fps during brief CPU spikes; telemetry added to tune this quickly.
  - Build validation for macOS agent remains blocked by unrelated WirelessTransport compile issue, so touched file compiles not fully re-verified in this environment.

## Lane C Iteration 18 (Wi‑Fi tail/jitter stabilization, non‑E2E)

- Timestamp: 2026-04-04 12:38:23 EDT
- Scope: tune Wi‑Fi adaptive sender behavior for sustained tail quality/continuity without reducing floor below 30fps; no E2E run per constraint.
- Commands:
  - `xcodebuild -workspace keyd.xcworkspace -scheme KeydAgent -configuration Debug -sdk macosx build`
  - `xcodebuild -workspace keyd.xcworkspace -scheme KeydAgentTests -configuration Debug -sdk macosx test -destination 'platform=macOS'` (not configured for test action)
  - `xcodebuild -workspace keyd.xcworkspace -scheme KeydApp -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro (11-inch) (4th generation)' test` (destination unavailable)
  - `xcodebuild -workspace keyd.xcworkspace -scheme KeydApp -configuration Debug -destination 'generic/platform=iOS' build` (blocked by provisioning profile)
- Result:
  - KeydAgent build ✅
  - Targeted tests/build attempts outside macOS lane ⚠️ blocked by scheme/test-action config, simulator destination mismatch, and signing constraints (no semantic code-test failures observed for touched path).
- Hypothesis: post-iter17 stream spends long periods in mid‑50s fps but still suffers completion-tail spikes and jitter due controller overreaction/rebound; continuity-first tail shaping should prioritize bitrate-first pressure relief, slower upshift, and escalation hysteresis.
- Instrumentation/behavior added (`RemoteDesktop/macOS/App/SessionManager.m`):
  - Added sampled/forced adaptive classification telemetry:
    - `WiFi adaptive eval: severe=... mild=... tailRisk=... healthy=... metrics[...] streaks[...]`
    - sampled every 30 evals, forced on severe/tail-risk/drop events.
  - Added severe-congestion escalation state (`wifiAdaptiveSevereCongestionStreak`) with explicit branch logging and reset semantics.
  - Added tail-risk branch for completion-tail control (`tcpSlow>=2` or `tcpMaxCompletion>=32ms`) before hard severe behavior.
  - Adaptation smoothing adjusted to reduce oscillation:
    - upshift slowed (`+2fps`, `+75kbps`, healthy streak 8, recovery hold 5200ms),
    - mild path now bitrate-only downshift (`downshift-mild-bitrate`) to preserve continuity/fps floor,
    - severe now two-stage (`downshift-severe-soft` then `downshift-severe-hard`) to avoid abrupt floor dives unless persistent.
  - Floor protection preserved at 30fps (`kWirelessAdaptiveMinFPS` unchanged and still clamped).
- Expected effect:
  - Lower p95 completion/jitter tails by reacting earlier to tail-risk signals while avoiding frequent FPS toggles.
  - Better 1% low stability via continuity-first bitrate trims and slower rebound.
- Residual risk:
  - If congestion turns abruptly hard, two-step severe escalation may delay full clamp by one interval.
  - No lane-C renderer change this iteration to keep causality clear at sender/control surface.

## Lane B Iteration 18 (USB guardrail + decode correctness)

- Timestamp: 2026-04-04 12:39:00 EDT
- Scope: USB-only regression guardrail and telemetry hygiene (no Wi‑Fi logic edits, no E2E run).
- Commands:
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgent -destination "platform=macOS,arch=arm64" build`
  - `xcodebuild -project RemoteDesktop/iPadOS/RemoteDesktopApp.xcodeproj -scheme RemoteDesktopApp -destination "generic/platform=iOS" build`
  - `xcodebuild -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests -destination "platform=macOS,arch=arm64" -only-testing:RemoteDesktopAgentTests/TransportFSMTests -only-testing:RemoteDesktopAgentTests/TransportNetworkTests test`
- Result:
  - macOS build ✅
  - iPadOS build ✅
  - targeted transport tests ❌ blocked by pre-existing unrelated compile failure in `RemoteDesktop/macOS/Transport/WirelessTransport.m` (`nw_connection_get_state` undeclared)
- USB review summary:
  - Re-checked:
    - `RemoteDesktop/macOS/Transport/USBNetworkTransport.m`
    - `RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift`
    - `RemoteDesktop/iPadOS/Decode/HEVCDecoder.swift`
    - `RemoteDesktop/iPadOS/Decode/LZ4Decompressor.swift`
  - Found one high-confidence correctness gap in LZ4 path: accepted short successful decode lengths (`result > 0`) and then applied delta/reference copy over full expected frame.
  - Fix applied in `LZ4Decompressor.swift`:
    - Added strict decoded-size check (`Int(result) == expectedBytes`) for both keyframe and delta branches.
    - Added explicit error logs for keyframe/delta size mismatch branches.
- Expected USB impact:
  - Prevents propagating partially decoded wired frames into keyframe reference/delta reconstruction.
  - Improves fail-fast behavior and diagnosis on malformed/truncated USB payloads without changing normal-path behavior.
- Residual risk:
  - Existing Wi‑Fi-targeted compile break in `WirelessTransport.m` currently blocks macOS test execution despite USB lane changes being isolated.
  - USB transport hot-path logging remains sampled/controlled; no additional high-risk hot-path logging changes made this iteration.

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

## Lane C Iteration (HEVC decode→renderer handoff trace + queue decouple)

- Timestamp: 2026-04-04 17:01:21 EDT
- Baseline command (orchestrator): `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: decode handoff latency focus"`
- Validation command: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate hevc handoff queue telemetry"`
- Result: `26/33` passed, `7` failed (same fail count; perf metrics improved, security known vuln unchanged)
- Baseline → Validation deltas (Wi‑Fi full profile):
  - sustained avg FPS: `54.6 -> 56.0`
  - sustained 1% low FPS: `6.7 -> 9.2`
  - sustained pipeline p95: `145ms -> 107ms`
  - sustained glass p95: `173ms -> 129ms`
  - full pipeline-latency p95: `146ms -> 106ms`
  - full glass-to-glass p95: `172ms -> 128ms`
  - fps jitter stddev: `22.9ms -> 20.6ms`
  - heavy-load pipeline p95: `136ms -> 109ms` (median regressed `27ms -> 38ms`)
- Evidence from new instrumentation:
  - `HEVCDecoder: decode-callback ... didReturn=false callbackMs≈5-6ms` (callbacks usually complete before decode returns; not a post-return async backlog).
  - `SessionManager: hevc-handoff enqueue ... decodeToEnqueue p95≈0.10ms, enqueueCost p95≈0.09ms` (decode→renderer submit cost is tiny).
  - `SessionManager: hevc-handoff dequeue ... decodeToDequeue median≈21.95ms, p95≈26.52ms` and `submitToPresent p95≈34.97ms` (tail is dominated by queueing before render present, not enqueue cost).
  - Renderer catchup branch count dropped versus prior run context (`catchupTotal` finishing at `78` this run vs ~`235` prior), indicating reduced burst pressure.
- Change set implemented:
  - `RemoteDesktop/iPadOS/Decode/HEVCDecoder.swift`
    - Added explicit decode submit/callback timing logs (`decode-submit`, `decode-callback`) with success/error branch fields.
    - Extended async decode callback payload with `decodeSubmitUs` and `callbackUs`.
  - `RemoteDesktop/iPadOS/Render/MetalRenderer.swift`
    - Added dequeue and render-complete callback hooks for external correlation (`onFrameDequeuedForRender`, `onFrameRenderCompleted`).
  - `RemoteDesktop/iPadOS/App/SessionManager.swift`
    - Routed both inline and callback HEVC decoded frames through a dedicated serial handoff queue.
    - Added decode→enqueue→dequeue→present correlated telemetry keyed by capture timestamp (seq/source/state/transport/timing).
- Current hypothesis:
  - dominant remaining blocker is renderer queue delay/cadence instability (dequeue delay + catchup behavior), not HEVC decode callback latency or decode->enqueue overhead.
- Next move:
  - keep this instrumentation and target MetalRenderer dequeue policy under sustained load (reduce `queueDelay`/`catchup` oscillation without lowering fidelity), then rerun canonical Wi‑Fi full profile.

## WiFi Iteration (send-scheduler burst shaping validation)

- Timestamp: 2026-04-04 17:43:47 EDT
- Baseline command: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: send-scheduler burst shaping"`
- Validation command: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: validate send-scheduler burst shaping"`
- Result: non-improving (`26/33` passed on both runs, same 7 failures; known security C3 unchanged)
- Baseline → Validation deltas:
  - heavy-load FPS: `59.5 -> 58.4`
  - heavy-load pipeline p95: `102ms -> 161ms`
  - sustained avg FPS: `54.3 -> 54.5`
  - sustained 1% low FPS: `9.2 -> 8.6`
  - sustained maxGap: `467ms -> 358ms`
  - sustained pipeline p95: `109ms -> 147ms`
  - full pipeline-latency p95: `107ms -> 212ms`
  - full glass-to-glass p95: `129ms -> 223ms`
- Evidence / telemetry:
  - Baseline retained burst-tail signals in Mac adaptive logs (`tailRisk=yes`, burst density spikes up to `~50x`, intermittent TCP slow completions up to `98ms`).
  - Validation scheduler telemetry showed shaping rarely engaged in practice (`WiFi perf 1s ... scheduler[delays=0 avg=0us max=0us burstWindows=0 burstSends=0]` across sampled windows).
  - One backpressure event logged scheduler intent without realized delay: `WiFi TCP backpressure drop ... scheduler[delay=0us target=2200us reason=inflight-severe ...]`.
- Change/revert notes:
  - Implemented Wi-Fi TCP scheduler burst-window shaping + telemetry at macOS `SessionManager` send path for this hypothesis.
  - Reverted non-improving behavior change after validation per loop policy (no commit for this hypothesis).
- Current hypothesis:
  - Long-tail regressions are not currently dominated by TCP send enqueue micro-burst spacing; scheduler shaping did not activate meaningfully under observed timing.
  - Next bottleneck candidate is downstream render/present queue starvation windows (decode->glass side) and/or pre-encode drop timing interactions during stress bursts.
- Next immediate move:
  - Keep lane as `wifi`.
  - Add deeper observability on iPad render starvation windows (`dequeue wait`, `present interval outliers`, `queue depth transitions around >200ms gaps`) before any new behavior change.
  - Run canonical Wi-Fi full-profile again with that instrumentation, then target queue starvation mitigation.

## WiFi Iteration 2 (post-destination-timeout instrumentation)

- Timestamp: 2026-04-04 18:36:29 EDT
- Command: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration2 post-destination-timeout instrumentation"`
- Result: blocked in step `[1/6]` build phase (no stream tests executed)
- Pass/fail: `0/0` test cases executed (build blocker pre-empted `[TEST]` runtime)
- Key metrics/signals:
  - `e2e-results`: attempt 1 + attempt 2 both failed with `destinationTimeout=true`
  - `keyd-e2e-build-ipad.log`: `Timed out waiting for all destinations...`
  - `Available destinations`: `My iPad Pros ... may need to be unlocked to recover from previously reported preparation errors`
  - `/tmp/keyd-e2e-ipad.log` and `/tmp/keyd-e2e-mac.log` not created (run never reached runtime stages)
- Hypothesis:
  - Highest-impact blocker is iPad destination readiness (device ID mismatch/readiness state), not WiFi media pipeline behavior. Until this clears, no FPS/bitrate/stutter evidence can be gathered.
- Instrumentation/recovery added this iteration:
  - `RemoteDesktop/scripts/run-e2e-tests.sh`
    - Added `wait_for_job` watchdog telemetry (`entry`, `branch`, `heartbeat`, `success`, `failure`) with `elapsedSec`, `logAgeSec`, and `logSize`.
    - Added bounded build watchdog controls (wall timeout + log-stall timeout) for Mac/iPad build waits.
    - Added explicit iPad build failure fields (`waitFailReason`, `waitFailDetail`, `stalled`) and retry decision reason logging.
    - Extended retry trigger to include watchdog stall/timeout failures (still bounded to one retry).
- Next move:
  - Re-run canonical WiFi command after device readiness is restored; use new watchdog logs to disambiguate destination-timeout vs stall-timeout failure paths before any media-pipeline behavior change.

## WiFi Iteration 4 (launch-retry diagnostics run analysis + adaptive guard fix)

- Timestamp: 2026-04-04 18:47:18 EDT
- Command: `./RemoteDesktop/scripts/run-e2e-tests.sh --transport-rotation wifi --profile full --notes "wifi: iteration4 launch-retry diagnostics"`
- Result: tests executed (launch blocker cleared), but WiFi performance regressions persist.
- Pass/fail signals (high impact):
  - `FAIL heavy-load`: `58.6fps`, pipeline `avg=42ms p95=135ms`
  - `FAIL sustained-stream`: `avg=55.9fps`, `1% low=13.3fps`, pipeline `29/38/100ms`, glass `52/59/133ms`
  - `FAIL fps`: `56.9fps`, `1% low=13.3fps`, `maxGap=200ms`
  - `FAIL frame-pacing`: `cv=0.865`
  - `FAIL pipeline-latency`: `19/28/37/101/223ms`
  - `FAIL glass-to-glass-latency`: `37/50/58/134/245ms`
  - `PASS transport/session`: launch + handshake + transport detection + frame-loss all passed
- Root-cause hypothesis for this iteration:
  - Launch path is no longer the blocker; highest-impact blocker is false-positive WiFi adaptive severe downshift during bursty but non-congested windows.
  - Evidence from `/tmp/keyd-e2e-mac.log`:
    - `WiFi adaptive apply: reason=downshift-severe-soft requested=54fps... prev=60fps...`
    - Triggering eval had no drops and low in-flight pressure (`sendDrop=0 queueDrop=0 preDrop=0 staleDrop=0 inFlight=0`) with only `slow=1 max=26ms`, but burst-density heuristics forced severe classification.
  - This unnecessarily pulled target FPS below 60 and likely amplified sustained/fps failures.
- Change implemented (one coherent fix + branch-complete logging):
  - File: `RemoteDesktop/macOS/App/SessionManager.m`
  - Tightened burst-severe escalation gate:
    - old: escalate on `burstSevereRisk && (slow>=1 || max>=30ms)`
    - new: escalate only when burst-severe risk coincides with real pressure (`inFlight>=limit` or `slow>=2` or `max>=32ms` or send/queue/pre/stale drops)
  - Added explicit branch telemetry:
    - `WiFi adaptive burst escalation: branch=trigger|hold ... metrics[...] thresholds[...]`
    - Covers both success and non-escalation branches for next-run causality.
- Instrumentation added this iteration:
  - New adaptive branch decision log at the exact severe-escalation decision point with full correlation metrics.
- Next move:
  - Run canonical WiFi command (same profile/notes style) and verify:
    - reduced/absent `downshift-severe-soft` events under low-pressure bursts,
    - improved `avg FPS`, `1% low`, and p95 pipeline/glass tails without transport regressions.
