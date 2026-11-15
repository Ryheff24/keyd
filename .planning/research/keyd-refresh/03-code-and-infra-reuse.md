# 03 — Code and infrastructure reuse for a keyd rebuild

Scope: read-only audit. Nothing in the repo or siblings was modified and no builds or E2E scripts were run. Paths are absolute. Where a claim is a judgement rather than a read, it is marked **inference**.

Projects surveyed deeply: keyd (v1 + RemoteDesktop), drdabber, switcher, prompt-utilities. Skimmed: videocap, llama-tui, healthbot, video/intab-fullscreen-safari, apps/healthExports (only layout and build config were checked; treat as lighter evidence).

---

## 1. Project table

| Project (absolute path) | Platform / deployment target | Targets | Swift / concurrency | Project generation | Notable reusable parts |
|---|---|---|---|---|---|
| `.` (v1 = `KeydApp/`, `macOS/`, `SharedProtocol/`) | iOS 17.0 (`KeydApp/project.yml:8,40`); macOS 14.0 (`macOS/project.yml:8`); SPM iOS17/macOS14 (`SharedProtocol/Package.swift:7-9`) | KeydApp, KeydAppTests, KeydIntegrationTests, KeydLiveActivity (widget ext); KeydAgent, KeydAgentTests | iOS `SWIFT_VERSION 5.9` (`KeydApp/project.yml`); agent `6.0` (`macOS/project.yml:33`); SPM tools 5.9 | XcodeGen `project.yml` per app, but `.xcodeproj` checked in; **no `gen` target** in `Makefile`. `DEVELOPMENT_TEAM: ""` in all four iOS targets (`KeydApp/project.yml:51,73,95,126`) while agent uses `M2DUW2UUKH` (`macOS/project.yml:29,60`) | `SharedProtocol` (Messages, MessageEncoder/Decoder, KeydLogger, TransportEventLog, TransportStateMachine); `scripts/deploy-and-run.sh` (467 lines); `macOS/KeydAgent/MenuBar/PermissionChecker.swift` |
| `./RemoteDesktop` (keyd-rd) | macOS agent: `MACOSX_DEPLOYMENT_TARGET 14.2`, hardened runtime on, app sandbox off (`macOS/RemoteDesktopAgent.xcodeproj/project.pbxproj`, `macOS/Resources/RemoteDesktopAgent.entitlements`). iPad: iOS 17.0 | `RemoteDesktopAgent` (C + Obj-C, ARC), `RemoteDesktopApp` (Swift) | iPad `SWIFT_VERSION 5.0`; agent is C/ObjC by design (no Swift runtime, per `.planning/PROJECT.md`) | **Hand-maintained pbxproj**, no `project.yml`; `RemoteDesktop.xcworkspace` | `macOS/Transport/USBNetworkTransport.m` (getifaddrs NCM detection, l.318-400); `macOS/Pairing/PairingManager.m` + `iPadOS/Pairing/QRPairing.swift` (QR + TLS pinning); `scripts/ipad-debug.sh`, `mac-debug.sh`, `run-apps.sh`, `run-e2e-tests.sh` (1431 lines), `async-index.sh` |
| `~/Documents/projects/drdabber` (`src/App`, `src/Tools/junk/SwitchKit`, `Scripts/ember` Go harness) | iOS 27.0 (`project.yml`, `src/App/Config/Project.xcconfig`); SwitchKit iOS 27 / macOS 15 / watchOS 27 | Ember app, Widgets, Catalogue, EmberUITests; SwitchKit package (10 library products) | `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete` (`project.yml` settings base). SwitchKit tools 6.2 (`src/Tools/junk/SwitchKit/Package.swift:1`). ~100 `@MainActor`/`actor`/`@Observable` sites, 84 files mention `Sendable` | **XcodeGen** `project.yml`; generated `.xcodeproj` is git-ignored. Layered xcconfig: `Project.xcconfig` → `Signing.xcconfig` (`EMBER_TEAM_ID = M2DUW2UUKH`) → `Team.local.xcconfig` (ignored) → `Pairing.xcconfig` (`PAIRING_MODE` switch) | `Scripts/ember` Go harness (`Harness/`), `Makefile` wrappers, `AGENTS.md`, `docs/briefs/implementation-process.md`, `.claude/agents/*.md`, `.claude/skills/ember-harness/SKILL.md`, `src/App/Config/*.xcconfig` layering, `os.Logger` subsystem convention (`com.user.switch2`) |
| `~/Documents/projects/switcher/Switcher` (`switchd`) | macOS 26.0, arm64 only (`Switcher/project.yml`), `ENABLE_HARDENED_RUNTIME NO`, `CODE_SIGNING_ALLOWED NO` (ad-hoc) | Switcher app, SwitcherTests (hosted unit tests) | Swift 6.0, `SWIFT_STRICT_CONCURRENCY complete`; stores `@Observable @MainActor` (per `switcher/CLAUDE.md`) | XcodeGen `project.yml`; `.xcodeproj` checked in and is source of truth at runtime (`switcher/CLAUDE.md`). `Install Switcher.command` builds, copies to `/Applications`, writes `~/Library/LaunchAgents/com.ryheff.switchd.plist`, `launchctl kickstart` | `Switcher/Support/SingleInstanceGuard.swift`; `Switcher/App/GlobalHotkey.swift` (Carbon `RegisterEventHotKey`, ⌃⌥S, no Accessibility needed); `Switcher/Actions/ProcessRunner` + `SafetyPolicy` (command allowlist); `scripts/showcase.sh`, `scripts/coverage.sh`, `px-audit.py`; `Log` → `os.Logger` + `~/Library/Logs/switchd/events.log` |
| `~/Documents/projects/prompt-utilities` (Promptbar) | macOS 26 (`Package.swift:6`) | SPM executable `Promptbar` + tests; packaged to `.app` by `Scripts/package-app.sh` | swift-tools 6.2, `swiftLanguageMode(.v5)` for both targets (`Package.swift:8,12`) | **Pure SPM** (`Package.swift`) plus shell packaging | `Sources/Promptbar/Accessibility.swift` (AX trust check and prompt); `StatusMenu.swift` (NSStatusItem menu; `SMAppService` login item, l.235-248); `GlobalHotKey.swift` (Carbon, "needs no Accessibility permission"); `Log.swift` (rotating file log, test-host guard l.11); `SelfTest.swift` (confirmation-gated live self-test); `Scripts/deploy.sh` (pid-verification deploy) |
| `~/Documents/projects/videocap` | iOS 17.0 | VideoCap app | Swift 5.0 (`project.yml`) | **XcodeGen** `project.yml`; `Makefile` with `help` target generated from `## ` comments and `logs` target (`devicectl device process launch --console`) | `Makefile` (`run: install logs`, l.44-50); `README.md` latency rationale (direct preview-layer render, no frame backlog) |
| `~/Documents/projects/llama-tui` (`daemon/`, `kit/`, `frontend/app/`, Go `cmd/` `internal/`) | macOS (Swift daemon/frontend), Go CLI/TUI | HubDaemon, ModelHub app (ModelHub.xcodeproj), Go TUI | Swift tools (daemon `Package.swift`); Go 1.21+ | Mixed: `project.yml` for frontend; SPM for daemon/kit; Go `Makefile` (`build`, `test`, `test ane <type>`) | Daemon control API on `127.0.0.1:8990` (`daemon/Sources/.../main`, `frontend/app/Sources/App/LaunchOptions.swift`); `AGENTS.md` context-minimisation rules |
| `~/Documents/projects/healthbot/HealthDaemonApp` | macOS 14 (`Package.swift`), tools 5.10 | HealthDaemonApp executable + tests | Swift 5.10 | SPM (`Package.swift`), Makefile at repo root | **gRPC over Unix domain socket** `~/.healthdaemon/healthdaemon.sock` with token metadata `x-healthdaemon-token` and a 0600 token file with 24h TTL (`Sources/Transport/GRPCClient.swift:18,48-50`; `Sources/Transport/AuthManager.swift:13-14`) |
| `~/Documents/projects/video/intab-fullscreen-safari` | macOS + iOS Xcode project (`InTabVideoFullscreen.xcodeproj`), Safari web extension | macOS app, iOS app, iOS extension | not surveyed | Xcode project | `AGENTS.md` working agreement ("Stage explicit paths only. Never use `git add -A`"; separate evidence levels) |
| `~/Documents/projects/apps/healthExports/dataExport` | not surveyed beyond layout | Xcode project + tests | not surveyed | `.xcodeproj` | none evaluated |

