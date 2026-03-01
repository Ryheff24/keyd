import SwiftUI
import ServiceManagement
import AppKit
import SharedProtocol

private let logger = KeydLogger(category: "AppDelegate")

/// Passed to TransportManager and PairingManager when --test-mode is active.
/// All fields use test-safe defaults. Never instantiated in production.
struct TestMode {
    /// USB identity timeout (production: 2s default; test: 2s — same, but explicit for clarity)
    let identityTimeout: TimeInterval = 2.0
    /// AWDL slot timeout (production: 3s; test: 2s)
    let awdlSlotTimeout: TimeInterval = 2.0
    /// Verbose wire log to stdout for every message (excluding heartbeats, tagged [HB])
    let verboseWireLog: Bool = true
    /// Counter for deterministic conn-N IDs
    var connectionCounter: Int = 0
}

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
    private var pairingManager: PairingManager = PairingManager()
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — KeydAgent is an accessory app (menu bar only)
        NSApp.setActivationPolicy(.accessory)

        // Detect --test-mode flag
        let isTestMode = ProcessInfo.processInfo.arguments.contains("--test-mode")
        let testMode: TestMode? = isTestMode ? TestMode() : nil

        if isTestMode {
            logger.info("[TEST MODE] Agent starting in test mode — Keychain writes disabled, 2s timeouts, verbose wire log")
        }

        // In test mode, skip SMAppService registration — test agents are transient processes.
        if !isTestMode {
            // Register as Login Item — idempotent and safe to call on every launch.
            // Appears in System Settings → General → Login Items as "KeydAgent".
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Already registered or registration not needed — not a fatal error
                logger.warning("SMAppService.mainApp.register(): \(error.localizedDescription)")
            }
        }

        // Build PairingManager with test mode awareness
        pairingManager = PairingManager(testMode: testMode)

        // Initialize status bar immediately so the icon appears and the user
        // can see what's happening before anything else runs.
        let statusBar = StatusBarController()
        statusBar.onShowPairing = { [weak self] in self?.showPairingWindow() }
        statusBar.onResetPairing = { [weak self] in self?.resetPairing() }
        statusBarController = statusBar

        // In test mode, bypass the permissions check — test environment has permissions granted.
        // The poll-and-wait loop is not appropriate for automated tests.
        if isTestMode {
            startTransport(testMode: testMode)
            return
        }

        // Silent permission check — no popups. Menu bar shows what's missing.
        let perms = checker.checkPermissions()
        statusBarController?.update(permissions: perms)

        if perms.allGranted {
            startTransport()
        } else {
            logger.warning("Missing permissions — waiting. Menu bar shows status.")
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
            logger.info("All permissions granted — starting transport")
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

    private func startTransport(testMode: TestMode? = nil) {
        guard let statusBar = statusBarController else { return }
        let injector = InjectionRouter()
        let manager = TransportManager(
            injectionRouter: injector,
            statusBar: statusBar,
            pairingManager: pairingManager,
            testMode: testMode
        )
        manager.onPairingCompleted = { [weak self] in
            self?.closePairingWindow()
        }
        self.transportManager = manager
        Task { @MainActor in
            await manager.start()
        }
        logger.info("Transport started\(testMode != nil ? " (test mode)" : "")")
    }

    @MainActor
    private func resetPairing() {
        transportManager?.invalidateRemotePairing()
        pairingManager.resetPairing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.transportManager?.resetActiveSession()
        }
        closePairingWindow()
        logger.info("Pairing reset")
    }

    @MainActor
    private func closePairingWindow() {
        pairingWindow?.close()
        pairingWindow = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release all modifier keys on quit — prevents stuck modifiers if app is force-quit
        // during a key sequence.
        permissionPollTimer?.invalidate()
        logger.info("Application terminating — releasing all modifiers")
    }
}
