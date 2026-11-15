# keyd refresh: Apple platform research (as of 2026-10-29)

## Method and confidence

- **Local SDK headers and swiftinterfaces (strongest evidence).** Read from the installed Xcode 27.1 (build 27A9275): `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.sdk` (SDK 27.0) and `.../iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk`. Symbol presence and `@available` annotations are authoritative for what ships in the SDK. They say nothing about runtime behavior changes (TCC, Secure Input, USB networking).
- **apple-docs MCP.** Mostly returned a snapshot that predates iOS 27 (e.g. `NSGlassEffectView` shows macOS 26.0). Symbol searches for `glassEffect*` and `ControlWidget*` returned nothing. Used only for a few confirmations.
- **developer.apple.com.** Release-notes pages returned as redirect stubs or titles only. Release listing: https://developer.apple.com/news/releases/ (read via WebFetch). Release-note links: https://developer.apple.com/go/?id=macos-27_2-rn , https://developer.apple.com/go/?id=ios-27_2-rn , https://developer.apple.com/go/?id=xcode-27_2-sdk-rn . Their bodies could not be retrieved, so **behavioral release-note items are UNVERIFIED**.
- **Secondary web coverage** (MacRumors, Cult of Mac, DEV Community, Apple Developer Forums): used only where marked. Treat as leads, not facts.

### Current versions (verified)

| Item | Version | Source |
|---|---|---|
| Latest public OS | iOS / iPadOS / macOS 27.2, released Oct 26, 2026 (macOS 27.2 build 26B123; iOS 27.2 builds 24B91020 and 24B119 both listed) | https://developer.apple.com/news/releases/ |
| Xcode | 27.1 (27A9275) installed; 27.2 RC (27B48) listed Oct 19, 2026 | same; `xcodebuild -version` |
| Swift | Swift 6.4 (swiftlang-6.4.0.34.1) | `swift --version` in Xcode toolchain |
| macOS SDK | MacOSX27.sdk, version 27.0; MACOSX_DEPLOYMENT_TARGET default 27.0 | `SDKSettings.plist` / `SDKSettings.json` |
| iOS SDK | iPhoneOS27.1.sdk | directory listing |

