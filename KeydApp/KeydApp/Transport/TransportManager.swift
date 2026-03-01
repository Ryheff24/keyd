import Foundation
import SharedProtocol
import UIKit

/// iOS-side transport state machine.
/// USB is primary; AWDL discovery stays warm and a fresh AWDL connection is made when needed.
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
            if connectionState == .awdlConnected, oldValue != .awdlConnected {
                startAWDLHeartbeat()
            } else if connectionState != .awdlConnected, oldValue == .awdlConnected {
                stopAWDLHeartbeat()
            }
            if connectionState != .connecting {
                awdlConnectingFallbackTask?.cancel()
                awdlConnectingFallbackTask = nil
            }
            if isConnected {
                resolveConnectionReady()
            }
            if isConnected, connectionState != oldValue, !suppressAWDLStatusUntilPaired {
                sendSessionResume()
            }
        }
    }

    private var usbTransport = USBTransport()
    private var awdlTransport = AWDLTransport()
    private let liveActivityManager = KeydLiveActivityManager()
    private var startTask: Task<Void, Never>?
    private var awdlConnectingFallbackTask: Task<Void, Never>?
    private var awdlHeartbeatTask: Task<Void, Never>?
    private var connectionReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectionReadyTimeoutTask: Task<Void, Never>?
    private var pairingResponseContinuation: CheckedContinuation<PairingResponse, Error>?
    private var pairingResponseTimeoutTask: Task<Void, Never>?
    private var awdlEnabledForCurrentSession = true
    private var suppressAWDLStatusUntilPaired = false
    private var awaitingAWDLHeartbeatAck = false

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

    var allowsAWDL: Bool { awdlEnabledForCurrentSession }

    // MARK: - Start

    func start(allowAWDL: Bool = true, suppressAWDLStatus: Bool = false) {
        suppressAWDLStatusUntilPaired = suppressAWDLStatus

        if allowAWDL, isConnected, !awdlEnabledForCurrentSession {
            awdlEnabledForCurrentSession = true
            logConnectionEvent("AWDL standby enabled")
            Task { [weak self] in
                await self?.startAWDLPrewarm()
            }
        }

        guard startTask == nil else {
            logConnectionEvent("Start ignored — connection attempt already in progress")
            return
        }
        guard !isConnected else {
            logConnectionEvent("Start ignored — transport already connected")
            return
        }

        awdlEnabledForCurrentSession = allowAWDL
        connectionState = .connecting
        setIdleTimerState(false)
        logConnectionEvent(allowAWDL ? "Starting transport" : "Starting transport (USB only)")

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            if allowAWDL {
                await self.startAWDLPrewarm()
            } else {
                await self.awdlTransport.stop()
            }
            await self.startUSBConnection()
        }
    }

    func reconnect() {
        let allowAWDL = awdlEnabledForCurrentSession
        let suppressAWDLStatus = suppressAWDLStatusUntilPaired
        resetConnections()
        start(allowAWDL: allowAWDL, suppressAWDLStatus: suppressAWDLStatus)
    }

    func resetConnections() {
        startTask?.cancel()
        startTask = nil
        awdlConnectingFallbackTask?.cancel()
        awdlConnectingFallbackTask = nil
        stopAWDLHeartbeat()
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

    func invalidateRemotePairing() async {
        do {
            try await sendMessage(.pairingInvalidated)
            logConnectionEvent("Sent pairing invalidation")
        } catch {
            logConnectionEvent("Pairing invalidation skipped: \(error.localizedDescription)")
        }
    }

    private func startAWDLPrewarm() async {
        await awdlTransport.setOnDisconnect { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressAWDLStatusUntilPaired {
                    self.logConnectionEvent("AWDL pairing channel disconnected")
                    return
                }
                if self.connectionState == .awdlConnected {
                    self.enterDisconnectedState(logMessage: "AWDL disconnected")
                }
            }
        }
        await awdlTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressAWDLStatusUntilPaired {
                    self.logConnectionEvent("AWDL ready for pairing")
                    self.resolveConnectionReady()
                    return
                }
                if self.connectionState == .disconnected || self.connectionState == .connecting {
                    self.connectionState = .awdlConnected
                    self.setIdleTimerState(true)
                    self.logConnectionEvent("AWDL connected")
                } else if self.connectionState == .usbConnected {
                    await self.awdlTransport.prepareForUSBStandby()
                    self.logConnectionEvent("AWDL connection closed while USB is primary")
                } else {
                    self.logConnectionEvent("AWDL connection event ignored")
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

                print("[TransportManager] USB disconnected — evaluating fresh AWDL handoff")
                self.logConnectionEvent("USB disconnected")
                await self.startAWDLConnectionAttempt(
                    availableNowMessage: "Attempting fresh AWDL handoff",
                    unavailableMessage: "Disconnected — AWDL unavailable"
                )
            }
        }
        await usbTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                if self.awdlEnabledForCurrentSession {
                    await self.awdlTransport.prepareForUSBStandby()
                }

                if case .awdlConnected = self.connectionState {
                    self.logConnectionEvent("USB reconnected; AWDL standby cleared")
                }

                if self.connectionState != .usbConnected {
                    self.connectionState = .usbConnected
                    self.setIdleTimerState(true)
                    self.logConnectionEvent("USB connected")
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
                if awdlEnabledForCurrentSession {
                    await startAWDLConnectionAttempt(
                        availableNowMessage: "USB unavailable — attempting AWDL connection",
                        unavailableMessage: "USB unavailable — waiting for AWDL or cable"
                    )
                } else {
                    enterDisconnectedState(logMessage: "USB unavailable — waiting for cable or manual retry")
                }
            }
            return
        }
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
        if await usbTransport.hasReadyConnection() {
            try await usbTransport.send(message)
            return
        }

        if await awdlTransport.hasConnection() {
            try await awdlTransport.send(message)
            return
        }

        throw TransportError.notConnected
    }

    func sendPairingRequest(_ request: PairingRequest) async throws {
        let message = KeydMessage.pairingRequest(request)

        if connectionState == .usbConnected, await usbTransport.hasReadyConnection() {
            try await usbTransport.sendBestEffort(message)
            logConnectionEvent("Queued pairing request over USB")
            return
        }

        if await awdlTransport.hasConnection() {
            try await awdlTransport.sendBestEffort(message)
            logConnectionEvent("Queued pairing request over AWDL")
            return
        }

        throw TransportError.notConnected
    }

    func waitForConnection(timeoutNanoseconds: UInt64 = 8_000_000_000) async throws {
        let usbConnected = await usbTransport.hasReadyConnection()
        let awdlConnected = await awdlTransport.hasConnection()
        if isConnected || usbConnected || awdlConnected {
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

    func finalizePairingTransportState() async {
        suppressAWDLStatusUntilPaired = false

        if await usbTransport.hasReadyConnection() {
            if connectionState != .usbConnected {
                connectionState = .usbConnected
                setIdleTimerState(true)
                logConnectionEvent("USB connected")
            }
            return
        }

        if await awdlTransport.hasConnection() {
            if connectionState != .awdlConnected {
                connectionState = .awdlConnected
                setIdleTimerState(true)
                logConnectionEvent("AWDL connected")
            }
            return
        }

        connectionState = .disconnected
        setIdleTimerState(false)
    }

    func suspendLiveActivity() {
        liveActivityManager.end()
    }

    func resumeLiveActivity() {
        updateLiveActivity(for: connectionState)
    }

    private func sendSessionResume() {
        let resume = SessionResume(
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        )

        Task { [weak self] in
            do {
                try await self?.sendMessage(.sessionResume(resume))
                await MainActor.run {
                    self?.logConnectionEvent("Sent session resume")
                }
            } catch {
                await MainActor.run {
                    self?.logConnectionEvent("Session resume failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Receive

    private func handleIncomingMessage(_ message: KeydMessage) {
        switch message {
        case .pairingResponse(let response):
            logConnectionEvent(response.accepted ? "Pairing accepted by Mac" : "Pairing rejected by Mac")
            resolvePairingResponse(response)
        case .pairingInvalidated:
            logConnectionEvent("Pairing invalidated by Mac")
            NotificationCenter.default.post(name: .pairingInvalidated, object: nil)
        case .secureInputChanged(let ev):
            onSecureInputChanged?(ev.isActive)
        case .transportHeartbeat:
            Task { [weak self] in
                do {
                    try await self?.sendMessage(.transportHeartbeatAck)
                } catch {
                    await MainActor.run {
                        self?.logConnectionEvent("Heartbeat ack failed: \(error.localizedDescription)")
                    }
                }
            }
        case .transportHeartbeatAck:
            awaitingAWDLHeartbeatAck = false
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

    private func startAWDLHeartbeat() {
        awdlHeartbeatTask?.cancel()
        awaitingAWDLHeartbeatAck = false

        awdlHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled, self.connectionState == .awdlConnected {
                self.awaitingAWDLHeartbeatAck = true

                do {
                    try await self.awdlTransport.send(.transportHeartbeat)
                } catch {
                    guard !Task.isCancelled, self.connectionState == .awdlConnected else { return }
                    await self.handleAWDLHeartbeatFailure("AWDL heartbeat send failed")
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                guard self.connectionState == .awdlConnected else { return }
                if self.awaitingAWDLHeartbeatAck {
                    await self.handleAWDLHeartbeatFailure("AWDL heartbeat timed out")
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopAWDLHeartbeat() {
        awdlHeartbeatTask?.cancel()
        awdlHeartbeatTask = nil
        awaitingAWDLHeartbeatAck = false
    }

    private func handleAWDLHeartbeatFailure(_ logMessage: String) async {
        guard connectionState == .awdlConnected else { return }

        await awdlTransport.invalidateActiveConnection()
        enterDisconnectedState(logMessage: logMessage)
    }

    private func startAWDLConnectionAttempt(availableNowMessage: String, unavailableMessage: String) async {
        let canAttemptImmediately = await awdlTransport.beginAutoConnect()

        if canAttemptImmediately {
            connectionState = .connecting
            setIdleTimerState(false)
            logConnectionEvent(availableNowMessage)
            scheduleAWDLConnectingFallback()
        } else {
            enterDisconnectedState(logMessage: unavailableMessage)
        }
    }

    private func scheduleAWDLConnectingFallback(after delayNanoseconds: UInt64 = 1_000_000_000) {
        awdlConnectingFallbackTask?.cancel()
        awdlConnectingFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, self.connectionState == .connecting else { return }
            self.enterDisconnectedState(logMessage: "AWDL connection still pending")
        }
    }

    private func enterDisconnectedState(logMessage: String) {
        connectionState = .disconnected
        setIdleTimerState(false)
        logConnectionEvent(logMessage)
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
    func setOnConnectionReady(_ handler: @escaping () -> Void) async { onConnectionReady = handler }
    func setOnMessage(_ handler: @escaping (KeydMessage) -> Void) async { onMessage = handler }
}
