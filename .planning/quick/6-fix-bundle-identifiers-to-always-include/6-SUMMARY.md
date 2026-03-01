---
phase: quick-6
plan: 6
subsystem: build-config
tags: [bundle-id, xcode, provisioning, project-yml]
key-files:
  modified:
    - KeydApp/project.yml
    - macOS/project.yml
    - KeydApp/KeydApp.xcodeproj/project.pbxproj
    - .planning/phases/01-transport-and-core-keyboard/01-03-PLAN.md
    - .planning/phases/01-transport-and-core-keyboard/01-04-PLAN.md
    - .planning/phases/01-transport-and-core-keyboard/01-04-SUMMARY.md
    - .planning/phases/01-transport-and-core-keyboard/01-07-PLAN.md
    - .planning/phases/01.1-connected-integration-test-suite/01.1-03-PLAN.md
decisions:
  - "bundleIdPrefix also corrected in both project.yml files to prevent any xcodegen fallback from using the wrong prefix"
metrics:
  duration: 80s
  completed: 2026-03-01
  tasks_completed: 3
  files_modified: 8
---

# Quick Task 6: Fix Bundle Identifiers — Summary

**One-liner:** Corrected all 5 bundle ID variants across project.yml, project.pbxproj, and planning docs from `com.keyd.*` to canonical `com.ryheff.keyd.*` form required for valid provisioning.

## What Was Changed

### Task 1: Fix project.yml files (canonical source of truth)
**Commit:** 820db8e

Fixed 5 PRODUCT_BUNDLE_IDENTIFIER values and both bundleIdPrefix entries:

| File | Old | New |
|------|-----|-----|
| `KeydApp/project.yml` | `bundleIdPrefix: com.keyd` | `com.ryheff.keyd` |
| `KeydApp/project.yml` | `com.keyd.app` | `com.ryheff.keyd.app` |
| `KeydApp/project.yml` | `com.keyd.app.tests` | `com.ryheff.keyd.app.tests` |
| `KeydApp/project.yml` | `com.keyd.app.live-activity` | `com.ryheff.keyd.app.live-activity` |
| `macOS/project.yml` | `bundleIdPrefix: com.keyd` | `com.ryheff.keyd` |
| `macOS/project.yml` | `com.keyd.agent` | `com.ryheff.keyd.agent` |
| `macOS/project.yml` | `com.keyd.agent.tests` | `com.ryheff.keyd.agent.tests` |

### Task 2: Fix KeydApp/KeydApp.xcodeproj/project.pbxproj
**Commit:** 8d2f92c

Fixed 6 PRODUCT_BUNDLE_IDENTIFIER entries (Debug + Release for each of 3 targets):

| Target | Config | Old | New |
|--------|--------|-----|-----|
| KeydApp | Debug | `com.keyd.app` | `com.ryheff.keyd.app` |
| KeydApp | Release | `com.keyd.app` | `com.ryheff.keyd.app` |
| KeydAppTests | Debug | `com.keyd.app.tests` | `com.ryheff.keyd.app.tests` |
| KeydAppTests | Release | `com.keyd.app.tests` | `com.ryheff.keyd.app.tests` |
| KeydLiveActivity | Debug | `"com.keyd.app.live-activity"` | `"com.ryheff.keyd.app.live-activity"` |
| KeydLiveActivity | Release | `"com.keyd.app.live-activity"` | `"com.ryheff.keyd.app.live-activity"` |

### Task 3: Fix planning doc references
**Commit:** d0b4de5

| File | Occurrences Fixed |
|------|-------------------|
| `01-03-PLAN.md` | 1 (line 121: `com.keyd.app`) |
| `01-04-PLAN.md` | 4 (lines 111, 273, 798, 828) |
| `01-04-SUMMARY.md` | 4 (lines 67, 77, 149, 150) |
| `01-07-PLAN.md` | 2 (lines 166, 197: `.tests` variants) |
| `01.1-03-PLAN.md` | 1 (line 93: `com.keyd.app.tests`) |

## Deviations from Plan

**1. [Rule 2 - Missing Critical Fix] Also corrected `bundleIdPrefix` in both project.yml files**
- **Found during:** Task 1
- **Issue:** Both project.yml files had `bundleIdPrefix: com.keyd` — if any new target were added without an explicit `PRODUCT_BUNDLE_IDENTIFIER`, xcodegen would auto-assign `com.keyd.*` using this prefix, silently re-introducing the bug
- **Fix:** Updated `bundleIdPrefix` to `com.ryheff.keyd` in both files
- **Files modified:** `KeydApp/project.yml`, `macOS/project.yml`
- **Commit:** 820db8e (included in Task 1 commit)

## Verification Results

```
PASS: no invalid IDs in project.yml files
PASS: all PRODUCT_BUNDLE_IDENTIFIER values in project.pbxproj = com.ryheff.keyd.*
PASS: planning docs clean
PASS: no double-ryheff (com.ryheff.ryheff) artifacts in any source file
```

Note: grep on `.planning/` returns matches in `6-PLAN.md` itself — those are documentation lines describing the old→new replacement patterns, not actual bundle ID values in source code.

## Self-Check: PASSED

- `KeydApp/project.yml` contains `com.ryheff.keyd.app` — FOUND
- `macOS/project.yml` contains `com.ryheff.keyd.agent` — FOUND
- `KeydApp/KeydApp.xcodeproj/project.pbxproj` all 8 PRODUCT_BUNDLE_IDENTIFIER = `com.ryheff.keyd.*` — FOUND
- Commits 820db8e, 8d2f92c, d0b4de5 exist in git log — FOUND
