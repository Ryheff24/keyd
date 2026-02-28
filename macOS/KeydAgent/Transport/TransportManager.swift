import Network
import Foundation
import CoreGraphics
import Carbon.HIToolbox

// SharedProtocol added as local package dependency in Xcode project
@preconcurrency import SharedProtocol

/// Connection state for the macOS agent.
enum AgentConnectionState {
    case disconnected
    case usbConnected(NWConnection)
    case pairingAWDL(NWConnection)
    case awdlConnected(NWConnection)
}

enum ConnectionKind: CustomStringConvertible {
    case usb, awdl
    var description: String { self == .usb ? "USB" : "AWDL" }
}

/// Manages USB and AWDL listeners; routes decoded messages to InjectionRouter.
/// Both listeners start concurrently (AWDL pre-warmed per TRANS-04).
/// USB takes priority; AWDL is promoted on USB disconnect (TRANS-03).
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
            // Start both listeners concurrently — AWDL pre-warmed per TRANS-04
            await usbListener.setOnConnection { [weak self] conn in
                Task { @MainActor in
                    await self?.handleNewConnection(conn, transport: .usb)
                }
            }
            await awdlListener.setOnConnection { [weak self] conn in
                Task { @MainActor in
                    await self?.handleNewConnection(conn, transport: .awdl)
                }
            }
            try await usbListener.start()
            try await awdlListener.start()
            logEvent("Both listeners started (USB port \(USBListener.port), AWDL _keyd._tcp)")
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
        case (.awdlConnected(let old), .usb), (.pairingAWDL(let old), .usb):
            // USB connects while AWDL was active — promote USB (re-plug case)
            old.cancel()
            connectionState = .usbConnected(connection)
            statusBar.update(state: .usb)
            logEvent("USB promoted over AWDL (re-plug)")
        case (.disconnected, .usb):
            connectionState = .usbConnected(connection)
            statusBar.update(state: .usb)
        case (.awdlConnected(let old), .awdl):
            old.cancel()
            connectionState = .awdlConnected(connection)
            statusBar.update(state: .awdl)
            logEvent("Replaced stale AWDL connection")
        case (.disconnected, .awdl):
            if pairingManager.isPaired {
                connectionState = .awdlConnected(connection)
                statusBar.update(state: .awdl)
                logEvent("AWDL connected")
            } else {
                connectionState = .pairingAWDL(connection)
                logEvent("AWDL pairing channel ready")
            }
        case (.pairingAWDL(let old), .awdl):
            old.cancel()
            connectionState = .pairingAWDL(connection)
            logEvent("Replaced stale AWDL pairing channel")
        case (.usbConnected, .awdl):
            // AWDL comes up while USB is active — keep as pre-warmed standby
            // The TransportManager will promote AWDL on USB disconnect (handleDisconnect)
            logEvent("AWDL pre-warmed while USB active (standby)")
            startAWDLStandby(connection)
            return
        case (.usbConnected, .usb):
            logEvent("Ignoring duplicate \(transport) connection")
            connection.cancel()
            return
        }

        // Set up decoder for this connection
        let decoder = MessageDecoder()
        let encoder = MessageEncoder()
        self.activeDecoder = decoder
        self.activeEncoder = encoder

        decoder.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleIncomingMessage(message)
            }
        }
        decoder.onError = { error in
            print("[TransportManager] Decode error: \(error)")
        }

        // Start receive loop
        startReceiveLoop(on: connection, decoder: decoder, transport: transport)

        // Start secure input polling
        if case .pairingAWDL = connectionState {
            return
        }
        startSecureInputPolling()
    }

    // Pre-warmed AWDL connection kept ready as standby
    private var standbyAWDLConnection: NWConnection?

    private func startAWDLStandby(_ connection: NWConnection) {
        standbyAWDLConnection = connection
        // Start receiving but don't make it active yet
        let decoder = MessageDecoder()
        decoder.onMessage = { _ in }  // Discard while on standby
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                Task { @MainActor in
                    self?.standbyAWDLConnection = nil
                }
            }
        }
    }

    private func startReceiveLoop(on connection: NWConnection, decoder: MessageDecoder, transport: ConnectionKind) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                decoder.receive(data)
            }
            if isComplete || error != nil {
                print("[TransportManager] \(transport) connection closed: \(error?.localizedDescription ?? "EOF")")
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
        case (.usbConnected, .usb):
            // Check if AWDL standby is available for fallback
            if let awdlConn = standbyAWDLConnection {
                logEvent("USB dropped — promoting pre-warmed AWDL connection (TRANS-03)")
                standbyAWDLConnection = nil
                connectionState = .awdlConnected(awdlConn)
                statusBar.update(state: .awdl)
                // Set up decoder for AWDL connection
                let decoder = MessageDecoder()
                let encoder = MessageEncoder()
                self.activeDecoder = decoder
                self.activeEncoder = encoder
                decoder.onMessage = { [weak self] message in
                    Task { @MainActor in
                        self?.handleIncomingMessage(message)
                    }
                }
                startReceiveLoop(on: awdlConn, decoder: decoder, transport: .awdl)
                startSecureInputPolling()
            } else {
                logEvent("USB dropped — no AWDL standby available; disconnected")
                connectionState = .disconnected
                statusBar.update(state: .disconnected)
            }

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

    private func handleIncomingMessage(_ message: KeydMessage) {
        if !pairingManager.isPaired {
            switch message {
            case .pairingRequest, .sessionResume:
                break
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
                onPairingCompleted?()
            }
            logEvent("Pairing \(accepted ? "accepted" : "rejected") for \(request.deviceID)")

        case .sessionResume(let resume):
            if pairingManager.isPaired {
                logEvent("Session resumed for \(resume.deviceID)")
            } else {
                send(.pairingInvalidated)
                logEvent("Rejected session resume from unpaired device")
            }

        default:
            injectionRouter.route(message)
        }
    }

    func send(_ message: KeydMessage) {
        guard let encoder = activeEncoder else { return }
        guard let frame = try? encoder.encode(message) else { return }
        guard let connection = activeConnection else { return }
        connection.send(content: frame, completion: .idempotent)
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
        standbyAWDLConnection?.cancel()
        standbyAWDLConnection = nil
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
        case .usbConnected(let c): return c
        case .pairingAWDL(let c): return c
        case .awdlConnected(let c): return c
        case .disconnected: return nil
        }
    }

    private func isCurrentConnection(_ connection: NWConnection, for transport: ConnectionKind) -> Bool {
        switch (connectionState, transport) {
        case (.usbConnected(let current), .usb):
            return current === connection
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
        print("[TransportManager] \(entry)")
    }

    func getEventLog() -> [String] { connectionEventLog }
}

// MARK: - Actor callback setters
extension USBListener {
    func setOnConnection(_ handler: @escaping @Sendable (NWConnection) -> Void) async {
        onConnection = handler
    }
}
extension AWDLListener {
    func setOnConnection(_ handler: @escaping @Sendable (NWConnection) -> Void) async {
        onConnection = handler
    }
}
