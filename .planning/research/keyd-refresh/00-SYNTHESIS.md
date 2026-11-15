# keyd refresh — synthesis (2026-10-29)

Combines three Haiku research reports (`01-apple-platform-docs.md`, `02-ui-principles-and-glass.md`,
`03-code-and-infra-reuse.md`). Key claims were re-checked by the orchestrator against the Xcode 27.1 SDK and
the source; corrections are listed first. Read-only research: no code was changed.

## Corrections to the agent reports (verified)

| Report claim | Verified fact |
|---|---|
| 01: "`AXIsProcessTrusted` is deprecated" | Wrong. `AXUIElement.h:74` is `CF_AVAILABLE_MAC(10_4)`, no deprecation. The deprecation note nearby belongs to `AXAPIEnabled`. |
| 01: "Wi-Fi Aware is iPad-only" | Wrong. `WiFiAware.swiftmodule` is `@available(iOS 26.0, *)` (iPhone and iPad), with 26.4 and 27.0 additions; `macOS, unavailable`. Conclusion unchanged: it cannot reach the Mac. |
| 01: "`glassEffect` / `GlassEffectContainer` not found, UNVERIFIED" | They exist. They live in `SwiftUICore.framework` (iOS 27.1 SDK swiftinterface), not `SwiftUI.framework`, which is why the agent's grep missed them. drdabber's `glass-api.md` (typechecked on Xcode 27.0) is the better reference. |
| 03: v1 transport unencrypted | Confirmed. `NWParameters.tcp` at `AWDLTransport.swift:73,123`, `USBTransport.swift:64`, `AWDLListener.swift:16`. The ECDH key from `macOS/KeydAgent/Pairing/PairingManager.swift:85-100` is saved to Keychain and never used by transport. |
| 03: team ID split, E2E `git add -A` | Confirmed (`KeydApp/project.yml:51,73,95,126` = `""`; `macOS/project.yml` = `M2DUW2UUKH`; `run-e2e-tests.sh:676`). |
| 02: green/yellow/orange/red status, faux glass panel | Confirmed (`ConnectionStatusView.swift:11-13`, `HotkeyPanel.swift:5,80`). |

Still unverified (Apple's 27.x release-note pages returned stubs): macOS 27 TCC / Accessibility / Secure Input
behavior changes, Xcode 27 default concurrency build settings, ActivityKit/ControlWidget 27 changes.

## Platform baseline (verified)

- macOS 27.2 / iOS 27.2 shipped 2026-10-26. Xcode 27.1 installed (27.2 RC out). Swift 6.4.
- macOS text injection: `CGEventKeyboardSetUnicodeString`, `CGEventPost`, `CGPreflightPostEventAccess` /
  `CGRequestPostEventAccess` all present. CGEvent stays the only write path; no new sanctioned remote-keyboard API.
- AWDL via `includePeerToPeer` remains the Mac-reachable wireless path. Wi-Fi Aware is iOS-only.
- New in 27: Network pacing (`setMaximumPacingRateBytesPerSecond`), SwiftUI `onPasteCommand`/`copyable`/
  `cuttable` (useful for the editor), `NSGlassEffectView.effectIsInteractive` (macOS 27).
- Paid account: 1-year provisioning removes the weekly re-sign in `idea.md`. Skip multicast and Wi-Fi Aware entitlements.

## The rebuild, in priority order

1. **Secure the link.** TLS 1.3 via `NWProtocolTLS` with a pinned SHA-256 cert fingerprint carried in the QR
   (RemoteDesktop's model, `USBNetworkTransport.m:186-200`), but with the identity generated in Keychain — not
   RD's `/tmp/keydrd-tls` PKCS12 with passphrase `keydrd`. Put it in a small shared Swift package.
2. **Raise the floor to iOS 27 / macOS 27.** Personal-use app, paid account, both devices on 27.x. Unlocks real
   Liquid Glass with no fallbacks (drdabber's "no fallbacks" stance) and Swift 6 strict concurrency everywhere.
   *Owner decision.*
3. **Project hygiene (drdabber/videocap pattern).** XcodeGen with `.xcodeproj` git-ignored and a `make gen`
   target; one `Signing.xcconfig` holding `M2DUW2UUKH`; Swift 6 + `SWIFT_STRICT_CONCURRENCY complete` on all
   targets; move `KeydApp/KeydApp/Debug/*` out of the production target.
4. **UI to drdabber standard.**
   - Adapt (not copy) drdabber's `liquid-glass-ui` skill into `keyd/.claude/skills/liquid-glass-ui/`: copy
     `references/glass-api.md` nearly verbatim, keep only the Apple rows of `sources.md`, rewrite `SKILL.md`
     without drdabber's private A/D citations and Ember-specific rules, add macOS menu-bar and Live Activity sections.
   - Glass on keys (`.buttonStyle(.glass)` in one `GlassEffectContainer`), fills on the hotkey panel — the reverse of v1.
   - Status palette blue / amber / red with shape + word on every state (switcher `Tokens.swift`,
     `StatusShape.swift`). No green anywhere — including drdabber's default accent `#0E6B27`.
   - drdabber navigation shape: `AppRouter`, a Settings tab grouped in the user's words, debug tools only in a
     developer-mode Dev tab, connection status as the `tabViewBottomAccessory` mini bar.
   - Text styles, not fixed sizes (`HotkeyPanel.swift:114-130`); sans + `.monospacedDigit()` for the pairing code.
5. **macOS agent polish.** Copy switcher `SingleInstanceGuard.swift`; `SMAppService` login item (Promptbar
   `StatusMenu.swift:235-248`); rotating file log with test-host guard (Promptbar `Log.swift`); the agent never
   calls `NSApp.activate` itself.
6. **Workflow.** Promptbar's pid-proof `deploy.sh`; videocap `make help`/`make logs`; explicit-path staging, no
   auto-commit to `main`; merge `CLAUDE.md` and `agents.md` into one rule source; drop the Makefile's absolute
   paths into `RemoteDesktop/scripts`.

## Open decisions for the owner

1. Deployment floor: iOS 27 / macOS 27 (recommended) vs keep 17/14 with `#available` fallbacks.
2. USB transport: keep usbmuxd (locked in `idea.md` Phase 1) or move to RD's USB NCM + TLS path. Recommend keeping
   usbmuxd and putting TLS over it; NCM only if usbmuxd breaks on 27.
3. Dark-first like drdabber, or follow system appearance.
4. Menu bar: keep `NSStatusItem` + `NSMenu`, or move to `MenuBarExtra(.window)` like switcher.
