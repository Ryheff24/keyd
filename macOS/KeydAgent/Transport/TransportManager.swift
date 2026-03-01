import Network
import Foundation
import CoreGraphics
import Carbon.HIToolbox

// SharedProtocol added as local package dependency in Xcode project
@preconcurrency import SharedProtocol

private let logger = KeydLogger(category: "TransportManager")

/// Connection state for the macOS agent.
enum AgentConnectionState {
    case disconnected
    case usbConnected
    case pairingAWDL(NWConnection)
    case awdlConnected(NWConnection)
}

enum ConnectionKind: CustomStringConvertible {
    case usb, awdl
    var description: String { self == .usb ? "USB" : "AWDL" }
}

/// Manages USB and AWDL listeners; routes decoded messages to InjectionRouter.
/// Both listeners start concurrently so AWDL discovery stays warm while USB is primary.
/// USB takes priority; AWDL reconnects fresh after USB disconnects.
@MainActor
final class TransportManager {
    private let injectionRouter: InjectionRouter
    private let statusBar: StatusBarController
    private let pairingManager: PairingManager
    private var connectionState: AgentConnectionState = .disconnected
    var onPairingCompleted: (() -> Void)?

    private var usbListener = USBListener()
    private var awdlListener = AWDLListener()

    private var activeDecoder: MessageDecoder?
    private var activeEncoder: MessageEncoder?
    private var pendingUSBDecoder: MessageDecoder?
    private var pendingUSBIdentityTimeoutTask: Task<Void, Never>?

    // Secure input polling (AGENT-06)
    private var secureInputTimer: Timer?
    private var lastSecureInputState = false

    // Connection event log for debug overlay
    private var connectionEventLog: [String] = []

    init(injectionRouter: InjectionRouter, statusBar: StatusBarController, pairingManager: PairingManager) {
        self.injectionRouter = injectionRouter
        self.statusBar = statusBar
        self.pairingManager = pairingManager
    }

