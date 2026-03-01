# Debug Session: keyboard-undo-and-predictive-text-not-disabled

## Summary

Issue: The recent iOS quick fixes did not stop Shake to Undo or predictive text behavior while using the hidden system keyboard host. The final fix keeps predictive text visible instead of letting it repeatedly appear and disappear after swipe input, which removes the visual glitch and aligns with the next phase.

## Symptoms

- Expected: Shaking the phone should never show Undo, and swipe typing should not surface predictive text UI or suggestion insertion behavior.
- Actual: Both behaviors reproduced after the recent quick fixes, and later testing showed the real user-facing problem was predictive text repeatedly appearing and disappearing after swipe-typed words.
- Errors: No explicit runtime error reported.
- Timeline: Observed immediately after quick tasks 4 and 5 were merged on 2026-03-01.
- Reproduction:
  1. Launch `KeydApp` and focus the stock iOS keyboard.
  2. Type using the hidden keyboard host.
  3. Shake the device.
  4. Observe Shake to Undo still appears.
  5. Swipe-type on the system keyboard.
  6. Observe predictive text behavior still appears.

## Root Cause

The previous fixes were applied at the wrong layer:

- `UIApplication.shared.applicationSupportsShakeToEdit = false` is app-global, but the actual undo/prediction behaviors are owned by the hidden first-responder `UITextField`.
- Ignoring `insertInputSuggestion` only drops one late callback path; it does not change the keyboard traits that determine whether suggestions are shown in the first place.
- For this app’s current UX, forcing prediction off was the wrong goal. The visible flicker came from prediction UI being suppressed and reintroduced around swipe input rather than staying consistently visible.

## Fix

- Keep `applicationSupportsShakeToEdit = false` immediately before the hidden text field becomes first responder.
- Keep the hidden text field's `undoManager` disabled so the keyboard responder no longer participates in text undo registration.
- Remove the secure-text-entry suppression that was added for predictive text, because it disables swipe typing itself.
- Restore the hidden text field's prediction-related traits to their default values and remove the `insertInputSuggestion` override, so predictive behavior stays consistently visible while the later predictive-text phase is still pending.
- Do not add swipe-only predictive suppression now; the stable, always-visible prediction UI is the correct behavior for the current phase.

## Verification

- Initial broadened patch compiled, but user reported on-device that Shake to Undo was fixed and swipe typing stopped working.
- After removing the secure-text-entry suppression and restoring default prediction behavior, the app compiled again.
- User verified on-device that the final behavior works as intended: Shake to Undo stays disabled, swipe typing still works, and predictive text no longer visually flickers by appearing and disappearing after swipes.

## Status

Root cause found and fix applied.
