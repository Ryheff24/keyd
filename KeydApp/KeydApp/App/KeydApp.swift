import SwiftUI

@main
struct KeydApp: App {
    @StateObject private var transportManager = TransportManager()
    @State private var isSecureInputActive = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(transportManager)
                .onAppear {
                    transportManager.onSecureInputChanged = { active in
                        isSecureInputActive = active
                    }
                    transportManager.start()
                }
        }
    }
}
