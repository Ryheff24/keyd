import Network
import Foundation
import SharedProtocol

/// Discovers and connects to the macOS agent over AWDL via Bonjour (_keyd._tcp).
/// Pre-warmed concurrently with USB; promoted to primary on USB disconnect.
actor AWDLTransport {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var isConnecting = false
    private var isReady = false
    var onMessage: ((KeydMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnectionReady: (() -> Void)?  // Called when AWDL is ready (pre-warm complete)

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    func startBrowsing() {
        guard browser == nil else { return }

        decoder.onMessage = { [weak self] msg in
            Task { await self?.onMessage?(msg) }
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_keyd._tcp", domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            // Connect to first discovered result
            if let result = results.first, self != nil {
                Task { await self?.connectToEndpoint(result.endpoint) }
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[AWDLTransport] Browser ready, searching for _keyd._tcp")
            case .failed(let error):
                print("[AWDLTransport] Browser failed: \(error)")
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
        connection = nil
        isConnecting = false
        isReady = false
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) async {
        guard connection == nil, !isConnecting else { return }  // Already connected or attempting
        isConnecting = true

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state, for: conn) }
        }
        conn.start(queue: .global(qos: .userInteractive))
    }

    private func handleConnectionState(_ state: NWConnection.State, for conn: NWConnection) async {
        switch state {
        case .ready:
            print("[AWDLTransport] Connected via AWDL")
            setConnection(conn, ready: true)
            onConnectionReady?()
            await startReceiving(conn)
        case .waiting(let error):
            print("[AWDLTransport] Connection waiting: \(error)")
            let didLoseReadyConnection = markConnectionUnavailable(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
        case .failed(let error):
            print("[AWDLTransport] Connection failed: \(error)")
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
        case .cancelled:
            let didLoseReadyConnection = clearConnection(for: conn)
            if didLoseReadyConnection {
                onDisconnect?()
            }
        default:
            break
        }
    }

    private func setConnection(_ conn: NWConnection?, ready: Bool = false) {
        connection = conn
        isConnecting = false
        isReady = ready
    }

    private func markConnectionUnavailable(for conn: NWConnection) -> Bool {
        guard connection === conn else { return false }

        let wasReady = isReady
        isReady = false
        return wasReady
    }

    private func clearConnection(for conn: NWConnection) -> Bool {
        guard connection === conn else {
            if connection == nil {
                isConnecting = false
            }
            return false
        }

        let wasReady = isReady
        connection = nil
        isConnecting = false
        isReady = false
        return wasReady
    }

    private func startReceiving(_ conn: NWConnection) async {
        while true {
            do {
                let data = try await receiveOnce(on: conn)
                decoder.receive(data)
            } catch {
                print("[AWDLTransport] Receive error: \(error)")
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

    func stop() {
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        isConnecting = false
        isReady = false
    }
}