    func start() async {
        do {
            // Start both transports concurrently — AWDL stays pre-warmed and USB now
            // reconnects through a host-initiated usbmux tunnel.
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
                    await self?.handleNewConnection(conn, transport: .awdl)
                }
            }
            await usbListener.start()
            try await awdlListener.start()
            logEvent("USB connector and AWDL listener started (USB port \(USBListener.port), AWDL _keyd._tcp)")
        } catch {
            logEvent("Failed to start listeners: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection, transport: ConnectionKind) async {
        logEvent("\(transport) connection accepted")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    await self?.activateConnection(connection, transport: transport)
                }
            case .failed(let error):
                Task { @MainActor in
                    self?.logEvent("\(transport) connection failed before ready: \(error.localizedDescription)")
                }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
    }

    private func activateConnection(_ connection: NWConnection, transport: ConnectionKind) async {
        logEvent("\(transport) connection ready")
        switch (connectionState, transport) {
        case (_, .usb):
            logEvent("Ignoring unexpected USB NWConnection callback")
            connection.cancel()
            return
        case (.awdlConnected, .awdl):
            logEvent("Additional AWDL connection arrived while AWDL is active; closing it")
            connection.cancel()
            return
        case (.disconnected, .awdl):
            if pairingManager.isPaired {
                connectionState = .pairingAWDL(connection)
                logEvent("AWDL connected while no confirmed session is active; waiting for AWDL session identity")
            } else {
                connectionState = .pairingAWDL(connection)
                logEvent("AWDL pairing channel ready")
            }
        case (.pairingAWDL(let old), .awdl):
            old.cancel()
            connectionState = .pairingAWDL(connection)
            if pairingManager.isPaired {
                logEvent("Replaced stale AWDL candidate while waiting for session identity")
            } else {
                logEvent("Replaced stale AWDL pairing channel")
            }
        case (.usbConnected, .awdl):
            logEvent("AWDL connection arrived while USB is active; closing it")
            startAWDLStandby(connection)
            return
        }

        let decoder = makeActiveDecoder()

        // Start receive loop
        startReceiveLoop(on: connection, decoder: decoder, transport: transport)

        // Start secure input polling
        if case .pairingAWDL = connectionState {
            return
        }
        startSecureInputPolling()
    }

    private func handleUSBConnectionReady() {
        if pairingManager.isPaired {
            switch connectionState {
            case .usbConnected:
                logEvent("Ignoring duplicate USB connection")
                return
            case .awdlConnected:
                _ = makePendingUSBDecoder()
                schedulePendingUSBIdentityTimeout()
                logEvent("USB connected while AWDL is active; waiting for USB session identity")
                return
            case .pairingAWDL(let old):
                old.cancel()
                _ = makePendingUSBDecoder()
                schedulePendingUSBIdentityTimeout()
                logEvent("USB connected while a stale AWDL pairing channel existed; waiting for USB session identity")
                return
            case .disconnected:
                _ = makePendingUSBDecoder()
                schedulePendingUSBIdentityTimeout()
                logEvent("USB connected while no confirmed session is active; waiting for USB session identity")
                return
            }
        }

        switch connectionState {
        case .usbConnected:
            logEvent("Ignoring duplicate USB connection")
            return
        case .awdlConnected(let old), .pairingAWDL(let old):
            old.cancel()
            connectionState = .usbConnected
            statusBar.update(state: .usb)
            logEvent("USB promoted over AWDL (re-plug)")
        case .disconnected:
            connectionState = .usbConnected
            statusBar.update(state: .usb)
            logEvent("USB connected")
        }

        pendingUSBDecoder = nil
        cancelPendingUSBIdentityTimeout()
        _ = makeActiveDecoder()

        startSecureInputPolling()
    }

    private func handleUSBData(_ data: Data) {
        if case .usbConnected = connectionState {
            activeDecoder?.receive(data)
            return
        }

        pendingUSBDecoder?.receive(data)
    }

    // While USB is active, keep discovery/listening warm but do not retain a live
    // standby AWDL socket. Fresh AWDL connections must be established after USB drops.
    private var standbyAWDLConnection: NWConnection?
    private var standbyAWDLDecoder: MessageDecoder?

    private func startAWDLStandby(_ connection: NWConnection) {
        if let existing = standbyAWDLConnection, existing !== connection {
            existing.cancel()
        }

        standbyAWDLConnection = nil
        standbyAWDLDecoder = nil
        connection.cancel()
    }

    private func startStandbyReceiveLoop(on connection: NWConnection, decoder: MessageDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                decoder.receive(data)
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    self?.handleStandbyAWDLDisconnect(connection)
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.startStandbyReceiveLoop(on: connection, decoder: decoder)
            }
        }
    }

    private func handleStandbyAWDLDisconnect(_ connection: NWConnection) {
        if standbyAWDLConnection === connection {
            standbyAWDLConnection = nil
            standbyAWDLDecoder = nil
            logEvent("AWDL standby dropped")
            return
        }

        if case .awdlConnected(let current) = connectionState, current === connection {
            handleDisconnect(connection: connection, transport: .awdl)
        }
    }

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
            // Continue receiving
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

        logEvent("\(transport) disconnected")
        stopSecureInputPolling()

        // CRITICAL: Release all modifier keys on disconnect (SHORT-11)
        injectionRouter.releaseModifiers()

        switch (connectionState, transport) {
        case (.awdlConnected, .awdl):
            connectionState = .disconnected
            statusBar.update(state: .disconnected)
            logEvent("AWDL dropped; disconnected")

        case (.pairingAWDL, .awdl):
            connectionState = .disconnected
            logEvent("AWDL pairing channel dropped")

        default:
            break
        }
    }

    private func handleUSBDisconnect() {
        if pendingUSBDecoder != nil {
            cancelPendingUSBIdentityTimeout()
            pendingUSBDecoder = nil
            logEvent("Pending USB connection dropped")
            return
        }

        guard case .usbConnected = connectionState else { return }

        logEvent("usb disconnected")
        stopSecureInputPolling()
        injectionRouter.releaseModifiers()
        promoteStandbyAWDLOrDisconnect()
    }

    private func promoteStandbyAWDLOrDisconnect() {
        if let awdlConn = standbyAWDLConnection {
            logEvent("USB dropped — promoting pre-warmed AWDL connection (TRANS-03)")
            let decoder = standbyAWDLDecoder
            standbyAWDLConnection = nil
            standbyAWDLDecoder = nil
            connectionState = .awdlConnected(awdlConn)
            statusBar.update(state: .awdl)

            let encoder = MessageEncoder()
            activeDecoder = decoder
            activeEncoder = encoder

            decoder?.onMessage = { [weak self] message in
                Task { @MainActor in
                    self?.handleIncomingMessage(message)
                }
            }
            decoder?.onError = { error in
                logger.error("Decode error: \(error)")
            }

            if activeDecoder == nil {
                let freshDecoder = MessageDecoder()
                freshDecoder.onMessage = { [weak self] message in
                    Task { @MainActor in
                        self?.handleIncomingMessage(message)
                    }
                }
                freshDecoder.onError = { error in
                    logger.error("Decode error: \(error)")
                }
                activeDecoder = freshDecoder
                startReceiveLoop(on: awdlConn, decoder: freshDecoder, transport: .awdl)
            }
            startSecureInputPolling()
        } else {
            logEvent("USB dropped — no AWDL standby available; disconnected")
            connectionState = .disconnected
            statusBar.update(state: .disconnected)
            activeDecoder = nil
            activeEncoder = nil
        }
    }

    private func handlePendingUSBMessage(_ message: KeydMessage) {
        guard pendingUSBDecoder != nil else { return }

        switch message {
        case .sessionResume(let resume):
            if pairingManager.validateOrAdoptPairedDevice(resume.deviceID) {
                logEvent("USB session accepted for paired device; promoting USB")
                promotePendingUSBConnection(with: message, logMessage: "USB promoted over AWDL (matched paired device)")
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
            logEvent("Rejected unexpected USB message while AWDL is active")
            disconnectPendingUSBConnection()
        }
    }

    private func handleIncomingMessage(_ message: KeydMessage) {
        if pairingManager.isPaired, case .pairingRequest = message {
            send(.pairingInvalidated)
            logEvent("Rejected pairing request while another device is already paired")

            switch connectionState {
            case .pairingAWDL(let connection):
                connection.cancel()
                connectionState = .disconnected
                statusBar.update(state: .disconnected)
                activeDecoder = nil
                activeEncoder = nil
                logEvent("Dropped unexpected AWDL pairing candidate")
            case .awdlConnected(let connection):
                connection.cancel()
                connectionState = .disconnected
                statusBar.update(state: .disconnected)
                activeDecoder = nil
                activeEncoder = nil
                stopSecureInputPolling()
                injectionRouter.releaseModifiers()
                logEvent("Dropped unexpected AWDL pairing connection")
            default:
                break
            }
            return
        }

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
            if accepted, case .pairingAWDL(let connection) = connectionState {
                connectionState = .awdlConnected(connection)
                statusBar.update(state: .awdl)
                startSecureInputPolling()
                logEvent("AWDL promoted after pairing")
            }
            if accepted {
                onPairingCompleted?()
            }
            logEvent("Pairing \(accepted ? "accepted" : "rejected") for \(request.deviceID)")

        case .sessionResume(let resume):
            if pairingManager.isPaired {
                if pairingManager.validateOrAdoptPairedDevice(resume.deviceID) {
                    if case .pairingAWDL(let connection) = connectionState {
                        connectionState = .awdlConnected(connection)
                        statusBar.update(state: .awdl)
                        startSecureInputPolling()
                        logEvent("AWDL session accepted for paired device")
                    }
                    logEvent("Session resumed for \(resume.deviceID)")
                } else {
                    send(.pairingInvalidated)
                    logEvent("Rejected session resume from non-paired device \(resume.deviceID)")

                    if case .pairingAWDL(let connection) = connectionState {
                        connection.cancel()
                        connectionState = .disconnected
                        statusBar.update(state: .disconnected)
                        activeDecoder = nil
                        activeEncoder = nil
                        logEvent("Dropped unexpected AWDL candidate after resume mismatch")
                    } else if case .awdlConnected(let connection) = connectionState {
                        connection.cancel()
                        connectionState = .disconnected
                        statusBar.update(state: .disconnected)
                        activeDecoder = nil
                        activeEncoder = nil
                        stopSecureInputPolling()
                        injectionRouter.releaseModifiers()
                        logEvent("Dropped unexpected AWDL session after resume mismatch")
                    }
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
            break

        default:
            injectionRouter.route(message)
        }
    }

    func send(_ message: KeydMessage) {
        guard let encoder = activeEncoder else { return }
        guard let frame = try? encoder.encode(message) else { return }

        switch connectionState {
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
        case .pairingAWDL(let connection), .awdlConnected(let connection):
            connection.send(content: frame, completion: .idempotent)
        case .disconnected:
            break
        }
    }

    func invalidateRemotePairing() {
        guard activeConnection != nil else {
            logEvent("No active session to invalidate")
            return
        }
        send(.pairingInvalidated)
        logEvent("Sent pairing invalidation")
    }

    func resetActiveSession() {
        activeConnection?.cancel()
        Task { [usbListener] in
            await usbListener.disconnectCurrentConnection()
        }
        standbyAWDLConnection?.cancel()
        standbyAWDLConnection = nil
        standbyAWDLDecoder = nil
        cancelPendingUSBIdentityTimeout()
        pendingUSBDecoder = nil
        activeDecoder = nil
        activeEncoder = nil
        connectionState = .disconnected
        statusBar.update(state: .disconnected)
        stopSecureInputPolling()
        injectionRouter.releaseModifiers()
        logEvent("Active transport session reset")
    }

    private var activeConnection: NWConnection? {
        switch connectionState {
        case .pairingAWDL(let c): return c
        case .awdlConnected(let c): return c
        case .usbConnected: return nil
        case .disconnected: return nil
        }
    }

    private func isCurrentConnection(_ connection: NWConnection, for transport: ConnectionKind) -> Bool {
        switch (connectionState, transport) {
        case (.pairingAWDL(let current), .awdl):
            return current === connection
        case (.awdlConnected(let current), .awdl):
            return current === connection
        default:
            return false
        }
    }

    // MARK: - Secure Input Polling (AGENT-06)

    private func startSecureInputPolling() {
        stopSecureInputPolling()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSecureInput()
            }
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

    // MARK: - Event Log (for debug overlay)

    func logEvent(_ event: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(event)"
        connectionEventLog.append(entry)
        if connectionEventLog.count > 100 { connectionEventLog.removeFirst() }
        logger.info(entry)
    }

    func getEventLog() -> [String] { connectionEventLog }

    private func makeActiveDecoder() -> MessageDecoder {
        let decoder = MessageDecoder()
        decoder.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }
        decoder.onError = { error in
            logger.error("Decode error: \(error)")
        }
        activeDecoder = decoder
        activeEncoder = MessageEncoder()
        return decoder
    }

    private func makePendingUSBDecoder() -> MessageDecoder {
        let decoder = MessageDecoder()
        decoder.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handlePendingUSBMessage(message)
            }
        }
        decoder.onError = { error in
            logger.error("Decode error: \(error)")
        }
        pendingUSBDecoder = decoder
        return decoder
    }

    private func promotePendingUSBConnection(with initialMessage: KeydMessage, logMessage: String) {
        guard let decoder = pendingUSBDecoder else { return }

        pendingUSBDecoder = nil
        cancelPendingUSBIdentityTimeout()
        decoder.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }
        decoder.onError = { error in
            logger.error("Decode error: \(error)")
        }

        if case .awdlConnected(let old) = connectionState {
            old.cancel()
        }

        connectionState = .usbConnected
        statusBar.update(state: .usb)
        activeDecoder = decoder
        activeEncoder = MessageEncoder()
        logEvent(logMessage)
        startSecureInputPolling()
        handleIncomingMessage(initialMessage)
    }

    private func disconnectPendingUSBConnection() {
        cancelPendingUSBIdentityTimeout()
        pendingUSBDecoder = nil
        Task { [usbListener] in
            await usbListener.disconnectCurrentConnection()
        }
    }

    private func schedulePendingUSBIdentityTimeout(timeoutNanoseconds: UInt64 = 2_000_000_000) {
        pendingUSBIdentityTimeoutTask?.cancel()
        pendingUSBIdentityTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }

            guard let self, self.pendingUSBDecoder != nil else { return }
            self.logEvent("Pending USB connection did not identify itself; rotating to next USB device")
            self.disconnectPendingUSBConnection()
        }
    }

    private func cancelPendingUSBIdentityTimeout() {
        pendingUSBIdentityTimeoutTask?.cancel()
        pendingUSBIdentityTimeoutTask = nil
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
