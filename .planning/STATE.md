# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.
**Current focus:** Phase 1 — Transport and Core Keyboard

## Current Position

Phase: 1 of 3 (Transport and Core Keyboard)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-02-27 — Roadmap created

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: -
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: -
- Trend: -

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Pre-Phase 1]: USB primary, AWDL fallback — lowest latency on USB; AWDL preserves connection on unplug
- [Pre-Phase 1]: AX read + CGEvent write — AX value writes silently fail in Safari/Firefox; CGEvent is the only reliable write path
- [Pre-Phase 1]: Foreground UIViewController (not UIInputViewController) — extensions cannot initiate network connections
- [Pre-Phase 1]: Binary framing (4-byte length prefix) over JSON — required for sub-50ms latency
- [Pre-Phase 1]: No App Sandbox on macOS helper — sandbox blocks CGEventPost and AX operations

### Pending Todos

None yet.

### Blockers/Concerns

- [Phase 1]: AWDL entitlement requirements for self-signed personal-use provisioning are LOW confidence — must test NWBrowser + NWListener on a physical device with infrastructure Wi-Fi and Bluetooth disabled before writing any AWDL-dependent code
- [Phase 1]: usbmuxd iOS 18 TCP forwarding behavior needs physical-device validation before building the full transport layer
- [Phase 2]: AXObserver cross-process PID behavior for Safari and Firefox web content processes — verify before implementing real-time reflection

## Session Continuity

Last session: 2026-02-28
Stopped at: Phase 1 scaffolding partially built (macOS agent compiles); plan-phase ran out of tokens before creating PLAN.md files
Resume with: `/gsd:plan-phase 1`

### What's already built (do not rebuild)
- `SharedProtocol/` SPM package — Messages, MessageEncoder, MessageDecoder — builds + tests pass
- `macOS/KeydAgent/` Xcode project — Transport, Injection, MenuBar, App layers
  - Build fixed: CGEventInjector (import + tap location), TransportManager (import), AXInjector (framework), USBListener (@Sendable)
  - AWDLListener @Sendable fix may still be needed (interrupted before confirming)
  - Build command: `xcodebuild -project macOS/KeydAgent.xcodeproj -scheme KeydAgent -destination "platform=macOS,arch=arm64" build`

### What's NOT done yet (plan-phase didn't complete)
- No PLAN.md files in `.planning/phases/01-transport-and-core-keyboard/`
- No iOS app Xcode project created yet
- No pairing/QR code flow
- No Dynamic Island integration
- No hotkey panel UI
