import Foundation
import Network
import SharedProtocol

private let logger = KeydLogger(category: "USBTransport")

/// Accepts a Mac-side usbmux tunnel on a fixed TCP port exposed by the iPhone app.
/// The host initiates the usbmux connection; iOS listens and promotes USB when the
/// inbound tunnel becomes ready.
actor USBTransport {
    static let port: UInt16 = 12345

    private var listener: NWListener?
    private var connection: NWConnection?
    private var isReady = false
    private var waitContinuation: CheckedContinuation<Bool, Never>?
    private var waitTimeoutTask: Task<Void, Never>?

    var onMessage: ((KeydMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnectionReady: (() -> Void)?

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    /// Ensure the listener is running, then wait briefly for an inbound usbmux tunnel.
    /// If the initial wait times out, the listener remains active and a later tunnel
    /// will still trigger `onConnectionReady`.
    func connect(timeoutNanoseconds: UInt64 = 8_000_000_000) async -> Bool {
        if isReady {
            return true
        }

        do {
            try startListenerIfNeeded()
        } catch {
            logger.error("Failed to start USB listener: \(error)")
            return false
        }

        if isReady {
            return true
        }

        resolvePendingWait(with: false)

        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
            waitTimeoutTask?.cancel()
            waitTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.resolvePendingWait(with: false)
            }
        }
    }

    private func startListenerIfNeeded() throws {
        guard listener == nil else { return }

        decoder.onMessage = { [weak self] message in
            Task { await self?.onMessage?(message) }
        }

        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)

        listener.newConnectionHandler = { [weak self] newConnection in
            Task { await self?.acceptConnection(newConnection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.info("Listening for USB tunnel on port \(Self.port)")
            case .failed(let error):
                logger.error("Listener failed: \(error)")
                Task { await self?.handleListenerStopped() }
            case .cancelled:
                Task { await self?.handleListenerStopped() }
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInteractive))
        self.listener = listener
    }

    private func acceptConnection(_ newConnection: NWConnection) async {
        if let existing = connection, existing !== newConnection {
            connection = nil
            isReady = false
            existing.cancel()
        }

        connection = newConnection
        isReady = false

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.handleConnectionReady(newConnection) }
            case .failed(let error):
                logger.error("USB tunnel failed: \(error)")
                Task { await self?.handleConnectionClosed(newConnection) }
            case .cancelled:
                Task { await self?.handleConnectionClosed(newConnection) }
            default:
                break
            }
        }

        newConnection.start(queue: .global(qos: .userInteractive))
    }

    private func handleConnectionReady(_ readyConnection: NWConnection) async {
        guard connection === readyConnection else { return }

        isReady = true
        logger.info("USB tunnel ready")
        resolvePendingWait(with: true)
        onConnectionReady?()
        await startReceiving(on: readyConnection)
    }

    private func handleConnectionClosed(_ closedConnection: NWConnection) async {
        guard connection === closedConnection else { return }

        connection = nil
        isReady = false
        onDisconnect?()
    }

    private func handleListenerStopped() {
        listener = nil
        connection = nil
        isReady = false
        resolvePendingWait(with: false)
    }

    private func resolvePendingWait(with result: Bool) {
        waitTimeoutTask?.cancel()
        waitTimeoutTask = nil
        waitContinuation?.resume(returning: result)
        waitContinuation = nil
    }

    private func startReceiving(on connection: NWConnection) async {
        while true {
            do {
                let data = try await receiveOnce(on: connection)
                decoder.receive(data)
            } catch {
                logger.error("Receive error: \(error)")
                await handleConnectionClosed(connection)
                return
            }
        }
    }

    private func receiveOnce(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                } else if let data = data {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    func send(_ message: KeydMessage) async throws {
        guard let connection else {
            throw URLError(.notConnectedToInternet)
        }

        let frame = try encoder.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func sendBestEffort(_ message: KeydMessage) throws {
        guard let connection else {
            throw URLError(.notConnectedToInternet)
        }

        let frame = try encoder.encode(message)
        connection.send(content: frame, completion: .idempotent)
    }

    func disconnect() {
        resolvePendingWait(with: false)

        let activeConnection = connection
        connection = nil
        isReady = false
        activeConnection?.cancel()

        listener?.cancel()
        listener = nil
    }

    var isConnected: Bool { connection != nil }

    func hasConnection() -> Bool { connection != nil }

    func hasReadyConnection() -> Bool { connection != nil && isReady }
}
