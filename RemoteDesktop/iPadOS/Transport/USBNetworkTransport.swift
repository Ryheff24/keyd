import Foundation
import Network
import Security
import CryptoKit
import os.log

/// USB NCM transport for the iPadOS app.
///
/// Detects USB NCM (wiredEthernet) interfaces via NWPathMonitor, then creates
/// NWConnection instances for UDP (media, port 14567) and TCP (input, port 14568)
/// bound to the exact NWInterface object (never hardcoded name -- per research pitfall).
///
/// All connections use TLS 1.3 (TCP) and DTLS (UDP) with certificate pinning.
/// No cleartext fallback exists. If TLS/DTLS handshake fails, connection fails.
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

    private let keychainService = "com.ryheff.keyd.remote.app"

    // MARK: - Certificate Pinning

    /// Verify peer certificate against stored Mac cert fingerprint from Keychain.
    /// Returns true if fingerprint matches stored value, false otherwise.
    private func verifyPeerCertificate(_ trust: sec_trust_t) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let peerCert = certChain.first else {
            log.error("Certificate verify: no peer certificate")
            return false
        }

        let peerCertData = SecCertificateCopyData(peerCert) as Data
        let fingerprint = SHA256.hash(data: peerCertData)
        let peerFingerprint = Data(fingerprint)

        guard let storedFingerprint = loadStoredPeerFingerprint() else {
            log.error("Certificate verify: no stored peer fingerprint (not paired)")
            return false
        }

        let match = peerFingerprint == storedFingerprint
        if !match {
            log.error("Certificate verify: peer cert fingerprint MISMATCH -- rejecting")
        } else {
            log.info("Certificate verify: peer cert fingerprint matches stored -- trusted")
        }
        return match
    }

    /// Load stored Mac cert fingerprint from Keychain.
    private func loadStoredPeerFingerprint() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: "peer-cert-fingerprint",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - TLS/DTLS Parameter Configuration

    /// Create TLS 1.3 parameters for TCP connections with certificate pinning.
    /// No cleartext fallback -- if TLS handshake fails, connection fails.
    private func createSecureTCPParameters(interface: NWInterface) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                guard let self = self else {
                    complete(false)
                    return
                }
                let trusted = self.verifyPeerCertificate(trust)
                complete(trusted)
            }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        params.requiredInterface = interface
        return params
    }

    /// Create DTLS parameters for UDP connections with certificate pinning.
    /// No cleartext fallback -- if DTLS handshake fails, connection fails.
    private func createSecureUDPParameters(interface: NWInterface) -> NWParameters {
        let dtlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            dtlsOptions.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(dtlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                guard let self = self else {
                    complete(false)
                    return
                }
                let trusted = self.verifyPeerCertificate(trust)
                complete(trusted)
            }, DispatchQueue.global())

        let params = NWParameters(dtls: dtlsOptions, udp: .init())
        params.requiredInterface = interface
        params.requiredLocalEndpoint = nil
        return params
    }

    // MARK: - Public API

    /// Start monitoring for USB NCM interfaces.
    /// When an interface is detected, connections are created automatically.
    func startMonitoring() {
        guard pathMonitor == nil else { return }

        log.info("Starting USB NCM path monitor (TLS/DTLS enabled)")

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

        log.info("Connecting over USB NCM with TLS/DTLS to Mac on interface \(interface.debugDescription)")

        // DTLS-encrypted UDP connection for media (port 14567)
        let udpParams = createSecureUDPParameters(interface: interface)

        let mediaHost = NWEndpoint.Host("::")
        let mediaPort = NWEndpoint.Port(rawValue: keydrdMediaPort)!
        let mediaEndpoint = NWEndpoint.hostPort(host: mediaHost, port: mediaPort)

        let mediaConn = NWConnection(to: mediaEndpoint, using: udpParams)
        mediaConnection = mediaConn

        mediaConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("USB NCM DTLS media connection ready")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                self.log.error("USB NCM DTLS media connection failed: \(error)")
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

        // TLS 1.3-encrypted TCP connection for input (port 14568)
        let tcpParams = createSecureTCPParameters(interface: interface)

        let inputPort = NWEndpoint.Port(rawValue: keydrdInputPort)!
        let inputEndpoint = NWEndpoint.hostPort(host: mediaHost, port: inputPort)

        let inputConn = NWConnection(to: inputEndpoint, using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("USB NCM TLS input connection ready")
                self.isConnected = true
                self.scheduleInputReceive(inputConn)
            case .failed(let error):
                self.log.error("USB NCM TLS input connection failed: \(error)")
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
