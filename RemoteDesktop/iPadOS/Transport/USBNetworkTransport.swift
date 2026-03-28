import Foundation
import Network
import os.log

/// USB NCM transport for the iPadOS app.
///
/// Detects USB NCM (wiredEthernet) interfaces via NWPathMonitor, then creates
/// NWConnection instances for UDP (media, port 14567) and TCP (input, port 14568)
/// bound to the exact NWInterface object (never hardcoded name -- per research pitfall).
///
/// iPad is the CONNECTOR side -- it connects to the Mac's listeners.
final class USBNetworkTransport {

    // MARK: - Properties

    private(set) var isConnected = false
    private(set) var activeInterface: NWInterface?

    /// Callback fired when raw media frame data arrives over UDP.
    var onMediaReceived: ((Data) -> Void)?

    /// Callback fired when raw input event data arrives over TCP.
    var onInputReceived: ((Data) -> Void)?

    /// Callback fired when the USB NCM interface appears or disappears.
    var onInterfaceChanged: ((_ appeared: Bool, _ interface: NWInterface?) -> Void)?

    // MARK: - Private

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.monitor")
    private let transportQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.transport")

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "USBTransport")

    // MARK: - Public API

    /// Start monitoring for USB NCM interfaces.
    /// When an interface is detected, connections are created automatically.
    func startMonitoring() {
        guard pathMonitor == nil else { return }

        log.info("Starting USB NCM path monitor")

        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.log.info("USB NCM path update: status=\(String(describing: path.status))")

            if path.status == .satisfied || path.status == .requiresConnection {
                // Extract the exact NWInterface object -- NEVER just use type
                guard let interface = path.availableInterfaces.first(where: {
                    $0.type == .wiredEthernet
                }) else {
                    return
                }

                self.log.info("USB NCM interface found: \(interface.debugDescription)")

                if self.activeInterface == nil ||
                   self.activeInterface?.index != interface.index {
                    self.activeInterface = interface
                    self.connectOverUSBNCM(interface: interface)
                    self.onInterfaceChanged?(true, interface)
                }
            } else {
                if self.activeInterface != nil {
                    self.log.info("USB NCM interface disappeared")
                    self.tearDownConnections()
                    self.activeInterface = nil
                    self.isConnected = false
                    self.onInterfaceChanged?(false, nil)
                }
            }
        }

        monitor.start(queue: monitorQueue)
    }

    /// Stop monitoring and tear down all connections.
    func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        tearDownConnections()
        activeInterface = nil
        isConnected = false
    }

    /// Send an input event over TCP to the Mac.
    func sendInputEvent(_ data: Data) {
        guard let connection = inputConnection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Input send error: \(error)")
            }
        })
    }

    /// Send media data over UDP to the Mac (for acknowledgements/control).
    func sendMediaData(_ data: Data) {
        guard let connection = mediaConnection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Media send error: \(error)")
            }
        })
    }

    // MARK: - Private: Connection Setup

    private func connectOverUSBNCM(interface: NWInterface) {
        tearDownConnections()

        log.info("Connecting over USB NCM to Mac on interface \(interface.debugDescription)")

        // UDP connection for media (port 14567)
        // iPad connects to Mac's link-local address on the USB NCM interface
        let udpParams = NWParameters(dtls: nil, udp: .init())
        udpParams.requiredInterface = interface
        udpParams.requiredLocalEndpoint = nil

        let mediaHost = NWEndpoint.Host("::")
        let mediaPort = NWEndpoint.Port(rawValue: keydrdMediaPort)!
        let mediaEndpoint = NWEndpoint.hostPort(host: mediaHost, port: mediaPort)

        let mediaConn = NWConnection(to: mediaEndpoint, using: udpParams)
        mediaConnection = mediaConn

        mediaConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("USB NCM media UDP connection ready")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                self.log.error("USB NCM media connection failed: \(error)")
                self.mediaConnection = nil
                if self.inputConnection == nil { self.isConnected = false }
            case .cancelled:
                self.mediaConnection = nil
                if self.inputConnection == nil { self.isConnected = false }
            default:
                break
            }
        }

        mediaConn.start(queue: transportQueue)

        // TCP connection for input (port 14568)
        let tcpParams = NWParameters(tls: nil, tcp: .init())
        tcpParams.requiredInterface = interface

        let inputPort = NWEndpoint.Port(rawValue: keydrdInputPort)!
        let inputEndpoint = NWEndpoint.hostPort(host: mediaHost, port: inputPort)

        let inputConn = NWConnection(to: inputEndpoint, using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("USB NCM input TCP connection ready")
                self.isConnected = true
                self.scheduleInputReceive(inputConn)
            case .failed(let error):
                self.log.error("USB NCM input connection failed: \(error)")
                self.inputConnection = nil
                if self.mediaConnection == nil { self.isConnected = false }
            case .cancelled:
                self.inputConnection = nil
                if self.mediaConnection == nil { self.isConnected = false }
            default:
                break
            }
        }

        inputConn.start(queue: transportQueue)
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
    }

    deinit {
        stopMonitoring()
    }
}
