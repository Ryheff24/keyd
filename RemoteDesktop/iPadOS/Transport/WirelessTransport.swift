import Foundation
import Network
import os.log

/// Wireless transport for the iPadOS app (Wi-Fi + AWDL).
///
/// Uses NWBrowser to discover the Mac's `_keydrd._tcp` Bonjour service over
/// Wi-Fi or AWDL (with peer-to-peer enabled). When discovered, creates
/// connections to the Mac.
///
/// iPad is the CONNECTOR side -- it discovers and connects to the Mac.
final class WirelessTransport {

    // MARK: - Properties

    private(set) var isConnected = false
    private(set) var isAWDL = false

    /// Callback fired when raw media frame data arrives over UDP.
    var onMediaReceived: ((Data) -> Void)?

    /// Callback fired when raw input event data arrives over TCP.
    var onInputReceived: ((Data) -> Void)?

    /// Callback fired when a wireless connection is established or lost.
    var onConnectionChanged: ((_ connected: Bool, _ isAWDL: Bool) -> Void)?

    // MARK: - Private

    private var browser: NWBrowser?
    private let transportQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.wireless.transport")

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "WirelessTransport")

    // MARK: - Public API

    /// Start browsing for the Mac's Bonjour service.
    /// Enables peer-to-peer (AWDL) discovery.
    func startBrowsing() {
        guard browser == nil else { return }

        log.info("Starting Bonjour browse for \(keydrdService)")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: keydrdService, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)
        browser = newBrowser

        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("Bonjour browser ready")
            case .failed(let error):
                self.log.error("Bonjour browser failed: \(error)")
            case .cancelled:
                self.log.info("Bonjour browser cancelled")
            default:
                break
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }

            for change in changes {
                switch change {
                case .added(let result):
                    self.log.info("Bonjour service found: \(result.endpoint.debugDescription)")
                    self.connectToService(endpoint: result.endpoint)
                case .removed(let result):
                    self.log.info("Bonjour service lost: \(result.endpoint.debugDescription)")
                    // Connection state changes will handle teardown
                default:
                    break
                }
            }
        }

        newBrowser.start(queue: transportQueue)
    }

    /// Stop browsing and tear down all connections.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        tearDownConnections()
    }

    /// Send an input event over TCP to the Mac.
    func sendInputEvent(_ data: Data) {
        guard let connection = inputConnection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Wireless input send error: \(error)")
            }
        })
    }

    /// Send media data over UDP to the Mac (for acknowledgements/control).
    func sendMediaData(_ data: Data) {
        guard let connection = mediaConnection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Wireless media send error: \(error)")
            }
        })
    }

    // MARK: - Private: Connection Setup

    private func connectToService(endpoint: NWEndpoint) {
        tearDownConnections()

        log.info("Connecting to discovered Mac service: \(endpoint.debugDescription)")

        // TCP connection for input -- connect to the discovered Bonjour endpoint
        let tcpParams = NWParameters(tls: nil, tcp: .init())
        tcpParams.includePeerToPeer = true

        let inputConn = NWConnection(to: endpoint, using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                self.log.info("Wireless TCP connection ready")

                // Determine if AWDL or Wi-Fi via connection path interface type
                let detectedAWDL = self.detectAWDL(connection: inputConn)
                self.isAWDL = detectedAWDL
                self.isConnected = true

                self.log.info("Wireless transport: AWDL=\(detectedAWDL)")
                self.onConnectionChanged?(true, detectedAWDL)

                self.scheduleInputReceive(inputConn)
                self.establishMediaConnection(from: inputConn)

            case .failed(let error):
                self.log.error("Wireless TCP connection failed: \(error)")
                self.inputConnection = nil
                self.isConnected = false
                self.onConnectionChanged?(false, self.isAWDL)

            case .cancelled:
                self.inputConnection = nil
                if self.mediaConnection == nil {
                    self.isConnected = false
                }

            default:
                break
            }
        }

        inputConn.start(queue: transportQueue)
    }

    private func establishMediaConnection(from tcpConnection: NWConnection) {
        // Extract the remote host from the TCP connection to create a UDP media path
        guard let path = tcpConnection.currentPath,
              let remoteEndpoint = path.remoteEndpoint else {
            log.warning("Cannot establish media connection: no remote endpoint")
            return
        }

        // Extract host from the remote endpoint
        let host: NWEndpoint.Host
        let mediaPort = NWEndpoint.Port(rawValue: keydrdMediaPort)!

        switch remoteEndpoint {
        case .hostPort(let h, _):
            host = h
        default:
            // For Bonjour-resolved endpoints, use the same endpoint pattern
            log.warning("Cannot extract host from endpoint: \(remoteEndpoint.debugDescription)")
            return
        }

        let udpParams = NWParameters(dtls: nil, udp: .init())
        udpParams.includePeerToPeer = true

        // Bind to the same interface as the TCP connection
        if let pathInterface = path.availableInterfaces.first {
            udpParams.requiredInterface = pathInterface
        }

        let mediaEndpoint = NWEndpoint.hostPort(host: host, port: mediaPort)
        let mediaConn = NWConnection(to: mediaEndpoint, using: udpParams)
        mediaConnection = mediaConn

        mediaConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("Wireless media UDP connection ready")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                self.log.error("Wireless media UDP connection failed: \(error)")
            default:
                break
            }
        }

        mediaConn.start(queue: transportQueue)
    }

    // MARK: - Private: Interface Detection

    private func detectAWDL(connection: NWConnection) -> Bool {
        guard let path = connection.currentPath else { return false }

        var hasWiFi = false
        var hasPeerToPeer = false

        for interface in path.availableInterfaces {
            log.info("Connection interface: \(interface.debugDescription) (type=\(String(describing: interface.type)))")
            switch interface.type {
            case .wifi:
                hasWiFi = true
            case .other:
                hasPeerToPeer = true
            default:
                break
            }
        }

        // AWDL connections show up as type_other; Wi-Fi as type_wifi
        return hasPeerToPeer && !hasWiFi
    }

    // MARK: - Private: Receive Loops

    private func scheduleMediaReceive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.onMediaReceived?(data)
            }

            if error != nil || isComplete { return }
            self.scheduleMediaReceive(connection)
        }
    }

    private func scheduleInputReceive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.onInputReceived?(data)
            }

            if error != nil || isComplete { return }
            self.scheduleInputReceive(connection)
        }
    }

    // MARK: - Private: Teardown

    private func tearDownConnections() {
        mediaConnection?.cancel()
        mediaConnection = nil
        inputConnection?.cancel()
        inputConnection = nil
        isConnected = false
        isAWDL = false
    }

    deinit {
        stopBrowsing()
    }
}
