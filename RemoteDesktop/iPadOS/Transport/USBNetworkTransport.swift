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
    private var fallbackPathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.monitor")
    private let transportQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.usb.transport")

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    /// TCP reassembly buffer for length-prefixed messages.
    private var tcpBuffer = Data()

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

    // MARK: - Public API

    /// Start monitoring for USB NCM interfaces.
    ///
    /// Uses TWO monitors to catch USB NCM regardless of how the OS classifies it:
    ///   1. NWPathMonitor(requiredInterfaceType: .wiredEthernet) -- ideal case
    ///   2. NWPathMonitor() (unfiltered) -- fallback for when NCM reports as .other
    ///
    /// When an interface is detected, connections are created automatically.
    func startMonitoring() {
        guard pathMonitor == nil else { return }

        print("[CONSOLE] Starting USB NCM path monitors (TLS/DTLS enabled)")
        log.info("Starting USB NCM path monitors (TLS/DTLS enabled)")

        // Primary monitor: wiredEthernet type (works when OS correctly types USB NCM)
        let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        pathMonitor = wiredMonitor

        wiredMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, source: "wiredEthernet")
        }
        wiredMonitor.start(queue: monitorQueue)

        // Fallback monitor: unfiltered, manually checks for NCM-like interfaces
        // This catches the case where USB NCM reports as .other instead of .wiredEthernet
        let fallbackMonitor = NWPathMonitor()
        fallbackPathMonitor = fallbackMonitor

        fallbackMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, source: "fallback")
        }
        fallbackMonitor.start(queue: monitorQueue)
    }

    /// Unified handler for path updates from either monitor.
    private func handlePathUpdate(_ path: NWPath, source: String) {
        let statusStr: String
        switch path.status {
        case .satisfied: statusStr = "satisfied"
        case .unsatisfied: statusStr = "unsatisfied"
        case .requiresConnection: statusStr = "requiresConnection"
        @unknown default: statusStr = "unknown"
        }

        print("[CONSOLE] [\(source)] path update: status=\(statusStr)")
        log.info("[\(source)] path update: status=\(statusStr)")

        // Log ALL interfaces for debugging
        logAllInterfaces(in: path, label: source)

        if path.status == .satisfied || path.status == .requiresConnection {
            // Find the first USB NCM interface using our detection heuristic
            let ncmInterface = path.availableInterfaces.first(where: { isUSBNCMInterface($0) })

            guard let interface = ncmInterface else {
                // This monitor fired but no NCM interface found -- not an error for
                // the fallback monitor since it sees all interface changes
                if source == "wiredEthernet" {
                    print("[CONSOLE] [\(source)] path satisfied but no NCM interface found in available interfaces")
                }
                return
            }

            let typeName: String
            switch interface.type {
            case .wifi: typeName = "wifi"
            case .cellular: typeName = "cellular"
            case .wiredEthernet: typeName = "wiredEthernet"
            case .loopback: typeName = "loopback"
            case .other: typeName = "other"
            @unknown default: typeName = "unknown"
            }

            print("[CONSOLE] [\(source)] USB NCM interface found: name=\(interface.name) type=\(typeName) index=\(interface.index)")
            log.info("[\(source)] USB NCM interface found: \(interface.name) type=\(typeName) index=\(interface.index)")

            if activeInterface == nil || activeInterface?.index != interface.index {
                activeInterface = interface
                connectOverUSBNCM(interface: interface)
                onInterfaceChanged?(true, interface)
            }
        } else {
            // Only process disconnection if this source was the one that originally
            // detected the interface. The fallback monitor fires unsatisfied for many
            // unrelated changes, so we only tear down if we actually had an active interface
            // AND the wiredEthernet monitor says unsatisfied (or we detected via fallback).
            if activeInterface != nil && source == "wiredEthernet" {
                print("[CONSOLE] [\(source)] USB NCM interface disappeared")
                log.info("[\(source)] USB NCM interface disappeared")
                tearDownConnections()
                activeInterface = nil
                isConnected = false
                onInterfaceChanged?(false, nil)
            } else if activeInterface != nil && source == "fallback" {
                // For fallback, verify the NCM interface is truly gone by checking
                // if ANY remaining interface matches our NCM heuristic
                let stillHasNCM = path.availableInterfaces.contains(where: { isUSBNCMInterface($0) })
                if !stillHasNCM {
                    print("[CONSOLE] [\(source)] USB NCM interface disappeared (confirmed via fallback)")
                    log.info("[\(source)] USB NCM interface disappeared (confirmed via fallback)")
                    tearDownConnections()
                    activeInterface = nil
                    isConnected = false
                    onInterfaceChanged?(false, nil)
                }
            }
        }
    }

    /// Stop monitoring and tear down all connections.
    func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        fallbackPathMonitor?.cancel()
        fallbackPathMonitor = nil
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.tcpBuffer.append(data)
                self.drainUSBTCPBuffer()
            }

            if error != nil || isComplete { return }
            self.scheduleInputReceive(connection)
        }
    }

    /// Extract complete length-prefixed messages from the USB TCP reassembly buffer.
    private func drainUSBTCPBuffer() {
        while tcpBuffer.count >= 4 {
            let msgLen = tcpBuffer.withUnsafeBytes { buf -> Int in
                let raw = buf.load(as: UInt32.self)
                return Int(UInt32(bigEndian: raw))
            }

            guard msgLen > 0, msgLen < 4_000_000 else {
                tcpBuffer.removeAll()
                return
            }

            guard tcpBuffer.count >= 4 + msgLen else { return }

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
        tcpBuffer.removeAll()
    }

    deinit {
        stopMonitoring()
    }
}