Note on naming: the MacRumors/Cult of Mac coverage calls the macOS release "Golden Gate". I did not verify that from Apple. Note also that the WWDC26 keynote was June 8, 2026 (secondary: https://www.eweek.com/news/10-biggest-announcements-apple-wwdc-2026/ and https://www.macrumors.com/2026/05/07/ios-27-and-macos-27-rumored-features). No official WWDC26 session pages were reachable.

---

## Key takeaways for keyd

1. **Keep CGEvent as the only macOS write path, and add explicit permission checks.** `CGEventKeyboardSetUnicodeString` is still in the macOS 27 SDK (`CoreGraphics/CGEvent.h:205`). `CGPreflightPostEventAccess()` and `CGRequestPostEventAccess()` (`CGEvent.h:405, 408`, macOS 10.15+) exist. Use them to check and request posting access. Do not rely on `AXIsProcessTrusted()`, which the SDK marks deprecated in favor of `AXIsProcessTrustedWithOptions` (`HIServices/AXUIElement.h:49, 55-64`).
2. **Do not switch the Mac side to Input Method Kit.** IMKit headers are present (`InputMethodKit.framework/Headers`: `IMKServer.h`, `IMKInputController.h`, `IMKCandidates.h`). I found no new macOS 27 IMKit API for sending text from a remote device. An input method is a registered system component, which is heavier than keyd needs.
3. **Wi-Fi Aware is iPad-only, so it cannot replace AWDL on the Mac.** The `WiFiAware` Swift interface is `@available(iOS 26.0, *)` and `@available(macOS, unavailable)`. Keep the Bonjour/AWDL path via `NWParameters.includePeerToPeer` (iOS 12 / macOS 10.14, `Network` docs: https://developer.apple.com/documentation/network/nwparameters/includepeertopeer ; apple-docs MCP confirmed the availability line).
4. **Consider the new Network pacing and protocol-prepend APIs for the USB and AWDL transports.** The macOS 27 SDK adds `setMaximumPacingRateBytesPerSecond(_:)` (annotated `anyAppleOS 27.0`) and `prependApplicationProtocolIgnoringReady(options:)` (`macOS 27.0, iOS 27.0`) to the `Network` module. Both are useful for rate-limiting keyd's frame or keystroke stream and for TLS layering. The owning type was not confirmed (the line is inside a class in the swiftinterface, likely `NWConnection`). Verify before adopting.
5. **Do not request the multicast entitlement.** `com.apple.developer.networking.multicast` requires an approval request from Apple (forum reports: https://developer.apple.com/forums/thread/679089 , https://developer.apple.com/forums/thread/681444). keyd only needs unicast Bonjour over USB NCM and AWDL.
6. **Use SwiftUI 27 pasteboard commands for the iOS editing surface.** The iOS 27 SDK adds `copyable(_:)`, `cuttable(for:action:)`, `pasteDestination(for:action:validator:)`, `onCopyCommand`, `onCutCommand`, `onPasteCommand`, and `onDragSessionUpdated` (all `iOS 27.0` / `macOS 27.0` in `SwiftUI.swiftinterface`). These cover the Command-C/X/V path on the iPad side and the Mac-side hot-key menus.
7. **Adopt `NSGlassEffectView.effectIsInteractive` only if the Mac menu UI needs it.** It is annotated `API_AVAILABLE(macos(27.0))` in `NSGlassEffectView.h:45`. The class itself is macOS 26.0 (apple-docs MCP: https://developer.apple.com/documentation/appkit/nsglasseffectview).
8. **Re-check the Liquid Glass baseline before design work.** SDK-level glass APIs were confirmed only at the AppKit `NSGlassEffectView` level. I could not confirm `glassEffect` / `GlassEffectContainer` names or any iOS 27 changes from the SDK, so their status is UNVERIFIED. Secondary coverage says Apple updated "the foundations of how Liquid Glass is built" and added a Liquid Glass customization slider (https://www.cultofmac.com/news/liquid-glass-changes-ios-27-macos-27). A separate report says Golden Gate walks back some Liquid Glass design. These conflict. Confirm in the SDK once the symbols are checked.
9. **Plan around the Local Network and TCC permissions as unchanged until proven otherwise.** I found no official macOS 27 release-note text on Accessibility, Input Monitoring, or Local Network privacy. Forum reports (https://developer.apple.com/forums/thread/844416) describe system input hanging when Accessibility is revoked while a `CGEventTap` is active. Keep keyd's posting path free of event taps, or handle revocation.
10. **Verify the Swift 6.x concurrency defaults and build settings from the Xcode 27 templates, not from memory.** The Swift 6.4 toolchain is installed, but I could not retrieve the Xcode 27 release notes. Approachable-concurrency and MainActor-by-default status is UNVERIFIED.

---

## 1. Text input injection on macOS 27

**Confirmed (SDK headers, MacOSX27.sdk):**
- `CGEventKeyboardSetUnicodeString` — `CoreGraphics/CGEvent.h:205` (C name; Swift name `CGEvent.keyboardSetUnicodeString(self:stringLength:unicodeString:)` in `CoreGraphics.apinotes:1040`). No macOS 27-specific availability marker seen at that line.
- `CGEventPost` — `CGEvent.h:353`. `CGEventPostToPid` — `CGEvent.h:372`. A "DEPRECATED; use CGEventPostToPid instead" comment appears at `CGEvent.h:367` (check which declaration it governs before using).
- Event taps: `CGEventTapCreate` (`:296`), `CGEventTapCreateForPid` (`:315`). `CGEventTapCreateForPSN` is marked deprecated in its comment (`:305`).
- Listen and post access: `CGRequestListenEventAccess` (`:402`), `CGPreflightPostEventAccess` (`:405`), `CGRequestPostEventAccess` (`:408`). All `API_AVAILABLE(macos(10.15))`. apple-docs MCP confirmed `CGRequestListenEventAccess()` exists: https://developer.apple.com/documentation/coregraphics/cgrequestlistenevent­access()
- Accessibility trust: `AXIsProcessTrusted` is deprecated (`AXUIElement.h:49`). Use `AXIsProcessTrustedWithOptions` (`AXUIElement.h:55-64`).

**Forum signals (not authoritative):**
- Posting vs listening: "Accessibility" grants both, while "Input Monitoring" grants listening only (https://developer.apple.com/forums/thread/828052 , https://developer.apple.com/forums/thread/828082).
- App Store Guideline 2.4.5 rejection of a sandboxed clipboard app that used `CGEvent.post` for ⌘V (https://developer.apple.com/forums/thread/820594). Relevant only if keyd is ever distributed, which the idea sheet rules out.
- Revocation hang with an active event tap (https://developer.apple.com/forums/thread/844416 , https://developer.apple.com/forums/thread/735204).

**Secure Input:** I could not find `IsSecureEventInputEnabled` or `EnableSecureEventInput` in the Carbon/HIToolbox headers I checked. Its status in macOS 27 is UNVERIFIED. The usual limit still applies: Secure Input blocks CGEvent injection into password fields, so keyd cannot type into them.

**New sanctioned APIs for remote/virtual keyboards:** none found in the SDK. UNVERIFIED for runtime changes.

**Accessibility/TCC changes in macOS 27:** UNVERIFIED. The macOS 27.2 notes page returned a redirect stub only: https://developer.apple.com/go/?id=macos-27_2-rn

## 2. iOS 27 text editing

**Confirmed (iPhoneOS27.1.sdk, SwiftUI):**
- New in iOS/macOS 27 (annotated `iOS 27.0, macOS 27.0, visionOS 27.0`): `copyable`, `cuttable(for:action:)`, `pasteDestination(for:action:validator:)`, `onCopyCommand(perform:)`, `onCutCommand(perform:)`, `onPasteCommand(of:perform:)` and its validator variant, `onDragSessionUpdated(_:)`, `dragConfiguration(_:)`, `reorderable()` and the `reorderContainer` / `reorderDestination` family, `toolbarOverflowMenu`, `ToolbarMinimizationBehavior`, `ToolbarItemVisibilityPriority`, `Document` / `ReadableDocument` / `WritableDocument` protocols, `previewContext`, and `alert(error:actions:)`. Several of these are also in the macOS 27 SDK with `macOS 27.0` annotations.

**Confirmed (iPhoneOS27.1.sdk, UIKit):** `UIBarMinimization`, `UITraitSystemPrefersReducedResourceUsage`, `SystemPrefersReducedResourceUsageDidChangeMessage`, `UIBarButtonItemVisibilityPriority` initializers. Annotations are `iOS 27.0` or `iOS 27.1`.

**Not found in the SDK:** `UITextInput` / `UIKeyInput` / `UITextView` changes, a SwiftUI `TextEditor` / `TextField` change, hardware-keyboard API changes, dictation changes, and Writing Tools APIs. Treat these as UNVERIFIED. The keyd Phase 2 editing behaviors (cursor movement, selection, predictive text) should be built on the existing `UITextInput` / `UIKeyInput` surface until proven otherwise.

**Apple Intelligence / Siri AI:** keynote coverage says a Siri app and new Siri AI features arrived for developers (https://www.eweek.com/news/10-biggest-announcements-apple-wwdc-2026/). I found no API that feeds a remote text editor.

## 3. Networking

**Confirmed (SDK):**
- `Network.framework` (iOS/macOS 27, `Network.swiftmodule` arm64e swiftinterface): `prependApplicationProtocolIgnoringReady(options:)` (`@available(macOS 27.0, iOS 27.0, ...)`) and `setMaximumPacingRateBytesPerSecond(_:)` (`@available(anyAppleOS 27.0, *)`). The owning type was not confirmed from the lines I read.
- `Network.DTLS` appears in the interface. Its availability was not confirmed. Mark UNVERIFIED for 27.
- `includePeerToPeer` on `NWParameters` (apple-docs MCP): iOS 12.0, iPadOS 12.0, Mac Catalyst 12.0, macOS 10.14, tvOS 12.0, visionOS 1.0, watchOS 5.0. https://developer.apple.com/documentation/network/nwparameters/includepeertopeer
- `WiFiAware.swiftmodule` (SDK 27): `@available(iOS 26.0, *)`, `@available(macOS, unavailable)`, `@available(tvOS, unavailable)`, `@available(visionOS, unavailable)`, `@available(watchOS, unavailable)`. The Wi-Fi Aware entitlement page lists iOS 26.0 as baseline: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-aware.md
- Forum report: a Wi-Fi Aware network adapter appeared in a macOS 27 beta. No official answer (https://developer.apple.com/forums/thread/834091, unverified). Do not design around it.

**Multicast entitlement:** requires Apple approval. Forum reports describe the request form and the owner-only filing rule (https://developer.apple.com/forums/thread/679089 , https://developer.apple.com/forums/thread/786597).

**Local network privacy:** UNVERIFIED for macOS 27 / iOS 27 changes. Bonjour service types still need to be declared for `NWBrowser` / `NWListener` in Info.plist (`NSBonjourServices`). Forum reports say the multicast entitlement goes in the app entitlements file, not Info.plist.

**USB networking:** keyd's USB path uses USB NCM and `getifaddrs()` (per the project's locked decisions). I found no new public USB-networking API in the SDK, and the usbmuxd status is UNVERIFIED. Keep the USB NCM path.

**TLS/QUIC:** no new TLS API seen beyond the existing `Network` TLS options. QUIC status is UNVERIFIED.

## 4. Swift and Xcode 27 project and build changes

**Confirmed:** Xcode 27.1 (27A9275) with Swift 6.4 (`swift-driver 1.168.6`, `swiftlang-6.4.0.34.1`). Default target triple `arm64-apple-macosx27.2.0` (from `swift --version`).

**UNVERIFIED:** approachable concurrency, MainActor-by-default, strict concurrency defaults, Observation or SwiftData changes, and XcodeGen compatibility. The Xcode 27.2 SDK release-notes page returned a redirect stub: https://developer.apple.com/go/?id=xcode-27_2-sdk-rn

**Recommendation:** when `project.yml` (XcodeGen) is regenerated, compare the generated build settings for `SWIFT_VERSION`, `SWIFT_DEFAULT_ACTOR_ISOLATION`, and `SWIFT_APPROACHABLE_CONCURRENCY` against the Xcode 27.1 template. Do not infer them from memory.

## 5. Liquid Glass and design

**Confirmed (SDK):**
- `NSGlassEffectView` is `API_AVAILABLE(macos(26.0))` (`AppKit/NSGlassEffectView.h:19, 23`). Its `effectIsInteractive` property is `API_AVAILABLE(macos(27.0))` (`NSGlassEffectView.h:45`).
- Apple docs (apple-docs MCP): `NSGlassEffectView` exposes `contentView`, `cornerRadius`, `effectIsInteractive`, `style`, `tintColor`: https://developer.apple.com/documentation/appkit/nsglasseffectview
- AppKit 27 adds `NSToolbar.WillAddItemMessage` and `DidRemoveItemMessage` notifications (`AppKit.swiftinterface`, `macOS 27.0`).

**Not confirmed:** `glassEffect(_:in:)`, `GlassEffectContainer`, glass button styles, the iOS 27 Liquid Glass customization API, and the menu-bar-extra changes. apple-docs MCP returned no `glassEffect*` matches, and the SDK grep did not locate these names. Treat as UNVERIFIED.

**Secondary reports (not authoritative):**
- Apple said it updated "the foundations of how Liquid Glass is built" for iOS 27, iPadOS 27, macOS 27, and added a customization slider (https://www.cultofmac.com/news/liquid-glass-changes-ios-27-macos-27 ; https://www.macrumors.com/2026/05/07/ios-27-and-macos-27-rumored-features).
- Golden Gate reportedly walks back some Liquid Glass design (https://www.gizbot.com/features/ios-27-macos-27-golden-gate-ipados-27-top-features-announced-wwdc-2026-126145.html). Conflicts with the above.

**HIG:** no HIG update retrieved. UNVERIFIED.

## 6. Live Activities, widgets, Control Center, App Intents

**Confirmed (SDK):** AppIntents (MacOSX27.sdk) adds many `iOS 27.0 / macOS 27.0` declarations, including `IndexedEntity`, `IndexedEntityQuery`, `LongRunningIntent`, `ProgressReportingIntent` (as a base protocol), `SyncableEntity`, `OwnershipProvidingEntity`, `AppUnionValue`, `EntityCollection`, `IntentExecutionTargets`, `RelevantEntities`, `RunSystemShortcutIntent`, and `SystemShortcut`. None are keyboard-specific.

**Confirmed (SDK):** WidgetKit has `iOS 27.0` and `macOS 27.0` annotations. Declaration names were not extracted.

**Not confirmed:** `ControlWidget` (apple-docs MCP returned no matches; the SDK grep did not check it). `ActivityKit` 27 changes: none found in the SDK interface I checked. UNVERIFIED.

**Recommendation:** the Live Activity should keep showing the connection state (USB vs AWDL, connected or not). Use `LongRunningIntent` and `ProgressReportingIntent` only if keyd adds a long-running sync action. A Control Center toggle for connect/disconnect is plausible but its API names are UNVERIFIED.

## 7. Paid Apple Developer Program: what it unlocks for keyd

These are from general knowledge unless marked. Verify against https://developer.apple.com/support/compare-memberships/ (not retrieved).

| Capability | Relevance to keyd | Status |
|---|---|---|
| 1-year provisioning profiles (vs 7 days on free) | Removes the weekly re-sign the idea sheet describes | Matches the idea sheet's stated pain; paid behavior from general knowledge |
| TestFlight distribution to own devices | Possible iPad install path without Xcode re-sign | Paid-only (general knowledge, UNVERIFIED here) |
| App Groups (shared container) | Only if the Live Activity or a widget needs shared state | Likely available on free for local dev; UNVERIFIED |
| Push notifications / Live Activity push updates | Not needed; Live Activity can update locally | Paid-only (general knowledge); keyd does not need it |
| Wi-Fi Aware entitlement (`com.apple.developer.wifi-aware`) | iPad side only; does not help the Mac | Entitlement page exists; paid-only status UNVERIFIED |
| Multicast networking entitlement | Not needed | Apple-approved (forum reports) |
| Network Extension | Not needed | Not checked |

**Summary:** the paid membership most likely removes the weekly signing refresh. Other capabilities keyd needs (Bonjour over AWDL, USB NCM, CGEvent posting) do not require paid entitlements. The Wi-Fi Aware and multicast entitlements are not worth pursuing.

---

## Open items (could not confirm)

- Apple's macOS 27 and iOS 27 release-note text (Accessibility, Input Monitoring, Local Network, Network, Secure Input, Writing Tools, SwiftUI text, Live Activities). Notes pages returned stubs. Read them in a browser: https://developer.apple.com/go/?id=macos-27_2-rn , https://developer.apple.com/go/?id=ios-27_2-rn
- Xcode 27 Swift and concurrency defaults. Read https://developer.apple.com/go/?id=xcode-27_2-sdk-rn in a browser.
- WWDC26 session list. Official session pages were not reachable.
- `glassEffect` / `GlassEffectContainer` names and iOS 27 Liquid Glass API surface.
- Whether `setMaximumPacingRateBytesPerSecond` and `prependApplicationProtocolIgnoringReady` belong to `NWConnection`.
