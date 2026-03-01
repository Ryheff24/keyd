import Network
import Foundation
import CoreGraphics
import Carbon.HIToolbox

// SharedProtocol added as local package dependency in Xcode project
@preconcurrency import SharedProtocol

private let logger = KeydLogger(category: "TransportManager")

/// Active connection resources managed alongside FSM state.
/// The FSM itself contains no connection references — only logical state.
@MainActor
private struct ConnectionResources {
    var activeDecoder: MessageDecoder?
    var activeEncoder: MessageEncoder?
    var pendingUSBDecoder: MessageDecoder?
    var pendingUSBIdentityTimeoutTask: Task<Void, Never>?
    // Pending AWDL pool: keyed by ObjectIdentifier of NWConnection
    var pendingAWDLSlots: [ObjectIdentifier: PendingAWDLSlot] = [:]
    // Track the currently active AWDL NWConnection (for disconnect detection)
    var activeAWDLConnection: NWConnection?
    // Slot counter for timer coordination
    var nextAWDLSlotIndex: Int = 0
}

private struct PendingAWDLSlot {
    let connection: NWConnection
    let decoder: MessageDecoder
    let timeoutTask: Task<Void, Never>
    let slotIndex: Int
}

enum ConnectionKind: CustomStringConvertible {
    case usb, awdl
    var description: String { self == .usb ? "USB" : "AWDL" }
}

/// Manages USB and AWDL listeners; routes decoded messages to InjectionRouter.
///
/// All state changes go through agentTransportTransition() — no direct mutation of fsmState.
/// Side effects are returned by the transition function and executed by handleEvent().
@MainActor
final class TransportManager {
    private let injectionRouter: InjectionRouter
    private let statusBar: StatusBarController
    private let pairingManager: PairingManager

    // MARK: - FSM State

    private var fsmState: AgentTransportState = .disconnected
    private let eventLog = TransportEventLog(capacity: 500)
    private var resources = ConnectionResources()

    var onPairingCompleted: (() -> Void)?

    private var usbListener = USBListener()
    private var awdlListener = AWDLListener()

    // Secure input polling (AGENT-06)
    private var secureInputTimer: Timer?
    private var lastSecureInputState = false

    init(injectionRouter: InjectionRouter, statusBar: StatusBarController, pairingManager: PairingManager) {
        self.injectionRouter = injectionRouter
        self.statusBar = statusBar
        self.pairingManager = pairingManager
    }

    func start() async {
        do {
            await usbListener.setOnConnectionReady { [weak self] in
                Task { @MainActor in
                    self?.handleUSBConnectionReady()
                }
            }
            await usbListener.setOnData { [weak self] data in
                Task { @MainActor in
                    self?.handleUSBData(data)
                }
            }
            await usbListener.setOnDisconnect { [weak self] in
                Task { @MainActor in
                    self?.handleUSBDisconnect()
                }
            }
            await awdlListener.setOnConnection { [weak self] conn in
                Task { @MainActor in
                    await self?.handleNewAWDLConnection(conn)
                }
            }
            await usbListener.start()
            try await awdlListener.start()
            logEvent("USB connector and AWDL listener started (USB port \(USBListener.port), AWDL _keyd._tcp)")
        } catch {
            logEvent("Failed to start listeners: \(error)")
        }
    }

    // MARK: - FSM Event Handler

