import CoreGraphics
import Foundation
import SharedProtocol

/// Injects keystrokes into the frontmost macOS application via CGEvent.
/// This is the ONLY write path for text and shortcuts in this project.
/// AX text writes (kAXValueAttribute) silently fail in Safari, Firefox, Messages.
///
/// Uses .annotatedSession event tap for reliable delivery to frontmost app.
/// All modifier sequences include defer blocks for key-up (prevents stuck Cmd key, SHORT-11).
final class CGEventInjector {
    private let source = CGEventSource(stateID: .hidSystemState)

    // MARK: - Character injection

    /// Inject a Unicode character as key-down + key-up events.
    /// Uses keyboardSetUnicodeString to bypass keyboard layout mapping.
    func injectCharacter(scalar: UInt32, keyDown: Bool, modifiers: ModifierFlags) {
        guard Unicode.Scalar(scalar) != nil else { return }
        guard let cgFlags = cgEventFlags(from: modifiers) else { return }

        let utf16Value = UInt16(scalar & 0xFFFF)  // BMP characters
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
        guard let event = event else { return }

        withUnsafePointer(to: utf16Value) { ptr in
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: ptr)
        }
        event.flags = cgFlags
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Virtual key injection (shortcuts)

    /// Inject a virtual key code event with optional modifier keys.
    /// CRITICAL: Modifier key-up is sent in a defer block (SHORT-11).
    func injectVirtualKey(virtualKeyCode: UInt16, keyDown: Bool, modifiers: ModifierFlags) {
        guard let cgFlags = cgEventFlags(from: modifiers) else { return }
        let hasModifiers = !modifiers.isEmpty

        if keyDown && hasModifiers {
            // Send modifier key-down
            sendModifiersDown(modifiers)
            // CRITICAL: defer ensures modifier key-up fires even on error/exception
            defer { sendModifiersUp(modifiers) }

            // Send the key event with modifier flags
            let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKeyCode), keyDown: true)
            keyDownEvent?.flags = cgFlags
            keyDownEvent?.post(tap: .cghidEventTap)

            let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKeyCode), keyDown: false)
            keyUpEvent?.flags = cgFlags
            keyUpEvent?.post(tap: .cghidEventTap)
            // defer fires sendModifiersUp here
        } else {
            // Non-modifier key (Return, Tab, Escape, Backspace, etc.)
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKeyCode), keyDown: keyDown)
            event?.flags = cgFlags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Modifier key release

    /// Release all modifier keys unconditionally. Called on transport disconnect (SHORT-11).
    /// Prevents stuck Command/Shift/Option/Control if connection drops mid-sequence.
    func releaseAllModifiers() {
        let modifierKeyCodes: [(CGKeyCode, String)] = [
            (0x37, "Command"),
            (0x38, "Shift"),
            (0x3A, "Option"),
            (0x3B, "Control"),
            (0x36, "Right Command")
        ]
        for (keyCode, name) in modifierKeyCodes {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
            print("[CGEventInjector] Released \(name) key")
        }
    }

    // MARK: - Private helpers

    private func sendModifiersDown(_ modifiers: ModifierFlags) {
        if modifiers.contains(.command)  { postKey(0x37, down: true) }
        if modifiers.contains(.shift)    { postKey(0x38, down: true) }
        if modifiers.contains(.option)   { postKey(0x3A, down: true) }
        if modifiers.contains(.control)  { postKey(0x3B, down: true) }
    }

    private func sendModifiersUp(_ modifiers: ModifierFlags) {
        if modifiers.contains(.command)  { postKey(0x37, down: false) }
        if modifiers.contains(.shift)    { postKey(0x38, down: false) }
        if modifiers.contains(.option)   { postKey(0x3A, down: false) }
        if modifiers.contains(.control)  { postKey(0x3B, down: false) }
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        // HID posting is required for system shortcuts like screenshots.
        event?.post(tap: .cghidEventTap)
    }

    private func cgEventFlags(from modifiers: ModifierFlags) -> CGEventFlags? {
        var flags: CGEventFlags = []
        if modifiers.contains(.command)  { flags.insert(.maskCommand) }
        if modifiers.contains(.shift)    { flags.insert(.maskShift) }
        if modifiers.contains(.option)   { flags.insert(.maskAlternate) }
        if modifiers.contains(.control)  { flags.insert(.maskControl) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }
}
