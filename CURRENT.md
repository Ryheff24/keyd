# CURRENT

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
