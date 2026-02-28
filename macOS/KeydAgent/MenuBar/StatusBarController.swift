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
/// Shows connection state as an icon; includes Quit and debug info items.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var currentState: ConnectionState = .disconnected

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

        // Status line
        let statusItem = NSMenuItem(title: currentState.menuTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

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
