import Foundation
import Accessibility
import IOKit.hid
import AppKit

struct PermissionResult {
    let accessibility: Bool
    let inputMonitoring: Bool

    var allGranted: Bool { accessibility && inputMonitoring }
}

/// Checks macOS privacy permissions required by KeydAgent without triggering system prompts.
/// Both Accessibility and Input Monitoring are required since macOS 10.15 Catalina.
/// IMPORTANT: Both permissions are revoked on every Xcode rebuild — users must
/// toggle off and on again in System Settings after each rebuild.
final class PermissionChecker {

    /// Silent check — reads current permission state without showing any system prompts.
    func checkPermissions() -> PermissionResult {
        // Use string literal to avoid Swift 6 concurrency issue with kAXTrustedCheckOptionPrompt global
        let axOptions: CFDictionary = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)

        // IOHIDCheckAccess — reads current Input Monitoring state without prompting
        let imStatus = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let imTrusted = imStatus == kIOHIDAccessTypeGranted

        return PermissionResult(accessibility: axTrusted, inputMonitoring: imTrusted)
    }

    /// Trigger system prompts for any missing permissions.
    /// Call only when the user explicitly requests it (e.g. menu item click).
    func requestPermissions(result: PermissionResult) {
        if !result.accessibility {
            let axOptions: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(axOptions)
        }
        if !result.inputMonitoring {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    /// Open the Privacy & Security pane in System Settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
