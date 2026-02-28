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
    private var menuTarget: MenuTarget?

    /// Called when the user clicks "Pair iPhone…" in the menu.
    var onShowPairing: (() -> Void)?

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
            if let button = statusItem.button {
                // keyboard.badge.exclamationmark is macOS 14+ — fall back to keyboard
                let image = NSImage(systemSymbolName: "keyboard.badge.exclamationmark",
                                    accessibilityDescription: "KeydAgent: permissions required")
                           ?? NSImage(systemSymbolName: "keyboard",
                                    accessibilityDescription: "KeydAgent: permissions required")
                button.image = image
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

    /// Red xmark.circle.fill icon for missing permission items.
    private static let redXImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "not granted")?
            .withSymbolConfiguration(config)
    }()

    private func buildMenu() {
        let menu = NSMenu()
        let target = MenuTarget(checker: checker, permissions: permissions, onShowPairing: onShowPairing)
        self.menuTarget = target  // retain

        if !permissions.allGranted {
            // ── Permission section (only shown while permissions are missing) ──
            let header = NSMenuItem(title: "Permissions Required", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            // Only show items for missing permissions — each is a clickable button
            // that opens its specific System Settings privacy page.
            if !permissions.accessibility {
                let axItem = NSMenuItem(
                    title: "Accessibility",
                    action: #selector(MenuTarget.openAccessibilitySettings),
                    keyEquivalent: ""
                )
                axItem.image = Self.redXImage
                axItem.target = target
                menu.addItem(axItem)
            }

            if !permissions.inputMonitoring {
                let imItem = NSMenuItem(
                    title: "Input Monitoring",
                    action: #selector(MenuTarget.openInputMonitoringSettings),
                    keyEquivalent: ""
                )
                imItem.image = Self.redXImage
                imItem.target = target
                menu.addItem(imItem)
            }

            menu.addItem(NSMenuItem.separator())

            let relaunchItem = NSMenuItem(
                title: "Relaunch KeydAgent",
                action: #selector(MenuTarget.relaunch),
                keyEquivalent: "r"
            )
            relaunchItem.target = target
            menu.addItem(relaunchItem)

            menu.addItem(NSMenuItem.separator())
        } else {
            // ── Connected status ────────────────────────────────────────
            let statusMenuItem = NSMenuItem(title: currentState.menuTitle, action: nil, keyEquivalent: "")
            statusMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Pair iPhone
        let pairItem = NSMenuItem(
            title: "Pair iPhone…",
            action: #selector(MenuTarget.pairIphone),
            keyEquivalent: "p"
        )
        pairItem.target = target
        menu.addItem(pairItem)

        menu.addItem(NSMenuItem.separator())

        // App info
        let versionItem = NSMenuItem(title: "KeydAgent v1.0", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit KeydAgent",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        ))

        self.statusItem.menu = menu
    }
}

/// Target object for menu item actions (must be NSObject for target-action).
@MainActor
private final class MenuTarget: NSObject {
    private let checker: PermissionChecker
    private let permissions: PermissionResult
    var onShowPairing: (() -> Void)?

    init(checker: PermissionChecker, permissions: PermissionResult, onShowPairing: (() -> Void)?) {
        self.checker = checker
        self.permissions = permissions
        self.onShowPairing = onShowPairing
    }

    @objc func openAccessibilitySettings() {
        // AXIsProcessTrustedWithOptions(prompt:true) is the official API for opening
        // the Accessibility privacy pane — more reliable than URL schemes on Sequoia.
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func pairIphone() {
        onShowPairing?()
    }

    @objc func relaunch() {
        // Launch a fresh copy then terminate this one — IOHIDCheckAccess only
        // reflects new grants after a process restart.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
