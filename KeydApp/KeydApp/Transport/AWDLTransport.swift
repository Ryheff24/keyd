import Network
import Foundation
import SharedProtocol

/// Discovers and connects to the macOS agent over AWDL via Bonjour (_keyd._tcp).
/// Pre-warmed concurrently with USB; promoted to primary on USB disconnect.
actor AWDLTransport {
    private var browser: NWBrowser?
    private var connection: NWConnection?
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

        let params = NWParameters.applicationService
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
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) async {
        guard connection == nil else { return }  // Already connected

        let params = NWParameters.applicationService
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[AWDLTransport] Connected via AWDL")
                Task {
                    await self?.setConnection(conn)
                    await self?.onConnectionReady?()
                    await self?.startReceiving(conn)
                }
            case .failed(let error):
                print("[AWDLTransport] Connection failed: \(error)")
                Task { await self?.setConnection(nil) }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
    }

    private func setConnection(_ conn: NWConnection?) async {
        connection = conn
    }

    private func startReceiving(_ conn: NWConnection) async {
        while true {
            do {
                let data = try await receiveOnce(on: conn)
                decoder.receive(data)
            } catch {
                print("[AWDLTransport] Receive error: \(error)")
                connection = nil
                onDisconnect?()
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
        guard let conn = connection else {
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

    var isConnected: Bool { connection != nil }

    func stop() {
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
    }
}
