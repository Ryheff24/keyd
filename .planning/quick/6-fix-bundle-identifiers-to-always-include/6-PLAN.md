---
phase: quick-6
plan: 6
type: execute
wave: 1
depends_on: []
files_modified:
  - KeydApp/project.yml
  - KeydApp/KeydApp.xcodeproj/project.pbxproj
  - macOS/project.yml
  - .planning/phases/01-transport-and-core-keyboard/01-03-PLAN.md
  - .planning/phases/01-transport-and-core-keyboard/01-04-PLAN.md
  - .planning/phases/01-transport-and-core-keyboard/01-04-SUMMARY.md
  - .planning/phases/01-transport-and-core-keyboard/01-07-PLAN.md
  - .planning/phases/01.1-connected-integration-test-suite/01.1-03-PLAN.md
autonomous: true
requirements: []

must_haves:
  truths:
    - "All PRODUCT_BUNDLE_IDENTIFIER values contain .ryheff (com.ryheff.keyd.*)"
    - "project.yml files are the canonical source of truth and match the correct IDs"
    - "project.pbxproj reflects the corrected identifiers"
    - "No file in the repo contains com.keyd.app or com.keyd.agent (without .ryheff)"
  artifacts:
    - path: "KeydApp/project.yml"
      provides: "Canonical iOS bundle ID definitions"
      contains: "com.ryheff.keyd.app"
    - path: "macOS/project.yml"
      provides: "Canonical macOS bundle ID definitions"
      contains: "com.ryheff.keyd.agent"
    - path: "KeydApp/KeydApp.xcodeproj/project.pbxproj"
      provides: "Xcode project bundle ID settings"
      contains: "com.ryheff.keyd.app"
  key_links:
    - from: "KeydApp/project.yml"
      to: "KeydApp/KeydApp.xcodeproj/project.pbxproj"
      via: "xcodegen (project.yml is source of truth)"
      pattern: "PRODUCT_BUNDLE_IDENTIFIER.*com\\.ryheff\\.keyd"
---

<objective>
Fix all bundle identifiers in the project that are missing the `.ryheff` component.

Purpose: Bundle IDs missing `.ryheff` (e.g. `com.keyd.app`) are invalid and would cause provisioning failures, Keychain conflicts, and mismatched entitlements on device.
Output: All five bundle IDs corrected to their canonical form in all project files and planning docs.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@.planning/ROADMAP.md

# Correct bundle IDs (from MEMORY.md — NEVER deviate from these)
# iOS app:           com.ryheff.keyd.app
# iOS tests:         com.ryheff.keyd.app.tests
# iOS Live Activity: com.ryheff.keyd.app.live-activity
# macOS agent:       com.ryheff.keyd.agent
# macOS tests:       com.ryheff.keyd.agent.tests

# Invalid bundle IDs being replaced:
# com.keyd.app            → com.ryheff.keyd.app
# com.keyd.app.tests      → com.ryheff.keyd.app.tests
# com.keyd.app.live-activity → com.ryheff.keyd.app.live-activity
# com.keyd.agent          → com.ryheff.keyd.agent
# com.keyd.agent.tests    → com.ryheff.keyd.agent.tests

# Files confirmed to have CORRECT IDs already (do not touch):
# macOS/KeydAgent.xcodeproj/project.pbxproj — already has com.ryheff.keyd.agent (verified)

# Files confirmed to need fixes:
# KeydApp/project.yml — 3 bad IDs (lines 45, 68, 120)
# KeydApp/KeydApp.xcodeproj/project.pbxproj — 6 bad IDs (lines 559, 580, 686, 706, 727, 768)
# macOS/project.yml — 2 bad IDs (lines 30, 56)
# .planning docs — historical references (lines identified below)
</context>

<tasks>

