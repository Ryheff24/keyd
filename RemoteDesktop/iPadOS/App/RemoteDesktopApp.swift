import SwiftUI

@main
struct RemoteDesktopApp: App {

    @State private var sessionManager = SessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(sessionManager: sessionManager)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        sessionManager.resumeFromBackground()
                    case .background:
                        sessionManager.pauseForBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
