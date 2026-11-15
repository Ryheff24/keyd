# keyd refresh: UI principles, navigation and Liquid Glass

Research only. No project was modified. Sources are read from `~/Documents/projects/`:
drdabber (the "Ember" app; also `src/Tools/junk/SwitchKit` holds its design module), switcher (macOS menu-bar app),
llama-tui (Model Hub, macOS), and keyd v1 (`KeydApp/`, `macOS/KeydAgent/`). Line numbers were read on 2026-10-29.

Path shorthand: `DRD` = `~/Documents/projects/drdabber`, `SWT` = `~/Documents/projects/switcher`,
`LLT` = `~/Documents/projects/llama-tui/frontend/app`, `KEYD` = `.`.
drdabber's design module is at `DRD/src/Tools/junk/SwitchKit/Sources/` (the directory is named "junk" in the repo but is live code; `project.yml` points at it).

---

## 1. drdabber: core principles and navigation (what to replicate)

### 1.1 Navigation model

Tabs, one full-screen player, one mini bar. Concrete code:

- **Tab bar of five, one conditional.** `DRD/src/App/RootView.swift:100-120`: `History`, `Presets`, `Lights`, `Settings`, and `Dev` only when developer mode is on (`if model.developerMode`). Each tab is a `Tab(title, systemImage:, value:)` with a `accessibilityIdentifier`.
- **Mini bar above the tab bar.** `RootView.swift:123-127`: `.tabViewBottomAccessory { EmberMiniBar(...) .matchedTransitionSource(id: "player", in: playerSpace) }`. The system places it; nothing floats over scrolling content (rule L5).
- **Full-screen player, zoom transition.** `RootView.swift:129-135`: `.fullScreenCover(isPresented: $router.playerExpanded) { EmberPlayer(...) .navigationTransition(.zoom(sourceID: "player", in: playerSpace)) }`. The mini bar is the zoom source, so tapping it grows into the player.
- **Forced dark, tinted app.** `RootView.swift:37-38`: `.tint(appearance.value.accent.mix(with: .white, by: 0.4))` and `.preferredColorScheme(.dark)`. The player repeats `.preferredColorScheme(.dark)` at line 135.
- **One router owns navigation state.** `DRD/src/App/Support/AppRouter.swift`: `enum AppTab` (history, presets, lights, settings, dev, plus an unused `session`), `enum SettingsRoute` (rename, details, simulatorTools, alerts; "Settings pushes these screens; nothing else does"), and `@Observable final class AppRouter` with `tab`, `settingsPath: NavigationPath`, `presetsPath: [Int]`, `playerExpanded`, and `openSettings()` (which resets the path and closes the player). It lives in the environment.
- **Restore last place.** `RootView.swift` `restore()` and `remember()`: the last tab and the preset being edited are saved (`LastPlace`) and restored on launch; a wiped launch ignores it. Tabs that are not allowed (Dev when developer mode is off) are skipped.
- **Locking.** While a protocol check runs (`model.protocolCheck.lockAppInteraction`), only Settings and Dev may be selected (`RootView.swift`, `.onChange(of: router.tab)`).
- **Settings is one tab, grouped.** `DRD/src/App/Settings/SettingsScreen.swift` header doc (lines 7-18) lists six named groups: Device, Temperature Unit, Device Behaviour, Notifications, Reset, About. A `NavigationStack(path: $router.settingsPath)` wraps a `List` of `Section`s. Developer tools are not in Settings: "The Simulated Switch 2 never appears here; it lives in Dev."
- **One entry point per destination.** Rule L11 forbids a gear plus a tab for the same screen. Simulator and fixture tools exist only in the Dev tab.

### 1.2 Principles (as stated in the project, not just implied)

Source: `DRD/.claude/skills/liquid-glass-ui/SKILL.md` (rules), `DRD/docs/plans/plan-mvp.md` section 1 (owner taste), `DRD/.claude/skills/frontend-design/SKILL.md` (global owner taste).

1. **Dark first.** "Dark mode first" is stated in plan-mvp section 1 and enforced by `preferredColorScheme(.dark)`.
2. **Figures, state words, accent as three colour buckets.** Rule C5: Accent (fills, indicators, controls), Figures (big numbers and state words), Graph (grid, axes, trace). Literal colours are grep failures.
3. **Accent only on fills.** Rule C1: never a text or symbol colour on a non-accent background. Rule C2: text on an accent fill is white or black, checked for contrast against every swatch.
4. **One tinted glass element per screen** (rule C7). The primary action (Start) is the only `glassProminent`.
5. **No meaning by hue alone** (C3). The status thermometer is one shape, recoloured and animated per state (S3). The selection mark is `circle` / `checkmark.circle.fill` (S4).
6. **Each fact once per surface** (T3). "Never call a surface fine" (MVP section 3): the owner is the only visual judge, and agents must not claim a surface is good.
7. **Direct manipulation before steppers** (M11, D15): a value with a visual (curve point, time, temperature) is edited on the visual; steppers are visible but secondary.
8. **Continuous motion** (M8): live values interpolate per frame (`TimelineView`), no tick-once-a-second.
9. **Nothing floats over scrolling content** except system bars (L5).
10. **Glass is for the control layer only** (G1). Cards, graphs, rows and readouts are content and use `.fill`, `.background.secondary` or `.regularMaterial`.