<task type="auto">
  <name>Task 1: Fix project.yml files (canonical source of truth)</name>
  <files>KeydApp/project.yml, macOS/project.yml</files>
  <action>
    In KeydApp/project.yml, replace every occurrence of the invalid bundle IDs with the correct ones:
    - `com.keyd.app` → `com.ryheff.keyd.app` (appears at PRODUCT_BUNDLE_IDENTIFIER for KeydApp target)
    - `com.keyd.app.tests` → `com.ryheff.keyd.app.tests` (appears at PRODUCT_BUNDLE_IDENTIFIER for KeydAppTests target)
    - `com.keyd.app.live-activity` → `com.ryheff.keyd.app.live-activity` (appears at PRODUCT_BUNDLE_IDENTIFIER for KeydLiveActivity target)

    In macOS/project.yml, replace every occurrence of the invalid bundle IDs:
    - `com.keyd.agent` → `com.ryheff.keyd.agent` (appears at PRODUCT_BUNDLE_IDENTIFIER for KeydAgent target)
    - `com.keyd.agent.tests` → `com.ryheff.keyd.agent.tests` (appears at PRODUCT_BUNDLE_IDENTIFIER for KeydAgentTests target)

    Use sed or direct file edits. Be careful NOT to introduce a double `.ryheff.ryheff` — only replace `com.keyd.` with `com.ryheff.keyd.`. After editing, verify no `com.keyd.` remains in either file.
  </action>
  <verify>
    <automated>grep -r "com\.keyd\." ./KeydApp/project.yml ./macOS/project.yml && echo "FAIL: invalid IDs remain" || echo "PASS: no invalid IDs"</automated>
  </verify>
  <done>
    Both project.yml files contain only `com.ryheff.keyd.*` identifiers. Zero occurrences of `com.keyd.app` or `com.keyd.agent` (without `.ryheff`) remain.
  </done>
</task>

<task type="auto">
  <name>Task 2: Fix KeydApp/KeydApp.xcodeproj/project.pbxproj</name>
  <files>KeydApp/KeydApp.xcodeproj/project.pbxproj</files>
  <action>
    In KeydApp/KeydApp.xcodeproj/project.pbxproj, replace all six occurrences of invalid PRODUCT_BUNDLE_IDENTIFIER values:
    - `PRODUCT_BUNDLE_IDENTIFIER = com.keyd.app;` → `PRODUCT_BUNDLE_IDENTIFIER = com.ryheff.keyd.app;`
    - `PRODUCT_BUNDLE_IDENTIFIER = com.keyd.app.tests;` → `PRODUCT_BUNDLE_IDENTIFIER = com.ryheff.keyd.app.tests;`
    - `PRODUCT_BUNDLE_IDENTIFIER = "com.keyd.app.live-activity";` → `PRODUCT_BUNDLE_IDENTIFIER = "com.ryheff.keyd.app.live-activity";`

    These appear at lines 559, 580, 686, 706, 727, and 768. Use sed with a global replace on the pattern `com\.keyd\.` → `com.ryheff.keyd.` scoped to PRODUCT_BUNDLE_IDENTIFIER lines, or do a full file sed replace of `com\.keyd\.(app|agent)` → `com.ryheff.keyd.\1`.

    Note: `com.ryheff.keyd.app` must NOT become `com.ryheff.ryheff.keyd.app`. The pattern to replace is specifically `com.keyd.` (without `.ryheff.`). Verify the result contains no remaining `com.keyd.` occurrences.

    Do NOT modify any other values in project.pbxproj (DevelopmentTeam, signing settings, etc.).
  </action>
  <verify>
    <automated>grep "PRODUCT_BUNDLE_IDENTIFIER" ./KeydApp/KeydApp.xcodeproj/project.pbxproj</automated>
  </verify>
  <done>
    All six PRODUCT_BUNDLE_IDENTIFIER lines in project.pbxproj contain `com.ryheff.keyd.*`. No line contains `com.keyd.` (without `.ryheff.`). The file has no `com.ryheff.ryheff` double-insert artifacts.
  </done>
