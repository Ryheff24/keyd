import SwiftUI
import os.log

private let appLog = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "RemoteDesktopApp")

@main
struct RemoteDesktopApp: App {

    @State private var sessionManager = SessionManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        appLog.info("[RemoteDesktopApp] init called")
    }

    var body: some Scene {
        appLog.info("[RemoteDesktopApp] body evaluated")
        return WindowGroup {
            ContentView(sessionManager: sessionManager)
                .onChange(of: scenePhase) { _, newPhase in
                    appLog.info("[RemoteDesktopApp] scenePhase changed to: \(String(describing: newPhase))")
                    switch newPhase {
                    case .active:
                        appLog.info("[RemoteDesktopApp] scenePhase -> active, calling resumeFromBackground")
                        sessionManager.resumeFromBackground()
                    case .background:
                        appLog.info("[RemoteDesktopApp] scenePhase -> background, calling pauseForBackground")
                        sessionManager.pauseForBackground()
                    case .inactive:
                        appLog.info("[RemoteDesktopApp] scenePhase -> inactive")
                        break
                    @unknown default:
                        appLog.info("[RemoteDesktopApp] scenePhase -> unknown default")
                        break
                    }
                }
        }
    }
}