### 1.3 Design system: what exists, and what does not

- **There is no spacing or typography token file.** A search for `enum Spacing`, `enum Metrics`, `enum Layout` and `Font.custom` in `DRD/src` returns nothing. Values are inline, and the discipline is in the skill file, not in code. For keyd, copy the *rules*, not a token enum; use switcher's `Tokens.swift` for the token shape (section 4.4).
- **Colour.** Accent, line and figure colours are persisted hex values, not named tokens: `DRD/src/Tools/junk/SwitchKit/Sources/SwitchDesign/Model.swift:371-373` (`defaultAccentHex = "#0E6B27"`, `defaultLineHex = "#EDEDED"`, `defaultFigureHex = "#FFFFFF"`), swatches at line 524. The `Appearance` struct is at `Model.swift` (about line 390) and is read through `AppearanceStore` in `DRD/src/Tools/junk/SwitchKit/Sources/SwitchUI/SwitchUI.swift:11`.
  - **Conflict with the owner's rule.** The default accent is green. The owner's global `frontend-design` skill says "NO GREEN EVER" (deuteranopia). Do not inherit `#0E6B27` into keyd. The SKILL's C2 rule even lists it as a swatch to check.
- **Accent contrast helper.** `SelectionMark.contrasting(_:)` (`Components.swift:1096`) picks white or black by WCAG relative luminance. This is pure maths and is worth copying.
- **Figures.** `PlayerFigures` (`DRD/src/Tools/junk/SwitchKit/Sources/SwitchDesign/Figures.swift:21`) switches between seven player layouts; not for keyd, but the doc comment ("Nothing is reserved for what a state does not show, so no layout leaves an empty band") is the right rule.

### 1.4 How glass is applied in drdabber

Grep for `glassEffect`, `GlassEffectContainer`, `buttonStyle(.glass)`, `.glassProminent` finds glass in: `Player.swift` (lines 59, 196, 282, 293, 305, 353, 410, 459, 524, 569, 572, 581, 591, 648, 769, 798, 819, 1109-1111, 1141, 1148), `SliderStyles.swift:52,276`, `Editor.swift:706,730,1204`, `ProfileRow.swift:173`, `Components.swift` (control buttons), `ExperienceDocumentHost.swift:222,290`, `PendingChanges.swift:48`, `StressTestScreen.swift:236-244`, `AppearanceScreen.swift:132`, `App/Support/InAppAlerts.swift`, `App/Settings/SettingsScreen.swift`, `App/Device/RenameScreen.swift`, `App/Onboarding/OnboardingView.swift`.

Pattern worth copying:
- Controls are glass, cards are not. `Player.swift:282-305` wraps sibling capsules in `GlassEffectContainer(spacing: Gap.merge)`; a comment explains the spacing (merge distance, "the glass merges only within 4 pt", line 304).
- The identity-glass trick for overlays, `Player.swift:1125-1148`: a badge that must sit above a glass card joins the container with `.glassEffect(.identity, in: .circle)`, so it is drawn in the glass layer. A bug fix (A-row) is recorded in that comment; reuse the idea.
- `AccentCircle` (`Components.swift:7-35`): the primary control gets `glassProminent` and `tint(accent)`; secondary gets `.glass`; in non-glass mode, a flat accent circle. Good template for keyd's primary keys.

**Self-violations found while reading (do not copy):**
- `DRD/src/App/Widgets/DeviceStatusWidget.swift:207, 213, 253` use `.minimumScaleFactor(0.8 / 0.6)`. Rule T7 forbids shrinking text to fit.
- `DRD/src/App/Support/InAppAlerts.swift`, `RenameScreen.swift`, `OnboardingView.swift` appear in the glass grep; not checked line by line against G2/G4.
- `Player.swift:459` is `glassEffect(.regular, in: .rect(cornerRadius: 30))`; rule G1 says cards are content and not glass. Verify which element this is before treating it as a precedent.

---

## 2. The Liquid Glass skill

### 2.1 What it is

`DRD/.claude/skills/liquid-glass-ui/SKILL.md` (about 200 lines, frontmatter `name`, `description`) plus two references:

- `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md`: which APIs exist, which do not compile, faux-glass list, open questions. Verified against the Xcode 27.0 SDK swiftinterface on 2026-10-01 (the research is `DRD/docs/research/liquid-glass.md`).
- `DRD/.claude/skills/liquid-glass-ui/references/sources.md`: the key-to-source table. Apple keys (HIG-Materials, Adopting, Custom-glass, WWDC25-219, etc.) with quoted lines, plus a project table.

Rules are written as checks an agent can run on a screenshot or on a grep. Each has a citation key. The pre-hand-over checklist is at the end of the SKILL.

### 2.2 Rules (summary, one line each)