</task>

<task type="auto">
  <name>Task 3: Fix planning doc references</name>
  <files>
    .planning/phases/01-transport-and-core-keyboard/01-03-PLAN.md,
    .planning/phases/01-transport-and-core-keyboard/01-04-PLAN.md,
    .planning/phases/01-transport-and-core-keyboard/01-04-SUMMARY.md,
    .planning/phases/01-transport-and-core-keyboard/01-07-PLAN.md,
    .planning/phases/01.1-connected-integration-test-suite/01.1-03-PLAN.md
  </files>
  <action>
    In each planning doc, replace all occurrences of invalid bundle IDs with the correct ones. These are historical reference documents; the fixes ensure they accurately reflect what was actually built.

    Files and known occurrences:
    - `.planning/phases/01-transport-and-core-keyboard/01-03-PLAN.md` line 121: `com.keyd.app` → `com.ryheff.keyd.app`
    - `.planning/phases/01-transport-and-core-keyboard/01-04-PLAN.md` lines 111, 273, 798, 828: replace all `com.keyd.app` and `com.keyd.agent` occurrences
    - `.planning/phases/01-transport-and-core-keyboard/01-04-SUMMARY.md` lines 67, 77, 149, 150: replace all `com.keyd.app` and `com.keyd.agent` occurrences
    - `.planning/phases/01-transport-and-core-keyboard/01-07-PLAN.md` lines 166, 197: replace `com.keyd.app.tests` and `com.keyd.agent.tests`
    - `.planning/phases/01.1-connected-integration-test-suite/01.1-03-PLAN.md` line 93: replace `com.keyd.app.tests`

    Apply replacements: `com.keyd.app` → `com.ryheff.keyd.app`, `com.keyd.agent` → `com.ryheff.keyd.agent` (these two patterns cover all variants including `.tests` and `.live-activity` suffixes since those contain the base pattern).

    Do NOT change any other content in these files.
  </action>
  <verify>
    <automated>grep -rn "com\.keyd\.(app|agent)" ./.planning/ && echo "FAIL: invalid IDs remain in planning docs" || echo "PASS: planning docs clean"</automated>
  </verify>
  <done>
    Zero occurrences of `com.keyd.app` or `com.keyd.agent` (without `.ryheff.`) remain in any .planning/ file. All five planning doc files accurately show `com.ryheff.keyd.*` identifiers.
  </done>
</task>

</tasks>

<verification>
Run this final check after all tasks complete:

```bash
grep -rn "com\.keyd\.(app|agent)" \
  ./KeydApp/project.yml \
  ./macOS/project.yml \
  ./KeydApp/KeydApp.xcodeproj/project.pbxproj \
  ./.planning/ \
  && echo "FAIL: invalid IDs remain" || echo "PASS: all bundle IDs corrected"
```

Also confirm no double-insert:
```bash
grep -rn "com\.ryheff\.ryheff" ./ --exclude-dir=.git --exclude-dir=.build \
  && echo "FAIL: double ryheff found" || echo "PASS: no double-insert"
```
</verification>

<success_criteria>
- Zero files outside `.build/` contain `com.keyd.app` or `com.keyd.agent` (without `.ryheff.`)
- `KeydApp/project.yml` has: `com.ryheff.keyd.app`, `com.ryheff.keyd.app.tests`, `com.ryheff.keyd.app.live-activity`
- `macOS/project.yml` has: `com.ryheff.keyd.agent`, `com.ryheff.keyd.agent.tests`
- `KeydApp/KeydApp.xcodeproj/project.pbxproj` has all six PRODUCT_BUNDLE_IDENTIFIER entries corrected
- No `com.ryheff.ryheff` double-insert artifacts exist anywhere
</success_criteria>

<output>
After completion, create `.planning/quick/6-fix-bundle-identifiers-to-always-include/6-SUMMARY.md` with what was changed.
</output>
