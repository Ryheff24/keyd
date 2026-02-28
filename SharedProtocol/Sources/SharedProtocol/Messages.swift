import Foundation

// MARK: - Top-level message envelope

/// All messages sent over the keyd transport, in both directions.
/// IMPORTANT: This enum defines the wire protocol for Phase 1.
/// New message types may be added in later phases but existing
/// type codes must never be renumbered — doing so breaks the protocol.
public enum KeydMessage: Codable, Sendable {

    // MARK: iOS → Mac messages

    /// A single character or key event from the iOS keyboard
    case keyEvent(KeyEvent)

    /// A modifier+key shortcut from the iOS hotkey panel (e.g. Cmd-C)
    case hotkeyEvent(HotkeyEvent)

    /// First-time pairing: iOS sends its Curve25519 public key
    case pairingRequest(PairingRequest)

    /// Existing paired device reconnecting; macOS validates pairing state
    case sessionResume(SessionResume)

    // MARK: Mac → iOS messages (reserved in Phase 1; implemented in Phase 2+)

    /// Acknowledges pairing; macOS sends its Curve25519 public key back
    case pairingResponse(PairingResponse)

    /// macOS invalidated the stored pairing; iOS must discard local pairing
    case pairingInvalidated

    /// Notifies iOS that macOS entered or exited secure input mode (password field)
    case secureInputChanged(SecureInputChanged)

    /// [Phase 2] Reflects macOS field content and cursor state back to iOS
    case reflectState(ReflectState)

    /// [Phase 3] Notifies iOS of frontmost macOS application change
    case appStateChanged(AppStateChanged)
}

// MARK: - iOS → Mac payloads

/// A character typed on the iOS keyboard, delivered as a Unicode scalar.
public struct KeyEvent: Codable, Sendable {
    /// Unicode scalar value (e.g. 97 for 'a')
    public let unicodeScalar: UInt32
    /// True for key-down, false for key-up
    public let keyDown: Bool
    /// Active modifier flags at time of event
    public let modifiers: ModifierFlags

    public init(unicodeScalar: UInt32, keyDown: Bool, modifiers: ModifierFlags = []) {
        self.unicodeScalar = unicodeScalar
        self.keyDown = keyDown
        self.modifiers = modifiers
    }
}

/// A virtual key event (non-character keys: Return, Tab, Escape, Backspace, arrow keys)
/// Also used for hotkey shortcuts where keyCode is known (not just Unicode).
public struct HotkeyEvent: Codable, Sendable {
    /// Carbon HIToolbox virtual key code (kVK_*)
    public let virtualKeyCode: UInt16
    /// True for key-down, false for key-up
    public let keyDown: Bool
    /// Active modifier flags (Command, Shift, Option, Control)
    public let modifiers: ModifierFlags

    public init(virtualKeyCode: UInt16, keyDown: Bool, modifiers: ModifierFlags = []) {
        self.virtualKeyCode = virtualKeyCode
        self.keyDown = keyDown
        self.modifiers = modifiers
    }
}

/// One-time pairing handshake: iOS sends its Curve25519 public key.
public struct PairingRequest: Codable, Sendable {
    /// Raw bytes of the iOS device's Curve25519 public key (32 bytes)
    public let publicKeyData: Data
    /// Unique identifier for this iOS device (UUID string)
    public let deviceID: String

    public init(publicKeyData: Data, deviceID: String) {
        self.publicKeyData = publicKeyData
        self.deviceID = deviceID
    }
}

/// Existing paired device reconnect announcement.
public struct SessionResume: Codable, Sendable {
    /// Unique identifier for this iOS device (UUID string)
    public let deviceID: String

    public init(deviceID: String) {
        self.deviceID = deviceID
    }
}

// MARK: - Mac → iOS payloads

/// Pairing acknowledgement: macOS sends its Curve25519 public key back.
public struct PairingResponse: Codable, Sendable {
    /// Raw bytes of the macOS agent's Curve25519 public key (32 bytes)
    public let publicKeyData: Data
    /// Indicates whether this is an accepted pairing or rejection
    public let accepted: Bool

    public init(publicKeyData: Data, accepted: Bool) {
        self.publicKeyData = publicKeyData
        self.accepted = accepted
    }
}

/// Notifies iOS of secure input mode state on macOS (password field active/inactive).
public struct SecureInputChanged: Codable, Sendable {
    /// True when a secure input field (password) is focused on macOS
    public let isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }
}

/// [Phase 2] Real-time macOS field state reflection. Reserved in Phase 1.
public struct ReflectState: Codable, Sendable {
    /// Current text content of the focused macOS field
    public let text: String
    /// Cursor position (character offset from start)
    public let cursorOffset: Int
    /// Selected range (start offset, length); (0, 0) if no selection
    public let selectionStart: Int
    public let selectionLength: Int

    public init(text: String, cursorOffset: Int, selectionStart: Int = 0, selectionLength: Int = 0) {
        self.text = text
        self.cursorOffset = cursorOffset
        self.selectionStart = selectionStart
        self.selectionLength = selectionLength
    }
}

/// [Phase 3] Frontmost macOS application changed.
public struct AppStateChanged: Codable, Sendable {
    /// Bundle identifier of the frontmost app (e.g. "com.apple.Safari")
    public let bundleID: String
    /// Display name of the frontmost app
    public let appName: String

    public init(bundleID: String, appName: String) {
        self.bundleID = bundleID
        self.appName = appName
    }
}

// MARK: - Modifier flags

/// Bitmask of keyboard modifier keys.
/// Mirrors CGEventFlags values for easy conversion on macOS.
public struct ModifierFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command   = ModifierFlags(rawValue: 1 << 0)
    public static let shift     = ModifierFlags(rawValue: 1 << 1)
    public static let option    = ModifierFlags(rawValue: 1 << 2)
    public static let control   = ModifierFlags(rawValue: 1 << 3)
    public static let capsLock  = ModifierFlags(rawValue: 1 << 4)
}

// MARK: - Well-known virtual key codes (Carbon kVK_ constants)
// These match Carbon.HIToolbox values. Using them here avoids importing Carbon in iOS code.

public enum VirtualKey {
    public static let returnKey:     UInt16 = 0x24
    public static let tab:           UInt16 = 0x30
    public static let space:         UInt16 = 0x31
    public static let delete:        UInt16 = 0x33   // Backspace
    public static let escape:        UInt16 = 0x35
    public static let forwardDelete: UInt16 = 0x75   // fn+Delete / Delete key on full keyboard
    public static let leftArrow:     UInt16 = 0x7B
    public static let rightArrow:    UInt16 = 0x7C
    public static let downArrow:     UInt16 = 0x7D
    public static let upArrow:       UInt16 = 0x7E

    // ANSI letter keys (for shortcuts)
    public static let a: UInt16 = 0x00
    public static let c: UInt16 = 0x08
    public static let q: UInt16 = 0x0C
    public static let v: UInt16 = 0x09
    public static let x: UInt16 = 0x07
    public static let y: UInt16 = 0x10
    public static let z: UInt16 = 0x06

    // Number keys (for shortcuts like Cmd-Shift-4)
    public static let three: UInt16 = 0x14
    public static let four: UInt16 = 0x15
}
