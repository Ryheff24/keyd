import Foundation
import SharedProtocol
import UIKit

/// iOS-side transport state machine.
/// USB primary; AWDL pre-warmed and promoted on USB disconnect (TRANS-03, TRANS-04).
@MainActor
final class TransportManager: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case usbConnected
        case awdlConnected
    }

    @Published var connectionState: State = .disconnected {
        didSet {
            updateLiveActivity(for: connectionState)
        }
    }

    private var usbTransport = USBTransport()
    private var awdlTransport = AWDLTransport()
    private let liveActivityManager = KeydLiveActivityManager()

    var onSecureInputChanged: ((Bool) -> Void)?

    // MARK: - Start

    func start() {
        Task {
            await startAWDLPrewarm()
            await startUSBConnection()
        }
    }

    private func startAWDLPrewarm() async {
        await awdlTransport.setOnDisconnect { [weak self] in
            Task { @MainActor in
                if self?.connectionState == .awdlConnected {
                    self?.connectionState = .disconnected
                    self?.start()  // Restart both
                }
            }
        }
        await awdlTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                // AWDL is ready but only promote if USB is not active
                if self?.connectionState == .disconnected || self?.connectionState == .connecting {
                    self?.connectionState = .awdlConnected
                    self?.setIdleTimerState(true)
                }
            }
        }
        await awdlTransport.setOnMessage { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }
        await awdlTransport.startBrowsing()
    }

    private func startUSBConnection() async {
        connectionState = .connecting
        setIdleTimerState(false)

        await usbTransport.setOnDisconnect { [weak self] in
            Task { @MainActor in
                print("[TransportManager] USB disconnected — falling back to AWDL")
                let awdlReady = await self?.awdlTransport.isConnected ?? false
                if awdlReady {
                    self?.connectionState = .awdlConnected
                } else {
                    self?.connectionState = .disconnected
                    self?.setIdleTimerState(false)
                }
            }
        }
        await usbTransport.setOnMessage { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }

        await usbTransport.connect()
        connectionState = .usbConnected
        setIdleTimerState(true)
    }

    // MARK: - Send

    func send(_ message: KeydMessage) {
        Task {
            do {
                switch connectionState {
                case .usbConnected:
                    try await usbTransport.send(message)
                case .awdlConnected:
                    try await awdlTransport.send(message)
                default:
                    print("[TransportManager] Cannot send — not connected")
                }
            } catch {
                print("[TransportManager] Send error: \(error)")
            }
        }
    }

    // MARK: - Receive

    private func handleIncomingMessage(_ message: KeydMessage) {
        switch message {
        case .secureInputChanged(let ev):
            onSecureInputChanged?(ev.isActive)
        case .pairingResponse, .reflectState, .appStateChanged:
            // Handled by PairingManager or future plans
            break
        default:
            print("[TransportManager] Unexpected iOS-received message: \(message)")
        }
    }

    // MARK: - Idle Timer

    private func setIdleTimerState(_ active: Bool) {
        UIApplication.shared.isIdleTimerDisabled = active
    }

    // MARK: - Live Activity (Dynamic Island)

    private func updateLiveActivity(for state: State) {
        switch state {
        case .usbConnected:
            if liveActivityManager.activity == nil {
                liveActivityManager.start(status: .usb)
            } else {
                liveActivityManager.update(status: .usb)
            }
        case .awdlConnected:
            if liveActivityManager.activity == nil {
                liveActivityManager.start(status: .awdl)
            } else {
                liveActivityManager.update(status: .awdl)
            }
        case .connecting:
            // Don't start activity yet — wait until actually connected
            break
        case .disconnected:
            liveActivityManager.end()
        }
    }
}

// MARK: - AWDLTransport helper for callback setting
extension AWDLTransport {
    func setOnDisconnect(_ handler: @escaping () -> Void) async { onDisconnect = handler }
    func setOnConnectionReady(_ handler: @escaping () -> Void) async { onConnectionReady = handler }
    func setOnMessage(_ handler: @escaping (KeydMessage) -> Void) async { onMessage = handler }
}
extension USBTransport {
    func setOnDisconnect(_ handler: @escaping () -> Void) async { onDisconnect = handler }
    func setOnMessage(_ handler: @escaping (KeydMessage) -> Void) async { onMessage = handler }
}
