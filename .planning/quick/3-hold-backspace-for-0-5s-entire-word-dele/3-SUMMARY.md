---
quick_task: "3"
description: Hold Backspace for 0.5s -> entire word deleted in TextEdit (word-delete) doesnt work
code_commit: 261eebf
completed_date: "2026-02-28"
files_modified:
  - KeydApp/KeydApp/UI/KeyboardView.swift
  - KeydApp/KeydApp/App/RootViewController.swift
---

# Quick Task 3 Summary: Fix Hold-to-Delete Word

## What Changed

- Wired `KeyboardView`'s hidden text field to track backspace bursts so it can detect a sustained hold and trigger the long-press callback once per hold.
- Added a small repeat heuristic that keeps normal backspace taps working, waits for fast repeat cadence, and infers release after the repeat stream stops.
- Changed the hold-to-delete shortcut in `RootView` to reuse the same `Option-Delete` path as the existing `Delete Word` hotkey.

## Verification

- Built the iOS app successfully with `xcodebuild -project KeydApp/KeydApp.xcodeproj -scheme KeydApp -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/keyd-quick-3 build CODE_SIGNING_ALLOWED=NO`.

## Notes

- The repository still has an unrelated untracked file at `.planning/phases/01-transport-and-core-keyboard/01-05-SUMMARY.md`, which was left untouched.