---

## 2. Reuse candidates for keyd (ranked by value)

Coupling key: **Low** = copy or imitate with little change; **Med** = needs adaptation to keyd's protocol or target set; **High** = depends on RD's C/ObjC or on its protocol headers.

### R1. Build / deploy / live-log scripts (value: high, coupling: low, action: imitate)

- **Replaces:** keyd `scripts/deploy-and-run.sh` (467 lines, modes deploy/run/stop/attach/test-integration) and `Makefile` `attach`/`run-apps` plumbing.
- **Pattern sources:**
  - `~/Documents/projects/prompt-utilities/Scripts/deploy.sh` — quits the old process, starts the new bundle, then **proves the running pid is this build** (checks pid count = 1, executable path equals built binary, process start time ≥ build mtime). This is the single best idea to copy; keyd's deploy has no equivalent proof step.
  - `~/Documents/projects/videocap/Makefile` — `help` target auto-generated from `## ` comments (l.28-30), `install` = `build` + `devicectl device install`, `logs` relaunches with `--console` into a log file (l.44-50). Cheap to adopt for keyd's `Makefile`, which has no `help` and no project-generation target.
  - `./RemoteDesktop/scripts/ipad-debug.sh` — lockfile that kills a prior run (l.12-24), trap-based cleanup, `devicectl --console` capture. Useful for the iPad side; note it sleeps for the timeout rather than watching.
