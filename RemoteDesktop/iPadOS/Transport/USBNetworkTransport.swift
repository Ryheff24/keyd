import Foundation
import Network
import Security
import CryptoKit
import os.log
import Darwin.POSIX.net  // getifaddrs, ifaddrs

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

    private var pollTimer: DispatchSourceTimer?
    private var detectedLocalIP: String?
    private var detectedMacIP: String?
    private let monitorQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.monitor")
    private let transportQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.transport")

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    /// TCP reassembly buffer for length-prefixed messages.
    private var tcpBuffer = Data()
    /// Read cursor into tcpBuffer to avoid O(n) front-removal on every frame.
    private var tcpBufferReadOffset = 0
    private var tcpDrainInvocationCount = 0
    private var tcpCompactionCount = 0
    private var tcpMessagesDelivered = 0
    private static let tcpCompactionMinConsumedBytes = 2 << 20

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "USBTransport")

    private let keychainService = "com.ryheff.keyd.remote.app"
    private let clientIdentityPKCS12Account = "client-identity-p12"
    private let clientCertificateDERAccount = "client-cert-der"
    private let clientPrivateKeyRepresentationAccount = "client-private-key"
    private let provisionedClientIdentityPassphrase = "keydrd-client"

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
    /// No cleartext fallback -- if TLS handshake fails, connection fails.
    private func createSecureTCPParameters(interface: NWInterface) -> NWParameters {
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
        params.requiredInterface = interface
        return params
    }

    /// Create DTLS parameters for UDP connections with certificate pinning.
    /// No cleartext fallback -- if DTLS handshake fails, connection fails.
    private func createSecureUDPParameters(interface: NWInterface) -> NWParameters {
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
        params.requiredInterface = interface
        params.requiredLocalEndpoint = nil
        return params
    }

    // MARK: - USB NCM Interface Detection

    /// Check if an interface looks like a USB NCM interface.
    /// USB NCM on iPad may report as `.wiredEthernet` OR `.other` depending on
    /// iOS version and how the USB-C Ethernet gadget driver presents itself.
    /// We match by: type is wiredEthernet, OR name starts with "en" / "bridge"
    /// and type is `.other` (excluding known non-NCM like awdl0, llw0, utun*, lo0).
    private func isUSBNCMInterface(_ interface: NWInterface) -> Bool {
        let name = interface.name

        // Definite match: wiredEthernet type
        if interface.type == .wiredEthernet {
            return true
        }

        // Heuristic match: type == .other with NCM-like interface name
        // USB NCM commonly appears as en2..en15 or bridgeXXX on iPad
        if interface.type == .other {
            // Exclude known non-USB interfaces that also report as .other
            let excluded = ["awdl0", "llw0", "anpi0", "anpi1"]
            if excluded.contains(name) { return false }
            if name.hasPrefix("utun") { return false }
            if name.hasPrefix("ipsec") { return false }

            // Match enN where N >= 1 (en0 is typically built-in Wi-Fi on Mac,
            // but on iPad there is no en0 -- USB NCM is enN with N >= 1)
            if name.hasPrefix("en") {
                let suffix = String(name.dropFirst(2))
                if let n = Int(suffix), n >= 1 {
                    return true
                }
            }

            // bridge interfaces used by NCM
            if name.hasPrefix("bridge") {
                return true
            }
        }

        return false
    }

    /// Log every interface in a path for debugging.
    private func logAllInterfaces(in path: NWPath, label: String) {
        var count = 0
        for interface in path.availableInterfaces {
            let typeName: String
            switch interface.type {
            case .wifi: typeName = "wifi"
            case .cellular: typeName = "cellular"
            case .wiredEthernet: typeName = "wiredEthernet"
            case .loopback: typeName = "loopback"
            case .other: typeName = "other"
            @unknown default: typeName = "unknown"
            }
            print("[CONSOLE] [\(label)] interface[\(count)]: name=\(interface.name) type=\(typeName) index=\(interface.index)")
            count += 1
        }
        if count == 0 {
            print("[CONSOLE] [\(label)] no interfaces available")
        }
    }

    // MARK: - USB NCM Detection via getifaddrs

    /// Scan kernel interfaces for a USB NCM link-local address.
    ///
    /// NWPathMonitor cannot detect USB NCM interfaces — they only have
    /// 169.254.x.x link-local IPs with no routes, making them "unsatisfied."
    /// We use getifaddrs() to directly enumerate kernel interfaces.
    private func detectUSBNCMInterface() -> (ip: String, name: String)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let firstAddr = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var ifa: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ifa {
            defer { ifa = addr.pointee.ifa_next }

            guard let sockaddr = addr.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == AF_INET else { continue }

            let flags = addr.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let sin = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)

            // Link-local range: 169.254.0.0/16
            guard (ip & 0xFFFF0000) == 0xA9FE0000 else { continue }

            let name = String(cString: addr.pointee.ifa_name)

            // Skip known non-USB interfaces
            if name == "en0" { continue }   // Wi-Fi
            if name.hasPrefix("awdl") { continue }
            if name.hasPrefix("llw") { continue }
            if name.hasPrefix("utun") { continue }
            if name.hasPrefix("lo") { continue }
            if name.hasPrefix("ap") { continue }

            var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinCopy = sin
            inet_ntop(AF_INET, &sinCopy.sin_addr, &addrBuf, socklen_t(INET_ADDRSTRLEN))
            let ipStr = String(cString: addrBuf)

            print("[CONSOLE] USB NCM candidate: \(name) = \(ipStr)")
            return (ip: ipStr, name: name)
        }

        return nil
    }

    // MARK: - Public API

    /// Start polling for USB NCM interfaces via getifaddrs().
    ///
    /// NWPathMonitor cannot detect USB NCM interfaces because they only
    /// have 169.254.x.x link-local IPs with no routes. We poll every 2s.
    func startMonitoring() {
        guard pollTimer == nil else { return }

        print("[CONSOLE] Starting USB NCM interface polling via getifaddrs (TLS/DTLS enabled)")
        log.info("Starting USB NCM interface polling via getifaddrs")

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if let ncm = self.detectUSBNCMInterface() {
                if ncm.ip != self.detectedLocalIP {
                    print("[CONSOLE] USB NCM interface detected: \(ncm.name) = \(ncm.ip)")
                    self.log.info("USB NCM interface detected: \(ncm.name) = \(ncm.ip)")
                    self.detectedLocalIP = ncm.ip
                    self.connectOverUSBNCMByIP(localIP: ncm.ip)
                    self.onInterfaceChanged?(true, nil)
                }
            } else {
                if self.detectedLocalIP != nil {
                    print("[CONSOLE] USB NCM interface disappeared")
                    self.log.info("USB NCM interface disappeared")
                    self.tearDownConnections()
                    self.activeInterface = nil
                    self.detectedLocalIP = nil
                    self.isConnected = false
                    self.onInterfaceChanged?(false, nil)
                }
            }
        }

        timer.resume()
        pollTimer = timer
    }

    /// Stop monitoring and tear down all connections.
    func stopMonitoring() {
        pollTimer?.cancel()
        pollTimer = nil
        tearDownConnections()
        activeInterface = nil
        detectedLocalIP = nil
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

    /// Set the Mac's IP address (from QR payload) for USB NCM direct connection.
    /// Called after pairing when the Mac's link-local IP is known.
    func setPeerAddress(_ ip: String) {
        print("[CONSOLE] USBTransport: peer address set to \(ip)")
        log.info("Peer address set to \(ip)")
        detectedMacIP = ip
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

    /// Connect to the Mac over USB NCM using a specific IP (no NWInterface required).
    ///
    /// NWPathMonitor can't provide an NWInterface for USB NCM (link-local only).
    /// Instead, we connect directly to the Mac's link-local IP.
    private func connectOverUSBNCMByIP(localIP: String) {
        guard let macIP = detectedMacIP else {
            print("[CONSOLE] USBTransport: cannot connect — no peer address set (call setPeerAddress first)")
            log.warning("Cannot connect via USB NCM: no peer address")
            return
        }

        tearDownConnections()

        print("[CONSOLE] USBTransport: connecting to Mac at \(macIP) via USB NCM (local=\(localIP))")
        log.info("Connecting to Mac at \(macIP) via USB NCM (local=\(localIP))")

        let host = NWEndpoint.Host(macIP)

        // Bind to local USB NCM IP to force traffic through the correct interface.
        // Without this, macOS/iOS may route link-local traffic over WiFi.
        let localEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(localIP), port: 0)

        // DTLS-encrypted UDP for media (port 14567)
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
            { [weak self] _, trust, complete in
                complete(self?.verifyPeerCertificate(trust) ?? false)
            }, DispatchQueue.global())

        let udpParams = NWParameters(dtls: dtlsOptions, udp: .init())
        udpParams.requiredLocalEndpoint = localEndpoint

        let mediaPort = NWEndpoint.Port(rawValue: keydrdMediaPort)!
        let mediaEndpoint = NWEndpoint.hostPort(host: host, port: mediaPort)
        let mediaConn = NWConnection(to: mediaEndpoint, using: udpParams)
        mediaConnection = mediaConn

        mediaConn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] USBTransport: DTLS media connection READY")
                self.log.info("USB NCM DTLS media connection ready (IP-based)")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                print("[CONSOLE] USBTransport: DTLS media FAILED: \(error)")
                self.log.error("USB NCM DTLS media failed: \(error)")
                self.mediaConnection = nil
                if self.inputConnection == nil { self.isConnected = false }
            default: break
            }
        }
        mediaConn.start(queue: transportQueue)

        // TLS 1.3-encrypted TCP for input (port 14568)
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)
        if let identity = loadProvisionedClientIdentity(),
           let secIdentity2 = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                secIdentity2
            )
        }
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { [weak self] _, trust, complete in
                complete(self?.verifyPeerCertificate(trust) ?? false)
            }, DispatchQueue.global())

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let tcpParams = NWParameters(tls: tlsOptions, tcp: tcpOpts)
        tcpParams.requiredLocalEndpoint = localEndpoint

        let inputPort = NWEndpoint.Port(rawValue: keydrdInputPort)!
        let inputEndpoint = NWEndpoint.hostPort(host: host, port: inputPort)
        let inputConn = NWConnection(to: inputEndpoint, using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] USBTransport: TLS input connection READY")
                self.log.info("USB NCM TLS input connection ready (IP-based)")
                self.isConnected = true
                self.scheduleInputReceive(inputConn)
            case .failed(let error):
                print("[CONSOLE] USBTransport: TLS input FAILED: \(error)")
                self.log.error("USB NCM TLS input failed: \(error)")
                self.inputConnection = nil
                if self.mediaConnection == nil { self.isConnected = false }
            case .waiting(let error):
                print("[CONSOLE] USBTransport: TLS input WAITING: \(error) — will retry in 0.5s")
                // NWConnection retry for link-local TCP is unreliable.
                // Cancel and reconnect after a short delay.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.detectedLocalIP != nil, self.detectedMacIP != nil else { return }
                    if self.inputConnection?.state != .ready {
                        print("[CONSOLE] USBTransport: retrying TCP connection")
                        self.inputConnection?.cancel()
                        self.inputConnection = nil
                        self.retryTCPConnection(macIP: self.detectedMacIP!, localIP: self.detectedLocalIP!)
                    }
                }
            default: break
            }
        }
        inputConn.start(queue: transportQueue)
    }

    /// Retry just the TCP input connection (used when initial attempt is refused).
    private func retryTCPConnection(macIP: String, localIP: String) {
        let host = NWEndpoint.Host(macIP)
        let localEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(localIP), port: 0)

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
            { [weak self] _, trust, complete in
                complete(self?.verifyPeerCertificate(trust) ?? false)
            }, DispatchQueue.global())

        let retryTcpOpts = NWProtocolTCP.Options()
        retryTcpOpts.noDelay = true
        let tcpParams = NWParameters(tls: tlsOptions, tcp: retryTcpOpts)
        tcpParams.requiredLocalEndpoint = localEndpoint

        let inputPort = NWEndpoint.Port(rawValue: keydrdInputPort)!
        let inputConn = NWConnection(to: NWEndpoint.hostPort(host: host, port: inputPort), using: tcpParams)
        inputConnection = inputConn

        inputConn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] USBTransport: TLS input READY (retry)")
                self.log.info("USB NCM TLS input ready (retry)")
                self.isConnected = true
                self.scheduleInputReceive(inputConn)
            case .failed(let error):
                print("[CONSOLE] USBTransport: TLS input FAILED (retry): \(error)")
            case .waiting(let error):
                print("[CONSOLE] USBTransport: TLS input still WAITING (retry): \(error)")
            default: break
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                let beforeCount = self.tcpBuffer.count
                self.tcpBuffer.reserveCapacity(beforeCount + data.count + (256 << 10))
                self.tcpBuffer.append(data)
                let afterCount = self.tcpBuffer.count
                if beforeCount == 0 || afterCount >= (2 << 20) || afterCount % (1 << 20) < data.count {
                    print("[CONSOLE] USBTransport: tcp-recv append=\(data.count)B buffer=\(afterCount)B readOffset=\(self.tcpBufferReadOffset)")
                    self.log.info("USB TCP recv append=\(data.count, privacy: .public)B buffer=\(afterCount, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public)")
                }
                self.drainUSBTCPBuffer()
            }

            if error != nil || isComplete { return }
            self.scheduleInputReceive(connection)
        }
    }

    /// Extract complete length-prefixed messages from the USB TCP reassembly buffer.
    private func drainUSBTCPBuffer() {
        tcpDrainInvocationCount += 1
        let drainStart = CFAbsoluteTimeGetCurrent()
        let startBufferCount = tcpBuffer.count
        let startReadOffset = tcpBufferReadOffset
        var deliveredThisDrain = 0

        while (tcpBuffer.count - tcpBufferReadOffset) >= 4 {
            let msgLen = tcpBuffer.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                var raw: UInt32 = 0
                memcpy(&raw, base.advanced(by: tcpBufferReadOffset), 4)
                return Int(UInt32(bigEndian: raw))
            }

            guard msgLen > 0, msgLen < 4_000_000 else {
                print("[CONSOLE] USBTransport: invalid TCP frame length \(msgLen), clearing buffer")
                self.log.error("USB TCP drain invalid-length msgLen=\(msgLen, privacy: .public) clearing buffer=\(self.tcpBuffer.count, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public)")
                tcpBuffer.removeAll()
                tcpBufferReadOffset = 0
                return
            }

            guard (tcpBuffer.count - tcpBufferReadOffset) >= 4 + msgLen else {
                let available = tcpBuffer.count - tcpBufferReadOffset
                if available >= (1 << 20) {
                    print("[CONSOLE] USBTransport: tcp-drain partial msgLen=\(msgLen) available=\(available)B buffer=\(tcpBuffer.count)B")
                    self.log.info("USB TCP drain partial msgLen=\(msgLen, privacy: .public) available=\(available, privacy: .public)B buffer=\(self.tcpBuffer.count, privacy: .public)B")
                }
                break
            }

            let msgStart = tcpBufferReadOffset + 4
            let msgEnd = msgStart + msgLen
            let message = tcpBuffer.subdata(in: msgStart..<msgEnd)
            tcpBufferReadOffset = msgEnd
            deliveredThisDrain += 1
            tcpMessagesDelivered += 1
            onInputReceived?(message)
        }

        // Compact only when consumed bytes dominate unread bytes to avoid frequent O(n) memmove churn.
        let consumedBytes = tcpBufferReadOffset
        let unreadBytes = tcpBuffer.count - tcpBufferReadOffset
        if consumedBytes >= Self.tcpCompactionMinConsumedBytes &&
            (unreadBytes == 0 || consumedBytes >= (unreadBytes * 3)) {
            let compactStart = CFAbsoluteTimeGetCurrent()
            tcpBuffer.removeSubrange(0..<tcpBufferReadOffset)
            tcpBufferReadOffset = 0
            tcpCompactionCount += 1
            let compactElapsedMs = (CFAbsoluteTimeGetCurrent() - compactStart) * 1000.0
            print("[CONSOLE] USBTransport: tcp-compact #\(tcpCompactionCount) consumed=\(consumedBytes)B unread=\(unreadBytes)B elapsed=\(String(format: "%.2f", compactElapsedMs))ms newBuffer=\(tcpBuffer.count)B")
            self.log.info("USB TCP compact #\(self.tcpCompactionCount, privacy: .public) consumed=\(consumedBytes, privacy: .public)B unread=\(unreadBytes, privacy: .public)B elapsedMs=\(compactElapsedMs, privacy: .public) newBuffer=\(self.tcpBuffer.count, privacy: .public)B")
        } else if consumedBytes > 0 && (consumedBytes % (2 << 20) == 0) {
            print("[CONSOLE] USBTransport: tcp-drain hold consumed=\(consumedBytes)B unread=\(unreadBytes)B buffer=\(tcpBuffer.count)B")
            self.log.info("USB TCP drain hold consumed=\(consumedBytes, privacy: .public)B unread=\(unreadBytes, privacy: .public)B buffer=\(self.tcpBuffer.count, privacy: .public)B")
        }

        let drainElapsedMs = (CFAbsoluteTimeGetCurrent() - drainStart) * 1000.0
        if deliveredThisDrain > 0 && (drainElapsedMs > 4.0 || deliveredThisDrain >= 8 || tcpDrainInvocationCount <= 8) {
            print("[CONSOLE] USBTransport: tcp-drain delivered=\(deliveredThisDrain) elapsed=\(String(format: "%.2f", drainElapsedMs))ms start=\(startBufferCount)B/\(startReadOffset) end=\(tcpBuffer.count)B/\(tcpBufferReadOffset) totalMsgs=\(tcpMessagesDelivered)")
            self.log.info("USB TCP drain delivered=\(deliveredThisDrain, privacy: .public) elapsedMs=\(drainElapsedMs, privacy: .public) startBuf=\(startBufferCount, privacy: .public)B startOffset=\(startReadOffset, privacy: .public) endBuf=\(self.tcpBuffer.count, privacy: .public)B endOffset=\(self.tcpBufferReadOffset, privacy: .public) totalMsgs=\(self.tcpMessagesDelivered, privacy: .public)")
        }
    }

    // MARK: - Private: Teardown

    private func tearDownConnections() {
        mediaConnection?.cancel()
        mediaConnection = nil
        inputConnection?.cancel()
        inputConnection = nil
        // Clear tcpBuffer on transportQueue to avoid data race with
        // drainUSBTCPBuffer running on the same queue from receive callbacks.
        transportQueue.async { [weak self] in
            self?.tcpBuffer.removeAll()
            self?.tcpBufferReadOffset = 0
        }
    }

    deinit {
        stopMonitoring()
    }
}
