import Foundation
import SharedProtocol
import UIKit

private let logger = KeydLogger(category: "TransportManager")

/// iOS-side transport state machine.
/// USB is primary; AWDL discovery stays warm and a fresh AWDL connection is made when needed.
///
/// All state changes go through iOSTransportTransition() — no direct mutation of fsmState.
/// The `@Published connectionState` is a computed alias over fsmState for SwiftUI compatibility.
@MainActor
final class TransportManager: ObservableObject {

    // MARK: - Legacy UI State (preserved for SwiftUI compatibility)

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

    // MARK: - FSM State

    /// The canonical transport state. All state changes go through handleEvent().
    private var fsmState: iOSTransportState = .disconnected(awdlEnabled: true) {
        didSet {
            // Derive the legacy State for SwiftUI compatibility and publish changes.
            let newDisplayState = displayState(for: fsmState)
            if connectionState != newDisplayState {
                objectWillChange.send()
                connectionState = newDisplayState
            }
        }
    }

    /// Legacy @Published state for SwiftUI — derived from fsmState.
    /// Direct assignment only used during reset operations.
    @Published var connectionState: State = .disconnected

    private let eventLog = TransportEventLog(capacity: 500)

    private func displayState(for fsm: iOSTransportState) -> State {
        switch fsm {
        case .disconnected:            return .disconnected
        case .connecting:              return .connecting
        case .usbConnected:            return .usbConnected
        case .awdlConnected:           return .awdlConnected
        case .backgroundSuspended(let prev):
            // Show the previous transport state while backgrounded.
            switch prev {
            case .usb: return .usbConnected
            case .awdl: return .awdlConnected
            case .none: return .connecting
            }
        }
    }

    // MARK: - FSM Event Handler

    /// Central event dispatch. Calls the pure transition function, updates state, logs, executes side effects.
    private func handleEvent(_ event: iOSTransportEvent) {
        let (newState, effects) = iOSTransportTransition(from: fsmState, on: event)

        // Record transition
        if newState != fsmState || !effects.isEmpty {
            let entry = TransportEventEntry(
                previousState: fsmState.description,
                event: event.description,
                newState: newState.description,
                sideEffects: effects.map(\.description)
            )
            eventLog.append(entry)
        }

        fsmState = newState
        executeSideEffects(effects)
    }

    private func executeSideEffects(_ effects: [iOSTransportSideEffect]) {
        for effect in effects {
            executeSideEffect(effect)
        }
    }