- **L (layout):** L1 nothing moves between states except the changed part; L2 equal gaps around a highlight; L3 no empty bands; L4 large title and action on one row; L5 nothing floats over scrolling content except system bars; L6 actions not hidden under the mini bar; L7 the thing being changed stays visible; L8 no ellipsis at 393 pt; L9 system metrics, no hard-coded row heights; L10 concentric corners; L11 settings separated, one entry point.
- **T (text):** T1 no text over a graph line; T2 min, max and preset labelled on every graph; T3 each fact once; T4 no "Target"/"to N"/arrow glyphs; T5 preset reads "temperature · hold · profile"; T6 current temperature always visible; T7 never `minimumScaleFactor` on labels; T8 use the user's words; T9 one timer, never negative.
- **C (colour):** C1 accent never as text on a non-accent background; C2 text on accent is white or black, contrast 4.5:1 for every swatch; C3 greyscale test, no hue-only meaning; C4 label hierarchy on materials; C5 three colour buckets; C6 dark first, light and increased-contrast variants; C7 one tinted glass element per screen.
- **G (glass):** G1 glass only for control and navigation layer; G2 never glass on glass; G3 `GlassEffectContainer` for siblings, count glass shapes; G4 no faux glass (Material + gradient + stroke, blur, clipShape/mask on glass, custom sheet/toolbar backgrounds); G5 system show-through and scroll edge effect, don't add opaque backings; G6 `.regular` glass, `.clear` only over rich media with a 35% dim; G7 `.interactive()` only for touchable glass.
- **M (motion/gestures):** M1 a drag moves only the grabbed thing; M2 finger 1:1, one commit on release; M3 redraw from live points; M4 clip hit areas (`contentShape`); M5 drags on non-movable content pass through to scroll; M6 first tap always lands, no parent `onTapGesture`; M7 44 x 44 pt hit targets; M8 continuous interpolation; M9 countdown never counts up; M10 matched geometry about 0.25 s, Reduce Motion crossfade; M11 direct manipulation first; M12 one gesture system per surface.
- **S (controls):** S1 exact state words; S2 state word stands alone; S3 one status icon, recoloured and animated; S4 active and selected differ, each with one marker; S5 icon-only controls with `accessibilityLabel`; S6 disabled controls dim and say why; S7 one-tap choice on visuals; S8 system button styles only.
- **P (presentation):** P1 one sheet at a time; P2 UIKit pickers presented from UIKit; P3 no `presentationBackground`/`presentationCornerRadius`; P4 segmented control of three or fewer words; P5 a menu is never the only route; P6 confirmation dialogs anchored to their control; P7 full-screen for long tasks, the X saves.
- **X (accessibility):** X1 Dynamic Type via text styles, no bare `.font(.system(size:`; X2 VoiceOver labels, `.isSelected`; X3 Reduce Motion path, not assumed; X4 Reduce Transparency and Increase Contrast checked.

### 2.3 Quality of the rules (what to trust)

- Strong: glass-api.md's "do not exist" list (for example `glassEffect(_:in:isEnabled:)`, `.buttonStyle(.glassClear)`, `presentationCornerRadius(.concentric)`). Each was typechecked. These save real time, but they are only true for the Xcode 27 SDK checked on 2026-10-01; re-check against keyd's actual deployment target.
- Strong: the faux-glass list and G2 (glass on glass), which match the Apple sources quoted in sources.md.
- Weak: several rules are drdabber-specific (graph labels T1/T2, thermometer S3, Rocket, profile tiles). They do not transfer.
- Contradiction: `SWT/docs/liquid-glass-research.md` section 7.5 item 23 says "Use semantic `Color.red`, `.green`" and section 4.5 says to default to system appearance. Both contradict the owner's deuteranopia rule and dark-first preference. Do not copy those points.

### 2.4 Recommendation: copy or adapt

**Adapt, do not copy verbatim.** Reasons:

1. Every rule cites drdabber-private IDs (`A1`–`A201`, `D1`–`D29`) in `docs/status/feedback-open.md`. Those rows do not exist in keyd. A rule with a dead citation is a rule nobody can check.
2. Many rules encode Ember's product: state words (Idle, Heating, Heated), the thermometer, temperature graphs, Rocket, profiles, the Dev tab. These need deletion.
3. Deployment target. drdabber is iOS 27 only and says "no fallbacks". keyd v1 targets iOS 17.0 (`KEYD/KeydApp/KeydApp.xcodeproj/project.pbxproj:534` and siblings). Glass APIs need iOS 26, so keyd must either raise its floor (owner decision) or gate with `#available` and a fallback. The fallback must be a standard system material, not faux glass.
4. keyd has no graphs, sheets-over-scroll, or a player, so roughly a third of the rules are idle.

**Exact files to copy (then edit):**

