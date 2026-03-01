# AWDL/USB Multi-Device Scenario Matrix And Invariant Checklist

## Goal

Run one deterministic suite that validates paired-device stability across USB and AWDL with two physically connected iOS devices (one paired, one unpaired), without manual unplug/replug actions.

The suite uses injected transport events (`force_usb_drop`, `force_awdl_drop`, identity timeout ticks, resume signals) to simulate disconnect and reconnect flows.

## Test Topology

- `Mac Agent` (already paired with `Device P`)
- `Device P` (paired iPhone/iPad)
- `Device U` (unpaired iPad/iPhone in pairing mode)

## State Model (Minimal)

- Device transport state:
  - `USB`: `disconnected | pending_identity | connected`
  - `AWDL`: `disconnected | pending_identity | connected`
- Device app mode:
  - `closed | pairing_mode | paired_mode`
- Mac session state:
  - `no_confirmed_session`
  - `confirmed_usb(DeviceID)`
  - `confirmed_awdl(DeviceID)`
  - `pending_usb(DeviceID?)`
  - `pending_awdl_pool([slots])`

## Injected Event API (Debug/Test Hook Contract)

- `plug_usb(Device)` / `unplug_usb(Device)` (optional if both remain plugged physically)
- `force_usb_drop(Device)`
- `force_awdl_drop(Device)`
- `awdl_candidate_arrives(Device)`
- `emit_session_resume(Device, transport)`
- `emit_pairing_request(Device, transport)`
- `advance_time(ms)` (drives timeout/backoff deterministically)
- `relaunch_app(Device)`
- `hard_close_app(Device)`
- `retry_connect(Device)`

## Invariant Checklist (Assert After Every Step)

- `INV-001`: Unpaired identity can never become confirmed session when already paired.
- `INV-002`: At most one confirmed active session exists on Mac at any time.
- `INV-003`: Pending USB identity timeout drops only that pending USB connection.
- `INV-004`: Pending AWDL identity timeout drops only that AWDL slot.
- `INV-005`: Non-matching `sessionResume` is rejected and does not evict confirmed session.
- `INV-006`: Matching `sessionResume` promotes candidate to confirmed session.
- `INV-007`: USB promotion over AWDL only occurs for matching paired identity.
- `INV-008`: AWDL promotion over USB only occurs when USB is absent/invalidated and identity matches policy.
- `INV-009`: Unpaired pairing-mode AWDL does not infinite-reconnect (attempt count bounded).
- `INV-010`: Paired reconnect backoff increases monotonically up to configured cap and resets only after confirmed healthy session signal.
- `INV-011`: Stale/duplicate AWDL candidates never displace a healthy confirmed session.
- `INV-012`: Arrival of pending USB from unpaired device does not clear unrelated AWDL pending slots needed by paired device.
- `INV-013`: USB listener/device rotation progresses after pending timeout or rejection (no starvation).
- `INV-014`: Agent relaunch preserves paired identity and still accepts paired session resume.
- `INV-015`: Heartbeat timeout policy does not terminate newly promoted healthy sessions during stabilization window.
- `INV-016`: After any forced disconnect, system converges to one stable confirmed session for `Device P` within bounded time.

## Top-Level Suite Structure

- `Suite A: Single-Device Regression`
  - Only `Device P` participates.
  - Covers baseline transport behavior and reconnect recovery without multi-device contention.
  - Includes dedicated single-device spam/stress scenarios.
- `Suite B: Multi-Device Regression`
  - `Device P` and `Device U` run concurrently.
  - Covers identity gating, arbitration races, starvation prevention, and reconnect stability under contention.
  - Includes dedicated multi-device spam/storm scenarios.

## Spam/Stress Requirements (Both Suites)

- `SPAM-01` Reconnect spam: repeated forced disconnect/retry cycles with deterministic virtual time.
- `SPAM-02` Candidate-arrival spam: burst AWDL/USB candidate arrivals (especially from unpaired device in Suite B).
- `SPAM-03` Payload burst spam: high-rate key payload bursts to catch lag-spike then character-flood behavior.
- `SPAM-04` Long-run churn: randomized event stream with fixed seed and invariant monitoring.

Pass condition for spam/stress:
- No invariant violations.
- No unbounded reconnect loop.
- No delayed flush that emits stale buffered character floods after recovery.

## Scenario Matrix

### Legend

- `P` = paired device
- `U` = unpaired device
- `Exp` = expected final stable state
- `Inv` = key invariants

