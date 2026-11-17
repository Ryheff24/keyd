Committed one timing-only win on branch `resume-time`.

- [C] `RemoteDesktop/iPadOS/Transport/WirelessTransport.swift:1203`: use zero delay only for attempt 1 with `spannedSuspension` and reason `link-silent` or `resume-after-suspension`.
- [C] Same file, line 1205: retain 250/500/1000/2000 ms capped backoff for other reasons and subsequent attempts. Browser-ready still resets the counter; TCP-ready clears the suspension flag.
- [C] Same file, line 1206: log `resumeFastRetry`, `spannedSuspension`, delay, reason, attempt and `tUs` on both decision outcomes.
- [C] Same file, line 1209: keep asynchronous dispatch and the existing browsing/current-browser/connection guards. Protocol, TLS, quality, cascade, listeners and thresholds are unchanged.

[O] Evidence: after `background-cycle entered`, scheduling-to-firing was 251.242 ms (bg7), 251.412 ms (bg8), 251.720 ms (bg10), from the supplied iPad logs' `tUs` pairs.
[I] Expected saving: about 250 ms before discovery on this branch; on-screen benefit depends on scheduling and AWDL readiness. Simple subtraction from bg10's 592 ms gives ~342 ms, still above 250 ms. The goal is unverified.

[C] TLA+: no rows run, no model edits, no TLAPS run (installed). Applied the task's pure-timing exception: `TransportConnections.tla:194` abstracts loss into discovery; `:201` enables dial without a browser-backoff clock. This changes only the unmodelled dispatch delay. FrameLoop and Lifecycle transitions are unchanged; no formal timing claim is made.

[C] Compile checks used the discovered app schemes, generic iOS/macOS destinations, `CODE_SIGNING_ALLOWED=NO`, and derived data under `build-dd/`:
- Mac `RemoteDesktopAgent`: BUILD SUCCEEDED, exit 0.
- iPad `RemoteDesktopApp`: BUILD FAILED, exit 65; `CompileMetalFile` cannot execute `metal` because the Metal Toolchain is unavailable. Swift compilation was not reached.
- Modified Swift source: `swiftc -frontend -parse` passed; this is syntax validation, not an iPad compile pass.
- `git diff --check` passed. Build artifacts were not staged. No device, deployment or E2E commands ran.

[I] Risk: discovery starts earlier while the app may still be inactive. Existing queued guards remain; browser/dial failures retain backoff. Runtime wake ordering and visible-frame benefit need the next E2E run.
[C] Deferred Mac encoder deduplication: `SessionManager.m:1195` and `:1254` both start it; startup also reconfigures capture and sends geometry. Avoided changing this sequencing in the cheap pass. No saving claimed there.

For the integrator's next E2E logs:
- Suspension-related silence: attempt 1, `resumeFastRetry=true spannedSuspension=true delay=0.00s`; firing should follow scheduling without the old ~251 ms gap.
- Ordinary failures: `resumeFastRetry=false` and the existing backoff; no repeated immediate-restart loop.
- Follow `LC IpadDial` -> `LC IpadReady` on AWDL -> accepted `FL IpadHs` -> `FL IpadKey`, then the E2E first-new-frame-after-active metric. Confirm <=250 ms using that metric, not key arrival alone.