| Target path in keyd | Source | Action |
|---|---|---|
| `.claude/skills/liquid-glass-ui/references/glass-api.md` | `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md` | Copy nearly verbatim. Add a header line: "Verified against Xcode 27.0 SDK, 2026-10-01; re-verify before use." Keep the "do not exist" and "faux glass" sections. |
| `.claude/skills/liquid-glass-ui/references/sources.md` | `DRD/.claude/skills/liquid-glass-ui/references/sources.md` | Copy only the Apple table (rows HIG-*, Adopting, Custom-glass, WWDC25-*). Delete the "Project" table (A/D/CP/MVP keys). |
| `.claude/skills/liquid-glass-ui/SKILL.md` | `DRD/.claude/skills/liquid-glass-ui/SKILL.md` | Adapt: keep sections 3 (colour), 4 (glass), 5 (motion, the hit-area rules only), 7 (presentation), 8 (accessibility), and the checklist. Drop T1–T9 except T7 (no shrink) and T8 (user words). Replace every `A…`/`D…` citation with the Apple key or a keyd source file. |
| `.claude/skills/frontend-design/SKILL.md` | `~/.claude/skills/frontend-design/SKILL.md` (identical to the DRD copy) | Do not copy whole. It is web-centric (Tailwind, shadcn, CSS, `font-mono`). Extract only: no green; no monospace for UI chrome; sans with tabular numerals; no summaries; every truncation recoverable; never shrink-to-fit; no hard-coded colours; "never claim it looks correct, the owner is the only visual verifier"; the frustration hierarchy. |

**What must change for keyd (checklist):**

- Replace the iPad/Ember/Switch words everywhere in the skill; the app is "keyd".
- Rewrite the state-word rule (S1) for keyd's states: USB, AWDL, Connecting, Disconnected (`KeydApp/KeydApp/UI/ConnectionStatusView.swift:6-30`).
- Add a macOS agent section (menu-bar status item, Settings window, permission rows). Sources: `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 (the shallow-glass checklist, items 1–10) and `SWT/docs/liquid-glass-research.md` section 4 (MenuBarExtra).
- Add a Live Activity section (ActivityKit: compact and expanded layouts; see drdabber's bug list below).
- Change the colour rule to name the keyd palette (see section 5.2): blue, amber, red; no green anywhere.
- Reconcile "Liquid Glass (Glassmorphism)" in `KEYD/idea.md` (UI/UX section) with G1/G4: glass on controls, fill on content.

---

## 3. Consolidated "UI mistakes never to repeat"

Each item has its source. Items marked **[keyd]** are already present in keyd v1.

### Colour and accessibility
1. **Green for status, or any red/green or yellow/orange pair without shape.** Owner has deuteranopia. Sources: `DRD/.claude/skills/frontend-design/SKILL.md` ("NO GREEN EVER"); `DRD/.claude/skills/liquid-glass-ui/SKILL.md` C3; `SWT/CLAUDE.md` "Deuteranopia" section. **[keyd]** `KEYD/KeydApp/KeydApp/UI/ConnectionStatusView.swift:9-14` uses `.green`, `.yellow`, `.orange`, `.red` with only a text label; `KEYD/KeydApp/KeydApp/LiveActivity/KeydConnectionAttributes.swift:26-29` does the same; `KEYD/macOS/KeydAgent/MenuBar/StatusBarController.swift:83` uses `.systemRed` (acceptable only because xmark is also a shape).
2. **Accent colour as text or symbol on a non-accent background.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` C1 (source A60).
3. **Accent default that is green.** `DRD/src/Tools/junk/SwitchKit/Sources/SwitchDesign/Model.swift:371` (`#0E6B27`) against the owner's global rule.
4. **Hard-coded RGB and literal `.green`/`.white` in views.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` C5; `SWT/docs/liquid-glass-research.md` 7.5 item 23 contradicts this and must not be followed.
5. **Dim secondary text on a material.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` C4 (A161).
6. **Dark mode forced in one scene but not in another.** `SWT/docs/liquid-glass-research.md` 4.5 (MenuBarExtra does not inherit `preferredColorScheme`; the claim comes from community posts and is unverified). Test per scene. DRD forces dark on both `RootView.swift:38` and `:135`.

### Glass and materials
7. **Glass on glass** (sheet, toolbar, another glass). `DRD/.claude/skills/liquid-glass-ui/SKILL.md` G2 (WWDC25-219). Also `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 item 3.
8. **Faux glass: `.ultraThinMaterial` plus clip plus a comment calling it Liquid Glass.** **[keyd]** `KEYD/KeydApp/KeydApp/UI/HotkeyPanel.swift:5, 79-81` (`.background(.ultraThinMaterial)`, `.clipShape(RoundedRectangle(cornerRadius: 22))`). Source: `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md` (Faux glass list); `SWT/docs/liquid-glass-research.md` 7.1 item 8.
9. **Glass on the panel, plain keys inside.** The inverse of the rule. **[keyd]** `HotkeyPanel.swift:79`: "Liquid Glass chrome — applied to panel, NOT to individual keys." Per G1, keys are the controls and get `.buttonStyle(.glass)` in one `GlassEffectContainer`; the panel behind them is content and gets a fill.
10. **Custom backgrounds on system bars, sheets and popovers.** `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md` (faux glass), G4; `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 item 9.
11. **Show-through of content behind the tab bar, or opaque backing to hide it.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` G5 (source A49).
12. **Hover-only essential actions.** `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 item 10.