- **Caveat:** keyd `Makefile` hard-codes `RUN_APPS_SCRIPT` and `E2E_SCRIPT` as absolute `~/...` paths into `RemoteDesktop/scripts` (`Makefile` top). Do not import those into a keyd rebuild.

### R2. Transport security and QR pairing from RemoteDesktop (value: high, coupling: high, action: imitate the pattern in Swift; do not copy files)

- **What keyd v1 does today (verified):**
  - Pairing runs ECDH over Curve25519 and stores a shared secret in Keychain (`KeydApp/KeydApp/Pairing/PairingManager.swift` header comment; `macOS/KeydAgent/Pairing/PairingManager.swift`).
  - The transport never uses that secret. A grep for `ChaChaPoly|AES|HKDF|sharedSecret|seal(` across `KeydApp/KeydApp/Transport`, `macOS/KeydAgent/Transport` and `SharedProtocol/Sources` finds nothing outside the two PairingManager files.
  - The AWDL listener is plain TCP: `NWParameters.tcp` in `macOS/KeydAgent/Transport/AWDLListener.swift:16`.
  - USB is raw length-prefixed JSON over the usbmuxd tunnel (`SharedProtocol/Sources/SharedProtocol/MessageEncoder.swift`; `macOS/KeydAgent/Transport/USBListener.swift`).
  - **Inference:** on a shared Wi-Fi or AWDL link, any local peer that can reach port 12345 or the Bonjour service can inject keystrokes, because nothing authenticates the connection after pairing.
- **What RD does:**
  - TLS 1.3 minimum (`iPadOS/Pairing/QRPairing.swift:455-457`, `:827-829`; `iPadOS/Transport/WirelessTransport.swift:208-210`).
  - Certificate pinning by SHA-256 fingerprint of the peer cert, stored in Keychain (`macOS/Transport/USBNetworkTransport.m:186-200`). A verify block completes `false` when nothing is stored (`:250-256`).
  - QR payload carries the fingerprint (`macOS/Pairing/PairingManager.h` header, "QR code is the trust anchor").
  - Keyd v1's `QRPayload` (`PairingManager.swift`) already has the same shape (`publicKeyBase64`, `port`, `agentID`, `version`), so the QR format is a short change.
- **Do not copy these RD details:**
  - The identity is a PKCS12 file at `/tmp/keydrd-tls/identity.p12` with the **hard-coded passphrase `keydrd`** (`scripts/mac-debug.sh:73-81`, `scripts/run-apps.sh:211-219`, `macOS/Pairing/PairingManager.m:97-98`). The private key sits in `/tmp`.
  - Test-only accept-any TLS verify exists in `iPadOS/Pairing/QRPairing.swift:~437-464` (`completePairingTestMode`). It is test-only by name but compiled into the production target.
- **Recommended shape for keyd:** generate a P-256 identity in Keychain (no `/tmp`, no PKCS12 round-trip), use `NWProtocolTLS` with a pinned-fingerprint verify block on both ends, and derive per-message MACs from the existing ECDH secret so the pairing secret is actually used.
- **Extract vs copy:** extract a small Swift package (`SharedTransportSecurity`) once, consumed by both keyd agent and iOS app. Keep usbmuxd, since `idea.md` locks "Wired over USB using usbmuxd" as a Phase 1 invariant. Only the USB NCM detection (R3) is worth borrowing from RD if keyd ever moves off usbmuxd.

### R3. USB NCM interface detection via getifaddrs (value: medium, coupling: medium, action: copy the function, do not adopt NCM yet)

