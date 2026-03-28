import SwiftUI

@main
struct RemoteDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            Text("RemoteDesktopApp")
                .foregroundStyle(.white)
        }
    }
}
