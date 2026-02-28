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

    enum TransportError: LocalizedError {
        case notConnected
        case connectionTimedOut
        case pairingTimedOut
        case pairingCancelled

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to the Mac."
            case .connectionTimedOut:
                return "Timed out waiting for the Mac connection."
            case .pairingTimedOut:
                return "Timed out waiting for the Mac to confirm pairing."
            case .pairingCancelled:
                return "The pending pairing attempt was cancelled."
            }
        }
    }

    @Published var connectionState: State = .disconnected {
        didSet {
            updateLiveActivity(for: connectionState)
            if isConnected {
                resolveConnectionReady()
            }
        }
    }

    private var usbTransport = USBTransport()
    private var awdlTransport = AWDLTransport()
    private let liveActivityManager = KeydLiveActivityManager()
    private var startTask: Task<Void, Never>?
    private var connectionReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectionReadyTimeoutTask: Task<Void, Never>?
    private var pairingResponseContinuation: CheckedContinuation<PairingResponse, Error>?
    private var pairingResponseTimeoutTask: Task<Void, Never>?

    var onSecureInputChanged: ((Bool) -> Void)?

    // Connection event log for debug overlay
    private var connectionEventLog: [String] = []

    func logConnectionEvent(_ event: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionEventLog.append("[\(timestamp)] \(event)")
        if connectionEventLog.count > 100 { connectionEventLog.removeFirst() }
        print("[TransportManager] \(event)")
    }

    func getEventLog() -> [String] { connectionEventLog }

    var isConnected: Bool {
        switch connectionState {
        case .usbConnected, .awdlConnected:
            return true
        case .disconnected, .connecting:
            return false
        }
    }

    // MARK: - Start

    func start() {
        guard startTask == nil else {
            logConnectionEvent("Start ignored — connection attempt already in progress")
            return
        }
        guard !isConnected else {
            logConnectionEvent("Start ignored — transport already connected")
            return
        }

        connectionState = .connecting
        setIdleTimerState(false)
        logConnectionEvent("Starting transport")

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            await self.startAWDLPrewarm()
            await self.startUSBConnection()
        }
    }

    func reconnect() {
        resetConnections()
        start()
    }

    func resetConnections() {
        startTask?.cancel()
        startTask = nil
        clearPendingConnectionReady(with: TransportError.pairingCancelled)
        clearPendingPairingResponse(with: TransportError.pairingCancelled)
        connectionState = .disconnected
        setIdleTimerState(false)
        logConnectionEvent("Transport reset")

        Task { [weak self] in
            guard let self else { return }
            await self.usbTransport.disconnect()
            await self.awdlTransport.stop()
        }
    }

    private func startAWDLPrewarm() async {
        await awdlTransport.setOnDisconnect { [weak self] in
            Task { @MainActor in
                if self?.connectionState == .awdlConnected {
                    self?.connectionState = .disconnected
                    self?.setIdleTimerState(false)
                    self?.logConnectionEvent("AWDL disconnected")
                    self?.scheduleReconnect()
                }
            }
        }
        await awdlTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                // AWDL is ready but only promote if USB is not active
                if self?.connectionState == .disconnected || self?.connectionState == .connecting {
                    self?.connectionState = .awdlConnected
                    self?.setIdleTimerState(true)
                    self?.logConnectionEvent("AWDL connected")
                } else {
                    self?.logConnectionEvent("AWDL pre-warmed and standing by")
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
        await usbTransport.setOnDisconnect { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                print("[TransportManager] USB disconnected — checking AWDL pre-warm status")
                self.logConnectionEvent("USB disconnected")

                let awdlReady = await self.awdlTransport.isConnected
                if awdlReady {
                    print("[TransportManager] AWDL pre-warmed and ready — switching to AWDL")
                    self.connectionState = .awdlConnected
                    self.logConnectionEvent("AWDL promoted (was pre-warmed)")
                } else {
                    print("[TransportManager] AWDL not ready — entering disconnected state")
                    self.connectionState = .disconnected
                    self.setIdleTimerState(false)
                    self.logConnectionEvent("Disconnected — AWDL unavailable; restarting")
                    self.scheduleReconnect()
                }
            }
        }
        await usbTransport.setOnMessage { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }

        let connected = await usbTransport.connect()
        guard connected else {
            if connectionState == .connecting {
                connectionState = .disconnected
                setIdleTimerState(false)
                logConnectionEvent("USB unavailable — waiting for AWDL or retry")
            }
            return
        }

        // Promote USB; log if AWDL was previously active (USB re-plug case)
        if case .awdlConnected = connectionState {
            logConnectionEvent("USB reconnected; AWDL demoted to pre-warm")
        }
        connectionState = .usbConnected
        setIdleTimerState(true)
        logConnectionEvent("USB connected")
    }

    // MARK: - Send

    func send(_ message: KeydMessage) {
        Task {
            do {
                try await self.sendMessage(message)
            } catch {
                self.logConnectionEvent("Send failed: \(error.localizedDescription)")
            }
        }
    }

    func sendMessage(_ message: KeydMessage) async throws {
        switch connectionState {
        case .usbConnected:
            try await usbTransport.send(message)
        case .awdlConnected:
            try await awdlTransport.send(message)
        case .disconnected, .connecting:
            throw TransportError.notConnected
        }
    }

    func waitForConnection(timeoutNanoseconds: UInt64 = 8_000_000_000) async throws {
        if isConnected {
            return
        }

        clearPendingConnectionReady(with: TransportError.pairingCancelled)

        try await withCheckedThrowingContinuation { continuation in
            connectionReadyContinuation = continuation
            connectionReadyTimeoutTask?.cancel()
            connectionReadyTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self, self.connectionReadyContinuation != nil else { return }
                self.clearPendingConnectionReady(with: TransportError.connectionTimedOut)
            }
        }
    }

    func awaitPairingResponse(timeoutNanoseconds: UInt64 = 5_000_000_000) async throws -> PairingResponse {
        clearPendingPairingResponse(with: TransportError.pairingCancelled)

        return try await withCheckedThrowingContinuation { continuation in
            pairingResponseContinuation = continuation
            pairingResponseTimeoutTask?.cancel()
            pairingResponseTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self, self.pairingResponseContinuation != nil else { return }
                self.clearPendingPairingResponse(with: TransportError.pairingTimedOut)
            }
        }
    }

    // MARK: - Receive

    private func handleIncomingMessage(_ message: KeydMessage) {
        switch message {
        case .pairingResponse(let response):
            logConnectionEvent(response.accepted ? "Pairing accepted by Mac" : "Pairing rejected by Mac")
            resolvePairingResponse(response)
        case .secureInputChanged(let ev):
            onSecureInputChanged?(ev.isActive)
        case .reflectState, .appStateChanged:
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

    private func scheduleReconnect(after delay: TimeInterval = 1.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isConnected, self.startTask == nil else { return }
            self.start()
        }
    }

    private func resolvePairingResponse(_ response: PairingResponse) {
        pairingResponseTimeoutTask?.cancel()
        pairingResponseTimeoutTask = nil
        pairingResponseContinuation?.resume(returning: response)
        pairingResponseContinuation = nil
    }

    private func resolveConnectionReady() {
        connectionReadyTimeoutTask?.cancel()
        connectionReadyTimeoutTask = nil
        connectionReadyContinuation?.resume()
        connectionReadyContinuation = nil
    }

    private func clearPendingConnectionReady(with error: Error) {
        connectionReadyTimeoutTask?.cancel()
        connectionReadyTimeoutTask = nil
        connectionReadyContinuation?.resume(throwing: error)
        connectionReadyContinuation = nil
    }

    private func clearPendingPairingResponse(with error: Error) {
        pairingResponseTimeoutTask?.cancel()
        pairingResponseTimeoutTask = nil
        pairingResponseContinuation?.resume(throwing: error)
        pairingResponseContinuation = nil
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