### Layout and text
13. **Shrink-to-fit text.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` T7. Violated in `DRD/src/App/Widgets/DeviceStatusWidget.swift:207, 213, 253`.
14. **Ellipsis that hides the distinguishing part.** `DRD/.claude/skills/frontend-design/SKILL.md` section 8 ("every ellipsis is recoverable").
15. **Labels crossing a line or a grid.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` T1, T2 (A119, A116, A104).
16. **Hand-made cards and boxes where native containers exist.** `LLT/docs/owner-requirements.md` section 3 rule 4 ("Native containers with borders... No hand-made cards"). Also `SWT/docs/liquid-glass-research.md` 7.3 item 16.
17. **Dense information with no hierarchy; the owner's "everything looks rough" pattern.** `LLT/docs/owner-requirements.md` section 1 (quotes about "kinda rough", "lacks coherency, borders, etc.").
18. **Monospace on UI chrome.** `DRD/.claude/skills/frontend-design/SKILL.md` "2026-06 typography correction" and the monospace decision gate. **[keyd]** `KEYD/KeydApp/KeydApp/UI/PairingView.swift:60` uses `.design: .monospaced` for pairing text. Acceptable only if it is a code-like token; otherwise use sans.
19. **Duplicate facts on one surface.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` T3; `DRD/docs/plans/plan-mvp.md` section 3.
20. **Scrolling with two scroll regions (double scroll).** `DRD/.claude/skills/frontend-design/SKILL.md` section 4 ("I hate any double scrolling").
21. **IDs or internal names in navigation.** `DRD/.claude/skills/frontend-design/SKILL.md` section 5. The llama-tui app's "Library/Processes/Conversions" confusion is the same family (`LLT/docs/owner-requirements.md` section 2).

### Controls and navigation
22. **Controls not on the thing they change.** `LLT/docs/owner-requirements.md` section 3 rule 1 ("A control sits on the thing it controls").
23. **More than one primary action per page in the toolbar.** `LLT/docs/owner-requirements.md` section 3 rule 2.
24. **Nested navigation under a sidebar item.** `LLT/docs/owner-requirements.md` section 3 rule 3 (flat sidebar, changed 2026-10-18).
25. **Menu as the only route to a choice.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` P5, S7.
26. **Icon-only controls without labels.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` S5, X2.
27. **Developer and simulator controls in production Settings.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` L11 (A67). **[keyd]** `KEYD/KeydApp/KeydApp/Debug/` (`DebugOverlayView`, `TransportTestRunnerView`) is reachable from the status badge in `RootViewController.swift` (`showDebug = true`). Move it behind a developer tab or gate it.
28. **Taps that fail on the first try (gesture conflicts).** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` M6 (A105). Check any `onTapGesture` wrapping a control in keyd's keyboard.

### Motion and performance
29. **Hit area not clipped during drag; drag on scrolling content eaten by the graph.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` M4, M5 (A113, A17). Relevant only if keyd gains a drag-to-reorder keyboard.
30. **Countdowns that count up, or values that tick every second.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` M8, M9 (A41, A151).
31. **Tab switch or Settings open lags because each tab rebuilds its whole content.** `DRD/docs/status/feedback-open.md` A115, A117 (Settings → Appearance lag; full-archive saves on every appear). Same family: `LLT/docs/owner-requirements.md` section 3 rule 7 ("Navigation must not lag").
32. **Scroll stutter from content re-layout during scroll.** `DRD/docs/status/feedback-open.md` A75.
33. **Reduce Motion not honoured for repeating animations.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` X3; `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md` (open questions).
34. **Continuous hidden-page drawing with `allowsHitTesting(false)` toggles.** `LLT/docs/handover.md` lines 532-560: toggling `allowsHitTesting` doubled a page switch (35 ms against 18 ms). Use opacity and zIndex instead. macOS, but the same SwiftUI graph cost.

### Presentation and app behaviour
35. **Two sheets, or a UIKit picker inside a SwiftUI sheet.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` P1, P2 (A159).
36. **Custom sheet background or corner radius.** `DRD/.claude/skills/liquid-glass-ui/SKILL.md` P3.
37. **The app activates itself or steals focus.** `LLT/docs/owner-requirements.md` section 3 rule 8; `LLT/docs/handover.md` section "Focus". Relevant to keyd's menu-bar agent: it must never call `NSApp.activate` on its own.
38. **Reading an `@Environment` object inside an AppKit table cell crashes on launch.** `LLT/docs/handover.md` lines 489-500 (`EnvironmentValues.subscript.getter` under `EnvironmentBox.update`). Pass plain values into cells.
39. **Custom title bar on a menu-bar panel.** `SWT/docs/liquid-glass-research.md` 7.7 item 27.
40. **Flat `.fill` sections and `.roundedBorder` fields in a Settings window.** `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 (`SettingsPanelView`, `DevPanelWindow` rows: "NOT Liquid Glass").
41. **"Looks fine" claims without evidence.** `DRD/.claude/skills/frontend-design/SKILL.md` item 12 and `DRD/docs/plans/plan-mvp.md` section 3. For keyd: report what the screenshot shows and let the owner judge.
42. **Re-applying a fix piecemeal instead of as a tight specification.** `DRD/AGENTS.md` (owner quote: "pulling all the over specifications into a tight specification"). Relevant to the process, not the UI.