- `./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:318-400` enumerates interfaces with `getifaddrs()` because NWPathMonitor cannot see 169.254.x.x links. It skips `en0` and `bridge*`.
- Relevant only if keyd adds a link-local transport later. Under the current usbmuxd design it adds nothing.

### R4. macOS permissions, event injection, menu bar, login item (value: medium, coupling: low, action: imitate)

- **Permissions:** keyd already has `macOS/KeydAgent/MenuBar/PermissionChecker.swift`, which is the same idea as switcher's AX check (`switcher/Switcher/Switcher/Model/LiveStateEvents.swift:122`, `Detection/GhosttyBridge.swift:204`). Promptbar's `Sources/Promptbar/Accessibility.swift` adds an explicit `requestTrust()` that only runs from a user action. Keyd's `PermissionChecker` already does this split (check silently, request only on menu click). No change needed.
- **Hotkeys:** `switcher/Switcher/App/GlobalHotkey.swift` and `prompt-utilities/Sources/Promptbar/GlobalHotKey.swift` both use Carbon `RegisterEventHotKey`, which needs no Accessibility permission. Keyd's agent has no global-hotkey requirement in v1; if one is added, use this pattern instead of an event tap.
- **Single instance:** `switcher/Switcher/Support/SingleInstanceGuard.swift` (about 20 lines, uses `NSRunningApplication.runningApplications(withBundleIdentifier:)`). Keyd agent has no single-instance guard; copy this.
- **Login item:** `prompt-utilities/Sources/Promptbar/StatusMenu.swift:235-248` uses `SMAppService.mainApp` and opens Login Items when approval is required. Switcher uses a hand-written LaunchAgent plist instead (`switcher/Install Switcher.command`, l.134-165). Prefer SMAppService.
- **Process execution allowlist:** `switcher/CLAUDE.md` describes `ProcessRunner.runSafe` + `SafetyPolicy`. Relevant only if the keyd agent ever shells out.
- **Injection:** keyd's `macOS/KeydAgent/Injection/InjectionRouter.swift` routes to `CGEventInjector` (117 lines) and a stub `AXInjector` (25 lines). Nothing in the siblings contradicts the memory note that CGEvent is the write path. No sibling does text injection, so there is nothing to reuse here.

### R5. Logging conventions (value: medium, coupling: low, action: imitate)

- keyd: `SharedProtocol/Sources/SharedProtocol/KeydLogger.swift` wraps `os.Logger` and mirrors to stderr. Good for `log stream`, but there is no file log.
- Promptbar `Sources/Promptbar/Log.swift`: rotating file at `~/Library/Logs/Promptbar/promptbar.log`, rotated at 1 MB, and **writes are skipped when `Bundle.main.bundleIdentifier` is not the app's id** (l.11), so the test host never writes the user's log. Adopt the rotation and the test-host guard.
- Switcher `Log`: `os.Logger` plus `~/Library/Logs/switchd/events.log` (`switcher/CLAUDE.md`, "Logging").
- drdabber: `Logger(subsystem: "com.user.switch2", category: ...)` in `src/Tools/junk/SwitchKit/Sources/SwitchBluetooth/CoreBluetoothClient.swift:7` and `SwitchPairing`. Keyd should use one subsystem for all targets (`com.ryheff.keyd`, already in `KeydLogger`).

### R6. Test harnesses (value: medium, coupling: medium, action: imitate the layering, do not copy the scale)

- **Do not copy** RD's E2E: `RemoteDesktop/macOS/Tests/E2ETests.m` (1147 lines), `iPadOS/App/DeviceTestRunner.swift` (3345 lines), `scripts/run-e2e-tests.sh` (1431 lines). Their cost is the reason the keyd memory asks for a skill with direction. Fresh keyd tests should be small and layered.
- **Keyd v1 issue:** `KeydApp/KeydApp/Debug/` (`TransportTestRunner.swift`, `TransportManager+Testing.swift`, `TransportTestRunnerView.swift`, `DebugOverlayView.swift`) is compiled into the production app target. Move it into a test-only target.
- **Pattern to imitate:** switcher hosts its unit tests in the app and keeps the app inert under test (`switcher/CLAUDE.md`, "Tests and coverage"). Promptbar does the same via `Bundle.main.bundleIdentifier` (see R5). Together with a coverage ratchet (`switcher/scripts/coverage.sh`, floor in `coverage/threshold`) that is a complete unit-test story for keyd's `SharedProtocol` and `TransportStateMachine`.
- **Protocol-level tests:** RD has `macOS/Tests/WireFormatTests.m` and `ProtocolTests.m` (C/ObjC wire format). Keyd's `SharedProtocol/Tests/SharedProtocolTests/MessageRoundTripTests.swift` already covers the equivalent. Keep keyd's.
- **Device proof:** drdabber's approach (`docs/briefs/implementation-process.md`, "Proof is before and after") is a useful model: a reproduction in the simulator before a fix, and an evidence file per run. Do not adopt the rest of drdabber's harness for a project this size.

