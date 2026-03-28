---
phase: 2
slug: foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-28
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (unit tests within Xcode projects) + pure C test executables for protocol/compression tests |
| **Config file** | None — embedded in Xcode project schemes (Wave 0 creates these) |
| **Quick run command** | `make -C RemoteDesktop/Tests test_protocol test_lz4 test_delta` |
| **Full suite command** | `xcodebuild test -project RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj -scheme RemoteDesktopAgentTests` + `make -C RemoteDesktop/Tests` |
| **Estimated runtime** | ~5 seconds (quick), ~30 seconds (full) |

---

## Sampling Rate

- **After every task commit:** Run `make -C RemoteDesktop/Tests test_protocol test_lz4 test_delta`
- **After every plan wave:** Full Xcode scheme test run on macOS agent + iPad simulator
- **Before `/gsd:verify-work`:** Full suite must be green + USB NCM loopback test passing on physical devices
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| TBD | 01 | 0 | RD-COMP-01 | unit (C) | `make -C RemoteDesktop/Tests test_lz4` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-COMP-02 | unit (C) | `make -C RemoteDesktop/Tests test_delta` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-COMP-04 | unit (C) | `make -C RemoteDesktop/Tests test_delta_concurrent` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-TRANS-08 | unit (C) | `make -C RemoteDesktop/Tests test_protocol` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-CAP-05 | unit (ObjC) | `xcodebuild test -scheme RemoteDesktopAgentTests` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-COMP-05 | unit (ObjC, ASan) | `xcodebuild test -scheme RemoteDesktopAgentTests` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-SEC-01/02 | integration (loopback) | `xcodebuild test -scheme RemoteDesktopAgentTests` | ❌ W0 | ⬜ pending |
| TBD | 01 | 0 | RD-REND-03 | unit (Swift, XCTest) | `xcodebuild test -project RemoteDesktop/iPadOS/...` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `RemoteDesktop/Tests/Protocol/FramingTests.c` — stubs for RD-TRANS-08
- [ ] `RemoteDesktop/Tests/Compression/LZ4RoundtripTests.c` — stubs for RD-COMP-01
- [ ] `RemoteDesktop/Tests/Compression/DeltaTests.c` — stubs for RD-COMP-02, RD-COMP-04
- [ ] `RemoteDesktop/Tests/Makefile` — builds and runs pure C tests without Xcode
- [ ] `RemoteDesktop/macOS/RemoteDesktopAgentTests/` — XCTest target for macOS agent
- [ ] `RemoteDesktop/iPadOS/RemoteDesktopAppTests/` — XCTest target for iPad app

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| USB NCM UDP loopback ping-pong | RD-TRANS-01, RD-TRANS-09 | Requires physical iPad + Mac connected via USB-C | 1. Connect iPad to Mac via USB-C 2. Run loopback test binary on both devices 3. Verify UDP packets traverse wiredEthernet interface |
| Mac agent CPU <3% during wired streaming | RD-PERF-03 | Requires live streaming + Instruments profiling | 1. Start wired streaming session 2. Open Instruments Energy Log 3. Monitor CPU for 60 seconds, verify <3% |
| Glass-to-glass latency <8ms wired | RD-PERF-01 | Requires 2 physical devices + timestamped frames | 1. Run latency measurement tool 2. Display timestamp on Mac, capture on iPad 3. Measure delta across 100 frames |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