    /// Central event dispatch. Calls the pure transition function, updates state, logs, executes side effects.
    private func handleEvent(_ event: AgentTransportEvent) {
        let (newState, effects) = agentTransportTransition(from: fsmState, on: event)

        // Record transition (skip no-op transitions to reduce noise)
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

    private func executeSideEffects(_ effects: [AgentTransportSideEffect]) {
        for effect in effects {
            executeSideEffect(effect)
        }
    }

    private func executeSideEffect(_ effect: AgentTransportSideEffect) {
        switch effect {
        case .startUSBIdentityTimer:
            scheduleUSBIdentityTimeout()

        case .cancelUSBIdentityTimer:
            cancelUSBIdentityTimeout()

        case .startAWDLIdentityTimer:
            // Timer is started inline when the slot is added (see addPendingAWDLSlot)
            break

        case .cancelAWDLIdentityTimer:
            // Cancellation happens when the slot is removed
            break

        case .promoteToActive(let transport):
            promoteToActive(transport: transport)

        case .closeConnection(let transport):
            closeConnection(transport: transport)

        case .clearPendingAWDLPool:
            removeAllPendingAWDLSlots(logMessage: nil)

        case .updateStatusBar(let state):
            switch state {
            case .usbConnected:      statusBar.update(state: .usb)
            case .awdlConnected:     statusBar.update(state: .awdl)
            case .disconnected:      statusBar.update(state: .disconnected)
            case .pairingAWDL:       statusBar.update(state: .awdl)
            case .pendingUSBIdentity, .pendingAWDLPool:
                break
            }

        case .logEvent(let description):
            logEvent(description)

        case .sendPairingInvalidated:
            send(.pairingInvalidated)

        case .startSecureInputPolling:
            startSecureInputPolling()

        case .stopSecureInputPolling:
            stopSecureInputPolling()

        case .releaseModifiers:
            injectionRouter.releaseModifiers()
        }
    }

    // MARK: - Resource Management

    private func promoteToActive(transport: ConnectionKind) {
        switch transport {
        case .usb:
            guard let decoder = resources.pendingUSBDecoder else {
                // USB is already promoted (for cases where USB was pending and confirmed)
                // In unpaired mode the active decoder was already set — just clear pending.
                _ = makeActiveDecoder()
                resources.pendingUSBDecoder = nil
                resources.activeAWDLConnection = nil
                return
            }
            resources.pendingUSBDecoder = nil
            decoder.onMessage = { [weak self] message in
                Task { @MainActor in self?.handleIncomingMessage(message) }
            }
            decoder.onError = { error in logger.error("Decode error: \(error)") }
            resources.activeDecoder = decoder
            resources.activeEncoder = MessageEncoder()
            resources.activeAWDLConnection = nil

        case .awdl:
            // Find the confirmed AWDL slot (should be only one left after clearPendingAWDLPool)
            // In the pending pool promotion path, slots are cleared before this runs.
            // For pairing completion, the pairing channel decoder is already in activeDecoder.
            // Check if we already have an active decoder rewired; if not, create fresh.
            if resources.activeDecoder == nil {
                let decoder = makeActiveDecoder()
                _ = decoder
            }
        }
    }

    private func closeConnection(transport: ConnectionKind) {
        switch transport {
        case .usb:
            resources.pendingUSBDecoder = nil
            Task { [usbListener] in
                await usbListener.disconnectCurrentConnection()
            }
        case .awdl:
            resources.activeAWDLConnection?.cancel()
            resources.activeAWDLConnection = nil
            resources.activeDecoder = nil
            resources.activeEncoder = nil
        }
    }

    // MARK: - USB Handling

    private func handleUSBConnectionReady() {
        logEvent("USB connection ready")

        // Clear all pending AWDL slots when USB arrives
        if !resources.pendingAWDLSlots.isEmpty {
            removeAllPendingAWDLSlots(logMessage: "Clearing pending AWDL slots because USB became available")
        }

        handleEvent(.usbConnectionArrived(deviceID: nil))

        // If paired mode, set up pending USB decoder
        if pairingManager.isPaired, case .pendingUSBIdentity = fsmState {
            _ = makePendingUSBDecoder()
        } else if case .usbConnected = fsmState {
            // Unpaired mode: USB promoted immediately without identity verification
            _ = makeActiveDecoder()
            startSecureInputPolling()
        }
    }

    private func handleUSBData(_ data: Data) {
        if case .usbConnected = fsmState {
            resources.activeDecoder?.receive(data)
            return
        }
        resources.pendingUSBDecoder?.receive(data)
    }

    private func handleUSBDisconnect() {
        if resources.pendingUSBDecoder != nil {
            handleEvent(.usbDisconnected)
            return
        }

        guard case .usbConnected = fsmState else { return }
        handleEvent(.usbDisconnected)
        resources.activeDecoder = nil
        resources.activeEncoder = nil
    }

    private func handlePendingUSBMessage(_ message: KeydMessage) {
        guard resources.pendingUSBDecoder != nil else { return }

        switch message {
        case .sessionResume(let resume):
            if pairingManager.validateOrAdoptPairedDevice(resume.deviceID) {
                logEvent("USB session accepted for paired device; promoting USB")
                promotePendingUSBConnection(deviceID: resume.deviceID, initialMessage: message)
            } else {
                sendDirectUSB(.pairingInvalidated)
                logEvent("Rejected USB session resume from non-paired device \(resume.deviceID)")
                disconnectPendingUSBConnection()
            }

        case .pairingRequest:
            sendDirectUSB(.pairingInvalidated)
            logEvent("Rejected USB pairing request while another device is already paired")
            disconnectPendingUSBConnection()

        case .transportHeartbeat, .transportHeartbeatAck:
            break

        default:
            sendDirectUSB(.pairingInvalidated)
            logEvent("Rejected unexpected USB message from pending state")
            disconnectPendingUSBConnection()
        }
    }

    private func promotePendingUSBConnection(deviceID: String, initialMessage: KeydMessage) {
        handleEvent(.usbIdentityConfirmed(deviceID: deviceID))
        handleIncomingMessage(initialMessage)
    }

    private func disconnectPendingUSBConnection() {
        handleEvent(.usbIdentityTimeout)
    }

    // MARK: - AWDL Handling

    private func handleNewAWDLConnection(_ connection: NWConnection) async {
        logEvent("AWDL connection accepted")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    await self?.handleAWDLConnectionReady(connection)
                }
            case .failed(let error):
                Task { @MainActor in
                    self?.logEvent("AWDL connection failed before ready: \(error.localizedDescription)")
                    self?.removeAWDLSlotIfPending(connection)
                }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
    }

