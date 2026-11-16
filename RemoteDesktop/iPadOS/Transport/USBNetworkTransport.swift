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
    private var detectedMacLinkLocalIP: String?
    /// AddrOnLink (tla/PLAN.md): learn the Mac's USB address on the USB link itself.
    private var detectedLocalIfName: String?
    private var usbBrowser: NWBrowser?
    private var usbConnectRetryPending = false
    private static let usbServiceType = "_keydrd-usb._tcp"
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
    private var tcpReceiveErrorCount = 0
    private var tcpReceiveCompleteCount = 0
    private var mediaReceiveErrorCount = 0
    private var mediaReceiveCompleteCount = 0
    private var inputReceiveConfigLogged = false
    private var tcpRecvAppendLogCount = 0
    private var tcpPartialLogCount = 0
    private var tcpCompactLogCount = 0
    private var tcpHoldLogCount = 0
    private var tcpDrainDeliveredLogCount = 0
    private var tcpBufferReservedCapacity = 0
    private var tcpBufferGrowthLogCount = 0
    private static let tcpRecvAppendLogInterval = 2048
    private static let tcpPartialLogInterval = 16
    private static let tcpCompactLogInterval = 16
    private static let tcpHoldLogInterval = 8
    private static let tcpDrainDeliveredLogInterval = 64
    private static let tcpBufferGrowthLogInterval = 16
    private static let tcpCompactionMinConsumedBytes = 8 << 20
    private static let tcpReceiveMaxLength = 1 << 20
    /// Upper bound on one framed TCP message. Lossless LZ4 keyframes at 2752x1786 BGRA
    /// (19.66 MB raw) were 4.25 MB on the E2E capture and can approach LZ4_compressBound
    /// (~19.7 MB) on incompressible content. The old 4 MB cap rejected real keyframes,
    /// cleared the buffer and lost framing for the rest of the session (2026-11-15).
    private static let tcpMaxFrameLength = 32 << 20
    private static let tcpReserveBaseCapacity = 1 << 20

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
                    self.detectedLocalIfName = ncm.name
                    self.startUSBBrowse()

                    if let linkLocal = self.detectedMacLinkLocalIP {
                        // Have link-local peer from a previous peerAddressUpdate — connect + notify
                        print("[CONSOLE] USB NCM: have link-local peer \(linkLocal) — connecting and firing wiredAppeared")
                        self.connectOverUSBNCMByIP(localIP: ncm.ip)
                        self.onInterfaceChanged?(true, nil)
                    } else {
                        // No link-local peer yet. Don't fire wiredAppeared — we can't connect.
                        // The USB browse (AddrOnLink) or a Wi-Fi peerAddressUpdate delivers it;
                        // setPeerAddress() fires onInterfaceChanged when the IP arrives.
                        print("[CONSOLE] USB NCM: no link-local peer yet — browsing \(Self.usbServiceType) on \(ncm.name)")
                    }
                }
            } else {
                if self.detectedLocalIP != nil {
                    print("[CONSOLE] USB NCM interface disappeared")
                    self.log.info("USB NCM interface disappeared")
                    self.stopUSBBrowse()
                    self.tearDownConnections()
                    self.activeInterface = nil
                    self.detectedLocalIP = nil
                    self.detectedLocalIfName = nil
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
        monitorQueue.async { [weak self] in self?.stopUSBBrowse() }
        tearDownConnections()
        activeInterface = nil
        detectedLocalIP = nil
        detectedLocalIfName = nil
        isConnected = false
    }

    // MARK: - AddrOnLink: discover the Mac on the USB NCM link

    /// Browse for the Mac's USB service while the NCM interface is up. Runs on monitorQueue.
    /// The Mac registers `_keydrd-usb._tcp` on its NCM interface only, with `ip=<link-local>`
    /// in the TXT record. Results not seen on our NCM interface are ignored.
    private func startUSBBrowse() {
        stopUSBBrowse()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.usbServiceType, domain: "local."),
                                using: params)
        browser.stateUpdateHandler = { state in
            print("[CONSOLE] USB browse state: \(state)")
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self = self, let browser = browser, browser === self.usbBrowser else {
                print("[CONSOLE] USB browse: results from stale browser ignored")
                return
            }
            self.handleUSBBrowseResults(results)
        }
        usbBrowser = browser
        print("[CONSOLE] USB browse: start type=\(Self.usbServiceType) ncm=\(detectedLocalIfName ?? "nil")")
        browser.start(queue: monitorQueue)
    }

    private func stopUSBBrowse() {
        if let browser = usbBrowser {
            print("[CONSOLE] USB browse: stop")
            browser.cancel()
            usbBrowser = nil
        }
    }

    private func handleUSBBrowseResults(_ results: Set<NWBrowser.Result>) {
        let ncmName = detectedLocalIfName
        print("[CONSOLE] USB browse: \(results.count) result(s), ncm=\(ncmName ?? "nil")")
        var candidate: String?
        for result in results {
            let ifNames = result.interfaces.map { $0.name }
            var ip: String?
            if case .bonjour(let txt) = result.metadata {
                ip = txt["ip"]
            }
            let onNCM = ncmName != nil && ifNames.contains(ncmName!)
            print("[CONSOLE] USB browse result: endpoint=\(result.endpoint) interfaces=\(ifNames) txtIP=\(ip ?? "nil") onNCM=\(onNCM)")
            guard onNCM, let ip = ip, isLinkLocal(ip) else { continue }
            candidate = ip
        }
        guard let ip = candidate else {
            print("[CONSOLE] USB browse: no usable result on NCM yet")
            return
        }
        let unchanged = (ip == detectedMacLinkLocalIP)
        if unchanged && (isConnected || inputConnection != nil) {
            print("[CONSOLE] USB browse: Mac link-local \(ip) unchanged and connection exists — no action")
            return
        }
        print("[CONSOLE] USB browse: learned Mac link-local \(ip) on \(ncmName ?? "nil") (previous=\(detectedMacLinkLocalIP ?? "nil"), connected=\(isConnected))")
        if !unchanged && isConnected {
            // Address changed under a live connection (re-plug): drop it so setPeerAddress re-dials.
            print("[CONSOLE] USB browse: address changed while connected — tearing down for re-dial")
            tearDownConnections()
            isConnected = false
        }
        setPeerAddress(ip)
    }

    /// Retry the USB connect while the cable is in (AddrOnLink: "retries while the cable is in").
    private func scheduleUSBConnectRetry(reason: String) {
        guard !usbConnectRetryPending else { return }
        usbConnectRetryPending = true
        print("[CONSOLE] USB retry: scheduled in 1.0s reason=\(reason)")
        monitorQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.usbConnectRetryPending = false
            guard let localIP = self.detectedLocalIP, self.detectedMacLinkLocalIP != nil else {
                print("[CONSOLE] USB retry: skipped (ncm=\(self.detectedLocalIP ?? "nil"), mac=\(self.detectedMacLinkLocalIP ?? "nil"))")
                return
            }
            guard !self.isConnected else {
                print("[CONSOLE] USB retry: skipped (already connected)")
                return
            }
            print("[CONSOLE] USB retry: re-dialing \(self.detectedMacLinkLocalIP!) from \(localIP)")
            self.connectOverUSBNCMByIP(localIP: localIP)
        }
    }

    /// Send an input event over TCP to the Mac.
    func sendInputEvent(_ data: Data) {
        guard let connection = inputConnection else { return }
        // 4-byte big-endian length prefix (Shared/framing.h, tla/Framing.tla): TCP may split or
        // merge messages, so the Mac reassembles whole frames.
        var framed = Data(capacity: data.count + 4)
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Input send error: \(error)")
            }
        })
    }

    /// Set the Mac's IP address for USB NCM direct connection.
    /// Called from QR pairing (WiFi IP) or peer address update (USB NCM link-local IP).
    /// Link-local IPs (169.254.x.x) are stored separately and take priority for USB NCM.
    /// WiFi IPs do NOT overwrite a previously received link-local IP.
    func setPeerAddress(_ ip: String) {
        if isLinkLocal(ip) {
            print("[CONSOLE] USBTransport: link-local peer address set to \(ip)")
            log.info("Link-local peer address set to \(ip)")
            detectedMacLinkLocalIP = ip
            detectedMacIP = ip
        } else if detectedMacLinkLocalIP != nil {
            print("[CONSOLE] USBTransport: WiFi peer address \(ip) ignored — already have link-local \(detectedMacLinkLocalIP!)")
            // Keep link-local as the USB peer — WiFi IP can't be reached over USB NCM
            detectedMacIP = detectedMacLinkLocalIP
        } else {
            print("[CONSOLE] USBTransport: peer address set to \(ip) (WiFi, no link-local yet)")
            log.info("Peer address set to \(ip)")
            detectedMacIP = ip
        }

        // If USB NCM interface is already up and we have a link-local IP, connect and notify.
        if let linkLocal = detectedMacLinkLocalIP, let localIP = detectedLocalIP, !isConnected {
            print("[CONSOLE] USBTransport: link-local peer \(linkLocal) + USB NCM up — connecting and notifying FSM")
            connectOverUSBNCMByIP(localIP: localIP)
            onInterfaceChanged?(true, nil)
        }
    }

    /// Clear stored link-local IP (e.g., on pairing reset).
    func clearLinkLocalPeerAddress() {
        detectedMacLinkLocalIP = nil
    }

    private func isLinkLocal(_ ip: String) -> Bool {
        return ip.hasPrefix("169.254.")
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
                guard mediaConn === self.mediaConnection else { return }
                self.mediaConnection = nil
                if self.inputConnection == nil { self.isConnected = false }
            case .cancelled:
                guard mediaConn === self.mediaConnection else { return }
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
                print("[CONSOLE] USBTransport: TLS input FAILED (interface): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale"))")
                guard inputConn === self.inputConnection else { return }
                self.usbInputLost(inputConn, reason: "input-failed-interface")
            case .cancelled:
                guard inputConn === self.inputConnection else { return }
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
                guard mediaConn === self.mediaConnection else { return }
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
            case .setup:
                print("[CONSOLE] USBTransport: TLS input state=setup")
            case .preparing:
                print("[CONSOLE] USBTransport: TLS input state=preparing")
            case .ready:
                print("[CONSOLE] USBTransport: TLS input connection READY")
                self.log.info("USB NCM TLS input connection ready (IP-based)")
                self.isConnected = true
                self.scheduleInputReceive(inputConn)
            case .failed(let error):
                let current = inputConn === self.inputConnection
                print("[CONSOLE] USBTransport: TLS input FAILED: \(error) (connection=\(current ? "current" : "stale"))")
                self.log.error("USB NCM TLS input failed: \(error)")
                guard current else { return }
                self.usbInputLost(inputConn, reason: "input-failed")
            case .waiting(let error):
                print("[CONSOLE] USBTransport: TLS input WAITING: \(error) — will retry in 0.5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.detectedLocalIP != nil, self.detectedMacIP != nil else { return }
                    if self.inputConnection?.state != .ready {
                        print("[CONSOLE] USBTransport: retrying TCP connection")
                        self.inputConnection?.cancel()
                        self.inputConnection = nil
                        self.retryTCPConnection(macIP: self.detectedMacIP!, localIP: self.detectedLocalIP!)
                    }
                }
            case .cancelled:
                print("[CONSOLE] USBTransport: TLS input CANCELLED (connection=\(inputConn === self.inputConnection ? "current" : "stale"))")
            @unknown default:
                print("[CONSOLE] USBTransport: TLS input unknown state: \(state)")
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
                print("[CONSOLE] USBTransport: TLS input FAILED (retry): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale"))")
                guard inputConn === self.inputConnection else { return }
                self.usbInputLost(inputConn, reason: "input-failed-retry")
            case .waiting(let error):
                // Refused (agent not listening yet, e.g. a Mac agent restart) parks the
                // connection in .waiting forever; as built nothing redialled, so the session
                // stayed on wireless with the cable in. Drop it and redial on the 1 s cadence
                // while the cable is in (scheduleUSBConnectRetry stops once the interface goes).
                print("[CONSOLE] USBTransport: TLS input still WAITING (retry): \(error) (connection=\(inputConn === self.inputConnection ? "current" : "stale")) -> cancel and redial")
                guard inputConn === self.inputConnection else { return }
                inputConn.cancel()
                self.usbInputLost(inputConn, reason: "input-waiting-retry")
            default: break
            }
        }
        inputConn.start(queue: transportQueue)
    }

    /// The TLS input (TCP) connection is the USB link's liveness: frames and control ride it,
    /// and the DTLS media socket (UDP, gated off) never notices a dead peer. So losing the
    /// current input connection ends the USB link: drop the media socket too, clear
    /// isConnected (routing falls back to wireless), and redial. TransportAgreement.tla T7
    /// assumes exactly this; as built a live media socket kept isConnected true, so after a
    /// Mac agent restart the iPad sent its viewport report into the dead USB connection and
    /// the Mac never started encoding (black screen, seen 2026-11-16).
    private func usbInputLost(_ conn: NWConnection, reason: String) {
        let hadMedia = mediaConnection != nil
        let wasConnected = isConnected
        inputConnection = nil
        if let media = mediaConnection {
            mediaConnection = nil
            media.cancel()
        }
        isConnected = false
        print("[CONSOLE] USBTransport: USB link lost reason=\(reason) wasConnected=\(wasConnected) droppedMedia=\(hadMedia) -> isConnected=false, redialing")
        monitorQueue.async { [weak self] in
            self?.scheduleUSBConnectRetry(reason: reason)
        }
    }

    // MARK: - Private: Receive Loops

    private func scheduleMediaReceive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.onMediaReceived?(data)
            }

            if let error = error {
                self.mediaReceiveErrorCount += 1
                print("[CONSOLE] USBTransport: media-recv error=\(error) count=\(self.mediaReceiveErrorCount)")
                self.log.error("USB media recv error=\(String(describing: error), privacy: .public) count=\(self.mediaReceiveErrorCount, privacy: .public)")
                return
            }
            if isComplete {
                self.mediaReceiveCompleteCount += 1
                print("[CONSOLE] USBTransport: media-recv complete count=\(self.mediaReceiveCompleteCount)")
                self.log.info("USB media recv complete count=\(self.mediaReceiveCompleteCount, privacy: .public)")
                return
            }
            self.scheduleMediaReceive(connection)
        }
    }

    private func scheduleInputReceive(_ connection: NWConnection) {
        if !inputReceiveConfigLogged {
            inputReceiveConfigLogged = true
            print("[CONSOLE] USBTransport: tcp-recv config min=1B max=\(Self.tcpReceiveMaxLength)B")
            log.info("USB TCP recv config min=1B max=\(Self.tcpReceiveMaxLength, privacy: .public)B")
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.tcpReceiveMaxLength) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                let beforeCount = self.tcpBuffer.count
                self.reserveTCPBufferIfNeeded(incomingBytes: data.count, currentCount: beforeCount)
                self.tcpBuffer.append(data)
                let afterCount = self.tcpBuffer.count
                if beforeCount == 0 || afterCount >= (2 << 20) || afterCount % (1 << 20) < data.count {
                    self.tcpRecvAppendLogCount += 1
                    // Sampled only. A former `afterCount >= 4 MB` clause tested the whole buffer
                    // (including consumed bytes), so it fired on nearly every read of a lossless
                    // frame: ~4,000 print+os_log per second on the receive thread (718k lines/run).
                    if self.tcpRecvAppendLogCount <= 10 ||
                        self.tcpRecvAppendLogCount % Self.tcpRecvAppendLogInterval == 0 {
                        print("[CONSOLE] USBTransport: tcp-recv append=\(data.count)B buffer=\(afterCount)B readOffset=\(self.tcpBufferReadOffset) sample=\(self.tcpRecvAppendLogCount)")
                        self.log.info("USB TCP recv append=\(data.count, privacy: .public)B buffer=\(afterCount, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public) sample=\(self.tcpRecvAppendLogCount, privacy: .public)")
                    }
                }
                self.drainUSBTCPBuffer()
            }

            if let error = error {
                self.tcpReceiveErrorCount += 1
                print("[CONSOLE] USBTransport: tcp-recv error=\(error) count=\(self.tcpReceiveErrorCount) buffer=\(self.tcpBuffer.count)B readOffset=\(self.tcpBufferReadOffset)")
                self.log.error("USB TCP recv error=\(String(describing: error), privacy: .public) count=\(self.tcpReceiveErrorCount, privacy: .public) buffer=\(self.tcpBuffer.count, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public)")
                return
            }
            if isComplete {
                self.tcpReceiveCompleteCount += 1
                print("[CONSOLE] USBTransport: tcp-recv complete count=\(self.tcpReceiveCompleteCount) buffer=\(self.tcpBuffer.count)B readOffset=\(self.tcpBufferReadOffset)")
                self.log.info("USB TCP recv complete count=\(self.tcpReceiveCompleteCount, privacy: .public) buffer=\(self.tcpBuffer.count, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public)")
                return
            }
            self.scheduleInputReceive(connection)
        }
    }

    /// Reserve receive buffer capacity with geometric growth to avoid frequent O(n)
    /// realloc+copy churn on sustained USB TCP media ingress.
    private func reserveTCPBufferIfNeeded(incomingBytes: Int, currentCount: Int) {
        let required = currentCount + incomingBytes
        guard required > tcpBufferReservedCapacity else { return }

        let previousReserved = tcpBufferReservedCapacity
        let doubled = max(Self.tcpReserveBaseCapacity, previousReserved << 1)
        let target = max(required + (256 << 10), doubled)
        tcpBuffer.reserveCapacity(target)
        tcpBufferReservedCapacity = target

        tcpBufferGrowthLogCount += 1
        if tcpBufferGrowthLogCount <= 6 ||
            tcpBufferGrowthLogCount % Self.tcpBufferGrowthLogInterval == 0 {
            print("[CONSOLE] USBTransport: tcp-buffer-grow required=\(required)B reserved=\(target)B prevReserved=\(previousReserved)B sample=\(tcpBufferGrowthLogCount)")
            log.info("USB TCP buffer grow required=\(required, privacy: .public)B reserved=\(target, privacy: .public)B prevReserved=\(previousReserved, privacy: .public)B sample=\(self.tcpBufferGrowthLogCount, privacy: .public)")
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

            guard msgLen > 0, msgLen < Self.tcpMaxFrameLength else {
                print("[CONSOLE] USBTransport: invalid TCP frame length \(msgLen), clearing buffer")
                self.log.error("USB TCP drain invalid-length msgLen=\(msgLen, privacy: .public) max=\(Self.tcpMaxFrameLength, privacy: .public)B clearing buffer=\(self.tcpBuffer.count, privacy: .public)B readOffset=\(self.tcpBufferReadOffset, privacy: .public)")
                tcpBuffer.removeAll()
                tcpBufferReadOffset = 0
                tcpBufferReservedCapacity = 0
                return
            }

            guard (tcpBuffer.count - tcpBufferReadOffset) >= 4 + msgLen else {
                let available = tcpBuffer.count - tcpBufferReadOffset
                if available >= (1 << 20) {
                    tcpPartialLogCount += 1
                    // No "every append over 2 MB" clause: with 10 MB lossless frames that printed
                // 114k lines per run on the receive queue (2026-11-15).
                if tcpPartialLogCount <= 10 ||
                        tcpPartialLogCount % 256 == 0 {
                        print("[CONSOLE] USBTransport: tcp-drain partial msgLen=\(msgLen) available=\(available)B buffer=\(tcpBuffer.count)B sample=\(tcpPartialLogCount)")
                        self.log.info("USB TCP drain partial msgLen=\(msgLen, privacy: .public) available=\(available, privacy: .public)B buffer=\(self.tcpBuffer.count, privacy: .public)B sample=\(self.tcpPartialLogCount, privacy: .public)")
                    }
                }
                break
            }

            let msgStart = tcpBufferReadOffset + 4
            let msgEnd = msgStart + msgLen
            // Avoid per-message payload copies on the USB TCP hot path.
            // Data slicing preserves shared storage until mutation (CoW),
            // which is sufficient because onInputReceived consumes synchronously.
            let message = tcpBuffer[msgStart..<msgEnd]
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
            if unreadBytes == 0 {
                tcpBuffer.removeAll(keepingCapacity: true)
            } else {
                tcpBuffer.removeSubrange(0..<tcpBufferReadOffset)
            }
            tcpBufferReadOffset = 0
            tcpCompactionCount += 1
            let compactElapsedMs = (CFAbsoluteTimeGetCurrent() - compactStart) * 1000.0
            let mode = unreadBytes == 0 ? "reset" : "trim"
            tcpCompactLogCount += 1
            if tcpCompactLogCount <= 10 ||
                tcpCompactLogCount % Self.tcpCompactLogInterval == 0 ||
                compactElapsedMs > 4.0 {
                print("[CONSOLE] USBTransport: tcp-compact #\(tcpCompactionCount) mode=\(mode) consumed=\(consumedBytes)B unread=\(unreadBytes)B elapsed=\(String(format: "%.2f", compactElapsedMs))ms newBuffer=\(tcpBuffer.count)B threshold=\(Self.tcpCompactionMinConsumedBytes)B sample=\(tcpCompactLogCount)")
                self.log.info("USB TCP compact #\(self.tcpCompactionCount, privacy: .public) mode=\(mode, privacy: .public) consumed=\(consumedBytes, privacy: .public)B unread=\(unreadBytes, privacy: .public)B elapsedMs=\(compactElapsedMs, privacy: .public) newBuffer=\(self.tcpBuffer.count, privacy: .public)B threshold=\(Self.tcpCompactionMinConsumedBytes, privacy: .public)B sample=\(self.tcpCompactLogCount, privacy: .public)")
            }
        } else if consumedBytes > 0 && (consumedBytes % (2 << 20) == 0) {
            tcpHoldLogCount += 1
            if tcpHoldLogCount <= 10 || tcpHoldLogCount % Self.tcpHoldLogInterval == 0 {
                print("[CONSOLE] USBTransport: tcp-drain hold consumed=\(consumedBytes)B unread=\(unreadBytes)B buffer=\(tcpBuffer.count)B sample=\(tcpHoldLogCount)")
                self.log.info("USB TCP drain hold consumed=\(consumedBytes, privacy: .public)B unread=\(unreadBytes, privacy: .public)B buffer=\(self.tcpBuffer.count, privacy: .public)B sample=\(self.tcpHoldLogCount, privacy: .public)")
            }
        }

        let drainElapsedMs = (CFAbsoluteTimeGetCurrent() - drainStart) * 1000.0
        if deliveredThisDrain > 0 && (drainElapsedMs > 4.0 || deliveredThisDrain >= 8 || tcpDrainInvocationCount <= 8) {
            tcpDrainDeliveredLogCount += 1
            if tcpDrainDeliveredLogCount <= 10 ||
                tcpDrainDeliveredLogCount % Self.tcpDrainDeliveredLogInterval == 0 ||
                drainElapsedMs > 8.0 {
                print("[CONSOLE] USBTransport: tcp-drain delivered=\(deliveredThisDrain) elapsed=\(String(format: "%.2f", drainElapsedMs))ms start=\(startBufferCount)B/\(startReadOffset) end=\(tcpBuffer.count)B/\(tcpBufferReadOffset) totalMsgs=\(tcpMessagesDelivered) sample=\(tcpDrainDeliveredLogCount)")
                self.log.info("USB TCP drain delivered=\(deliveredThisDrain, privacy: .public) elapsedMs=\(drainElapsedMs, privacy: .public) startBuf=\(startBufferCount, privacy: .public)B startOffset=\(startReadOffset, privacy: .public) endBuf=\(self.tcpBuffer.count, privacy: .public)B endOffset=\(self.tcpBufferReadOffset, privacy: .public) totalMsgs=\(self.tcpMessagesDelivered, privacy: .public) sample=\(self.tcpDrainDeliveredLogCount, privacy: .public)")
            }
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
            self?.tcpBufferReservedCapacity = 0
        }
    }

    deinit {
        stopMonitoring()
    }
}