### R7. Project generation and signing (value: medium, coupling: low, action: copy the layering)

- Copy drdabber's xcconfig stack (`src/App/Config/Signing.xcconfig` + gitignored `Team.local.xcconfig.example`, `Pairing.xcconfig`). Keyd currently puts `DEVELOPMENT_TEAM: ""` in `KeydApp/project.yml` and the real ID in the agent yml. Move the team ID into one `Signing.xcconfig` and let `project.yml` include it.
- Pick one project-generation model. keyd has `project.yml` plus a checked-in `.xcodeproj` and no `gen` target, so the two can drift. Either regenerate in a `make gen` target (videocap pattern) or drop the yml. drdabber and videocap both chose XcodeGen with the `.xcodeproj` git-ignored. Switcher's checked-in project is the exception to avoid.
- Swift language mode: drdabber and switcher use `SWIFT_STRICT_CONCURRENCY complete`. Keyd is 5.9 on iOS and 6.0 on the agent. Pick one.

### R8. Local control channel (value: low for v1, coupling: low, action: imitate if needed)

- healthbot `HealthDaemonApp/Sources/Transport/GRPCClient.swift` uses gRPC over a Unix socket with a token in metadata, and `AuthManager.swift` keeps the token in a 0600 file with a 24 h TTL. This is the pattern to use if keyd ever needs a local control socket (for example an agent-side CLI) that is not reachable from the network.
- llama-tui uses plain HTTP on `127.0.0.1:8990` (`llama-tui/frontend/app/Sources/App/LaunchOptions.swift`). Adequate for loopback, but not a pattern for keyd's network-facing transport.

### R9. Things *not* worth reusing

- `RemoteDesktop/macOS/Compress/FrameCompressor.c`, `Encode/HEVCEncoder.m`, `Capture/ScreenCapture.m`, the Metal renderer, and the LZ4 code: all video-specific.
- drdabber `SwitchKit` Bluetooth and Switch-controller code: out of domain.
- `RemoteDesktop/macOS/MenuBar/StatusBarController.m`: keyd's Swift `StatusBarController.swift` is already equivalent and keyd agent is Swift by memory choice.

---

## 3. Development-workflow conventions that evolved after keyd

Sources are the files named; these are conventions keyd does not yet have.