    private func handleAWDLConnectionReady(_ connection: NWConnection) async {
        let isPaired = pairingManager.isPaired

        // Route based on current FSM state
        switch fsmState {
        case .usbConnected:
            // AWDL while USB active — close it immediately.
            handleEvent(.awdlCandidateArrived(isPaired: isPaired))
            connection.cancel()
            return

        case .disconnected, .pendingAWDLPool, .awdlConnected:
            handleEvent(.awdlCandidateArrived(isPaired: isPaired))
            if isPaired {
                addPendingAWDLSlot(connection)
            } else {
                // pairingAWDL — activate directly as pairing channel
                let decoder = makeActiveDecoder()
                resources.activeAWDLConnection = connection
                startReceiveLoop(on: connection, decoder: decoder, transport: .awdl)
            }
            return

        case .pairingAWDL:
            // Replace stale pairing channel
            handleEvent(.awdlCandidateArrived(isPaired: isPaired))
            // Close old pairing channel (done by side effect)
            let decoder = makeActiveDecoder()
            resources.activeAWDLConnection = connection
            startReceiveLoop(on: connection, decoder: decoder, transport: .awdl)
            return

        case .pendingUSBIdentity:
            // AWDL arrived while USB identity pending — add to pool if space.
            if isPaired {
                addPendingAWDLSlot(connection)
            } else {
                connection.cancel()
                logEvent("Unpaired AWDL candidate rejected while USB identity pending")
            }
            return
        }
    }

    // MARK: - Pending AWDL Pool

