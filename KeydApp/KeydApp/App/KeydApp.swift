import SwiftUI
import UIKit
import SharedProtocol

private let logger = KeydLogger(category: "KeydApp")

extension Notification.Name {
    static let pairingInvalidated = Notification.Name("pairingInvalidated")
}

@main
struct KeydApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transportManager = TransportManager()
    @StateObject private var pairingManager = PairingManager()

    init() {
        UIApplication.shared.applicationSupportsShakeToEdit = false
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if pairingManager.isPaired {
                    // Keyboard is active — full app
                    RootView()
                        .environmentObject(transportManager)
                        .environmentObject(pairingManager)
                        .onAppear {
                            transportManager.start(allowAWDL: true)
                        }
                } else {
                    // First launch — show QR pairing screen
                    PairingView(pairingManager: pairingManager)
                        .environmentObject(transportManager)
                        .onAppear {
                            // Start transport so we can send PairingRequest after QR scan
                            transportManager.start(allowAWDL: true, suppressAWDLStatus: true)
                        }
                }
            }
            // Handle keyd://reconnect deep link from Dynamic Island reconnect button
            // CONTEXT.md locked decision: expanded Dynamic Island has reconnect button
            .onOpenURL { url in
                guard url.scheme == "keyd", url.host == "reconnect" else { return }
                logger.info("Reconnect triggered from Dynamic Island")
                transportManager.reconnect()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    transportManager.resumeLiveActivity()
                case .background:
                    break
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                transportManager.suspendLiveActivity()
                transportManager.resetConnections()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingInvalidated)) { _ in
                transportManager.resetConnections()
                pairingManager.resetPairing()
            }
        }
    }
}