---

## 4. Reusable UI code

Rating: **copy** (use as is or almost), **adapt** (copy the shape, rewrite the body), **idea only** (rule, not code). "Coupling" lists what must be removed.

### 4.1 drdabber (SwiftUI, iOS 27, in `DRD/src/Tools/junk/SwitchKit/Sources/`)

| Item | Path | Rating | Coupling to remove |
|---|---|---|---|
| `AccentCircle` modifier | `SwitchDesign/Components.swift:7-35` | adapt | `designAccent` environment key; `Color(.systemGray4)` is fine. Keep the glass-prominent / glass / flat switch. |
| `SelectionMark` (selection circle, contrasting check) | `SwitchDesign/Components.swift:1071-1110` | copy | `AX`-identifier strings (`preset.card.%d.mark`); keep `symbol(selected:)` and `contrasting(_:)`. Useful for keyd's selected hotkey or device row. |
| `StatusThermometer` | `SwitchDesign/Thermometer.swift:5` | idea only | Tied to temperatures. Pattern: one shape, recoloured, animated, plus state word. |
| `MiniPlayerBar` (mini bar above the tab bar) | `SwitchDesign/Player.swift:1161` | adapt | `PlayerSnapshot`, `Appearance`. The pattern: `tabViewBottomAccessory`, a compact glass capsule, tap to expand. For keyd, the Live-Activity-style compact status could sit here. |
| `AXID` / `AX` accessibility identifier tables | `SwitchDesign/Identifiers.swift:4`, `DRD/src/App/Support/AXID.swift` | copy the pattern | Strings are drdabber-specific; keep one enum per screen for UI tests. |
| `AppRouter` | `DRD/src/App/Support/AppRouter.swift` | copy the pattern | `AppTab` cases; `SettingsRoute` cases. |
| `RootView` tab shell | `DRD/src/App/RootView.swift:94-136` | adapt | `model.protocolCheck`, `LastPlace`, `EmberPlayer`, `AppModel`. Keep: `tabs`, `tabViewBottomAccessory`, the zoom-transition `fullScreenCover`, restore and remember. |
| `SettingsScreen` grouping | `DRD/src/App/Settings/SettingsScreen.swift` | adapt | Everything device-specific. Keep the grouping doc comment and `NavigationStack(path:)`. |
| `SessionGraph`, `TempAxis`, `GridLines` | `SwitchDesign/Components.swift:344-460` | idea only | Keyd has no graph. Rule T2 (labelled min and max) still applies to any chart keyd adds. |
| `GlassEffectContainer` patterns | `SwitchDesign/Player.swift:282-305, 1125-1148` | copy the pattern | Preset-specific names. |
| `SliderStyles` | `SwitchDesign/SliderStyles.swift` | idea only | Not needed. |

Not reusable: `Editor.swift`, `Figures.swift`, `RocketScene*.swift`, `Experience*.swift`, `Stress*.swift`. These are product features.

### 4.2 switcher (macOS, SwiftUI; macOS 26 target per its CLAUDE.md, macOS 27 measurements in Tokens)

| Item | Path | Rating | Coupling |
|---|---|---|---|
| `Tokens` enum (`Color`, `Grid`, `Font`, `Space`, `Radius`, `Glass`, `Fill`, `Motion`, `Slot`, `Settings`) | `SWT/Switcher/Switcher/Design/Tokens.swift` | copy the shape | Numbers were measured on macOS 27 for a 16 pt glyph in a glass control; re-measure for keyd. |
| `Tokens.Color` palette: blue accent, amber, red danger, "deuteranopia-safe pair" | `Tokens.swift` lines 9-22 | copy | Remove claude/codex/ghostty brand tints. |
| `StatusShape` (shape plus hue status marks) | `SWT/Switcher/Switcher/Design/StatusShape.swift` | copy the idea and the file | Adapt the states to keyd's transport states. |
| `Iconography` (SF Symbol mapping) | `SWT/Switcher/Switcher/Design/Iconography.swift` | adapt | App bundle icons are not needed. |
| `SwitcherPanel` (menu-bar panel, glass container, footer) | `SWT/Switcher/Switcher/Panel/SwitcherPanel.swift:113, 166, 183` | adapt | Project model. |
| `ExpandedProjectRow` glass model comments | `SWT/Switcher/Switcher/Panel/ExpandedProjectRow.swift:14-27` | copy the comments as design notes | Project-specific layout. |
| `QuickOpenIcons` (one `.buttonStyle(.glass)` per slot in one container) | `SWT/Switcher/Switcher/Components/QuickOpenIcons.swift:4-5, 157, 278` | copy the pattern | Icon set. |
| `MenuBarExtra` scene with `isInserted`, plus `Window` scenes for Settings and reference | `SWT/Switcher/Switcher/SwitcherApp.swift:47-77` | adapt | keyd uses an `NSStatusItem` (`KEYD/macOS/KeydAgent/MenuBar/StatusBarController.swift`). Decide which; see section 5.5. |
| `AppSettings` forced-dark toggle | `SWT/Switcher/Switcher/Model/AppSettings.swift:11-18` | idea only | Switcher forces dark; its own research says do not. Owner decides. |
| Shallow-glass checklist and per-surface table | `SWT/docs/workflow-and-glass-research-2026-05-16.md` section 6 | idea only (review tool) | Surface names are switcher's. |

