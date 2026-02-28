---
quick_task: "1"
description: swap the "select all" and "tab" shortcut positions
code_commit: c1b35cb
completed_date: "2026-02-28"
files_modified:
  - KeydApp/KeydApp/UI/HotkeyPanel.swift
---

# Quick Task 1 Summary: Swap the "Select All" and "Tab" shortcut positions

## What Changed

- Reordered the `hotkeys` array in `HotkeyPanel` so `Tab` now occupies the previous `Select All` slot.
- Moved `Select All` to the previous `Tab` slot, which swaps the two buttons in the rendered two-column grid without changing any key bindings.

## Verification

- Reviewed the row-major `hotkeys` order and confirmed the grid now places `Cut` / `Tab` on the third row and `Escape` / `Select All` on the fourth row.
- No build or test run was needed because this task only changes static array ordering in the SwiftUI view.

## Notes

- `HotkeyPanel.swift` already had unrelated local edits in the working tree; the code commit for this quick task isolates only the requested button-order change.
