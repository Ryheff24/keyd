---
quick_task: "4"
slug: disable-shake-to-undo-typing
type: quick
mode: quick
created: "2026-03-01"
autonomous: true
files_expected:
  - KeydApp/KeydApp/App/KeydApp.swift
  - .planning/STATE.md
  - .planning/quick/4-disable-shake-to-undo-typing/4-SUMMARY.md
---

# Quick Task 4 Plan: Disable Shake to Undo

## Objective

Turn off iOS shake-to-undo for the app so accidental device motion does not trigger the typing undo UI while using Keyd.

## Tasks

### Task 1

- files: `KeydApp/KeydApp/App/KeydApp.swift`
- action: Set `UIApplication.shared.applicationSupportsShakeToEdit` to `false` during app startup so the setting applies app-wide.
- verify: Confirm the SwiftUI app entry point disables shake-to-edit in its initializer.
- done: complete

### Task 2

- files: `.planning/STATE.md`, `.planning/quick/4-disable-shake-to-undo-typing/4-SUMMARY.md`
- action: Record the completed quick task after the code change is built and committed.
- verify: Confirm `STATE.md` includes task 4 with the code commit hash and quick-task directory link.
- done: complete
