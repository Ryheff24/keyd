# Roadmap: keyd

## Milestones

- **v1.0 keyd Keyboard** — Phases 1–1.1 (shipped 2026-03-01)
- **v2.0 Remote Desktop** — Phases 2–5 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

<details>
<summary>v1.0 keyd Keyboard (Phases 1–1.1) — SHIPPED 2026-03-01</summary>

- [x] **Phase 1: Transport and Core Keyboard** - USB + AWDL transport implemented, stock keyboard types into macOS, hotkey panel operational (completed 2026-03-01)
- [x] **Phase 1.1: Connected Integration Test Suite** - E2E connected integration test suite on physical hardware, `make test-integration` single-command entry point (completed 2026-03-01)

### Phase 1: Transport and Core Keyboard
**Goal**: User can type characters, shortcuts, and control keys into the frontmost macOS field from the iPhone over USB using the in-app stock keyboard host, with automatic AWDL fallback when unplugged, and the macOS agent starts at login
**Depends on**: Nothing (first phase)
**Requirements**: TRANS-01, TRANS-02, TRANS-03, TRANS-04, TRANS-05, TRANS-06, TRANS-07, KEY-01, KEY-02, KEY-03, KEY-04, KEY-05, SHORT-01, SHORT-02, SHORT-03, SHORT-04, SHORT-05, SHORT-06, SHORT-07, SHORT-08, SHORT-09, SHORT-10, SHORT-11, AGENT-01, AGENT-02, AGENT-03, AGENT-04, AGENT-05, AGENT-06, UX-01, UX-02, UX-03
**Success Criteria** (what must be TRUE):
  1. User types on the iPhone keyboard and the characters appear in the currently focused macOS text field in real time over USB
  2. User unplugs the USB cable and the keyboard continues working over AWDL within a few seconds, with no manual reconnect step
  3. User taps any shortcut button (Cmd-C, Cmd-V, Cmd-Z, etc.) on the iPhone hotkey panel and the corresponding macOS shortcut executes in the frontmost app
  4. macOS agent menu bar icon shows the current connection state (USB / AWDL / disconnected) and prompts for Accessibility and Input Monitoring permissions if missing
  5. iPhone does not auto-lock while connected; hotkey panel pauses with a visible indicator when macOS has a password field focused
**Plans**: 7 plans

Plans:
- [x] 01-01-PLAN.md — SharedProtocol verify/update
- [x] 01-02-PLAN.md — macOS agent transport + injection + menu bar
- [x] 01-03-PLAN.md — iOS app (USB/AWDL transport, keyboard, hotkey panel)
- [x] 01-04-PLAN.md — QR pairing + Dynamic Island Live Activity
- [x] 01-05-PLAN.md — Transport hardening + device validation
- [x] 01-06-PLAN.md — Transport state machine formalization (explicit FSM)
- [x] 01-07-PLAN.md — On-device test suite (XCTest + scenario matrix + invariant checker)

### Phase 1.1: Connected Integration Test Suite (INSERTED)
**Goal**: End-to-end connected integration test suite validating real USB/AWDL connections, pairing handshakes, and message round-trips on physical hardware; 4 regression tests; latency benchmark; `make test-integration` single-command entry point that gates `make deploy`
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):
  1. `make test-integration` completes without user interaction on two physical devices
  2. Pairing, message round-trip, and failover scenarios all pass deterministically
**Plans**: 4 plans

Plans:
- [x] 01.1-01-PLAN.md — SharedProtocol TestReset/TestResetAck protocol extension
- [x] 01.1-02-PLAN.md — macOS agent --test-mode flag
- [x] 01.1-03-PLAN.md — iOS KeydIntegrationTests XCTest target + IntegrationHarness
- [x] 01.1-04-PLAN.md — CLI wiring: deploy-and-run.sh + Makefile deploy gate

</details>

### v2.0 Remote Desktop (In Progress)

**Milestone Goal:** iPad Pro becomes a zero-latency remote desktop for macOS over USB-C/Thunderbolt (USB NCM) with Wi-Fi/AWDL fallback, full input, audio, and clipboard sync.

