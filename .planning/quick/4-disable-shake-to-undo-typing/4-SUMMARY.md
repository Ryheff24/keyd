---
quick_task: "4"
description: disable shake to undo typing.
code_commit: 3492fd6
completed_date: "2026-03-01"
files_modified:
  - KeydApp/KeydApp/App/KeydApp.swift
---

# Quick Task 4 Summary: Disable Shake to Undo

## What Changed

- Added an app initializer in `KeydApp` that sets `UIApplication.shared.applicationSupportsShakeToEdit` to `false`.
- This disables iOS's shake-to-undo behavior across the app so device movement does not surface the undo typing prompt while using Keyd.

## Verification

- Built the iOS app successfully with `xcodebuild -project KeydApp/KeydApp.xcodeproj -scheme KeydApp -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/keyd-quick-4 build CODE_SIGNING_ALLOWED=NO`.

## Notes

- The repository already had unrelated modifications in `.planning/debug/false-awdl-promotion-when-networking-unavailable.md`, `.planning/phases/01-transport-and-core-keyboard/01-05-SUMMARY.md`, `KeydApp/KeydApp/Transport/AWDLTransport.swift`, `KeydApp/KeydApp/Transport/TransportManager.swift`, and `macOS/KeydAgent/Transport/TransportManager.swift`; they were left untouched.
