# keyd

## What This Is

keyd is a personal-use iOS + macOS app pair where the iPhone acts as a physical keyboard/editor that controls text entry on the Mac in real time. Communication runs over USB via usbmuxd with automatic fallback to AWDL (Apple Wireless Direct Link) when USB is unplugged. Designed exclusively for personal use — self-signed, not distributed.

## Core Value

The iPhone becomes a full-featured keyboard that controls macOS text entry in real time over a direct USB/AWDL link — no Bluetooth, no infrastructure Wi-Fi, no internet required.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] USB transport via usbmuxd with real-time bidirectional communication
- [ ] AWDL wireless transport as primary fallback when USB is unplugged
- [ ] Automatic transport switchover on USB disconnect (USB → AWDL)
- [ ] Stock iOS keyboard hosted in-app that types into the currently focused macOS field
- [ ] Common macOS hotkeys (Cmd-C/X/V/Z/Shift-Z/A/Q, Option-Delete, Cmd-Delete, Cmd-Shift-4)
- [ ] iOS-native cursor movement controls mirrored to macOS
- [ ] iOS-native text selection mirrored to macOS
- [ ] Delete selected text on macOS from iOS controls
- [ ] Move cursor to arbitrary position and type/delete from iOS
- [ ] iOS predictive text feeding into macOS focused field
- [ ] iOS editing options (cut/copy/paste/select menu) reflected on macOS
- [ ] Real-time reflection of edits on macOS (planned around AX-based read/sync; CGEvent remains the write path)
- [ ] App-aware hotkey panel: detect frontmost macOS app, show relevant shortcuts
- [ ] "Liquid Glass" (Glassmorphism) visual style throughout iOS app

### Out of Scope

- Bluetooth transport — excluded by design (connectivity constraint)
- Infrastructure Wi-Fi — excluded by design (local-only constraint)
- App Store distribution — personal use, self-signed only
- Coding / terminal workflows — explicitly excluded
- Multi-user / server-side components — local-only
- Non-target apps (beyond Safari, Firefox, Messages) — v1 scope

## Context

- **Transport stack:** usbmuxd (USB) + AWDL; transport layer locked after Phase 1 and must not change
- **macOS text control:** Uses CGEvent for text/shortcut writes; AX is reserved for secure-input detection and later read/sync work
- **Target apps:** Safari, Firefox, Messages
- **Self-signed lifecycle:** Refreshed weekly via Xcode or manual signing
- **Design language:** Apple "Liquid Glass" / Glassmorphism
- **Phase 1 UI:** Stock in-app iOS keyboard host at bottom + macOS hotkey row above it
- **Phase 2 UI:** Adds predictive text bar above keyboard + text preview box above that

## Constraints

- **Connectivity:** No Bluetooth, no infrastructure Wi-Fi — USB (usbmuxd) and AWDL only
- **Distribution:** Personal use only, self-signed certificate, weekly refresh
- **Transport immutability:** Transport layer established in Phase 1 must not be modified in later phases
- **Target platform:** iOS app controlling macOS — no Android, no Windows
- **Design:** Must use Apple Liquid Glass visual style

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| USB primary, AWDL fallback | Lowest latency on USB; AWDL preserves connection on unplug | — Pending |
| CGEvent write + AX read/sync | Reliable text injection now, bidirectional state sync later | Chosen |
| Self-signed distribution | Personal use, avoids App Store review | — Pending |
| Liquid Glass design | Matches modern Apple aesthetic | — Pending |

---
*Last updated: 2026-02-28 after Phase 1 doc reconciliation*