- [ ] **Phase 2: Foundation** - End-to-end wired display pipeline: USB NCM transport, LZ4+delta capture and compression, Metal rendering, QR pairing, TLS/DTLS encryption, macOS agent and iPad app shells
- [ ] **Phase 3: Input** - Full remote desktop input: touch-to-mouse (tap, scroll, right-click, drag), keyboard passthrough (physical + on-screen), eco mode, cursor overlay
- [ ] **Phase 4: Testing and Wi-Fi Quality** - Deterministic E2E test suite (RD-TEST-01–10) passing on physical devices; Wi-Fi/AWDL HEVC path validated at full quality; VideoToolbox bitrate control experimentally confirmed
- [ ] **Phase 5: Audio and Clipboard** - System audio streaming (CoreAudio Tap → AAC-LC → UDP → AVAudioEngine) and bidirectional text clipboard sync

## Phase Details

### Phase 2: Foundation
**Goal**: The iPad displays the Mac screen over a USB cable at full Retina resolution with correct frame delivery, hardware-accelerated LZ4+delta compression, Metal ProMotion 120Hz rendering, automatic Wi-Fi/AWDL fallback, QR pairing, and TLS/DTLS encryption on all channels — the complete wired display pipeline works end-to-end
**Depends on**: Phase 1.1 (reuses keyd v1.0 QR pairing, CGEvent, Bonjour, failover FSM patterns)
**Requirements**: RD-TRANS-01, RD-TRANS-02, RD-TRANS-03, RD-TRANS-04, RD-TRANS-05, RD-TRANS-06, RD-TRANS-07, RD-TRANS-08, RD-TRANS-09, RD-TRANS-10, RD-CAP-01, RD-CAP-02, RD-CAP-03, RD-CAP-04, RD-CAP-05, RD-CAP-06, RD-COMP-01, RD-COMP-02, RD-COMP-03, RD-COMP-04, RD-COMP-05, RD-COMP-06, RD-COMP-07, RD-COMP-08, RD-COMP-09, RD-REND-01, RD-REND-02, RD-REND-03, RD-REND-04, RD-SEC-01, RD-SEC-02, RD-SEC-03, RD-SEC-04, RD-SEC-05, RD-AGENT-01, RD-AGENT-02, RD-AGENT-03, RD-AGENT-04, RD-AGENT-05, RD-AGENT-06, RD-AGENT-07, RD-APP-01, RD-APP-02, RD-APP-03, RD-APP-04, RD-APP-05, RD-APP-06, RD-APP-07, RD-PERF-01, RD-PERF-02, RD-PERF-03, RD-PERF-04, RD-PERF-07
**Success Criteria** (what must be TRUE):
  1. User plugs USB-C cable from iPad to Mac, scans QR code to pair, and the Mac screen appears on the iPad at full Retina resolution within a few seconds — no configuration beyond the QR scan
  2. User unplugs the cable and the Mac screen continues displaying on the iPad over Wi-Fi (or AWDL) within 2 seconds, with the HUD transport icon updating from USB to Wi-Fi
  3. User re-plugs the cable and the connection promotes back to USB NCM within 2 seconds
  4. Mac agent CPU usage stays below 3% during wired streaming and the agent uses 0% GPU at all times
  5. Glass-to-glass latency is below 8ms over wired (LZ4+delta) and below 25ms over wireless (HEVC)
**Plans**: 10 plans

Plans:
- [ ] 02-01-PLAN.md — Project scaffold (Xcode projects, shared C headers, LZ4, delta module)
- [ ] 02-02-PLAN.md — Screen capture + LZ4+delta compression pipeline (macOS)
- [ ] 02-03-PLAN.md — Transport layer: USB NCM, Wi-Fi, AWDL, failover FSM (both sides)
- [ ] 02-04-PLAN.md — TLS/DTLS encryption + QR pairing with ECDH (both sides)
- [ ] 02-05-PLAN.md — HEVC encode/decode + iPad LZ4 decompressor
- [ ] 02-06-PLAN.md — Metal rendering: ProMotion 120Hz, P3 color, letterbox (iPad)
- [ ] 02-07-PLAN.md — macOS agent shell: menu bar, permissions, SMAppService, session manager
- [ ] 02-08-PLAN.md — iPad app shell: ContentView, HUD overlay, session flow
- [ ] 02-09-PLAN.md — End-to-end wiring: session handshake, frame pipeline, failover integration
- [ ] 02-10-PLAN.md — End-to-end verification on physical devices