    private func executeSideEffect(_ effect: iOSTransportSideEffect) {
        switch effect {
        case .startHeartbeat:
            startAWDLHeartbeat()

        case .stopHeartbeat:
            stopAWDLHeartbeat()

        case .updateLiveActivity(let state):
            updateLiveActivity(for: displayState(for: state))

        case .resolveConnectionContinuation:
            resolveConnectionReady()

        case .resolvePairingContinuation:
            // Pairing continuation is resolved by the caller after receiving response
            break

        case .beginBackgroundTask:
            startBackgroundTask()

        case .endBackgroundTask:
            endBackgroundTask()

        case .closeConnections:
            Task { [weak self] in
                guard let self else { return }
                await self.usbTransport.disconnect()
                await self.awdlTransport.stop()
            }

        case .startReconnect(let skipBackoff):
            if skipBackoff {
                Task { [weak self] in
                    guard let self else { return }
                    await self.awdlTransport.resetBackoff()
                    await self.startAWDLConnectionAttempt(
                        availableNowMessage: "Fast reconnect on foreground",
                        unavailableMessage: "AWDL unavailable on foreground; waiting"
                    )
                }
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.startAWDLConnectionAttempt(
                        availableNowMessage: "Attempting AWDL reconnect",
                        unavailableMessage: "AWDL unavailable; disconnected"
                    )
                }
            }

        case .sendSessionResume:
            sendSessionResume()

        case .disableIdleTimer:
            setIdleTimerState(true)

        case .enableIdleTimer:
            setIdleTimerState(false)

        case .logEvent(let description):
            logConnectionEvent(description)
        }
    }

    // MARK: - Properties

    private var usbTransport = USBTransport()
    private var awdlTransport = AWDLTransport()
    private let liveActivityManager = KeydLiveActivityManager()
    private var startTask: Task<Void, Never>?
    private var transportResetTask: Task<Void, Never>?
    private var awdlConnectingFallbackTask: Task<Void, Never>?
    private var awdlHeartbeatTask: Task<Void, Never>?
    private var connectionReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectionReadyTimeoutTask: Task<Void, Never>?
    private var pairingResponseContinuation: CheckedContinuation<PairingResponse, Error>?
    private var pairingResponseTimeoutTask: Task<Void, Never>?

    // Background task support
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var onSecureInputChanged: ((Bool) -> Void)?

    // Connection event log for debug overlay
    private var connectionEventLog: [String] = []

    func logConnectionEvent(_ event: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionEventLog.append("[\(timestamp)] \(event)")
        if connectionEventLog.count > 100 { connectionEventLog.removeFirst() }
        logger.info(event)
    }

    func getEventLog() -> [String] { connectionEventLog }

    func exportEventLogJSON() -> Data { eventLog.exportJSON() }

    var isConnected: Bool { fsmState.isConnected }

    // AWDL is enabled when fsmState carries awdlEnabled = true, or when connected.
    var allowsAWDL: Bool { fsmState.awdlEnabled }

    // suppressAWDLStatusUntilPaired: still needed for pairing flow gating.
    // Kept as a property rather than FSM state since it's a UI-only gate.
    private var suppressAWDLStatusUntilPaired = false

    // MARK: - Start

    func start(allowAWDL: Bool = true, suppressAWDLStatus: Bool = false) {
        suppressAWDLStatusUntilPaired = suppressAWDLStatus

        if allowAWDL, isConnected, !allowsAWDL {
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

        let newFSMState = iOSTransportState.connecting(transport: .usb, awdlEnabled: allowAWDL)
        fsmState = newFSMState
        setIdleTimerState(false)
        logConnectionEvent(allowAWDL ? "Starting transport" : "Starting transport (USB only)")

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            let pendingReset = self.transportResetTask
            if let pendingReset {
                await pendingReset.value
            }
            guard !Task.isCancelled else { return }
            if allowAWDL {
                await self.startAWDLPrewarm()
            } else {
                await self.awdlTransport.stop()
            }
            await self.startUSBConnection()
        }
    }

    func reconnect() {
        let allowAWDL = allowsAWDL
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
        fsmState = .disconnected(awdlEnabled: true)
        setIdleTimerState(false)
        logConnectionEvent("Transport reset")

        transportResetTask?.cancel()
        transportResetTask = Task { [weak self] in
            guard let self else { return }
            await self.usbTransport.disconnect()
            guard !Task.isCancelled else { return }
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

    // MARK: - Scene Phase (App Lifecycle)

    func handleScenePhaseBackground() {
        handleEvent(.appBackgrounded)
    }

    func handleScenePhaseActive() {
        handleEvent(.appForegrounded)
    }

    // MARK: - Background Task Management

    private func startBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "keyd-transport") { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleEvent(.backgroundTaskExpiring)
            }
        }
        logConnectionEvent("Background task started (ID: \(backgroundTaskID.rawValue))")
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        logConnectionEvent("Background task ended")
    }

    // MARK: - AWDL Prewarm

    private func startAWDLPrewarm() async {
        await awdlTransport.setOnDisconnect { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressAWDLStatusUntilPaired {
                    if case .usbConnected = self.fsmState { } else {
                        self.logConnectionEvent("AWDL pairing channel disconnected (state=\(self.fsmState), suppress=\(self.suppressAWDLStatusUntilPaired)); dispatching awdlDisconnected")
                        self.handleEvent(.awdlDisconnected)
                    }
                    return
                }
                if case .awdlConnected = self.fsmState {
                    self.handleEvent(.awdlDisconnected)
                }
            }
        }
        await awdlTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .usbConnected = self.fsmState {
                    await self.awdlTransport.prepareForUSBStandby()
                    self.logConnectionEvent(
                        self.suppressAWDLStatusUntilPaired
                            ? "AWDL pairing channel closed while USB is primary"
                            : "AWDL connection closed while USB is primary"
                    )
                    return
                }
                if self.suppressAWDLStatusUntilPaired {
                    self.logConnectionEvent("AWDL ready for pairing")
                    self.handleEvent(.awdlReady)
                    return
                }
                self.handleEvent(.awdlReady)
            }
        }
        await awdlTransport.setOnMessage { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }
        await awdlTransport.startBrowsing()
    }

    // MARK: - USB Connection

    private func startUSBConnection() async {
        await usbTransport.setOnDisconnect { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                logger.info("USB disconnected — evaluating fresh AWDL handoff")
                self.handleEvent(.usbDisconnected)
            }
        }
        await usbTransport.setOnConnectionReady { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.allowsAWDL {
                    await self.awdlTransport.prepareForUSBStandby()
                }
                if case .awdlConnected = self.fsmState {
                    self.logConnectionEvent("USB reconnected; AWDL standby cleared")
                }
                self.handleEvent(.usbReady)
            }
        }
        await usbTransport.setOnMessage { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }

        let connected = await usbTransport.connect()
        guard connected else {
            if case .connecting = fsmState {
                if allowsAWDL {
                    await startAWDLConnectionAttempt(
                        availableNowMessage: "USB unavailable — attempting AWDL connection",
                        unavailableMessage: "USB unavailable — waiting for AWDL or cable"
                    )
                } else {
                    handleEvent(.usbDisconnected)
                    logConnectionEvent("USB unavailable — waiting for cable or manual retry")
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

        if case .usbConnected = fsmState, await usbTransport.hasReadyConnection() {
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
            if case .usbConnected = fsmState { } else {
                fsmState = .usbConnected
                setIdleTimerState(true)
                logConnectionEvent("USB connected")
            }
            return
        }

        if await awdlTransport.hasConnection() {
            if case .awdlConnected = fsmState { } else {
                fsmState = .awdlConnected(awaitingHeartbeatAck: false)
                setIdleTimerState(true)
                logConnectionEvent("AWDL connected")
            }
            startAWDLHeartbeat()
            return
        }

        fsmState = .disconnected(awdlEnabled: true)
        setIdleTimerState(false)
    }

    func suspendLiveActivity() {
        liveActivityManager.end()
    }

    func resumeLiveActivity() {
        updateLiveActivity(for: displayState(for: fsmState))
    }

    // MARK: - Session Resume

    private func sendSessionResume() {
        // During the initial pairing flow (suppressAWDLStatusUntilPaired = true), the device
        // is not yet paired. Sending a sessionResume before pairing completes causes the Mac
        // agent to respond with pairingInvalidated (unknown device), tearing down the transport
        // connection before the pairing handshake can start. Skip the resume here; the pairing
        // handshake itself establishes the session identity.
        guard !suppressAWDLStatusUntilPaired else {
            logConnectionEvent("Skipping session resume — pairing not yet complete")
            return
        }

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
        // Notify any registered integration test observers (no-op in production — no observers registered).
        notifyTestObservers(message)
        switch message {
        case .pairingResponse(let response):
            logConnectionEvent(response.accepted ? "Pairing accepted by Mac" : "Pairing rejected by Mac")
            resolvePairingResponse(response)
        case .pairingInvalidated:
            logConnectionEvent("Pairing invalidated by Mac")
            NotificationCenter.default.post(name: .pairingInvalidated, object: nil)
        case .secureInputChanged(let ev):
            handleEvent(.secureInputChanged(active: ev.isActive))
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
            handleEvent(.heartbeatAck)
            // Reset AWDL reconnect backoff on successful heartbeat exchange
            Task { [weak self] in
                await self?.awdlTransport.resetBackoff()
            }
        case .reflectState, .appStateChanged:
            // Handled by PairingManager or future plans
            break
        default:
            logger.warning("Unexpected iOS-received message: \(message)")
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
            break
        case .disconnected:
            liveActivityManager.end()
        }
    }

    // MARK: - AWDL Heartbeat

    private func startAWDLHeartbeat() {
        guard !suppressAWDLStatusUntilPaired else { return }
        awdlHeartbeatTask?.cancel()

        // Update heartbeat state in FSM
        if case .awdlConnected = fsmState {
            fsmState = .awdlConnected(awaitingHeartbeatAck: false)
        }

        awdlHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Let the AWDL connection stabilize before heartbeating.
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard case .awdlConnected = self.fsmState else { return }

            while !Task.isCancelled {
                guard case .awdlConnected = self.fsmState else { return }

                // Mark awaiting heartbeat ack in FSM state
                self.fsmState = .awdlConnected(awaitingHeartbeatAck: true)

                do {
                    try await self.awdlTransport.send(.transportHeartbeat)
                } catch {
                    guard !Task.isCancelled, case .awdlConnected = self.fsmState else { return }
                    await self.handleAWDLHeartbeatFailure("AWDL heartbeat send failed")
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                guard case .awdlConnected(let awaitingAck) = self.fsmState else { return }
                if awaitingAck {
                    self.handleEvent(.heartbeatTimeout)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopAWDLHeartbeat() {
        awdlHeartbeatTask?.cancel()
        awdlHeartbeatTask = nil
        // Clear awaitingHeartbeatAck in FSM if still in awdl state
        if case .awdlConnected = fsmState {
            fsmState = .awdlConnected(awaitingHeartbeatAck: false)
        }
    }

    private func handleAWDLHeartbeatFailure(_ logMessage: String) async {
        guard case .awdlConnected = fsmState else { return }
        await awdlTransport.invalidateActiveConnection()
        handleEvent(.awdlDisconnected)
        logConnectionEvent(logMessage)
    }

    private func startAWDLConnectionAttempt(availableNowMessage: String, unavailableMessage: String) async {
        let connectResult = await awdlTransport.beginAutoConnect(pairingMode: suppressAWDLStatusUntilPaired)

        switch connectResult {
        case .immediate, .alreadyActive:
            fsmState = .connecting(transport: .awdl, awdlEnabled: true)
            setIdleTimerState(false)
            logConnectionEvent("\(availableNowMessage) [result=\(String(describing: connectResult))]")
            scheduleAWDLConnectingFallback()
        case .pendingReconnect(let backoff):
            fsmState = .connecting(transport: .awdl, awdlEnabled: true)
            setIdleTimerState(false)
            logConnectionEvent("AWDL reconnect already scheduled [backoff=\(String(format: "%.2f", backoff))s, suppress=\(suppressAWDLStatusUntilPaired)]")
            scheduleAWDLConnectingFallback(after: UInt64(max(backoff * 1_500_000_000, 1_000_000_000)))
        case .waitingForDiscovery:
            handleEvent(.awdlDisconnected)
            logConnectionEvent("\(unavailableMessage) [result=waitingForDiscovery]")
        }
    }

    private func scheduleAWDLConnectingFallback(after delayNanoseconds: UInt64 = 1_000_000_000) {
        awdlConnectingFallbackTask?.cancel()
        awdlConnectingFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, case .connecting = self.fsmState else { return }
            self.handleEvent(.awdlDisconnected)
            self.logConnectionEvent("AWDL connection still pending")
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
    func setOnConnectionReady(_ handler: @escaping () -> Void) async { onConnectionReady = handler }
    func setOnMessage(_ handler: @escaping (KeydMessage) -> Void) async { onMessage = handler }
}
