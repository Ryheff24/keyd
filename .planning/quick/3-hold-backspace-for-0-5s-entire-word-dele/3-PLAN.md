---
quick_task: "3"
slug: hold-backspace-for-0-5s-entire-word-dele
type: quick
mode: quick
created: "2026-02-28"
autonomous: true
files_expected:
  - KeydApp/KeydApp/UI/KeyboardView.swift
  - KeydApp/KeydApp/App/RootViewController.swift
  - .planning/STATE.md
  - .planning/quick/3-hold-backspace-for-0-5s-entire-word-dele/3-SUMMARY.md
---

# Quick Task 3 Plan: Fix Hold-to-Delete Word

## Objective

Make holding Backspace for 0.5 seconds trigger the app's word-delete behavior in TextEdit instead of only sending repeated character deletes.

## Tasks

### Task 1

- files: `KeydApp/KeydApp/UI/KeyboardView.swift`
- action: Add backspace burst tracking so the first delete remains a normal backspace, a sustained repeat past 0.5 seconds triggers `onBackspaceStart()` once, and release is inferred when repeat events stop.
- verify: Confirm `KeyboardView` now wires `onBackspaceStart` and `onBackspaceEnd` into the hidden text field and only fires the long-press callback once per hold.
- done: complete

### Task 2

- files: `KeydApp/KeydApp/App/RootViewController.swift`
- action: Change the hold-to-delete action from `Command-Delete` to `Option-Delete` so it matches the existing `Delete Word` shortcut.
- verify: Confirm the backspace hold path sends `VirtualKey.delete` with `.option`.
- done: complete

### Task 3

- files: `.planning/STATE.md`, `.planning/quick/3-hold-backspace-for-0-5s-entire-word-dele/3-SUMMARY.md`
- action: Record the completed quick task after the code change is built and committed.
- verify: Confirm `STATE.md` includes task 3 with the code commit hash and quick-task directory link.
- done: complete
