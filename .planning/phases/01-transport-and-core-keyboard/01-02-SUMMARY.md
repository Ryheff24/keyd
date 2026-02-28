---
phase: 01-transport-and-core-keyboard
plan: "02"
subsystem: transport
tags: [nwlistener, cgevent, bonjour, usbmuxd, swift6, servicemanagement, iohid, accessibility]

# Dependency graph
requires:
  - phase: 01-01
    provides: SharedProtocol Swift Package (KeydMessage types, MessageEncoder, MessageDecoder)

provides:
  - macOS KeydAgent app: builds clean (BUILD SUCCEEDED)
  - USBListener: NWListener on localhost:12345 for usbmuxd forwarded connections
  - AWDLListener: NWParameters.applicationService + _keyd._tcp Bonjour service
  - TransportManager: USB primary + AWDL pre-warmed standby; silent USB→AWDL handoff
  - CGEventInjector: Unicode character injection + virtual key injection with defer modifier cleanup
  - InjectionRouter: routes KeydMessage to CGEventInjector; releaseModifiers on disconnect
  - PermissionChecker: AX + Input Monitoring checks at every launch; blocking alert with System Settings link
  - StatusBarController: menu bar icon with USB/AWDL/Disconnected states + SF Symbol icons
  - Secure input polling: IsSecureEventInputEnabled() every 500ms; SecureInputChanged message on state change
affects:
  - 01-03 (iOS app — builds against this macOS receiver)
  - 01-04 (pairing — TransportManager.send() already wired)
  - 01-05 (transport hardening — baseline to harden)

# Tech tracking
tech-stack:
  added:
    - Network.framework NWListener (USB + AWDL)
    - ServiceManagement (SMAppService.mainApp.register)
    - IOKit.hid (IOHIDRequestAccess for Input Monitoring)
    - Accessibility (AXIsProcessTrustedWithOptions)
    - Carbon.HIToolbox (IsSecureEventInputEnabled)
    - CoreGraphics (CGEvent, CGEventPost, CGKeyCode)
  patterns:
    - Swift 6 strict concurrency with @MainActor TransportManager + actor USBListener/AWDLListener
    - @Sendable closures on actor-crossing connection handlers
    - defer block for modifier key-up (prevents stuck modifier on error/disconnect)
    - .cgAnnotatedSessionEventTap for reliable CGEvent delivery to frontmost app
    - AX read-only (never write via AX — CGEvent is the sole write path)

key-files:
  created:
    - macOS/KeydAgent/App/KeydAgentApp.swift
    - macOS/KeydAgent/MenuBar/PermissionChecker.swift
    - macOS/KeydAgent/MenuBar/StatusBarController.swift
    - macOS/KeydAgent/Transport/USBListener.swift
    - macOS/KeydAgent/Transport/AWDLListener.swift
    - macOS/KeydAgent/Transport/TransportManager.swift
    - macOS/KeydAgent/Injection/CGEventInjector.swift
    - macOS/KeydAgent/Injection/InjectionRouter.swift
    - macOS/KeydAgent/Injection/AXInjector.swift
    - macOS/KeydAgent/KeydAgent.entitlements
    - macOS/KeydAgent/Info.plist
    - macOS/project.yml
    - macOS/KeydAgent.xcodeproj/project.pbxproj
  modified:
    - macOS/KeydAgent/Transport/AWDLListener.swift (added @Sendable to onConnection)
    - macOS/KeydAgent/Transport/TransportManager.swift (added Carbon.HIToolbox import)
    - macOS/KeydAgent/Injection/CGEventInjector.swift (fixed .annotatedSession to .cgAnnotatedSessionEventTap)
    - macOS/KeydAgent/MenuBar/PermissionChecker.swift (Swift 6 safe AX prompt key)
    - macOS/KeydAgent/App/KeydAgentApp.swift (added @MainActor to startTransport)

key-decisions:
  - "App Sandbox disabled in entitlements (required for CGEventPost and AX operations)"
  - "IsSecureEventInputEnabled polled from Carbon.HIToolbox not CoreGraphics"
  - "kAXTrustedCheckOptionPrompt used as string literal to avoid Swift 6 shared mutable state warning"
  - "AWDL standby connection kept live while USB is active for sub-second handoff on USB disconnect"
  - "defer block in injectVirtualKey guarantees modifier key-up fires even on error paths (SHORT-11)"

