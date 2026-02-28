import Foundation
import Accessibility
import IOKit.hid
import AppKit

struct PermissionResult {
    let accessibility: Bool
    let inputMonitoring: Bool
}

/// Checks and reports macOS privacy permissions required for KeydAgent.
/// Both Accessibility and Input Monitoring are required since macOS 10.15 Catalina.
/// IMPORTANT: Both permissions are revoked on every Xcode rebuild — users must
/// toggle off and on again after each rebuild from Xcode.
final class PermissionChecker {

    /// Check both Accessibility and Input Monitoring permissions.
    /// Passing kAXTrustedCheckOptionPrompt: true causes macOS to auto-show the Accessibility prompt.
    func checkPermissions() -> PermissionResult {
        // AXIsProcessTrustedWithOptions — with prompt option triggers system alert
        // Using the string literal to avoid Swift 6 concurrency issue with kAXTrustedCheckOptionPrompt
        let axOptions: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)

        // IOHIDRequestAccess — Input Monitoring (kIOHIDRequestTypeListenEvent)
        // Returns true if already granted; triggers system prompt if not
        let imTrusted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        return PermissionResult(accessibility: axTrusted, inputMonitoring: imTrusted)
    }

    /// Show a blocking alert listing which permissions are missing.
    /// "Open System Settings" button deep-links to Privacy & Security.
    /// "Quit" exits the app — connections will not be accepted without both permissions.
    func showPermissionAlert(accessibility: Bool, inputMonitoring: Bool) {
        var missing: [String] = []
        if !accessibility { missing.append("Accessibility") }
        if !inputMonitoring { missing.append("Input Monitoring") }

        let alert = NSAlert()
        alert.messageText = "KeydAgent requires permissions"
        alert.informativeText = """
        Missing permissions: \(missing.joined(separator: ", ")).

        Grant both in System Settings → Privacy & Security.

        Note: Both permissions are revoked on every Xcode rebuild — \
        toggle off and on again after each rebuild.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Deep-link to Privacy & Security pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
            // App stays running after opening System Settings — user must relaunch after granting
        } else {
            NSApp.terminate(nil)
        }
    }
}
