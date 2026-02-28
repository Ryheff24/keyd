import Network
import Foundation
import SharedProtocol

/// Connects to the macOS agent via USB using usbmuxd TCP tunnel.
/// usbmuxd on macOS forwards this iOS device's connections to localhost:12345.
actor USBTransport {
    static let port: UInt16 = 12345
    private var connection: NWConnection?
    var onMessage: ((KeydMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    /// Connect with exponential backoff retry.
    /// - Returns: `true` when a TCP connection is ready, `false` if all retries fail.
    func connect() async -> Bool {
        if connection != nil {
            return true
        }

        decoder.onMessage = { [weak self] msg in
            Task { await self?.onMessage?(msg) }
        }

        var delay: TimeInterval = 0.5
        let maxDelay: TimeInterval = 5.0
        var attempts = 0
        let maxAttempts = 10

        while attempts < maxAttempts {
            do {
                try await attemptConnect()
                print("[USBTransport] Connected on attempt \(attempts + 1)")
                return true
            } catch is CancellationError {
                connection = nil
                return false
            } catch {
                attempts += 1
                print("[USBTransport] Connect attempt \(attempts) failed: \(error). Retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled {
                    connection = nil
                    return false
                }
                delay = min(delay * 2, maxDelay)
            }
        }

        connection = nil
        print("[USBTransport] Max retries reached. Connection failed.")
        return false
    }

    private func attemptConnect() async throws {
        let params = NWParameters.tcp
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    cont.resume()
                    Task { await self?.startReceiving(conn) }
                case .failed(let error):
                    Task { await self?.setConnection(nil) }
                    cont.resume(throwing: error)
                case .cancelled:
                    Task { await self?.setConnection(nil) }
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInteractive))
        }
    }

    private func setConnection(_ connection: NWConnection?) {
        self.connection = connection
    }

    private func startReceiving(_ connection: NWConnection) async {
        while true {
            do {
                let data = try await receiveOnce(on: connection)
                decoder.receive(data)
            } catch {
                print("[USBTransport] Receive error: \(error)")
                self.connection = nil
                onDisconnect?()
                return
            }
        }
    }

    private func receiveOnce(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(throwing: URLError(.networkConnectionLost))
                } else if let data = data {
                    cont.resume(returning: data)
                }
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
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
