---
quick_task: "2"
slug: cmd-shift-4-should-crosshair-but-it-s-do
type: quick
mode: quick
created: "2026-02-28"
autonomous: true
files_expected:
  - KeydApp/KeydApp/UI/HotkeyPanel.swift
  - .planning/STATE.md
  - .planning/quick/2-cmd-shift-4-should-crosshair-but-it-s-do/2-SUMMARY.md
---

# Quick Task 2 Plan: Fix the Screenshot Hotkey Mapping

## Objective

Make the `Screenshot` button send `Cmd-Shift-4` so macOS enters crosshair capture mode instead of sending `Cmd-Shift-3` for a full-screen screenshot.

## Tasks

### Task 1

- files: `KeydApp/KeydApp/UI/HotkeyPanel.swift`
- action: Change the `Screenshot` hotkey binding from `VirtualKey.three` to `VirtualKey.four`.
- verify: Confirm the `Screenshot` button now uses `.command + .shift + VirtualKey.four`, which matches macOS `Cmd-Shift-4`.
- done: complete

### Task 2

- files: `.planning/STATE.md`, `.planning/quick/2-cmd-shift-4-should-crosshair-but-it-s-do/2-SUMMARY.md`
- action: Record the completed quick task after the code change is committed.
- verify: Confirm `STATE.md` includes the task number, description, commit hash, and quick-task directory link.
- done: complete
