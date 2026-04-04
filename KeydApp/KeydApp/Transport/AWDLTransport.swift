import Network
import Foundation
import SharedProtocol

private let logger = KeydLogger(category: "AWDLTransport")

/// Discovers the macOS agent over AWDL via Bonjour (_keyd._tcp).
/// While USB is primary, only discovery stays warm; AWDL connects fresh when needed.
actor AWDLTransport {

    /// Explicit connection state — replaces isConnecting/isReady/autoConnectEnabled booleans.
    enum AWDLConnectionState: Equatable {
        case idle
        case browsing
        case connecting(endpoint: NWEndpoint)
        case ready
        case reconnecting(backoff: TimeInterval)

        var isActive: Bool {
            switch self {
            case .connecting, .ready, .reconnecting: return true
            case .idle, .browsing: return false
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    enum BeginAutoConnectResult: Equatable {
        case immediate
        case alreadyActive
        case pendingReconnect(backoff: TimeInterval)
        case waitingForDiscovery
    }

    private var awdlState: AWDLConnectionState = .idle
    private var browser: NWBrowser?
    private var discoveredEndpoint: NWEndpoint?
    private var connection: NWConnection?
    var onMessage: ((KeydMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnectionReady: (() -> Void)?  // Called when AWDL is ready (pre-warm complete)

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    // Exponential backoff for reconnect attempts (kept from original — well-implemented).
    private var reconnectBackoff: TimeInterval = 0.0
    private let reconnectBackoffInitial: TimeInterval = 0.5
    private let reconnectBackoffMax: TimeInterval = 8.0
    private var reconnectTask: Task<Void, Never>?

    // Pairing mode: when true, auto-reconnect is disabled after first connection closes.
    // Unpaired devices should not hammer the Mac with reconnect attempts.
    // This is a policy flag (not state), so it stays as a Bool.
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
        awdlState = .browsing
    }

    private func resetBrowserState() {
        browser = nil
        discoveredEndpoint = nil
        connection = nil
        awdlState = .idle
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
        guard connection == nil, !awdlState.isConnecting else { return }  // Already connected or attempting

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        awdlState = .connecting(endpoint: endpoint)
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
            connection = conn
            awdlState = .ready
            // Don't reset backoff here — connection may die immediately.
            // Backoff only resets on confirmed session (heartbeat ack via resetBackoff()).
            onConnectionReady?()
            await startReceiving(conn)
        case .waiting(let error):
            logger.warning("Connection waiting: \(error)")
            let wasAttemptingOrReady = awdlState.isConnecting || awdlState.isReady
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection || (pairingModeEnabled && wasAttemptingOrReady) {
                logger.info("AWDL state update on waiting: pairingMode=\(self.pairingModeEnabled), wasAttemptingOrReady=\(wasAttemptingOrReady), didLoseReady=\(didLoseReadyConnection)")
                onDisconnect?()
            }
            await scheduleReconnectIfNeeded()
        case .failed(let error):
            logger.error("Connection failed: \(error)")
            let wasAttemptingOrReady = awdlState.isConnecting || awdlState.isReady
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection || (pairingModeEnabled && wasAttemptingOrReady) {
                logger.info("AWDL state update on failure: pairingMode=\(self.pairingModeEnabled), wasAttemptingOrReady=\(wasAttemptingOrReady), didLoseReady=\(didLoseReadyConnection)")
                onDisconnect?()
            }
            await scheduleReconnectIfNeeded()
        case .cancelled:
            let wasAttemptingOrReady = awdlState.isConnecting || awdlState.isReady
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection || (pairingModeEnabled && wasAttemptingOrReady) {
                logger.info("AWDL state update on cancel: pairingMode=\(self.pairingModeEnabled), wasAttemptingOrReady=\(wasAttemptingOrReady), didLoseReady=\(didLoseReadyConnection)")
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
        // Only reconnect if we were previously in an active state (not idle).
        guard awdlState != .idle else { return }

        // In pairing mode, disable auto-reconnect after connection closure.
        if pairingModeEnabled {
            awdlState = .browsing
            logger.info("Pairing mode: auto-reconnect disabled after connection close")
            return
        }

        guard connection == nil, !awdlState.isConnecting, discoveredEndpoint != nil else { return }

        // Apply exponential backoff
        if reconnectBackoff == 0.0 {
            reconnectBackoff = reconnectBackoffInitial
        } else {
            reconnectBackoff = min(reconnectBackoff * 2.0, reconnectBackoffMax)
        }

        let delay = reconnectBackoff
        logger.info("Scheduling AWDL reconnect in \(delay)s")
        awdlState = .reconnecting(backoff: delay)

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

    private func clearConnection(for conn: NWConnection) -> Bool {
        guard connection === conn else { return false }
        return disconnectCurrentConnection()
    }

    @discardableResult
    private func disconnectCurrentConnection() -> Bool {
        let wasReady = awdlState.isReady
        let activeConnection = connection
        connection = nil
        awdlState = browser != nil ? .browsing : .idle
        activeConnection?.cancel()
        return wasReady
    }

    private func maybeConnectIfNeeded() async {
        guard awdlState.isActive || awdlState == .browsing else { return }
        guard connection == nil, !awdlState.isConnecting, let endpoint = discoveredEndpoint else { return }
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
        guard awdlState.isReady, let connection, let path = connection.currentPath else { return false }
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }

    func beginAutoConnect(pairingMode: Bool = false) async -> BeginAutoConnectResult {
        pairingModeEnabled = pairingMode

        if hasConnection() {
            logger.info("beginAutoConnect: already connected (state=\(String(describing: awdlState)), pairingMode=\(pairingModeEnabled))")
            return .alreadyActive
        }

        if awdlState.isConnecting {
            logger.info("beginAutoConnect: connection attempt already in progress (state=\(String(describing: awdlState)), pairingMode=\(pairingModeEnabled))")
            return .alreadyActive
        }

        if case .reconnecting(let backoff) = awdlState {
            logger.info("beginAutoConnect: reconnect already scheduled (backoff=\(backoff)s, pairingMode=\(pairingModeEnabled))")
            return .pendingReconnect(backoff: backoff)
        }

        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
        awdlState = .browsing

        guard discoveredEndpoint != nil else {
            logger.info("beginAutoConnect: no discovered endpoint yet (state=\(String(describing: awdlState)), pairingMode=\(pairingModeEnabled))")
            return .waitingForDiscovery
        }

        await maybeConnectIfNeeded()
        logger.info("beginAutoConnect: connect attempt started (state=\(String(describing: awdlState)), pairingMode=\(pairingModeEnabled))")
        return .immediate
    }

    /// Reset the reconnect backoff (call after successful session resume acknowledgment).
    func resetBackoff() {
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func prepareForUSBStandby() {
        awdlState = .browsing
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
        awdlState = .idle
        reconnectBackoff = 0.0
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