    private func addPendingAWDLSlot(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        let maxSlots = 4

        // Enforce max pool size — evict oldest if at capacity
        if resources.pendingAWDLSlots.count >= maxSlots {
            if let oldestKey = resources.pendingAWDLSlots.keys.first {
                let oldest = resources.pendingAWDLSlots.removeValue(forKey: oldestKey)
                oldest?.timeoutTask.cancel()
                oldest?.connection.cancel()
                logEvent("Evicted oldest pending AWDL slot to make room")
            }
        }

        let slotIndex = resources.nextAWDLSlotIndex
        resources.nextAWDLSlotIndex += 1

        let decoder = MessageDecoder()
        decoder.onMessage = { [weak self, weak connection] message in
            guard let connection else { return }
            Task { @MainActor in
                self?.handlePendingAWDLPoolMessage(message, connection: connection)
            }
        }
        decoder.onError = { error in
            logger.error("Pending AWDL decode error: \(error)")
        }

        let timeoutTask = Task { @MainActor [weak self, weak connection] in
            let timeoutNs: UInt64 = 3_000_000_000
            do {
                try await Task.sleep(nanoseconds: timeoutNs)
            } catch { return }
            guard let self, let connection else { return }
            let cid = ObjectIdentifier(connection)
            guard self.resources.pendingAWDLSlots[cid] != nil else { return }
            self.logEvent("Pending AWDL slot timed out without identifying; closing")
            self.removeAWDLSlotIfPending(connection)
            let remaining = self.resources.pendingAWDLSlots.count
            self.handleEvent(.awdlIdentityTimeout(remainingSlots: remaining))
        }

        let slot = PendingAWDLSlot(connection: connection, decoder: decoder, timeoutTask: timeoutTask, slotIndex: slotIndex)
        resources.pendingAWDLSlots[connID] = slot

        startPendingAWDLPoolReceiveLoop(on: connection, decoder: decoder)
    }

    private func removeAWDLSlotIfPending(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        guard let slot = resources.pendingAWDLSlots.removeValue(forKey: connID) else { return }
        slot.timeoutTask.cancel()
        slot.connection.cancel()
    }

    private func removeAllPendingAWDLSlots(logMessage: String?) {
        for (_, slot) in resources.pendingAWDLSlots {
            slot.timeoutTask.cancel()
            slot.connection.cancel()
        }
        resources.pendingAWDLSlots.removeAll()
        if let logMessage { logEvent(logMessage) }
    }