1. **Model and effort pinned in agent definitions.** drdabber `.claude/agents/opus-medium.md`, `opus-high.md`, `opus-xhigh.md`, `sonnet-*.md`, `haiku-medium.md` (each with `model:` and `effort:` frontmatter; the body says "The prompt carries the role and task"). keyd has only GSD agents and `pipeline-debug.md` (`model: opus`, `effort: high`). Adopt the drdabber set; it matches the global `~/.claude/CLAUDE.md` profiles.
2. **One rule source.** drdabber: `AGENTS.md` is a repo map plus non-negotiables and points to `docs/briefs/implementation-process.md` as "the only rule source" (`AGENTS.md`, `docs/briefs/implementation-process.md` top section). keyd splits rules across `CLAUDE.md`, `agents.md` (same content, duplicated), and `.planning/`. Consolidate into one file.
3. **Explicit staging.** `video/intab-fullscreen-safari/AGENTS.md`: "Stage explicit paths only. Never use `git add -A`". keyd's `scripts/run-e2e-tests.sh` (`create_report_commit`, around l.669-677) runs `git add -A -- . ':(exclude)...'` and commits to `main` automatically. **This is the riskiest workflow in the repo.** Adopt explicit paths and remove the auto-commit to `main`.
4. **Heavy-job limits in code.** drdabber `AGENTS.md` ("Heavy jobs at once on this Mac ... they are code, not settings"). Relevant because keyd's E2E builds two apps in parallel and runs a 90 s stream.
5. **Harness wraps every command.** drdabber `Scripts/ember run --build -- <cmd>` and `make` targets; agents read `Scripts/ember summary` instead of logs (`docs/briefs/implementation-process.md`, "Large logs are summarised by a reporter agent"). Keyd agents currently read logs directly; the RD `run-e2e-tests.sh` writes `/tmp/e2e-results.log` (memory).
6. **Issue-first and proof-first (drdabber).** `AGENTS.md`, "The issue comes first" and "Proof is before and after, always." Adopt "reproduce before fix, record before and after", without the GitHub-issue dependency for a single-owner repo.
7. **Tests named before the flow runs.** drdabber `Scripts/ember e2e --list | --dry-run | --build-only` need no device. Keyd's E2E can get the same shape: `--dry-run` that prints the plan without touching devices.
8. **Makefile self-documentation.** videocap `Makefile` l.28-30 (`help` from `## ` comments).
9. **Bundle ID and team in one place.** drdabber `src/App/Config/Signing.xcconfig`, switcher `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`), keyd `macOS/project.yml` vs `KeydApp/project.yml` (inconsistent team IDs).
10. **Process cleanup on exit.** Promptbar `deploy.sh` (pkill, SIGKILL fallback, pid verify); RD `ipad-debug.sh` (lockfile, `trap cleanup EXIT`). Keyd `deploy-and-run.sh` has `stop` mode but no pid proof.
11. **Context minimisation for agents.** llama-tui `AGENTS.md` ("Start with `get_symbols_overview`... Only read symbol bodies when needed"); intab `AGENTS.md` ("evidence levels"). The keyd memory notes ask for exactly this: an agent that stops re-exploring the repo.
12. **Research docs convention.** drdabber `docs/research/` with `prompts/`, `responses/`, `archive/` and a README waiting table; `.planning/research/keyd-refresh/` (this file) is the keyd equivalent. Keep the prompt and answer pair under one folder.

---

## 4. Things in keyd v1 that are now outdated relative to siblings

1. **Transport is unauthenticated after pairing.** Pairing derives a secret that no transport code uses (see R2). Sibling RD pins TLS certificates. Highest-priority outdated item.
2. **Test code in the production app target.** `KeydApp/KeydApp/Debug/*` (7 files) ships inside `KeydApp`. Siblings keep test runners in test targets or behind a test host guard (Promptbar `Log.swift:11`, switcher `CLAUDE.md`).
3. **Team ID split.** `KeydApp/project.yml` sets `DEVELOPMENT_TEAM: ""` (four targets); `macOS/project.yml` sets `M2DUW2UUKH`. Memory note says "Don't set DevelopmentTeam = ''". Keyd's own memory conflicts with its own yml.
4. **Two project-generation states.** XcodeGen `project.yml` is present but `.xcodeproj` is checked in, with no `gen` target in `Makefile`. drdabber and videocap generate and git-ignore the project.
5. **Makefile hard-codes absolute paths** into `RemoteDesktop/scripts` (`Makefile`, `RUN_APPS_SCRIPT` and `E2E_SCRIPT`). Breaks on any other checkout.
6. **Deployment and language versions.** iOS 17.0 and Swift 5.9 for the app, macOS 14.0 and Swift 6.0 for the agent. Siblings have moved to Swift 6.0 strict concurrency (drdabber, switcher) or Swift 6.2 tools (prompt-utilities, drdabber SwitchKit). This is a choice, not a defect; flag it for the rebuild.
7. **Logging is stderr plus os_log only.** No file log, no rotation. Promptbar and switcher both keep a rotating file in `~/Library/Logs`.
8. **Login item and single instance missing.** Switcher and Promptbar have both; keyd agent has neither.
9. **Duplicated agent rules.** `./CLAUDE.md` and `./agents.md` carry the same operating rules (device-only physical actions, debug scripts, logging). Keep one, and point the other at it.
10. **`run-e2e-tests.sh` commits to `main` automatically** and uses `git add -A` (see workflow item 3). The sibling convention is explicit paths and human-gated commits.
11. **Stray artifacts at repo root.** `default.profraw` (0 bytes) and `scripts/__pycache__` are stray artifacts; `.gitignore` covers `logs/` and `.build/` but not `*.profraw`.

---

## Gaps and confidence

- Not read in depth: videocap source, healthbot daemon Go code, intab Safari extension code, healthExports, llama-tui Go internals, prompt-utilities Views/Proxy.
- `run-e2e-tests.sh` and `DeviceTestRunner.swift` were sampled by headers and grep, not read in full, as the audit asked.
- The "unauthenticated after pairing" finding is from grep plus reading `AWDLListener.swift` and `USBListener.swift`. It is not a traced runtime test.