| ID | Suite | Initial State | Injected Sequence | Exp | Inv |
|---|---|---|---|---|---|
| S01 | Multi | No session, both apps open (`P` paired mode, `U` pairing mode) | `awdl_candidate_arrives(U)` -> `emit_pairing_request(U, awdl)` -> `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | Confirmed AWDL on `P` | 001,002,004,006,011 |
| S02 | Multi | No session | `awdl_candidate_arrives(U)` -> `advance_time(identity_timeout+1)` | No confirmed session, `U` candidate removed | 002,004,009 |
| S03 | Multi | Confirmed AWDL on `P` | `awdl_candidate_arrives(U)` -> `emit_pairing_request(U, awdl)` | AWDL on `P` remains stable | 001,002,011 |
| S04 | Multi | Confirmed AWDL on `P`, USB for `U` appears | `plug_usb(U)` -> `emit_session_resume(U, usb)` | `U` rejected, AWDL on `P` remains | 001,002,005,007 |
| S05 | Single | Confirmed AWDL on `P`, USB for `P` appears | `plug_usb(P)` -> `emit_session_resume(P, usb)` | Promote to confirmed USB on `P` | 002,006,007 |
| S06 | Single | Confirmed USB on `P` | `force_usb_drop(P)` -> `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | Fallback to confirmed AWDL on `P` | 002,006,008,016 |
| S07 | Single | Confirmed AWDL on `P` | `force_awdl_drop(P)` -> `plug_usb(P)` -> `emit_session_resume(P, usb)` | Confirmed USB on `P` | 002,006,016 |
| S08 | Multi | No confirmed session, both USB connected (`U` attached first) | `plug_usb(U)` -> `plug_usb(P)` -> `advance_time(pending_usb_timeout+1)` -> `emit_session_resume(P, usb)` | Rotation reaches `P`, confirmed USB on `P` | 001,013 |
| S09 | Multi | No confirmed session, both AWDL candidates arrive near-simultaneously | `awdl_candidate_arrives(U)` + `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | Confirmed AWDL on `P`, `U` dropped | 001,002,006,011 |
| S10 | Single | Agent restarted; paired secret exists | `relaunch_app(MacAgent)` -> `plug_usb(P)` -> `emit_session_resume(P, usb)` | `P` accepted immediately | 006,014 |
| S11 | Single | Agent restarted; no active session | `relaunch_app(MacAgent)` -> `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | `P` accepted immediately | 006,014 |
| S12 | Multi | Confirmed AWDL on `P`, `U` in pairing mode | `force_awdl_drop(U)` repeated N times with `advance_time` | `U` attempts remain bounded; `P` stable | 009,011 |
| S13 | Multi | No confirmed session, `U` USB tunnel opens but idle | `plug_usb(U)` -> `advance_time(pending_usb_timeout+1)` -> rotate -> `plug_usb(P)` -> `emit_session_resume(P, usb)` | Idle `U` dropped, `P` wins USB | 003,013 |
| S14 | Single | Confirmed AWDL on `P`, heartbeat active | `advance_time(stabilization_window-1)` -> heartbeat tick -> `emit_heartbeat_ack(P)` | Connection not canceled during stabilization | 015 |
| S15 | Single | Confirmed AWDL on `P` then hard close | `hard_close_app(P)` -> observe reconnect attempts with `advance_time` | Backoff grows (0.5,1,2,4,8 cap), eventual stable resume after reopen | 010,016 |
| S16 | Multi | Confirmed USB on `P`, `U` AWDL storm attempts | Repeated: `awdl_candidate_arrives(U)` -> reject | USB on `P` unaffected | 001,002,011 |
| S17 | Multi | No session, AWDL-first race with stale candidate replacement | `awdl_candidate_arrives(U)` -> `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | Stale `U` slot replaced/dropped; `P` confirmed | 004,006,011 |
| S18 | Multi | Confirmed AWDL on `P`, pending USB on `U` arrives | `plug_usb(U)` (pending) while `P` AWDL reconnect in flight | Pending USB does not clear `P` AWDL path | 012,016 |
| S19 | Multi | Confirmed USB on `P` | `force_usb_drop(P)` -> `awdl_candidate_arrives(U)` -> `awdl_candidate_arrives(P)` -> `emit_session_resume(P, awdl)` | `P` AWDL confirmed despite `U` contention | 001,006,011,016 |
| S20 | Single + Multi | Long-run churn test | Randomized 200-step injected sequence with fixed seed across all events | No invariant violations; stable recovery windows met | 001-016 |
| S21 | Single (SPAM) | Confirmed USB on `P` | Repeat 200x: `force_usb_drop(P)` -> `plug_usb(P)` with bounded `advance_time` | No reconnect stall, no key burst flood | 010,016 |
| S22 | Single (SPAM) | Confirmed AWDL on `P` | Burst key payload test under reconnect churn | No lag-spike flush of stale buffered characters | 010,016 |
| S23 | Multi (SPAM) | Confirmed session on `P`, `U` pairing mode | Candidate storm from `U` + periodic drop/reconnect on `P` | `P` remains recoverable and never permanently evicted | 001,011,016 |
| S24 | Multi (SPAM) | No confirmed session | Alternating USB-first/AWDL-first 500-step seeded storm | Deterministic replay and zero invariant violations | 001-016 |

## Coverage Dimensions (For Generator)

- Transport order: `USB->AWDL`, `AWDL->USB`, same-transport reconnect
- Identity order: `P first`, `U first`, simultaneous candidate arrivals
- Agent lifecycle: `fresh`, `post-relaunch with persisted pairing`
- Failure mode: `timeout`, `forced drop`, `stale candidate`, `idle pending`
- Retry dynamics: `unpaired bounded retry`, `paired exponential backoff`

## Pass/Fail Criteria

- Suite fails immediately on first invariant breach and outputs:
  - scenario id
  - seed (if randomized)
  - exact event trace
  - observed vs expected state diff
- Suite passes only if:
  - all deterministic core scenarios `S01-S20` pass
  - all deterministic spam scenarios `S21-S24` pass in stress mode
  - invariant monitor reports zero violations
  - convergence SLA for `INV-016` remains within configured bound

## Implementation Notes

- Keep this matrix as the canonical acceptance spec for transport arbitration behavior.
- Any transport-state-machine change must update this file and corresponding suite coverage.
- New bug repros should first be encoded as a new `Sxx` scenario before code fix.
