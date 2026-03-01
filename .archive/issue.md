**Handoff Context**
Use this debug doc first; it has the full chronology of attempted fixes and why each was made: [multi-device-awdl-session-thrash.md](./.planning/debug/multi-device-awdl-session-thrash.md).

Current branch is `main` with a dirty tree:
- [TransportManager.swift](./macOS/KeydAgent/Transport/TransportManager.swift#L42) (uncommitted AWDL candidate/recovery gating work)
- [KeydApp.swift](./KeydApp/KeydApp/App/KeydApp.swift#L61) (`willTerminate` now calls `resetConnections()`)
- [.planning phase summary](./.planning/phases/01-transport-and-core-keyboard/01-05-SUMMARY.md)

**Latest Failure Signature (hard-close iPhone, then reconnect)**
Newest logs: [iPhone.log](./logs/latest/iPhone.log), [iPad.log](./logs/latest/iPad.log), [mac.log](./logs/latest/mac.log).

What they show:
- iPhone reconnect loop: repeated AWDL connect/disconnect with resume failures and resets ([iPhone.log](./logs/latest/iPhone.log#L10), [iPhone.log](./logs/latest/iPhone.log#L28), [iPhone.log](./logs/latest/iPhone.log#L88)).
- iPad (unpaired) AWDL churn is extreme: 455 `Connected via AWDL` / 455 `AWDL ready for pairing` / 455 `Code=-1005`, continuous pairing-channel flap ([iPad.log](./logs/latest/iPad.log#L10), [iPad.log](./logs/latest/iPad.log#L1831)).
- Mac unified info log (same window) shows storm behavior even with candidate-close logic:
  - `AWDL connection accepted: 588`
  - `AWDL connection ready: 517`
  - `Additional AWDL ... closing candidate: 503`
  - `AWDL connection failed before ready: 70`
  - Only one explicit `AWDL session accepted for paired device`, with same device ID resumed later.

**Why Mac Logs In `logs/latest` Miss Key Data**
`logs/latest/mac.log` is incomplete for transport debugging because the collector streams without `--info` in [deploy-and-run.sh](./scripts/deploy-and-run.sh#L255).  
For real debugging, the next agent should rely on unified log commands with `--info` (or update the script).

Overhaul Suggestions

Move to a strict session-arbitration state machine (single authority for promotion/eviction; explicit unconfirmed vs confirmed session epochs).
Split pairing traffic from control traffic at transport/service level (unpaired device should never contend with paired control channel).
Add admission control before “ready” promotion (identity/auth proof first, then state promotion).
Add aggressive backoff+jitter for unpaired AWDL retries to stop listener flood.
Add deterministic 2-device integration scenarios for the exact matrices you ran (USB/AWDL ordering + hard-close reopen).
