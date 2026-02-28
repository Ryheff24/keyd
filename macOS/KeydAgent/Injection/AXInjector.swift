import ApplicationServices
import Foundation

/// Phase 2: AX reading for focused element state (cursor position, selected text).
/// Phase 1: Stub — establishes the interface only.
/// AX is NEVER used for text WRITING — CGEvent is the sole write path.
/// AX text writes silently fail in Safari, Firefox, and Messages.
final class AXInjector {
    /// Returns the currently focused AX UI element, or nil if none or not trusted.
    func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    // Phase 2: Methods for reading text, cursor position, and selection will be added here.
    // They are stubs in Phase 1 to establish the interface.
}
