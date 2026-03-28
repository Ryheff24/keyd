# keyd

## What This Is

keyd is a personal-use Apple device ecosystem with two products:

1. **keyd (v1.0)** — iPhone acts as a physical keyboard/editor controlling macOS text entry in real time over USB/AWDL. Phase 1 complete, phases 2-3 deferred.

2. **keyd-rd (v2.0, active)** — iPad Pro becomes a zero-latency remote desktop for macOS over USB-C/Thunderbolt (USB NCM) with Wi-Fi/AWDL fallback. C + Objective-C on Mac (minimal resource usage), Swift on iPad. Full mouse + keyboard input, hardware-accelerated screen streaming, audio, clipboard sync.

Both products share this repo with separate Xcode projects and bundle IDs. Designed exclusively for personal use — self-signed, not distributed.

## Core Value

The iPad becomes a zero-latency remote desktop for macOS over a direct USB-C cable — full resolution, full input (mouse + keyboard), hardware-accelerated, with near-zero Mac CPU cost. No cloud, no account, no subscription, no infrastructure.

## Current Milestone: v2.0 Remote Desktop

**Goal:** Ship a working iPadOS-to-macOS remote desktop with sub-8ms wired latency, <3% Mac CPU usage, full input support, audio streaming, and clipboard sync.

**Target features:**
- Screen streaming over USB NCM (LZ4+delta) with Wi-Fi/AWDL fallback (HEVC)
- Full mouse input (touch-to-mouse translation) + keyboard passthrough
- Audio streaming (Mac audio piped to iPad)
- Bidirectional clipboard sync
- Eco mode for resource-constrained scenarios
- QR pairing with TLS 1.3 encryption
- Deterministic E2E test suite across 2 physical devices

## Requirements

### Validated

- USB transport via usbmuxd (keyd v1.0)
- AWDL fallback transport (keyd v1.0)
- CGEvent injection for keyboard/mouse (keyd v1.0)
- QR pairing with ECDH key exchange (keyd v1.0)
- Transport failover state machine (keyd v1.0)

### Active

- [ ] USB NCM transport with UDP media stream + TCP input stream
- [ ] Wi-Fi fallback with HEVC hardware encoding
- [ ] AWDL last-resort fallback
- [ ] ScreenCaptureKit full-display capture at Retina resolution, up to 120fps
- [ ] LZ4 + delta frame compression (wired mode)
- [ ] HEVC hardware encode/decode (wireless mode)
- [ ] Metal rendering on iPad (P3 color, ProMotion 120Hz)
- [ ] Touch-to-mouse input translation (move, click, scroll)
- [ ] Keyboard passthrough (physical + on-screen)
- [ ] Audio streaming (Mac → iPad)
- [ ] Bidirectional clipboard sync
- [ ] Eco mode (reduced resolution/framerate, <1% Mac CPU)
- [ ] TLS 1.3 / DTLS 1.3 encryption on all channels
- [ ] macOS agent in C + Objective-C (no Swift runtime)
- [ ] Deterministic E2E testing across physical devices

### Out of Scope

- Multi-monitor support — deferred to v2.1 (adds complexity, single display sufficient for v2.0)
- File drag-and-drop — deferred to v2.1
- iPad V2 C rewrite — separate milestone after v2.0 is proven
- Bluetooth transport — excluded by design
- App Store distribution — personal use, self-signed only
- keyd v1.0 phases 2-3 — deferred until keyd-rd ships

## Context

- **Hardware:** MacBook Pro M1 Max (32 GB, resource-starved — runs LLMs) + iPad Pro M4 (8 GB, idle resources)
- **Compute strategy:** Heavy work on iPad (decompress, render, color manage), near-zero work on Mac (capture + LZ4 + send)
- **Transport cascade:** USB NCM (primary) > Infrastructure Wi-Fi (fallback) > AWDL (last resort)
- **Mac language:** C + Objective-C only — no Swift runtime overhead (~15-30 MB saved)
- **iPad language:** Swift (V1) — adequate for client with idle resources
- **Protocol:** Binary framing (24-byte media header, 9-byte input header) — no JSON in data path
- **Shared infra from keyd v1.0:** QR pairing, CGEvent patterns, Bonjour discovery, failover FSM, menu bar agent
- **Self-signed lifecycle:** Refreshed weekly via Xcode or manual signing

## Constraints

- **DC-1: Mac resource-starved** — <3% CPU, <50 MB RSS during wired streaming. Mac runs LLMs concurrently.
- **DC-2: No Swift on macOS** — C + Objective-C only. Apple frameworks are native Obj-C/C.
- **DC-3: Swift on iPad V1** — C rewrite deferred to separate milestone.
- **DC-4: Two physical devices for E2E** — Deterministic tests, both sides know exact payloads.
- **DC-5: Reuse keyd infra** — Don't rebuild what already works.
- **Distribution:** Personal use only, self-signed certificate, weekly refresh.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| UDP for media over USB NCM | Thinnest protocol available to non-jailbroken iPadOS apps (8-byte header) | Chosen |
| TCP for input | Input events must be reliable and ordered | Chosen |
| LZ4 + delta for wired | Near-zero Mac CPU cost, sufficient compression for TB4 bandwidth | Chosen |
| HEVC for wireless | Hardware media engine, not CPU/GPU — doesn't compete with LLM workloads | Chosen |
| C + Obj-C on macOS | No Swift runtime, minimal memory footprint (~3-5 MB vs ~15-30 MB) | Chosen |
| CGEvent for input injection | AX writes silently fail in Safari/Firefox (proven in keyd v1.0) | Chosen |
| ScreenCaptureKit for capture | Apple's modern, hardware-accelerated capture API | Chosen |
| Metal for iPad rendering | Hardware-accelerated, P3 color, ProMotion 120Hz | Chosen |
| QR pairing with ECDH | Proven in keyd v1.0, reuse pattern | Chosen |
| TLS 1.3 mandatory | No cleartext mode, even over USB | Chosen |
| Heavy compute on iPad | M4 iPad faster single-core than M1 Max, and iPad has idle resources | Chosen |
| Binary protocol only | No JSON/text encoding in data path | Chosen |
| USB NCM > Wi-Fi > AWDL | NCM for speed, Wi-Fi for reliability, AWDL for zero-infra fallback | Chosen |

## Bundle Identifiers

- macOS agent: `com.ryheff.keyd.remote.agent`
- iPadOS app: `com.ryheff.keyd.remote.app`
- iPadOS tests: `com.ryheff.keyd.remote.app.tests`

---
*Last updated: 2026-03-27 after v2.0 milestone initialization*
