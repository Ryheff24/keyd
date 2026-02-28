---
quick_task: "1"
slug: swap-the-select-all-and-tab-shortcut-pos
type: quick
mode: quick
created: "2026-02-28"
autonomous: true
files_expected:
  - KeydApp/KeydApp/UI/HotkeyPanel.swift
  - .planning/STATE.md
  - .planning/quick/1-swap-the-select-all-and-tab-shortcut-pos/1-SUMMARY.md
---

# Quick Task 1 Plan: Swap the "Select All" and "Tab" shortcut positions

## Objective

Move the `Tab` hotkey into the current `Select All` grid slot and move `Select All` into the current `Tab` grid slot by reordering the `hotkeys` array that drives the two-column shortcut panel.

## Tasks

### Task 1

- files: `KeydApp/KeydApp/UI/HotkeyPanel.swift`
- action: Reorder the `hotkeys` array so `Tab` appears immediately after `Cut`, while `Select All` moves to the slot after `Escape`.
- verify: Confirm the row-major array order produces `Cut` / `Tab` on the third grid row and `Escape` / `Select All` on the fourth row.
- done: complete

### Task 2

- files: `.planning/STATE.md`, `.planning/quick/1-swap-the-select-all-and-tab-shortcut-pos/1-SUMMARY.md`
- action: Record the completed quick task and capture the implementation details after the code change is committed.
- verify: Confirm `STATE.md` includes the task number, description, code commit hash, and quick-task directory link.
- done: complete
