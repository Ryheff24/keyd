import SwiftUI
import ServiceManagement
import AppKit

/// Main entry point for KeydAgent — a menu bar accessory app with no Dock presence.
/// Responsibilities:
///   1. Register as a Login Item (SMAppService.mainApp.register)
///   2. Check Accessibility + Input Monitoring permissions at every launch
///   3. Show a blocking alert if either permission is missing
///   4. Start USB and AWDL transport listeners if permissions are granted
@main
struct KeydAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows — accessory app lives entirely in the menu bar.
        // Settings scene required by SwiftUI @main; body is empty.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var transportManager: TransportManager?
    private var permissionPollTimer: Timer?
    private let checker = PermissionChecker()
    private let pairingManager = PairingManager()
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — KeydAgent is an accessory app (menu bar only)
        NSApp.setActivationPolicy(.accessory)

        // Register as Login Item — idempotent and safe to call on every launch.
        // Appears in System Settings → General → Login Items as "KeydAgent".
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Already registered or registration not needed — not a fatal error
            print("[AppDelegate] SMAppService.mainApp.register(): \(error.localizedDescription)")
        }

        // Initialize status bar immediately so the icon appears and the user
        // can see what's happening before anything else runs.
        let statusBar = StatusBarController()
        statusBar.onShowPairing = { [weak self] in self?.showPairingWindow() }
        statusBarController = statusBar

        // Silent permission check — no popups. Menu bar shows what's missing.
        let perms = checker.checkPermissions()
        statusBarController?.update(permissions: perms)

        if perms.allGranted {
            startTransport()
        } else {
            print("[AppDelegate] Missing permissions — waiting. Menu bar shows status.")
            // Poll every 3 seconds so the app auto-starts when the user grants permissions
            // in System Settings without needing a manual relaunch.
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pollPermissions()
                }
            }
        }
    }

    private func pollPermissions() {
        let perms = checker.checkPermissions()
        statusBarController?.update(permissions: perms)
        if perms.allGranted {
            print("[AppDelegate] All permissions granted — starting transport")
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            startTransport()
        }
    }

    @MainActor
    private func showPairingWindow() {
        // Bring existing window forward if already open
        if let existing = pairingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = QRCodeWindowView(pairingManager: pairingManager)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Pair iPhone"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pairingWindow = window
    }

    private func startTransport() {
        guard let statusBar = statusBarController else { return }
        let injector = InjectionRouter()
        let manager = TransportManager(injectionRouter: injector, statusBar: statusBar)
        self.transportManager = manager
        Task { @MainActor in
            await manager.start()
        }
        print("[AppDelegate] Transport started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release all modifier keys on quit — prevents stuck modifiers if app is force-quit
        // during a key sequence.
        permissionPollTimer?.invalidate()
        print("[AppDelegate] Application terminating — releasing all modifiers")
    }
}