patterns-established:
  - "Pattern 1: CGEvent only for writes — AXInjector is read-only stub"
  - "Pattern 2: @Sendable closure on all actor-crossing callbacks"
  - "Pattern 3: TransportManager.releaseModifiers() called on every disconnect path"
  - "Pattern 4: Both USB and AWDL listeners start concurrently (AWDL pre-warmed per TRANS-04)"

requirements-completed:
  - TRANS-01
  - TRANS-02
  - TRANS-04
  - TRANS-07
  - KEY-01
  - KEY-02
  - SHORT-01
  - SHORT-02
  - SHORT-03
  - SHORT-04
  - SHORT-05
  - SHORT-06
  - SHORT-07
  - SHORT-08
  - SHORT-09
  - SHORT-10
  - SHORT-11
  - AGENT-01
  - AGENT-02
  - AGENT-03
  - AGENT-04
  - AGENT-05
  - AGENT-06

# Metrics
duration: 3min
completed: 2026-02-28
---

# Phase 1 Plan 02: macOS KeydAgent Summary

**macOS helper agent builds clean: CGEvent keystroke injection pipeline with USB/AWDL dual transport, secure input polling, and permission gating via NWListener + SMAppService**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-28T14:20:51Z
- **Completed:** 2026-02-28T14:24:00Z
- **Tasks:** 4
- **Files modified:** 13

## Accomplishments
- macOS KeydAgent builds clean (BUILD SUCCEEDED, no errors)
- Full receive-and-inject pipeline: USB NWListener → MessageDecoder → InjectionRouter → CGEventInjector → frontmost app
- AWDL pre-warmed standby with silent USB→AWDL handoff on disconnect (TRANS-03)
- Secure input polling (IsSecureEventInputEnabled every 500ms) with SecureInputChanged message on state change (AGENT-06)
- Modifier key stuck-key prevention: defer block in injectVirtualKey + releaseAllModifiers on disconnect (SHORT-11)
- Both AX and Input Monitoring permissions checked at every launch with blocking alert and System Settings deep-link

## Task Commits

Each task was committed atomically:

1. **Task 1: Verify project structure, fix entitlements, auto-fix build errors** - `d3b7e98` (chore)
2. **Task 2: App entry point, permission check, menu bar** - `7874152` (feat)
3. **Task 3: USB/AWDL listeners and TransportManager** - covered in `d3b7e98`
4. **Task 4: Injection router + build verification** - `5f90fb9` (feat)
5. **Project files:** - `5857a0b` (chore)

## Files Created/Modified
- `macOS/KeydAgent/App/KeydAgentApp.swift` - @main entry, accessory policy, SMAppService, permission gate
- `macOS/KeydAgent/MenuBar/PermissionChecker.swift` - AX + Input Monitoring check; blocking alert with System Settings link
- `macOS/KeydAgent/MenuBar/StatusBarController.swift` - USB/AWDL/Disconnected states with SF Symbol icons
- `macOS/KeydAgent/Transport/USBListener.swift` - NWListener on localhost:12345 for usbmuxd TCP forwarding
- `macOS/KeydAgent/Transport/AWDLListener.swift` - NWListener with _keyd._tcp Bonjour service for AWDL
- `macOS/KeydAgent/Transport/TransportManager.swift` - Connection state machine; AWDL standby; secure input polling
- `macOS/KeydAgent/Injection/CGEventInjector.swift` - Unicode char injection; virtual key + modifier injection with defer
- `macOS/KeydAgent/Injection/InjectionRouter.swift` - Message dispatch; releaseModifiers on disconnect
- `macOS/KeydAgent/Injection/AXInjector.swift` - Read-only focused element stub (no AX writes)
- `macOS/KeydAgent/KeydAgent.entitlements` - App Sandbox = false; network.server + network.client
- `macOS/KeydAgent/Info.plist` - App metadata
- `macOS/project.yml` - xcodegen config: macOS 14.0, Swift 6, SharedProtocol dependency
- `macOS/KeydAgent.xcodeproj/project.pbxproj` - Xcode project with SharedProtocol local package

