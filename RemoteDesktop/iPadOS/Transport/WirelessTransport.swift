import Foundation
import Network
import Security
import CryptoKit
import os.log

/// Wireless transport for the iPadOS app (Wi-Fi + AWDL).
///
/// Uses NWBrowser to discover the Mac's `_keydrd._tcp` Bonjour service over
/// Wi-Fi or AWDL (with peer-to-peer enabled). When discovered, creates
/// connections to the Mac.
///
/// All connections use TLS 1.3 (TCP) and DTLS (UDP) with certificate pinning.
/// No cleartext fallback exists.
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
    private let mediaProcessingQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.wireless.media-processing")

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    /// TCP reassembly buffer for length-prefixed messages.
    /// Mac prepends 4-byte big-endian length before each message.
    private var tcpBuffer = Data()

    /// Tracks the Bonjour service name we are connected/connecting to,
    /// preventing duplicate connections when NWBrowser fires multiple `.added`
    /// events for the same service on different interfaces (Wi-Fi + AWDL).
    private var connectedServiceName: String?
    private var pendingMediaCallbacks = 0
    private var maxPendingMediaCallbacks = 0

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "WirelessTransport")

    private let keychainService = "com.ryheff.keyd.remote.app"
    private let clientIdentityPKCS12Account = "client-identity-p12"
    private let clientCertificateDERAccount = "client-cert-der"
    private let clientPrivateKeyRepresentationAccount = "client-private-key"
    private let provisionedClientIdentityPassphrase = "keydrd-client"

    // MARK: - Certificate Pinning

    /// Verify peer certificate against stored Mac cert fingerprint from Keychain.
    private func verifyPeerCertificate(_ trust: sec_trust_t) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let peerCert = certChain.first else {
            print("[CONSOLE] WirelessTransport cert verify: NO peer certificate")
            log.error("Certificate verify: no peer certificate")
            return false
        }

        let peerCertData = SecCertificateCopyData(peerCert) as Data
        let fingerprint = SHA256.hash(data: peerCertData)
        let peerFingerprint = Data(fingerprint)

        guard let storedFingerprint = loadStoredPeerFingerprint() else {
            print("[CONSOLE] WirelessTransport cert verify: NO stored fingerprint (not paired?)")
            log.error("Certificate verify: no stored peer fingerprint (not paired)")
            return false
        }

        let match = peerFingerprint == storedFingerprint
        if !match {
            print("[CONSOLE] WirelessTransport cert verify: MISMATCH -- rejecting")
            log.error("Certificate verify: peer cert fingerprint MISMATCH -- rejecting")
        } else {
            print("[CONSOLE] WirelessTransport cert verify: MATCH -- trusted")
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

    private func loadProvisionedClientIdentity() -> SecIdentity? {
        let certificateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: clientCertificateDERAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let privateKeyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: clientPrivateKeyRepresentationAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var certificateResult: CFTypeRef?
        var privateKeyResult: CFTypeRef?
        if SecItemCopyMatching(certificateQuery as CFDictionary, &certificateResult) == errSecSuccess,
           SecItemCopyMatching(privateKeyQuery as CFDictionary, &privateKeyResult) == errSecSuccess,
           let certificateDER = certificateResult as? Data,
           let privateKeyRepresentation = privateKeyResult as? Data {
            let keyAttrs: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256,
            ]
            var keyError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(
                privateKeyRepresentation as CFData,
                keyAttrs as CFDictionary,
                &keyError
            ) else {
                log.error("Failed to import provisioned client private key: \(String(describing: keyError?.takeRetainedValue()))")
                return nil
            }
            guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
                  let identity = SecIdentityCreate(nil, certificate, privateKey) else {
                log.error("Failed to assemble provisioned client identity from stored certificate + private key")
                return nil
            }
            return identity
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: clientIdentityPKCS12Account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let pkcs12Data = result as? Data else {
            log.error("Missing provisioned client identity")
            return nil
        }

        var status: OSStatus = errSecSuccess
        guard let identity = KeydPKCS12ImportCopyIdentity(
            pkcs12Data,
            provisionedClientIdentityPassphrase,
            &status
        ) else {
            log.error("Failed to import provisioned client identity: \(status)")
            return nil
        }
        if status != errSecSuccess {
            log.warning("SecPKCS12Import returned status \(status), but an identity was still provided")
        }

        return identity
    }

    // MARK: - TLS/DTLS Parameter Configuration

    /// Create TLS 1.3 parameters for TCP connections with certificate pinning.
    private func createSecureTCPParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)
        if let identity = loadProvisionedClientIdentity(),
           let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                secIdentity
            )
        }

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                guard let self = self else {
                    complete(false)
                    return
                }
                let trusted = self.verifyPeerCertificate(trust)
                complete(trusted)
            }, DispatchQueue.global())

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.includePeerToPeer = true
        return params
    }

    /// Create DTLS parameters for UDP connections with certificate pinning.
    private func createSecureUDPParameters() -> NWParameters {
        let dtlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            dtlsOptions.securityProtocolOptions, .TLSv13)
        if let identity = loadProvisionedClientIdentity(),
           let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(
                dtlsOptions.securityProtocolOptions,
                secIdentity
            )
        }

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
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Public API

    /// Start browsing for the Mac's Bonjour service.
    /// Enables peer-to-peer (AWDL) discovery.
    func startBrowsing() {
        guard browser == nil else { return }

        log.info("Starting Bonjour browse for \(keydrdService) (TLS/DTLS enabled)")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: keydrdService, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)
        browser = newBrowser

        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] Bonjour browser ready for \(keydrdService)")
                self.log.info("Bonjour browser ready")
            case .failed(let error):
                print("[CONSOLE] Bonjour browser FAILED: \(error)")
                self.log.error("Bonjour browser failed: \(error)")
            case .cancelled:
                print("[CONSOLE] Bonjour browser cancelled")
                self.log.info("Bonjour browser cancelled")
            default:
                print("[CONSOLE] Bonjour browser state: \(state)")
                break
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }

            print("[CONSOLE] Bonjour browse results changed: \(results.count) results, \(changes.count) changes")
            for change in changes {
                switch change {
                case .added(let result):
                    print("[CONSOLE] Bonjour service FOUND: \(result.endpoint.debugDescription)")
                    self.log.info("Bonjour service found: \(result.endpoint.debugDescription)")

                    // Guard against re-entry: NWBrowser fires .added for every
                    // interface (Wi-Fi, AWDL) the same service appears on.
                    // Only connect on the first event; ignore the rest.
                    if self.isConnected || self.connectedServiceName != nil {
                        print("[CONSOLE] Bonjour: ignoring duplicate .added (already connected/connecting to '\(self.connectedServiceName ?? "?")')")
                        self.log.info("Ignoring duplicate .added — already connected/connecting")
                        continue
                    }

                    if case .service(let name, _, _, _) = result.endpoint {
                        self.connectedServiceName = name
                    }
                    self.connectToService(endpoint: result.endpoint)

                case .removed(let result):
                    print("[CONSOLE] Bonjour service LOST: \(result.endpoint.debugDescription)")
                    self.log.info("Bonjour service lost: \(result.endpoint.debugDescription)")

                    // Only tear down if the removed service is the one we are connected to.
                    if case .service(let name, _, _, _) = result.endpoint,
                       name == self.connectedServiceName {
                        print("[CONSOLE] Bonjour: connected service '\(name)' removed — tearing down")
                        self.log.info("Connected service removed — tearing down")
                        self.tearDownConnections()
                        self.onConnectionChanged?(false, false)
                    }

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

        print("[CONSOLE] WirelessTransport: connecting to \(endpoint.debugDescription)")
        log.info("Connecting with TLS to discovered Mac service: \(endpoint.debugDescription)")

        // TLS 1.3-encrypted TCP connection for input
        let tcpParams = createSecureTCPParameters()

        let inputConn = NWConnection(to: endpoint, using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                print("[CONSOLE] WirelessTransport: TLS TCP connection READY")
                self.log.info("TLS wireless TCP connection ready")

                // Determine if AWDL or Wi-Fi via connection path interface type
                let detectedAWDL = self.detectAWDL(connection: inputConn)
                self.isAWDL = detectedAWDL
                self.isConnected = true

                print("[CONSOLE] WirelessTransport: AWDL=\(detectedAWDL), calling onConnectionChanged")
                self.log.info("Wireless transport: AWDL=\(detectedAWDL)")
                self.onConnectionChanged?(true, detectedAWDL)

                self.scheduleInputReceive(inputConn)
                self.establishMediaConnection(from: inputConn)

            case .failed(let error):
                print("[CONSOLE] WirelessTransport: TLS TCP connection FAILED: \(error)")
                self.log.error("TLS wireless TCP connection failed: \(error)")
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
        // Extract the remote host from the TCP connection to create a DTLS-encrypted UDP media path
        guard let path = tcpConnection.currentPath,
              let remoteEndpoint = path.remoteEndpoint else {
            log.warning("Cannot establish DTLS media connection: no remote endpoint")
            return
        }

        // Extract host from the remote endpoint
        let host: NWEndpoint.Host
        let mediaPort = NWEndpoint.Port(rawValue: keydrdMediaPort)!

        switch remoteEndpoint {
        case .hostPort(let h, _):
            host = h
        default:
            log.warning("Cannot extract host from endpoint: \(remoteEndpoint.debugDescription)")
            return
        }

        let udpParams = createSecureUDPParameters()

        // Bind the DTLS media path to the same interface class as the TCP path.
        // `availableInterfaces.first` is unstable when both Wi-Fi and peer-to-peer
        // are available, which can move media onto the wrong path.
        let prefersAWDL = detectAWDL(connection: tcpConnection)
        let requiredType: NWInterface.InterfaceType = prefersAWDL ? .other : .wifi
        if let pathInterface = path.availableInterfaces.first(where: { $0.type == requiredType })
            ?? path.availableInterfaces.first(where: { $0.type != .loopback }) {
            udpParams.requiredInterface = pathInterface
        }

        let mediaEndpoint = NWEndpoint.hostPort(host: host, port: mediaPort)
        let mediaConn = NWConnection(to: mediaEndpoint, using: udpParams)
        mediaConnection = mediaConn

        mediaConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] WirelessTransport: DTLS UDP media connection READY")
                self.log.info("DTLS wireless media UDP connection ready")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                print("[CONSOLE] WirelessTransport: DTLS UDP media FAILED: \(error)")
                self.log.error("DTLS wireless media UDP connection failed: \(error)")
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

    private var mediaRecvCount = 0

    private func scheduleMediaReceive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if error == nil {
                /* Keep the DTLS receive pipeline armed before we hand the
                 * datagram to reassembly/decode. Media processing can be
                 * expensive enough to starve receive callbacks under load if
                 * we wait to reschedule until after it completes. */
                self.scheduleMediaReceive(connection)
            }

            if let data = content, !data.isEmpty {
                self.mediaRecvCount += 1
                if self.mediaRecvCount <= 3 {
                    print("[CONSOLE] WirelessTransport: UDP media recv #\(self.mediaRecvCount) (\(data.count) bytes)")
                }
                self.pendingMediaCallbacks += 1
                self.maxPendingMediaCallbacks = max(self.maxPendingMediaCallbacks, self.pendingMediaCallbacks)
                let backlog = self.pendingMediaCallbacks
                if backlog >= 8 && (backlog == 8 || backlog % 16 == 0) {
                    print("[CONSOLE] WirelessTransport: media processing backlog=\(backlog) max=\(self.maxPendingMediaCallbacks)")
                }
                self.mediaProcessingQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.onMediaReceived?(data)
                    self.transportQueue.async { [weak self] in
                        guard let self = self else { return }
                        self.pendingMediaCallbacks = max(0, self.pendingMediaCallbacks - 1)
                    }
                }
            }

            if let error = error {
                print("[CONSOLE] WirelessTransport: UDP media recv error: \(error)")
                return
            }
            /* For DTLS/UDP: ignore isComplete. Each datagram from the sender has
             * is_complete=true (required by DTLS), but this does NOT mean the
             * connection is closed. */
        }
    }

    private func scheduleInputReceive(_ connection: NWConnection) {
        // Read up to 256KB at a time — large enough for most HEVC frames.
        // Data arrives with 4-byte big-endian length prefix per message.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.tcpBuffer.append(data)
                self.drainTCPBuffer()
            }

            if let error = error {
                print("[CONSOLE] WirelessTransport: TCP receive error: \(error)")
                return
            }
            if isComplete {
                print("[CONSOLE] WirelessTransport: TCP receive complete (EOF)")
                return
            }
            self.scheduleInputReceive(connection)
        }
    }

    /// Extract complete length-prefixed messages from the TCP reassembly buffer.
    /// Format: [4 bytes big-endian length][payload of that length]
    private func drainTCPBuffer() {
        while tcpBuffer.count >= 4 {
            let msgLen = tcpBuffer.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                var raw: UInt32 = 0
                memcpy(&raw, base, 4)
                return Int(UInt32(bigEndian: raw))
            }

            guard msgLen > 0, msgLen < 4_000_000 else {
                // Invalid length — likely corrupt data, clear buffer
                print("[CONSOLE] WirelessTransport: invalid TCP frame length \(msgLen), clearing buffer")
                tcpBuffer.removeAll()
                return
            }

            guard tcpBuffer.count >= 4 + msgLen else {
                // Incomplete message — wait for more data
                return
            }

            // Extract complete message
            let message = tcpBuffer.subdata(in: 4..<(4 + msgLen))
            tcpBuffer.removeSubrange(0..<(4 + msgLen))

            onInputReceived?(message)
        }
    }

    // MARK: - Private: Teardown

    private func tearDownConnections() {
        mediaConnection?.cancel()
        mediaConnection = nil
        inputConnection?.cancel()
        inputConnection = nil
        connectedServiceName = nil
        tcpBuffer.removeAll()
        isConnected = false
        isAWDL = false
    }

    deinit {
        stopBrowsing()
    }
}
