---
quick_task: "5"
slug: disable-predictive-text-when-using-slide
type: quick
mode: quick
created: "2026-03-01"
autonomous: true
files_expected:
  - KeydApp/KeydApp/UI/KeyboardView.swift
  - .planning/STATE.md
  - .planning/quick/5-disable-predictive-text-when-using-slide/5-SUMMARY.md
---

# Quick Task 5 Plan: Disable Predictive Text During Slide-to-Type

## Objective

Keep slide-to-type available, but ignore keyboard-delivered input suggestions so predictive text does not inject extra words while the hidden keyboard host is active.

## Tasks

### Task 1

- files: `KeydApp/KeydApp/UI/KeyboardView.swift`
- action: Extend the hidden `UITextField` delegate to ignore `insertInputSuggestion` callbacks on iOS 18.4+, while preserving the existing direct text forwarding path.
- verify: Confirm `KeyboardView` still forwards normal typed text through `shouldChangeCharactersIn` and the new delegate method restores the hidden backing text without forwarding suggestions.
- done: pending

### Task 2

- files: `.planning/STATE.md`, `.planning/quick/5-disable-predictive-text-when-using-slide/5-SUMMARY.md`
- action: Record the completed quick task after the code change is built and committed.
- verify: Confirm `STATE.md` includes task 5 with the code commit hash and quick-task directory link.
- done: pending
