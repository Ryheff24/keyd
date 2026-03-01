import Network
import Foundation
import SharedProtocol

private let logger = KeydLogger(category: "AWDLTransport")

/// Discovers the macOS agent over AWDL via Bonjour (_keyd._tcp).
/// While USB is primary, only discovery stays warm; AWDL connects fresh when needed.
actor AWDLTransport {
    private var browser: NWBrowser?
    private var discoveredEndpoint: NWEndpoint?
    private var connection: NWConnection?
    private var isConnecting = false
    private var isReady = false
    private var autoConnectEnabled = false
    var onMessage: ((KeydMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnectionReady: (() -> Void)?  // Called when AWDL is ready (pre-warm complete)

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    // Exponential backoff for reconnect attempts
    private var reconnectBackoff: TimeInterval = 0.0
    private let reconnectBackoffInitial: TimeInterval = 0.5
    private let reconnectBackoffMax: TimeInterval = 8.0
    private var reconnectTask: Task<Void, Never>?

    // Pairing mode: when true, auto-reconnect is disabled after first connection closes.
    // Unpaired devices should not hammer the Mac with reconnect attempts.
    private var pairingModeEnabled = false

    func startBrowsing() {
        guard browser == nil else { return }

        decoder.onMessage = { [weak self] msg in
            Task { await self?.onMessage?(msg) }
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_keyd._tcp", domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleBrowseResults(results) }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Browser ready, searching for _keyd._tcp")
            case .failed(let error):
                logger.error("Browser failed: \(error)")
                Task { await self.resetBrowserState() }
            default:
                break
            }
        }
        browser.start(queue: .global(qos: .userInteractive))
        self.browser = browser
    }

    private func resetBrowserState() {
        browser = nil
        discoveredEndpoint = nil
        connection = nil
        isConnecting = false
        isReady = false
        autoConnectEnabled = false
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) async {
        discoveredEndpoint = results.first?.endpoint

        guard discoveredEndpoint != nil else {
            let didLoseReadyConnection = disconnectCurrentConnection()
            if didLoseReadyConnection {
                onDisconnect?()
            }
            return
        }

        await maybeConnectIfNeeded()
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) async {
        guard connection == nil, !isConnecting else { return }  // Already connected or attempting

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        isConnecting = true
        isReady = false
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state, for: conn) }
        }
        conn.start(queue: .global(qos: .userInteractive))
    }

    private func handleConnectionState(_ state: NWConnection.State, for conn: NWConnection) async {
        switch state {
        case .ready:
            guard connection === conn else {
                conn.cancel()
                return
            }
            logger.info("Connected via AWDL")
            setConnection(conn, ready: true)
            // Don't reset backoff here — connection may die immediately.
            // Backoff only resets on confirmed session (heartbeat ack via resetBackoff()).
            onConnectionReady?()
            await startReceiving(conn)
        case .waiting(let error):
            logger.warning("Connection waiting: \(error)")
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
            await scheduleReconnectIfNeeded()
        case .failed(let error):
            logger.error("Connection failed: \(error)")
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
            await scheduleReconnectIfNeeded()
        case .cancelled:
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
            await scheduleReconnectIfNeeded()
        default:
            break
        }
    }

    /// Schedule a reconnect with exponential backoff instead of immediate retry.
    /// In pairing mode, do NOT reconnect after a connection closes.
    private func scheduleReconnectIfNeeded() async {
        guard autoConnectEnabled else { return }

        // In pairing mode, disable auto-reconnect after connection closure.
        // The unpaired device already had its chance; it should wait for user action.
        if pairingModeEnabled {
            autoConnectEnabled = false
            logger.info("Pairing mode: auto-reconnect disabled after connection close")
            return
        }

        guard connection == nil, !isConnecting, discoveredEndpoint != nil else { return }

        // Apply exponential backoff
        if reconnectBackoff == 0.0 {
            reconnectBackoff = reconnectBackoffInitial
        } else {
            reconnectBackoff = min(reconnectBackoff * 2.0, reconnectBackoffMax)
        }

        let delay = reconnectBackoff
        logger.info("Scheduling AWDL reconnect in \(delay)s")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.maybeConnectIfNeeded()
        }
    }

    private func setConnection(_ conn: NWConnection?, ready: Bool = false) {
        connection = conn
        isConnecting = false
        isReady = ready
    }

    private func clearConnection(for conn: NWConnection) -> Bool {
        guard connection === conn else { return false }

        return disconnectCurrentConnection()
    }

    @discardableResult
    private func disconnectCurrentConnection() -> Bool {
        let wasReady = isReady
        let activeConnection = connection
        connection = nil
        isConnecting = false
        isReady = false
        activeConnection?.cancel()
        return wasReady
    }

    private func maybeConnectIfNeeded() async {
        guard autoConnectEnabled, connection == nil, !isConnecting, let endpoint = discoveredEndpoint else { return }
        await connectToEndpoint(endpoint)
    }

    private func startReceiving(_ conn: NWConnection) async {
        while true {
            do {
                let data = try await receiveOnce(on: conn)
                decoder.receive(data)
            } catch {
                logger.error("Receive error: \(error)")
                let didLoseReadyConnection = clearConnection(for: conn)
                if didLoseReadyConnection {
                    onDisconnect?()
                }
                return
            }
        }
    }

    private func receiveOnce(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error { cont.resume(throwing: error) }
                else if isComplete { cont.resume(throwing: URLError(.networkConnectionLost)) }
                else if let data = data { cont.resume(returning: data) }
            }
        }
    }

    func send(_ message: KeydMessage) async throws {
        guard hasConnection(), let conn = connection else {
            throw URLError(.notConnectedToInternet)
        }
        let frame = try encoder.encode(message)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    func sendBestEffort(_ message: KeydMessage) throws {
        guard hasConnection(), let conn = connection else {
            throw URLError(.notConnectedToInternet)
        }
        let frame = try encoder.encode(message)
        conn.send(content: frame, completion: .idempotent)
    }

    var isConnected: Bool { hasConnection() }

    func hasConnection() -> Bool {
        guard isReady, let connection, let path = connection.currentPath else { return false }
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }

    func beginAutoConnect(pairingMode: Bool = false) async -> Bool {
        autoConnectEnabled = true
        pairingModeEnabled = pairingMode
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil

        if hasConnection() || isConnecting {
            return true
        }

        guard discoveredEndpoint != nil else {
            return false
        }

        await maybeConnectIfNeeded()
        return true
    }

    /// Reset the reconnect backoff (call after successful session resume acknowledgment).
    func resetBackoff() {
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func prepareForUSBStandby() {
        autoConnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        _ = disconnectCurrentConnection()
    }

    func invalidateActiveConnection() {
        _ = disconnectCurrentConnection()
    }

    func stop() {
        browser?.cancel()
        _ = disconnectCurrentConnection()
        browser = nil
        discoveredEndpoint = nil
        autoConnectEnabled = false
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