### 4.3 llama-tui Model Hub (macOS, SwiftUI + AppKit tables)

| Item | Path | Rating | Notes |
|---|---|---|---|
| `KeptStack` and `PageVisibility` (keep pages drawn, not hit-testable) | `LLT/Sources/Shared/KeptPages.swift` (named in `LLT/docs/handover.md` line 532) | idea only | Keyd does not need page caching. |
| `HubEnvironment` (hub injected via `EnvironmentKey`, default `Hub.current`) | `LLT/Sources/Store/HubEnvironment.swift` | idea only | Lesson: inject a plain key, not `@Environment(Object.self)`, for AppKit-built views. |
| Owner rules section | `LLT/docs/owner-requirements.md` section 3 | copy the rules into keyd's skill | Rules 1–8 are app-agnostic. |

### 4.4 Apple-platform rules for keyd's own code

- Use the drdabber skill's `glass-api.md` as the API reference.
- Use switcher's `Tokens.swift` shape for keyd's tokens (one file, enums, measured values).

---

## 5. Mapping onto keyd specifically

keyd v1 (`KEYD/`): iOS app `KeydApp/` (SwiftUI `RootView` in `KeydApp/KeydApp/App/RootViewController.swift`, deployment iOS 17.0), macOS agent `macOS/KeydAgent/` (Swift, `MenuBar/StatusBarController.swift` uses `NSStatusItem`, `UI/QRCodeView.swift`).

### 5.1 iOS keyboard and editor screen

Current: `RootView` = connection badge at top, optional recovery controls, secure-input overlay, `HotkeyPanel` (2-column grid of shortcut buttons), then the keyboard at the bottom. Full-screen, portrait only. Its background comment says "Dark background to make Liquid Glass panels pop."

