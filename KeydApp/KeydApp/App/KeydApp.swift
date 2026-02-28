import SwiftUI
import UIKit

// MARK: - Shake detection via UIWindow subclass
extension UIWindow {
    open override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

@main
struct KeydApp: App {
    @StateObject private var transportManager = TransportManager()
    @StateObject private var pairingManager = PairingManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if pairingManager.isPaired {
                    // Keyboard is active — full app
                    RootView()
                        .environmentObject(transportManager)
                        .environmentObject(pairingManager)
                } else {
                    // First launch — show QR pairing screen
                    PairingView(pairingManager: pairingManager)
                        .environmentObject(transportManager)
                        .onAppear {
                            // Start transport so we can send PairingRequest after QR scan
                            transportManager.start()
                        }
                }
            }
            .onReceive(pairingManager.$isPaired) { paired in
                if paired {
                    // Just paired — restart transport with authenticated connection
                    transportManager.start()
                }
            }
            // Handle keyd://reconnect deep link from Dynamic Island reconnect button
            // CONTEXT.md locked decision: expanded Dynamic Island has reconnect button
            .onOpenURL { url in
                guard url.scheme == "keyd", url.host == "reconnect" else { return }
                print("[KeydApp] Reconnect triggered from Dynamic Island")
                transportManager.start()
            }
        }
    }
}