    private func startPendingAWDLPoolReceiveLoop(on connection: NWConnection, decoder: MessageDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            if let data = data, !data.isEmpty {
                decoder.receive(data)
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    guard let self else { return }
                    let connID = ObjectIdentifier(connection)
                    if self.resources.pendingAWDLSlots[connID] != nil {
                        self.removeAWDLSlotIfPending(connection)
                        let remaining = self.resources.pendingAWDLSlots.count
                        if remaining == 0, case .pendingAWDLPool = self.fsmState {
                            self.handleEvent(.awdlDisconnected)
                        }
                    } else {
                        // Slot was promoted — route through active disconnect handler
                        self.handleDisconnect(connection: connection, transport: .awdl)
                    }
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.startPendingAWDLPoolReceiveLoop(on: connection, decoder: decoder)
            }
        }
    }

    private func handlePendingAWDLPoolMessage(_ message: KeydMessage, connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        guard resources.pendingAWDLSlots[connID] != nil else { return }

        switch message {
        case .sessionResume(let resume):
            if pairingManager.validateOrAdoptPairedDevice(resume.deviceID) {
                logEvent("Pending AWDL slot matches paired device \(resume.deviceID); promoting")
                promotePendingAWDLPoolSlot(connection: connection, deviceID: resume.deviceID, initialMessage: message)
            } else {
                sendDirectAWDL(.pairingInvalidated, on: connection)
                logEvent("Rejected AWDL session resume from non-paired device \(resume.deviceID)")
                removeAWDLSlotIfPending(connection)
                let remaining = resources.pendingAWDLSlots.count
                handleEvent(.awdlIdentityTimeout(remainingSlots: remaining))
            }

        case .pairingRequest:
            sendDirectAWDL(.pairingInvalidated, on: connection)
            logEvent("Rejected AWDL pairing request from pending pool while already paired")
            removeAWDLSlotIfPending(connection)
            let remaining = resources.pendingAWDLSlots.count
            handleEvent(.awdlIdentityTimeout(remainingSlots: remaining))

        case .transportHeartbeat, .transportHeartbeatAck:
            break

        default:
            sendDirectAWDL(.pairingInvalidated, on: connection)
            logEvent("Rejected unexpected AWDL message from pending pool")
            removeAWDLSlotIfPending(connection)
            let remaining = resources.pendingAWDLSlots.count
            handleEvent(.awdlIdentityTimeout(remainingSlots: remaining))
        }
    }

    private func promotePendingAWDLPoolSlot(connection: NWConnection, deviceID: String, initialMessage: KeydMessage) {
        let connID = ObjectIdentifier(connection)
        guard let slot = resources.pendingAWDLSlots.removeValue(forKey: connID) else { return }
        slot.timeoutTask.cancel()

        // Rewire decoder to main message handler
        slot.decoder.onMessage = { [weak self] message in
            Task { @MainActor in self?.handleIncomingMessage(message) }
        }
        slot.decoder.onError = { error in logger.error("Decode error: \(error)") }

        // Close all other pending AWDL slots
        let remaining = resources.pendingAWDLSlots.count
        removeAllPendingAWDLSlots(logMessage: remaining > 0 ? "Clearing \(remaining) remaining pending AWDL slots after promotion" : nil)

        // Close existing active AWDL connection if any
        if let old = resources.activeAWDLConnection, old !== connection {
            stopSecureInputPolling()
            injectionRouter.releaseModifiers()
            old.cancel()
        }

        resources.activeDecoder = slot.decoder
        resources.activeEncoder = MessageEncoder()
        resources.activeAWDLConnection = connection

        // Fire FSM event with remaining=0 (pool cleared)
        handleEvent(.awdlIdentityConfirmed(deviceID: deviceID, remainingSlots: 0))
        handleIncomingMessage(initialMessage)
    }

    // MARK: - Receive Loops

    private func startReceiveLoop(on connection: NWConnection, decoder: MessageDecoder, transport: ConnectionKind) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                decoder.receive(data)
            }
            if isComplete || error != nil {
                logger.warning("\(transport) connection closed: \(error?.localizedDescription ?? "EOF")")
                Task { @MainActor in
                    self?.handleDisconnect(connection: connection, transport: transport)
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.startReceiveLoop(on: connection, decoder: decoder, transport: transport)
            }
        }
    }

    private func handleDisconnect(connection: NWConnection, transport: ConnectionKind) {
        guard isCurrentConnection(connection, for: transport) else {
            logEvent("Ignoring disconnect from superseded \(transport) connection")
            return
        }
        handleEvent(transport == .awdl ? .awdlDisconnected : .usbDisconnected)
        resources.activeDecoder = nil
        resources.activeEncoder = nil
        resources.activeAWDLConnection = nil
    }

    private func isCurrentConnection(_ connection: NWConnection, for transport: ConnectionKind) -> Bool {
        guard transport == .awdl else { return false }
        return resources.activeAWDLConnection === connection
    }

    // MARK: - Incoming Message Handling

    private func handleIncomingMessage(_ message: KeydMessage) {
        // Guard: reject pairing requests when already paired
        if pairingManager.isPaired, case .pairingRequest = message {
            send(.pairingInvalidated)
            logEvent("Rejected pairing request while another device is already paired")
            if case .pairingAWDL = fsmState {
                handleEvent(.pairingFailed)
            }
            return
        }

        // Guard: reject non-pairing messages when not paired
        if !pairingManager.isPaired {
            switch message {
            case .pairingRequest, .sessionResume:
                break
            case .transportHeartbeat, .transportHeartbeatAck:
                return
            case .keyEvent, .hotkeyEvent:
                send(.pairingInvalidated)
                logEvent("Rejected input from unpaired device")
                return
            case .pairingResponse, .pairingInvalidated, .secureInputChanged, .reflectState, .appStateChanged:
                send(.pairingInvalidated)
                logEvent("Rejected stale session from unpaired device")
                return
            }
        }

        switch message {
        case .pairingRequest(let request):
            let accepted = pairingManager.completePairing(
                iOSPublicKeyData: request.publicKeyData,
                deviceID: request.deviceID
            )
            let response = PairingResponse(
                publicKeyData: pairingManager.currentPublicKeyData ?? Data(),
                accepted: accepted
            )
            send(.pairingResponse(response))
            if accepted {
                handleEvent(.pairingCompleted(deviceID: request.deviceID))
                onPairingCompleted?()
            } else {
                handleEvent(.pairingFailed)
            }
            logEvent("Pairing \(accepted ? "accepted" : "rejected") for \(request.deviceID)")

        case .sessionResume(let resume):
            if pairingManager.isPaired {
                if pairingManager.validateOrAdoptPairedDevice(resume.deviceID) {
                    if case .pairingAWDL = fsmState {
                        handleEvent(.pairingCompleted(deviceID: resume.deviceID))
                    }
                    logEvent("Session resumed for \(resume.deviceID)")
                } else {
                    send(.pairingInvalidated)
                    logEvent("Rejected session resume from non-paired device \(resume.deviceID)")
                    handleEvent(.awdlDisconnected)
                    resources.activeDecoder = nil
                    resources.activeEncoder = nil
                    resources.activeAWDLConnection?.cancel()
                    resources.activeAWDLConnection = nil
                }
            } else {
                send(.pairingInvalidated)
                logEvent("Rejected session resume from unpaired device")
            }

        case .pairingInvalidated:
            logEvent("Pairing invalidated by iPhone")
            pairingManager.resetPairing()
            resetActiveSession()

        case .transportHeartbeat:
            send(.transportHeartbeatAck)

        case .transportHeartbeatAck:
            handleEvent(.heartbeatAck)

        default:
            injectionRouter.route(message)
        }
    }

    // MARK: - Send

    func send(_ message: KeydMessage) {
        guard let encoder = resources.activeEncoder else { return }
        guard let frame = try? encoder.encode(message) else { return }

        switch fsmState {
        case .usbConnected:
            Task { [weak self, frame] in
                guard let self else { return }
                do {
                    try await self.usbListener.send(frame)
                } catch {
                    await MainActor.run {
                        self.logEvent("USB send failed: \(error.localizedDescription)")
                    }
                }
            }
        case .pairingAWDL, .awdlConnected:
            resources.activeAWDLConnection?.send(content: frame, completion: .idempotent)
        case .disconnected, .pendingAWDLPool, .pendingUSBIdentity:
            break
        }
    }

    func invalidateRemotePairing() {
        guard resources.activeEncoder != nil else {
            logEvent("No active session to invalidate")
            return
        }
        send(.pairingInvalidated)
        logEvent("Sent pairing invalidation")
    }

    func resetActiveSession() {
        resources.activeAWDLConnection?.cancel()
        Task { [usbListener] in
            await usbListener.disconnectCurrentConnection()
        }
        cancelUSBIdentityTimeout()
        resources.pendingUSBDecoder = nil
        removeAllPendingAWDLSlots(logMessage: nil)
        resources.activeDecoder = nil
        resources.activeEncoder = nil
        resources.activeAWDLConnection = nil
        fsmState = .disconnected
        statusBar.update(state: .disconnected)
        stopSecureInputPolling()
        injectionRouter.releaseModifiers()
        logEvent("Active transport session reset")
    }

    // MARK: - Secure Input Polling (AGENT-06)

    private func startSecureInputPolling() {
        stopSecureInputPolling()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSecureInput() }
        }
    }

    private func stopSecureInputPolling() {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
    }

    private func pollSecureInput() {
        let isActive = IsSecureEventInputEnabled()
        if isActive != lastSecureInputState {
            lastSecureInputState = isActive
            let msg = KeydMessage.secureInputChanged(SecureInputChanged(isActive: isActive))
            send(msg)
            logEvent("Secure input state changed: \(isActive ? "active" : "inactive")")
        }
    }

    // MARK: - Structured Event Log (for debug overlay)

    func logEvent(_ event: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(event)"
        logger.info(entry)
        // Also append to structured log as a standalone note
        let structuredEntry = TransportEventEntry(
            previousState: fsmState.description,
            event: "log",
            newState: fsmState.description,
            sideEffects: [event]
        )
        eventLog.append(structuredEntry)
    }

    func getEventLog() -> [String] {
        eventLog.export().map { entry in
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            let ts = formatter.string(from: entry.timestamp)
            if entry.event == "log" {
                return "[\(ts)] \(entry.sideEffects.first ?? "")"
            }
            return "[\(ts)] \(entry.previousState) --[\(entry.event)]--> \(entry.newState)"
        }
    }

    func exportEventLogJSON() -> Data {
        eventLog.exportJSON()
    }

    // MARK: - Resource Helpers

    private func makeActiveDecoder() -> MessageDecoder {
        let decoder = MessageDecoder()
        decoder.onMessage = { [weak self] message in
            Task { @MainActor in self?.handleIncomingMessage(message) }
        }
        decoder.onError = { error in logger.error("Decode error: \(error)") }
        resources.activeDecoder = decoder
        resources.activeEncoder = MessageEncoder()
        return decoder
    }

    private func makePendingUSBDecoder() -> MessageDecoder {
        let decoder = MessageDecoder()
        decoder.onMessage = { [weak self] message in
            Task { @MainActor in self?.handlePendingUSBMessage(message) }
        }
        decoder.onError = { error in logger.error("Pending USB decode error: \(error)") }
        resources.pendingUSBDecoder = decoder
        return decoder
    }

    private func scheduleUSBIdentityTimeout(timeoutNanoseconds: UInt64 = 2_000_000_000) {
        resources.pendingUSBIdentityTimeoutTask?.cancel()
        resources.pendingUSBIdentityTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch { return }
            guard let self, self.resources.pendingUSBDecoder != nil else { return }
            self.logEvent("Pending USB connection did not identify itself; rotating to next USB device")
            self.handleEvent(.usbIdentityTimeout)
            self.resources.pendingUSBDecoder = nil
            Task { [usbListener = self.usbListener] in
                await usbListener.disconnectCurrentConnection()
            }
        }
    }

    private func cancelUSBIdentityTimeout() {
        resources.pendingUSBIdentityTimeoutTask?.cancel()
        resources.pendingUSBIdentityTimeoutTask = nil
    }

    private func sendDirectUSB(_ message: KeydMessage) {
        let encoder = MessageEncoder()
        guard let frame = try? encoder.encode(message) else { return }
        Task { [weak self, frame] in
            guard let self else { return }
            do {
                try await self.usbListener.send(frame)
            } catch {
                await MainActor.run {
                    self.logEvent("USB send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendDirectAWDL(_ message: KeydMessage, on connection: NWConnection) {
        let encoder = MessageEncoder()
        guard let frame = try? encoder.encode(message) else { return }
        connection.send(content: frame, completion: .idempotent)
    }
}

// MARK: - Actor callback setters
extension USBListener {
    func setOnConnectionReady(_ handler: @escaping @Sendable () -> Void) async { onConnectionReady = handler }
    func setOnData(_ handler: @escaping @Sendable (Data) -> Void) async { onData = handler }
    func setOnDisconnect(_ handler: @escaping @Sendable () -> Void) async { onDisconnect = handler }
}
extension AWDLListener {
    func setOnConnection(_ handler: @escaping @Sendable (NWConnection) -> Void) async {
        onConnection = handler
    }
}