Recommendations:
- **Keys are controls, so they are glass; the panel is content.** Replace `HotkeyPanel.swift:80-81` (`.background(.ultraThinMaterial)`, `.clipShape`) with a fill (`.background(.fill.tertiary, in: RoundedRectangle(...))` per the skill's table). Give each hotkey `.buttonStyle(.glass)` inside one `GlassEffectContainer(spacing:)` (G1, G3). Remove the comment that says the opposite.
- **One tinted control.** The one primary action on this screen (for example "send" or the active modifier) may be `glassProminent`. Everything else is plain glass (C7).
- **Destructive hotkeys** already route through `onDestructiveHotkey` (confirmation). Anchor the confirmation to the key that opened it (P6), not a centred alert.
- **Keyboard:** keep Apple's system keyboard unchanged. Do not restyle it; the skill's G5 says let the system provide show-through. Phase 2 predictive text is the system bar; do not add an overlay on top of it (L5).
- **Phase 2 text preview** (from `KEYD/idea.md`): a fill-based field above predictive text. No glass.
- **Dynamic Type:** `HotkeyPanel` uses fixed sizes (`.font(.system(size: 21/14/15))`, lines 114-130). Switch to text styles (X1) so the 2-column grid stacks at accessibility sizes.
- **Haptics on every key** (`HotkeyPanel.swift`, `UIImpactFeedbackGenerator`) are fine; no rule against them.
- **Debug entry:** the status badge opens `DebugOverlayView`/`TransportTestRunnerView` (`RootViewController.swift`, `showDebug`). Per L11, debug tools go in a Dev tab, or are compiled out of release.

### 5.2 Connection status and colour

`KEYD/KeydApp/KeydApp/UI/ConnectionStatusView.swift:9-14`: USB green, AWDL yellow, connecting orange, disconnected red, each with a dot and a text label. Same colours in `KeydConnectionAttributes.swift:26-29`.

Problems: green/red and yellow/orange are the deuteranopia failure pair; the dot is the only shape besides text.

Recommendation (per C3, and the Switcher palette in `Tokens.Color`):
- USB connected: blue, filled circle with a cable SF Symbol (`cable.connector`).
- AWDL connected: blue-outline circle with a wireless SF Symbol (`wifi`), or amber, but not both blue and amber for different meanings on one screen.
- Connecting: amber, dashed or animated ring (`circle.dotted` or a `ProgressView` with reduced-motion fallback).
- Disconnected: red, `xmark.octagon.fill` (switcher's shape pairing for danger, `SWT/CLAUDE.md`).
- Always show the word. Never colour alone (S2, C3).

### 5.3 Pairing

`KEYD/KeydApp/KeydApp/UI/PairingView.swift`: a scanner box with a "Liquid Glass overlay" (line 103) and a monospaced text (line 60).

- The camera preview is content. Draw a fill-based frame, not glass over the camera (G1, G4).
- If a glass control is needed (for example "Cancel" or "Enter code"), use `.buttonStyle(.glass)` (S8).
- Pairing code: use sans with tabular digits (`.monospacedDigit()`), not `.monospaced` design, unless it is a raw code token (frontend-design monospace gate).
- Pairing is a one-step physical flow (QR scan), so the state words rule applies (S1): Scanning, Paired, Failed.

### 5.4 Settings

Keyd v1 has no Settings screen (pairing and debug live in the main view). Recommend, when added, the drdabber grouping (`SettingsScreen.swift` doc comment): one `NavigationStack` `List`, groups named by the user's words (Device, Haptics, Connection, About), developer items only in Dev (L11). Use `.navigationTransition` or a system push, not a custom overlay.

### 5.5 Live Activity

`KEYD/KeydApp/LiveActivity/KeydLiveActivity.swift` and `KeydApp/KeydLiveActivity/KeydLiveActivityWidget.swift`.

- Colour fix as in 5.2 (`KeydConnectionAttributes.swift:26-29`).
- Compact and expanded Dynamic Island layouts: drdabber's lesson is that the expanded layout must align its figures and buttons to a grid, not float them (`DRD/docs/status/feedback-open.md` A56: "numbers and buttons not aligned to anything"). Its fix is A8, A101, A122 for stale state.
- Stale activity adoption (A80): reconcile a leftover activity with the current transport state on launch. This is a lifecycle lesson, not a UI one, but it shows up as a UI bug.
- Show the transport word, not only the icon (S2).

### 5.6 macOS agent (menu bar extra and settings window)

Current: `KEYD/macOS/KeydAgent/MenuBar/StatusBarController.swift` (`NSStatusItem`, `NSMenu`, permission rows with a red xmark, line 83); `UI/QRCodeView.swift` (pairing QR); `MenuBar/PermissionChecker.swift`.

Recommendations:
- **Status item.** Keep `NSStatusItem` if the menu is a plain menu. A menu's labels are short title-case verbs and icons on all items or none (drdabber's `HIG-Menus` table, `DRD/.claude/skills/liquid-glass-ui/references/sources.md`). Dim unavailable items, do not hide them.
- **Permission rows.** A missing permission is shape plus word (xmark plus "Accessibility not granted"), never colour alone. The existing red xmark is fine once it has the word.
- **Settings window.** If keyd gets a settings window, use a SwiftUI `Window` scene (switcher's `SwitcherApp.swift:67` pattern), with `List`, no custom backgrounds, glass only on the one toolbar-like action row (G1).
- **Menu-bar panel vs NSPanel.** Switcher's research recommends `MenuBarExtra(style: .window)` and avoiding an `NSPanel` (`SWT/docs/liquid-glass-research.md` 4.2). Keyd is an `NSStatusItem` today. Decide before rebuilding: `MenuBarExtra` is easier, but its colour-scheme behaviour is unverified (`SWT/docs/liquid-glass-research.md` 4.5).
- **Never activate the app** (`LLT/docs/owner-requirements.md` rule 8). A menu-bar agent must not call `NSApp.activate` when it shows a window, or the window appears late and steals focus.
- **Language constraint.** The keyd-rd remote-desktop macOS agent is C and Objective-C with no Swift runtime (per the keyd project memory: keyd-rd's macOS agent is C and Objective-C). The v1 agent is Swift. If the menu UI is shared with keyd-rd, the rules transfer but the code does not.

### 5.7 Cross-cutting decisions for the owner

1. **Deployment target.** iOS 17.0 today. Glass needs iOS 26. Raise it, or gate with a system-material fallback. This is the first decision.
2. **Dark or light.** drdabber and llama-tui owners prefer dark (`LLT/docs/owner-requirements.md`: "dark mode > light mode every day"). keyd's owner preference is not recorded here; ask.
3. **Accent.** Use blue, amber and red from switcher's `Tokens.Color`. No green.
4. **Glass wording.** Change "Liquid Glass (Glassmorphism)" in `KEYD/idea.md` to "Liquid Glass on controls; fills for content".
5. **Skill location.** Create `KEYD/.claude/skills/liquid-glass-ui/` (directory does not exist yet; `KEYD/.claude/` has only `settings.json`, `agents`, `commands`, `hooks`, and GSD files). Write it per section 2.4.

---

## Open questions and unverified claims

- `SWT/docs/liquid-glass-research.md` 4.5 (MenuBarExtra ignores `preferredColorScheme`) comes from community posts; not verified on macOS 27.
- `DRD/.claude/skills/liquid-glass-ui/references/glass-api.md` was verified on Xcode 27.0 on 2026-10-01; this research did not re-run the typecheck.
- `DRD/src/App/Support/InAppAlerts.swift`, `RenameScreen.swift`, `OnboardingView.swift`: contain glass; not checked against G2 or G4.
- `DRD/src/Tools/junk/SwitchKit/Sources/SwitchDesign/Player.swift:459`: a rect glass surface that may break G1; not identified.
- keyd `KeydApp/KeydApp/App/RootViewController.swift` holds a SwiftUI `RootView`; the project memory says the iOS app is a UIViewController host. The host file was not read.
