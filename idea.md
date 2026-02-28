# keyd — Requirements / Formal Idea Sheet

## Invariants (apply to all phases)
- **Goal:** Build an iOS → macOS personal-use app where the iOS app functions as a keyboard/editor that controls text entry on the Mac in real time.
- **Local-only:** For personal use only. Not shipped.
- **Lifecycle:** Self-signed and refreshed regularly (weekly).
- **Connectivity constraints:**
  - No Bluetooth.
  - No infrastructure Wi‑Fi dependency.
- **Supported links:**
  - Wired over USB using **usbmuxd**.
  - Wireless via **AWDL**.
- **Target apps:** Safari, Firefox, Messages.
- **Non-goals:** Not intended for coding/terminal workflows.
- **macOS visual fidelity:** What the Mac visibly shows (caret/selection/field state) is **app-dependent**.

## Phase 1 — Proof of Concept (Transport completed)
- **Purpose:** Establish end-to-end real-time connectivity and reliability, *and* prove basic keyboard control works.
- **Scope:** Phase 1 includes a minimal keyboard that can type into the currently focused field on macOS.
- **Completion requirement:** All networking is completed in this phase.
- **Link requirements:**
  - Works over USB (usbmuxd).
  - Works over AWDL.
  - **USB unplug fallback:** If USB is unplugged, communication falls back to AWDL.
- **Data invariance:**
  - The *data being sent* may change over time.
  - The *transport that the data is sent over* must not change once Phase 1 is complete.
- **Shortcut support:** Include support for my most used hot keys. [Support Link](https://support.apple.com/en-us/102650). This includes but it is not limited to:
    - copy: Command-C
    - cut: Command-X
    - paste: Command-V
    - undo: Command-Z
    - redo: Command-Y
    - select all: Command-A
    - quit: Command-Q
    - Delete word left: Command-Backspace
    - Delete entire line(hidden): Command-Delete
    - Screenshot: Command-Shift-4


## Phase 2 — iOS-native Editing Behaviors
- **Purpose:** The iOS app must provide iOS-native text editing behaviors while editing the currently focused text field on macOS.
- **Required iOS-native behaviors:**
  - Cursor movement.
  - Text selection.
  - Deleting selected text (e.g., delete a selected word).
  - Moving the cursor to an arbitrary position and typing/deleting there.
  - predictive text
  - [editing options](https://support.apple.com/guide/iphone/select-and-edit-text-iph1a9cae52c/ios)
- **Real-time reflection:** Edits performed on iOS must be reflected on the macOS focused field in real time.
- **macOS support note:** Implementation may involve **AX** and/or **IME**.

## Phase 3 - app based keyboard, shortcut hot keys
- **Purpose:** detect the current app and based on that app shows a different set of hot keys
<!-- Option-Command-Esc force quit  -->