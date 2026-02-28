import SwiftUI
import ServiceManagement

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var transportManager: TransportManager?

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

        // Initialize status bar BEFORE permission check so icon appears immediately
        statusBarController = StatusBarController()

        // Check BOTH Accessibility and Input Monitoring permissions at every launch.
        // CRITICAL: both are revoked on every Xcode rebuild.
        let checker = PermissionChecker()
        let perms = checker.checkPermissions()

        if !perms.accessibility || !perms.inputMonitoring {
            // Show blocking alert — app stays running but does not accept connections
            // until the user relaunches after granting permissions in System Settings.
            checker.showPermissionAlert(
                accessibility: perms.accessibility,
                inputMonitoring: perms.inputMonitoring
            )
            // Do NOT start transport without both permissions
            print("[AppDelegate] Missing permissions — transport not started")
            return
        }

        // Permissions granted — start USB and AWDL transport
        startTransport()
    }

    @MainActor
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
        print("[AppDelegate] Application terminating — releasing all modifiers")
    }
}