### Phase 3: Input
**Goal**: The iPad is a fully functional remote input device — touch controls the Mac cursor (tap, scroll, right-click, drag), physical and on-screen keyboards send keystrokes to the Mac, the cursor position is visible as an overlay on the iPad, and eco mode lets the Mac stay below 1% CPU for LLM-concurrent use
**Depends on**: Phase 2 (requires live display feed to validate cursor coordinate mapping and visual feedback)
**Requirements**: RD-INPUT-01, RD-INPUT-02, RD-INPUT-03, RD-INPUT-04, RD-INPUT-05, RD-INPUT-06, RD-INPUT-07, RD-INPUT-08, RD-INPUT-09, RD-INPUT-10, RD-PERF-05, RD-PERF-06, RD-PERF-08
**Success Criteria** (what must be TRUE):
  1. User taps the iPad screen and the Mac cursor moves to the exact corresponding position; single tap fires a left click; two-finger tap or long press fires a right click; two-finger pan scrolls the Mac content
  2. User types on a physical keyboard connected to the iPad and keystrokes appear in the focused Mac app with no dropped keys
  3. User toggles eco mode from the HUD and the Mac agent CPU drops to below 1% while the display continues streaming at reduced resolution and 30fps
  4. The Mac cursor position is visible as a rendered overlay on the iPad screen at all times, eliminating cursor-position confusion
  5. Input-to-screen latency (event sent to result visible on iPad) is below 12ms
**Plans**: TBD

### Phase 4: Testing and Wi-Fi Quality
**Goal**: The full pipeline is verified by a deterministic E2E test suite that both devices can run end-to-end using a shared PRNG seed, the Wi-Fi/HEVC path is validated for correct bitrate control and quality under real-world conditions, and benchmark results are saved to JSON for regression tracking
**Depends on**: Phase 3 (tests cover the complete pipeline including input)
**Requirements**: RD-TEST-01, RD-TEST-02, RD-TEST-03, RD-TEST-04, RD-TEST-05, RD-TEST-06, RD-TEST-07, RD-TEST-08, RD-TEST-09, RD-TEST-10
**Success Criteria** (what must be TRUE):
  1. Protocol and compression unit tests pass on a single machine with no physical devices required (loopback on lo0)
  2. Full E2E device test suite passes deterministically on two physical devices — synthetic frames traverse the complete capture-compress-send-receive-decompress-render pipeline and are verified bitwise on the receiving end
  3. Failover test: USB cable killed mid-stream → Wi-Fi takeover confirmed within 2 seconds with no manual intervention
  4. Benchmark results (throughput Gbps P50/P99, RTT latency P50/P99/P999) are written to a JSON file and can be compared across runs
**Plans**: TBD

### Phase 5: Audio and Clipboard
**Goal**: System audio from the Mac plays on the iPad with under 30ms latency, and text copied on either device is instantly available for paste on the other — both independent of the video pipeline, delivered over existing transport channels
**Depends on**: Phase 2 (reuses TCP control channel and UDP transport established in Foundation)
**Requirements**: RD-AUDIO-01, RD-AUDIO-02, RD-AUDIO-03, RD-AUDIO-04, RD-AUDIO-05, RD-CLIP-01, RD-CLIP-02, RD-CLIP-03, RD-CLIP-04
**Success Criteria** (what must be TRUE):
  1. User plays audio on the Mac and it plays on the iPad within 30ms, in sync with on-screen video content
  2. User copies text on the Mac and can immediately paste it on the iPad (and vice versa) without any manual sync step
  3. The iOS "app pasted from clipboard" privacy banner is documented in first-run UX so users are not surprised
**Plans**: TBD

## Progress

**Execution Order:**
v2.0 phases execute in numeric order: 2 → 3 → 4 → 5

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Transport and Core Keyboard | v1.0 | 7/7 | Complete | 2026-03-01 |
| 1.1. Connected Integration Test Suite | v1.0 | 4/4 | Complete | 2026-03-01 |
| 2. Foundation | v2.0 | 0/10 | Planned | - |
| 3. Input | v2.0 | 0/TBD | Not started | - |
| 4. Testing and Wi-Fi Quality | v2.0 | 0/TBD | Not started | - |
| 5. Audio and Clipboard | v2.0 | 0/TBD | Not started | - |
