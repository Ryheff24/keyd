# Roadmap: keyd

## Overview

Three phases that build toward a frozen transport layer: Phase 1 establishes the binary transport stack (USB + AWDL) and delivers a working keyboard that types into macOS in real time. Phase 2 adds bidirectional text sync, giving the iPhone cursor control, text selection, predictive text, and a live preview of the macOS field. Phase 3 makes the hotkey panel app-aware, so shortcut sets update automatically when the frontmost macOS application changes.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Transport and Core Keyboard** - USB + AWDL transport implemented and under device validation, stock keyboard host types into macOS, hotkey panel operational (completed 2026-03-01)
- [ ] **Phase 2: Bidirectional Text Sync and Advanced Editing** - Cursor control, text selection, predictive text, and live macOS field mirror on iOS
- [ ] **Phase 3: App-Aware Hotkey Panel** - Hotkey panel shows app-specific shortcuts based on frontmost macOS application

## Phase Details

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
- [x] 01-06-PLAN.md — Transport state machine formalization (explicit FSM). Phase 1.1 harness operational for verification (completed 2026-03-01)
- [ ] 01-07-PLAN.md — On-device test suite (XCTest + scenario matrix + invariant checker). Phase 1.1 harness operational for verification

### Phase 01.1: Connected Integration Test Suite (INSERTED)

**Goal:** End-to-end connected integration test suite validating real USB/AWDL connections, pairing handshakes, and message round-trips on physical hardware; 4 regression tests for commit 9046927 bugs; latency benchmark; `make test-integration` single-command entry point that gates `make deploy`
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Depends on:** Phase 1 (SharedProtocol, KeydApp, KeydAgent fully implemented)
**Plans:** 3/4 plans executed

Plans:
- [ ] 01.1-01-PLAN.md — SharedProtocol TestReset/TestResetAck protocol extension
- [ ] 01.1-02-PLAN.md — macOS agent --test-mode flag (2s timeouts, wire log, in-memory pairing, conn-N IDs, testReset handler)
- [ ] 01.1-03-PLAN.md — iOS KeydIntegrationTests XCTest target + IntegrationHarness + Suite C
- [ ] 01.1-04-PLAN.md — CLI wiring: deploy-and-run.sh test-integration mode + Makefile deploy gate

### Phase 2: Bidirectional Text Sync and Advanced Editing
**Goal**: iOS editing gestures and cursor controls operate on the macOS field, predictive text suggestions reflect the macOS field content, and the iOS app shows a live text mirror of what is in the macOS field
**Depends on**: Phase 1
**Requirements**: EDIT-01, EDIT-02, EDIT-03, EDIT-04, EDIT-05, EDIT-06, EDIT-07, UX-04
**Success Criteria** (what must be TRUE):
  1. User taps arrow controls on the iPhone and the cursor moves in the focused macOS text field in the expected direction
  2. User uses iOS selection gestures and the corresponding text becomes selected in the macOS field; user can then delete the selection from iOS
  3. iOS QuickType bar shows suggestions that are contextually relevant to the current content of the macOS field, not the iOS device state
  4. iOS app displays a real-time text preview box that mirrors the content and cursor position of the focused macOS field
  5. iOS cut/copy/paste editing menu operations execute on the macOS field content
**Plans**: TBD

### Phase 3: App-Aware Hotkey Panel
**Goal**: The iOS hotkey panel automatically switches to an app-specific shortcut set when the macOS frontmost application changes, covering Safari, Firefox, and Messages with a default fallback for all other apps
**Depends on**: Phase 2
**Requirements**: APP-01, APP-02, APP-03, APP-04, APP-05, APP-06
**Success Criteria** (what must be TRUE):
  1. User switches to Safari on the Mac and the iOS hotkey panel updates to show Safari-specific shortcuts within one second
  2. User switches to Firefox or Messages on the Mac and the hotkey panel updates to show the correct app-specific shortcut set
  3. User switches to any unrecognized macOS app and the hotkey panel falls back to the default shortcut set without error
  4. Hotkey panel transitions between shortcut sets with a visible Liquid Glass fade or slide animation
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 1.1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Transport and Core Keyboard | 7/7 | Complete   | 2026-03-01 |
| 1.1. Connected Integration Test Suite | 4/4 | Complete   | 2026-03-01 |
| 2. Bidirectional Text Sync and Advanced Editing | 0/TBD | Not started | - |
| 3. App-Aware Hotkey Panel | 0/TBD | Not started | - |
