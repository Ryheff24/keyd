# Milestones

## v1.0 — keyd Keyboard (completed 2026-03-01)

**Goal:** iPhone becomes a full-featured keyboard controlling macOS text entry in real time over USB/AWDL.

**Phases:** 1 through 1.1 (Transport + Core Keyboard, Integration Test Suite)
**Last phase number:** 1.1

**Shipped:**
- SharedProtocol SPM package (Messages, Encoder, Decoder, FSM, EventLog — 73/73 tests)
- macOS agent: USB/AWDL listeners, CGEvent injection, menu bar, permissions, QR pairing
- iOS app: keyboard UI, hotkey panel, dual transport, pairing, Dynamic Island, debug overlay
- Integration test suite with XCTest, scenario matrix, invariant checker

**Pending (from v1.0 roadmap):**
- Phase 2: Bidirectional Text Sync (cursor, selection, predictive text, live mirror)
- Phase 3: App-Aware Hotkey Panel (Safari, Firefox, Messages detection)

**Status:** Phase 1 verified, Phase 1.1 complete. Phases 2-3 deferred — keyd-rd (v2.0) is P0.