## Decisions Made
- App Sandbox disabled in entitlements — required for CGEventPost and AX operations (no CGEvent in sandboxed apps)
- `IsSecureEventInputEnabled()` imported from Carbon.HIToolbox — not available directly in CoreGraphics
- `kAXTrustedCheckOptionPrompt` used as string literal `"AXTrustedCheckOptionPrompt"` to avoid Swift 6 shared mutable state error
- AWDL standby connection kept live while USB active — allows sub-second handoff on USB disconnect without re-discovery
- `defer` block in `injectVirtualKey` guarantees modifier key-up fires even if an error path is hit mid-sequence (SHORT-11)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] AWDLListener.onConnection missing @Sendable**
- **Found during:** Task 1 (initial build verification)
- **Issue:** `AWDLListener.onConnection` was `((NWConnection) -> Void)?` — Swift 6 strict concurrency requires `@Sendable` for actor-crossing closures
- **Fix:** Changed to `(@Sendable (NWConnection) -> Void)?` and updated `setOnConnection` extension
- **Files modified:** `macOS/KeydAgent/Transport/AWDLListener.swift`, `macOS/KeydAgent/Transport/TransportManager.swift`
- **Verification:** Build succeeded after fix
- **Committed in:** `d3b7e98`

**2. [Rule 1 - Bug] CGEventInjector.postKey used wrong tap location**
- **Found during:** Task 1 (initial build)
- **Issue:** `event?.post(tap: .annotatedSession)` — `CGEventTapLocation` has no member `annotatedSession`; correct name is `.cgAnnotatedSessionEventTap`
- **Fix:** Changed to `.cgAnnotatedSessionEventTap`
- **Files modified:** `macOS/KeydAgent/Injection/CGEventInjector.swift`
- **Verification:** Build succeeded; all other CGEvent posts already used correct constant
- **Committed in:** `d3b7e98`

**3. [Rule 3 - Blocking] TransportManager missing IsSecureEventInputEnabled import**
- **Found during:** Task 1 (build)
- **Issue:** `IsSecureEventInputEnabled` not found — requires `Carbon.HIToolbox`
- **Fix:** Added `import Carbon.HIToolbox` to TransportManager.swift
- **Files modified:** `macOS/KeydAgent/Transport/TransportManager.swift`
- **Verification:** Build succeeded
- **Committed in:** `d3b7e98`

**4. [Rule 1 - Bug] PermissionChecker kAXTrustedCheckOptionPrompt Swift 6 error**
- **Found during:** Task 1 (build)
- **Issue:** `kAXTrustedCheckOptionPrompt` is a global `Unmanaged<CFString>` — Swift 6 flags as non-Sendable shared state
- **Fix:** Used string literal `"AXTrustedCheckOptionPrompt"` directly (same runtime value, Swift 6 safe)
- **Files modified:** `macOS/KeydAgent/MenuBar/PermissionChecker.swift`
- **Verification:** Build succeeded
- **Committed in:** `d3b7e98`

**5. [Rule 1 - Bug] startTransport() needs @MainActor for TransportManager.init**
- **Found during:** Task 1 (build)
- **Issue:** `TransportManager.init` is `@MainActor`-isolated but `startTransport()` was not annotated
- **Fix:** Added `@MainActor` to `startTransport()` in AppDelegate
- **Files modified:** `macOS/KeydAgent/App/KeydAgentApp.swift`
- **Verification:** Build succeeded
- **Committed in:** `d3b7e98`

---

**Total deviations:** 5 auto-fixed (4 Rule 1 bugs, 1 Rule 3 blocking)
**Impact on plan:** All auto-fixes necessary for Swift 6 strict concurrency and correct API usage. No scope creep. The pre-existing source files had partial implementations that needed fixing to compile under Swift 6.

## Issues Encountered
- The Xcode project and source files were pre-existing from a prior session but had not been committed to git. Build errors were latent Swift 6 concurrency issues that triggered when building with the full Swift 6 module map.
- Entitlements file was empty (just `<dict/>`) — needed full entitlements with App Sandbox = false.

## User Setup Required
After building, user must configure macOS permissions:
1. Open System Settings → Privacy & Security → Accessibility → enable KeydAgent
2. Open System Settings → Privacy & Security → Input Monitoring → enable KeydAgent
3. Note: Both permissions are revoked on every Xcode rebuild — toggle off/on after each rebuild
4. First launch: right-click → Open (Gatekeeper) or run `xattr -d com.apple.quarantine /path/to/KeydAgent.app`

## Next Phase Readiness
- macOS receiver is complete and buildable — iOS app development (Plan 03) can proceed
- TransportManager.send() is already wired — pairing (Plan 04) only needs to add PairingManager
- Both USB and AWDL listeners start on launch — iOS can connect immediately after permissions granted
- Known: AWDL entitlement requirements for self-signed provisioning need physical device testing

## Self-Check: PASSED

---
*Phase: 01-transport-and-core-keyboard*
*Completed: 2026-02-28*
