---
quick_task: "5"
description: disable predictive text when using slide to type
code_commit: de52b41
completed_date: "2026-03-01"
files_modified:
  - KeydApp/KeydApp/UI/KeyboardView.swift
---

# Quick Task 5 Summary: Disable Predictive Text During Slide-to-Type

## What Changed

- Added an iOS 18.4+ `UITextFieldDelegate` `insertInputSuggestion` handler to the hidden keyboard host.
- The new handler ignores keyboard-delivered `UIInputSuggestion` insertions and immediately restores the hidden backing text, so Phase 1 keeps forwarding only direct text input instead of predictive suggestions.

## Verification

- Built the iOS app successfully with `xcodebuild -project KeydApp/KeydApp.xcodeproj -scheme KeydApp -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/keyd-quick-5 build CODE_SIGNING_ALLOWED=NO`.

## Notes

- The repository already had unrelated modifications in `.planning/debug/false-awdl-promotion-when-networking-unavailable.md`, `.planning/phases/01-transport-and-core-keyboard/01-05-SUMMARY.md`, `KeydApp/KeydApp/Transport/AWDLTransport.swift`, `KeydApp/KeydApp/Transport/TransportManager.swift`, and `macOS/KeydAgent/Transport/TransportManager.swift`; they were left untouched.
