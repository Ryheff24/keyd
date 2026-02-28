import AppKit

/// Connection state for the menu bar icon display.
enum ConnectionState {
    case disconnected
    case usb
    case awdl

    var menuTitle: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .usb:          return "USB Connected"
        case .awdl:         return "AWDL Connected"
        }
    }

    /// SF Symbol name for current connection state.
    var symbolName: String {
        switch self {
        case .disconnected: return "keyboard"
        case .usb:          return "keyboard.badge.ellipsis"
        case .awdl:         return "wifi"
        }
    }
}

/// Manages the macOS menu bar icon and status dropdown menu.
/// Shows connection state and any missing permissions clearly in the dropdown.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var currentState: ConnectionState = .disconnected
    private var permissions: PermissionResult = PermissionResult(accessibility: true, inputMonitoring: true)
    private let checker = PermissionChecker()

    // Target-action holder for menu callbacks
    private var menuTarget: MenuTarget?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(state: .disconnected)
        buildMenu()
    }

    /// Update menu bar icon and menu to reflect current connection state.
    func update(state: ConnectionState) {
        currentState = state
        updateIcon(state: state)
        buildMenu()
    }

    /// Update permission state shown in the menu.
    func update(permissions: PermissionResult) {
        self.permissions = permissions
        if !permissions.allGranted {
            // Show warning badge when permissions are missing
            if let button = statusItem.button {
                button.image = NSImage(
                    systemSymbolName: "keyboard.badge.exclamationmark",
                    accessibilityDescription: "KeydAgent: permissions required"
                )
            }
        } else {
            updateIcon(state: currentState)
        }
        buildMenu()
    }

    private func updateIcon(state: ConnectionState) {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: state.symbolName,
                accessibilityDescription: "KeydAgent: \(state.menuTitle)"
            )
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let target = MenuTarget(checker: checker, permissions: permissions)
        self.menuTarget = target  // retain

        if !permissions.allGranted {
            // ── Permission section ──────────────────────────────────────
            let header = NSMenuItem(title: "Permissions Required", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let axLabel = permissions.accessibility ? "✓  Accessibility" : "✗  Accessibility — not granted"
            let axItem = NSMenuItem(title: axLabel, action: nil, keyEquivalent: "")
            axItem.isEnabled = false
            menu.addItem(axItem)

            let imLabel = permissions.inputMonitoring ? "✓  Input Monitoring" : "✗  Input Monitoring — not granted"
            let imItem = NSMenuItem(title: imLabel, action: nil, keyEquivalent: "")
            imItem.isEnabled = false
            menu.addItem(imItem)

            menu.addItem(NSMenuItem.separator())

            let grantItem = NSMenuItem(
                title: "Grant Missing Permissions…",
                action: #selector(MenuTarget.grantPermissions),
                keyEquivalent: ""
            )
            grantItem.target = target
            menu.addItem(grantItem)

            let settingsItem = NSMenuItem(
                title: "Open System Settings…",
                action: #selector(MenuTarget.openSettings),
                keyEquivalent: ","
            )
            settingsItem.target = target
            menu.addItem(settingsItem)

            let hint = NSMenuItem(
                title: "After granting, relaunch KeydAgent",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)

            menu.addItem(NSMenuItem.separator())
        } else {
            // ── Connected status ────────────────────────────────────────
            let statusMenuItem = NSMenuItem(title: currentState.menuTitle, action: nil, keyEquivalent: "")
            statusMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)

            menu.addItem(NSMenuItem.separator())
        }

        // App info
        let versionItem = NSMenuItem(title: "KeydAgent v1.0", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit KeydAgent",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }
}

/// Target object for menu item actions (must be NSObject for target-action).
private final class MenuTarget: NSObject {
    private let checker: PermissionChecker
    private let permissions: PermissionResult

    init(checker: PermissionChecker, permissions: PermissionResult) {
        self.checker = checker
        self.permissions = permissions
    }

    @objc func grantPermissions() {
        checker.requestPermissions(result: permissions)
    }

    @objc func openSettings() {
        checker.openSystemSettings()
    }
}
