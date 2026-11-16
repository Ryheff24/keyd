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
    /// Diagnostic launch arg `--no-peer-to-peer`: leave AWDL out of browse and connect,
    /// to tell AWDL off-channel time apart from Wi-Fi power save in latency spikes.
    static let includePeerToPeer: Bool = {
        let on = !ProcessInfo.processInfo.arguments.contains("--no-peer-to-peer")
        print("[CONSOLE] WirelessTransport: includePeerToPeer=\(on)")
        return on
    }()

    /// Test mode `--wireless-only` (harness `--transport-rotation wifi`): require the Wi-Fi
    /// interface. Without it Bonjour may resolve the Mac over USB NCM (en13), AWDL or another
    /// link, and a "Wi-Fi" run silently measures that link instead. Normal use is unchanged.
    static let requireWiFiInterface: Bool = {
        let args = ProcessInfo.processInfo.arguments
        let on = args.contains("--test-mode") && args.contains("--wireless-only")
        print("[CONSOLE] WirelessTransport: requireWiFiInterface=\(on)")
        return on
    }()

    private static func applyInterfacePolicy(_ params: NWParameters) {
        params.includePeerToPeer = includePeerToPeer
        if requireWiFiInterface { params.requiredInterfaceType = .wifi }
    }


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
    private var browsingRequested = false
    private var browserRestartAttempt = 0
    private var connectWatchdogWorkItem: DispatchWorkItem?
    private var controlRecoveryWorkItem: DispatchWorkItem?
    private var controlRecoveryStartedAt: DispatchTime?

    private var mediaConnection: NWConnection?
    private var inputConnection: NWConnection?

    /// TCP reassembly buffer for length-prefixed messages.
    /// Mac prepends 4-byte big-endian length before each message.
    private var tcpBuffer = Data()
    /// Read cursor into tcpBuffer to avoid O(n) front-removal on every message.
    private var tcpBufferReadOffset = 0
    private var tcpBufferReservedCapacity = 0
    private var tcpDrainInvocationCount = 0
    private var tcpDrainDeliveredCount = 0
    private var tcpCompactionCount = 0
    private var tcpAppendLogCount = 0
    private var tcpPartialLogCount = 0
    private var tcpCompactLogCount = 0
    private static let tcpReceiveMaxLength = 262_144
    private static let tcpMaxFrameLength = 4_000_000
    private static let tcpReserveBaseCapacity = 512 << 10
    private static let tcpCompactionMinConsumedBytes = 2 << 20

    /// Tracks the Bonjour service name we are connected/connecting to,
    /// preventing duplicate connections when NWBrowser fires multiple `.added`
    /// events for the same service on different interfaces (Wi-Fi + AWDL).
    private var connectedServiceName: String?
    private var pendingMediaCallbacks = 0
    private var maxPendingMediaCallbacks = 0
    private let controlRecoveryPollInterval: TimeInterval = 0.75
    private let controlRecoveryHardDeadline: TimeInterval = 6.0

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
        WirelessTransport.applyInterfacePolicy(params)
        print("[CONSOLE] WirelessTransport: TCP params includePeerToPeer=\(params.includePeerToPeer) requiredInterface=\(String(describing: params.requiredInterfaceType))")
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
        WirelessTransport.applyInterfacePolicy(params)
        return params
    }

    // MARK: - Public API

    /// Start browsing for the Mac's Bonjour service.
    /// Enables peer-to-peer (AWDL) discovery.
    func startBrowsing() {
        browsingRequested = true
        guard browser == nil else {
            print("[CONSOLE] WirelessTransport: startBrowsing skipped (browser already active, connectedServiceName=\(connectedServiceName ?? "nil"), isConnected=\(isConnected))")
            log.info("startBrowsing skipped: browser already active")
            return
        }

        log.info("Starting Bonjour browse for \(keydrdService) (TLS/DTLS enabled)")

        let params = NWParameters()
        WirelessTransport.applyInterfacePolicy(params)

        let descriptor = NWBrowser.Descriptor.bonjour(type: keydrdService, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)
        browser = newBrowser

        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[CONSOLE] Bonjour browser ready for \(keydrdService)")
                self.log.info("Bonjour browser ready")
                self.browserRestartAttempt = 0
            case .failed(let error):
                print("[CONSOLE] Bonjour browser FAILED: \(error)")
                self.log.error("Bonjour browser failed: \(error)")
                if self.browser === newBrowser {
                    print("[CONSOLE] Bonjour browser failure on active instance (connectedServiceName=\(self.connectedServiceName ?? "nil"), isConnected=\(self.isConnected))")
                    self.browser = nil
                    self.scheduleBrowserRestart(reason: "browser-failed")
                } else {
                    print("[CONSOLE] Bonjour browser failure from stale instance ignored")
                }
            case .cancelled:
                print("[CONSOLE] Bonjour browser cancelled")
                self.log.info("Bonjour browser cancelled")
                if self.browser === newBrowser {
                    self.browser = nil
                    self.scheduleBrowserRestart(reason: "browser-cancelled")
                }
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
                    let controlRecoveryActive = (self.controlRecoveryWorkItem != nil)
                    let allowControlPathReplacement = controlRecoveryActive &&
                        self.mediaConnection != nil &&
                        self.isConnected
                    if self.isConnected || self.connectedServiceName != nil {
                        if allowControlPathReplacement {
                            if let activeInput = self.inputConnection {
                                print("[CONSOLE] Bonjour: ignoring control-path replacement duplicate while replacement already in-flight decision=preserve-current-attempt inputState=\(activeInput.state) serviceLatch=\(self.connectedServiceName ?? "nil") mediaActive=\(self.mediaConnection != nil) isConnected=\(self.isConnected)")
                                self.log.info("Bonjour .added ignored during control recovery: replacement already in-flight")
                                continue
                            }
                            print("[CONSOLE] Bonjour: .added accepted during control-path recovery decision=keep-session action=replace-control-path serviceLatch=\(self.connectedServiceName ?? "nil") mediaActive=\(self.mediaConnection != nil) inputActive=\(self.inputConnection != nil) isConnected=\(self.isConnected)")
                            self.log.info("Bonjour .added accepted during control-path recovery")
                        } else {
                            print("[CONSOLE] Bonjour: ignoring duplicate .added (already connected/connecting to '\(self.connectedServiceName ?? "?")', recoveryActive=\(controlRecoveryActive), mediaActive=\(self.mediaConnection != nil), inputActive=\(self.inputConnection != nil), isConnected=\(self.isConnected))")
                            self.log.info("Ignoring duplicate .added — already connected/connecting")
                            continue
                        }
                    } else if controlRecoveryActive {
                        print("[CONSOLE] Bonjour: .added while control recovery active but no active session (mediaActive=\(self.mediaConnection != nil), inputActive=\(self.inputConnection != nil), isConnected=\(self.isConnected))")
                        self.log.info("Bonjour .added observed during control recovery without active session")
                    } else {
                        print("[CONSOLE] Bonjour: .added accepted (fresh connect path)")
                    }

                    if case .service(let name, _, _, _) = result.endpoint {
                        self.connectedServiceName = name
                    }
                    if allowControlPathReplacement {
                        self.connectToService(endpoint: result.endpoint, preserveMediaPathForControlRecovery: true)
                    } else {
                        self.connectToService(endpoint: result.endpoint)
                    }
                case .removed(let result):
                    print("[CONSOLE] Bonjour service LOST: \(result.endpoint.debugDescription)")
                    self.log.info("Bonjour service lost: \(result.endpoint.debugDescription)")

                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard name == self.connectedServiceName else {
                        print("[CONSOLE] Bonjour: removed service '\(name)' ignored (current latch=\(self.connectedServiceName ?? "nil"))")
                        self.log.info("Bonjour removed service ignored: not current latch")
                        continue
                    }

                    let hasActiveOrPendingSession =
                        self.inputConnection != nil || self.mediaConnection != nil || self.isConnected
                    if hasActiveOrPendingSession {
                        print("[CONSOLE] Bonjour: connected service '\(name)' removed but session is active/pending (isConnected=\(self.isConnected), input=\(self.inputConnection != nil), media=\(self.mediaConnection != nil)) — keeping transport up")
                        self.log.info("Bonjour removed current service while session active/pending — preserving live connection")
                        continue
                    }

                    print("[CONSOLE] Bonjour: current service '\(name)' removed with no active session — clearing service latch")
                    self.log.info("Bonjour removed current service with no active session — clearing latch")
                    self.connectedServiceName = nil

                default:
                    break
                }
            }
        }

        newBrowser.start(queue: transportQueue)
    }

    /// Stop browsing and tear down all connections.
    func stopBrowsing() {
        browsingRequested = false
        let hadBrowser = (browser != nil)
        print("[CONSOLE] WirelessTransport: stopBrowsing entry hadBrowser=\(hadBrowser) connectedServiceName=\(connectedServiceName ?? "nil") isConnected=\(isConnected)")
        connectWatchdogWorkItem?.cancel()
        connectWatchdogWorkItem = nil
        browser?.cancel()
        browser = nil
        tearDownConnections(reason: "stopBrowsing")
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

    private func connectToService(endpoint: NWEndpoint, preserveMediaPathForControlRecovery: Bool = false) {
        if case .service(let serviceName, _, _, _) = endpoint {
            print("[CONSOLE] WirelessTransport: connectToService entry service=\(serviceName), connectedServiceName=\(connectedServiceName ?? "nil"), isConnected=\(isConnected), preserveMediaPathForControlRecovery=\(preserveMediaPathForControlRecovery)")
        } else {
            print("[CONSOLE] WirelessTransport: connectToService entry endpoint=\(endpoint.debugDescription), connectedServiceName=\(connectedServiceName ?? "nil"), isConnected=\(isConnected), preserveMediaPathForControlRecovery=\(preserveMediaPathForControlRecovery)")
        }

        if preserveMediaPathForControlRecovery {
            print("[CONSOLE] WirelessTransport: control-path replacement path preserving media session (mediaActive=\(mediaConnection != nil), inputActive=\(inputConnection != nil), isConnected=\(isConnected))")
            log.info("Preserving media path while reconnecting TCP control channel")
            connectWatchdogWorkItem?.cancel()
            connectWatchdogWorkItem = nil
            if let staleInput = inputConnection {
                print("[CONSOLE] WirelessTransport: control-path replacement cancelling stale/pending input connection before reconnect")
                staleInput.cancel()
                inputConnection = nil
            } else {
                print("[CONSOLE] WirelessTransport: control-path replacement has no existing input connection to cancel")
            }
            tcpBuffer.removeAll()
            tcpBufferReadOffset = 0
            tcpBufferReservedCapacity = 0
        } else {
            tearDownConnections(clearServiceName: false, reason: "connectToService")
        }

        print("[CONSOLE] WirelessTransport: connecting to \(endpoint.debugDescription)")
        log.info("Connecting with TLS to discovered Mac service: \(endpoint.debugDescription)")

        // TLS 1.3-encrypted TCP connection for input
        let tcpParams = createSecureTCPParameters()

        let inputConn = NWConnection(to: endpoint, using: tcpParams)
        inputConnection = inputConn
        scheduleConnectWatchdog(for: inputConn)

        inputConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            let isActiveConnection = (self.inputConnection === inputConn)

            switch state {
            case .ready:
                guard isActiveConnection else {
                    print("[CONSOLE] WirelessTransport: ignoring READY from stale TCP connection (currentInput=\(String(describing: self.inputConnection)))")
                    self.log.info("Ignoring READY from stale TCP connection")
                    return
                }
                self.connectWatchdogWorkItem?.cancel()
                self.connectWatchdogWorkItem = nil
                self.cancelControlPathRecovery(reason: "tcp-ready")
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
                if self.controlRecoveryWorkItem != nil && self.mediaConnection != nil {
                    print("[CONSOLE] WirelessTransport: TCP control recovery READY -- preserving existing DTLS media path")
                    self.log.info("TCP control recovery READY -- preserving existing DTLS media path")
                } else {
                    self.establishMediaConnection(from: inputConn)
                }

            case .failed(let error):
                guard isActiveConnection else {
                    print("[CONSOLE] WirelessTransport: stale TCP connection FAILED ignored: \(error)")
                    self.log.info("Ignoring FAILED from stale TCP connection: \(error)")
                    return
                }
                self.connectWatchdogWorkItem?.cancel()
                self.connectWatchdogWorkItem = nil
                print("[CONSOLE] WirelessTransport: TLS TCP connection FAILED: \(error)")
                self.log.error("TLS wireless TCP connection failed: \(error)")
                self.inputConnection = nil
                let hasMediaPath = (self.mediaConnection != nil)
                let wasConnected = self.isConnected
                let wasAWDL = self.isAWDL
                if hasMediaPath && wasConnected {
                    print("[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-failed-media-active action=preserve-session-and-recover-control detail=\(error)")
                    self.log.info("Control path loss decision=degraded reason=tcp-failed-media-active detail=\(error)")
                    self.beginControlPathRecovery(reason: "tcp-failed", detail: "\(error)", wasAWDL: wasAWDL)
                } else {
                    self.cancelControlPathRecovery(reason: "tcp-failed-no-media")
                    print("[CONSOLE] WirelessTransport: clearing connectedServiceName after failure (\(self.connectedServiceName ?? "nil"))")
                    self.connectedServiceName = nil
                    self.isConnected = false
                    print("[CONSOLE] WirelessTransport: TCP FAILED teardown branch isConnected=\(self.isConnected), mediaActive=\(hasMediaPath), wasAWDL=\(wasAWDL)")
                    self.onConnectionChanged?(false, wasAWDL)
                    self.scheduleBrowserRestart(reason: "tcp-failed")
                }

            case .cancelled:
                guard isActiveConnection else {
                    print("[CONSOLE] WirelessTransport: stale TCP connection CANCELLED ignored")
                    self.log.info("Ignoring CANCELLED from stale TCP connection")
                    return
                }
                self.connectWatchdogWorkItem?.cancel()
                self.connectWatchdogWorkItem = nil
                let wasAWDL = self.isAWDL
                let wasConnected = self.isConnected
                print("[CONSOLE] WirelessTransport: TLS TCP connection CANCELLED, clearing service latch (\(self.connectedServiceName ?? "nil"))")
                self.inputConnection = nil
                self.connectedServiceName = nil
                let hasMediaPath = (self.mediaConnection != nil)
                if hasMediaPath && wasConnected {
                    self.isConnected = true
                    print("[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-cancelled-media-active action=preserve-session-and-recover-control")
                    self.log.info("Control path loss decision=degraded reason=tcp-cancelled-media-active")
                    self.beginControlPathRecovery(reason: "tcp-cancelled", detail: "state-cancelled", wasAWDL: wasAWDL)
                } else {
                    self.cancelControlPathRecovery(reason: "tcp-cancelled-no-media")
                    self.isConnected = false
                    print("[CONSOLE] WirelessTransport: TLS TCP connection CANCELLED teardown branch isConnected=\(self.isConnected) mediaConnectionActive=\(hasMediaPath) wasAWDL=\(wasAWDL)")
                    self.onConnectionChanged?(false, wasAWDL)
                    self.scheduleBrowserRestart(reason: "tcp-cancelled")
                }
                print("[CONSOLE] WirelessTransport: TLS TCP connection CANCELLED exit isConnected=\(self.isConnected) mediaConnectionActive=\(hasMediaPath)")
                self.log.info("TLS wireless TCP connection cancelled")

            case .waiting(let error):
                // Network.framework parks here (no failure) when it cannot reach the
                // endpoint on the allowed interfaces; the watchdog is the only exit.
                print("[CONSOLE] WirelessTransport: TCP CONNECT-STATE waiting active=\(isActiveConnection) error=\(error) path=\(String(describing: inputConn.currentPath)) endpoint=\(endpoint)")

            case .preparing:
                print("[CONSOLE] WirelessTransport: TCP CONNECT-STATE preparing active=\(isActiveConnection) endpoint=\(endpoint)")

            case .setup:
                print("[CONSOLE] WirelessTransport: TCP CONNECT-STATE setup active=\(isActiveConnection)")

            @unknown default:
                print("[CONSOLE] WirelessTransport: TCP CONNECT-STATE unknown=\(state) active=\(isActiveConnection)")
            }
        }
        inputConn.pathUpdateHandler = { path in
            print("[CONSOLE] WirelessTransport: TCP CONNECT-PATH status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name):\($0.type)" }) remote=\(String(describing: path.remoteEndpoint)) local=\(String(describing: path.localEndpoint))")
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
            let isActiveMediaConnection = (self.mediaConnection === mediaConn)
            switch state {
            case .ready:
                guard isActiveMediaConnection else {
                    print("[CONSOLE] WirelessTransport: ignoring READY from stale DTLS media connection")
                    self.log.info("Ignoring READY from stale DTLS media connection")
                    return
                }
                print("[CONSOLE] WirelessTransport: DTLS UDP media connection READY")
                self.log.info("DTLS wireless media UDP connection ready")
                self.scheduleMediaReceive(mediaConn)
            case .failed(let error):
                guard isActiveMediaConnection else {
                    print("[CONSOLE] WirelessTransport: stale DTLS media FAILED ignored: \(error)")
                    self.log.info("Ignoring FAILED from stale DTLS media connection: \(error)")
                    return
                }
                print("[CONSOLE] WirelessTransport: DTLS UDP media FAILED: \(error)")
                self.log.error("DTLS wireless media UDP connection failed: \(error)")
                self.mediaConnection = nil
                self.handleActiveMediaPathLoss(reason: "media-failed", detail: "\(error)")
            case .cancelled:
                guard isActiveMediaConnection else {
                    print("[CONSOLE] WirelessTransport: stale DTLS media CANCELLED ignored")
                    self.log.info("Ignoring CANCELLED from stale DTLS media connection")
                    return
                }
                print("[CONSOLE] WirelessTransport: DTLS UDP media connection CANCELLED")
                self.log.info("DTLS wireless media UDP connection cancelled")
                self.mediaConnection = nil
                self.handleActiveMediaPathLoss(reason: "media-cancelled", detail: "dtls-state-cancelled")
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
    private var transientDTLSGapCount = 0
    private var transientDTLSGapSuppressedLogs = 0
    private var transientDTLSGapFirstAt: DispatchTime?
    private var transientDTLSGapLastLogAt: DispatchTime?
    private static let transientDTLSGapBaseBackoffMs: UInt64 = 1
    private static let transientDTLSGapMaxBackoffMs: UInt64 = 4
    private static let transientDTLSGapSummaryIntervalMs: UInt64 = 250
    private func isTransientDTLSGap(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("No message available on STREAM")
    }

    private func transientDTLSGapBackoffMs(for streak: Int) -> UInt64 {
        if streak >= 256 { return Self.transientDTLSGapMaxBackoffMs }
        if streak >= 128 { return 3 }
        if streak >= 32 { return 2 }
        return Self.transientDTLSGapBaseBackoffMs
    }

    private func resetTransientDTLSGapTracking(reason: String) {
        guard transientDTLSGapCount > 0 else { return }
        let firstNs = transientDTLSGapFirstAt?.uptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - firstNs) / 1_000_000
        print("[CONSOLE] WirelessTransport: transient-dtls-recv-gap recovered reason=\(reason) events=\(transientDTLSGapCount) suppressed=\(transientDTLSGapSuppressedLogs) windowMs=\(elapsedMs) pending=\(pendingMediaCallbacks) maxPending=\(maxPendingMediaCallbacks)")
        log.info("Transient DTLS recv gap recovered reason=\(reason) events=\(self.transientDTLSGapCount) suppressed=\(self.transientDTLSGapSuppressedLogs) windowMs=\(elapsedMs)")
        transientDTLSGapCount = 0
        transientDTLSGapSuppressedLogs = 0
        transientDTLSGapFirstAt = nil
        transientDTLSGapLastLogAt = nil
    }

    private func scheduleMediaReceive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            guard self.mediaConnection === connection else {
                if error != nil || isComplete {
                    print("[CONSOLE] WirelessTransport: stale media receive callback dropped (isComplete=\(isComplete), error=\(String(describing: error)))")
                }
                return
            }

            if error == nil {
                /* Keep the DTLS receive pipeline armed before we hand the
                 * datagram to reassembly/decode. Media processing can be
                 * expensive enough to starve receive callbacks under load if
                 * we wait to reschedule until after it completes. */
                self.scheduleMediaReceive(connection)
            }

            if let data = content, !data.isEmpty {
                self.resetTransientDTLSGapTracking(reason: "media-data")
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
                let detail = "\(error)"
                let hasInputConnection = (self.inputConnection != nil)
                let inputReady: Bool
                if let inputConnection = self.inputConnection {
                    if case .ready = inputConnection.state {
                        inputReady = true
                    } else {
                        inputReady = false
                    }
                } else {
                    inputReady = false
                }
                let controlPathHealthy = hasInputConnection && self.isConnected && inputReady
                if controlPathHealthy && self.isTransientDTLSGap(detail) {
                    let now = DispatchTime.now()
                    if self.transientDTLSGapFirstAt == nil {
                        self.transientDTLSGapFirstAt = now
                    }
                    self.transientDTLSGapCount += 1
                    let streak = self.transientDTLSGapCount
                    let backoffMs = self.transientDTLSGapBackoffMs(for: streak)
                    let shouldEmitDetail = streak <= 3
                    var shouldEmitSummary = false
                    if !shouldEmitDetail {
                        let lastLogNs = self.transientDTLSGapLastLogAt?.uptimeNanoseconds ?? 0
                        let sinceLastLogMs = lastLogNs == 0 ? Self.transientDTLSGapSummaryIntervalMs : (now.uptimeNanoseconds - lastLogNs) / 1_000_000
                        if sinceLastLogMs >= Self.transientDTLSGapSummaryIntervalMs || streak % 128 == 0 {
                            shouldEmitSummary = true
                        }
                    }
                    if shouldEmitDetail {
                        print("[CONSOLE] WirelessTransport: media path loss decision=ignored reason=transient-dtls-recv-gap detail=\(detail) controlPathHealthy=\(controlPathHealthy) streak=\(streak) backoffMs=\(backoffMs) pending=\(self.pendingMediaCallbacks)")
                        self.log.info("Media path loss decision=ignored reason=transient-dtls-recv-gap streak=\(streak) backoffMs=\(backoffMs) detail=\(detail)")
                        self.transientDTLSGapLastLogAt = now
                    } else if shouldEmitSummary {
                        let firstNs = self.transientDTLSGapFirstAt?.uptimeNanoseconds ?? now.uptimeNanoseconds
                        let spanMs = (now.uptimeNanoseconds - firstNs) / 1_000_000
                        self.transientDTLSGapSuppressedLogs += 1
                        print("[CONSOLE] WirelessTransport: transient-dtls-recv-gap ongoing streak=\(streak) spanMs=\(spanMs) suppressed=\(self.transientDTLSGapSuppressedLogs) backoffMs=\(backoffMs) pending=\(self.pendingMediaCallbacks) maxPending=\(self.maxPendingMediaCallbacks)")
                        self.log.info("Transient DTLS recv gap ongoing streak=\(streak) spanMs=\(spanMs) suppressed=\(self.transientDTLSGapSuppressedLogs) backoffMs=\(backoffMs)")
                        self.transientDTLSGapLastLogAt = now
                    } else {
                        self.transientDTLSGapSuppressedLogs += 1
                    }
                    self.transportQueue.asyncAfter(deadline: .now() + .milliseconds(Int(backoffMs))) { [weak self] in
                        guard let self = self else { return }
                        guard self.mediaConnection === connection else { return }
                        self.scheduleMediaReceive(connection)
                    }
                    return
                }
                self.resetTransientDTLSGapTracking(reason: "non-transient-error")
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.tcpReceiveMaxLength) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            guard self.inputConnection === connection else {
                if error != nil || isComplete {
                    print("[CONSOLE] WirelessTransport: stale TCP receive callback dropped (isComplete=\(isComplete), error=\(String(describing: error)))")
                }
                return
            }

            if let data = content, !data.isEmpty {
                let beforeCount = self.tcpBuffer.count
                self.reserveTCPBufferIfNeeded(incomingBytes: data.count, currentCount: beforeCount)
                self.tcpBuffer.append(data)
                let afterCount = self.tcpBuffer.count
                if beforeCount == 0 || afterCount >= (1 << 20) {
                    self.tcpAppendLogCount += 1
                    if self.tcpAppendLogCount <= 10 || self.tcpAppendLogCount % 64 == 0 {
                        print("[CONSOLE] WirelessTransport: tcp-recv append=\(data.count)B buffer=\(afterCount)B readOffset=\(self.tcpBufferReadOffset) sample=\(self.tcpAppendLogCount)")
                    }
                }
                self.drainTCPBuffer()
            }

            if let error = error {
                let hasMediaPath = (self.mediaConnection != nil)
                let wasConnected = self.isConnected
                if hasMediaPath && wasConnected {
                    print("[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-receive-error-media-active action=cancel-input-and-preserve-session detail=\(error)")
                } else {
                    print("[CONSOLE] WirelessTransport: control path loss decision=reconnect-triggered reason=tcp-receive-error-no-media action=cancel-input detail=\(error)")
                }
                connection.cancel()
                return
            }
            if isComplete {
                let hasMediaPath = (self.mediaConnection != nil)
                let wasConnected = self.isConnected
                if hasMediaPath && wasConnected {
                    print("[CONSOLE] WirelessTransport: control path loss decision=degraded reason=tcp-eof-media-active action=cancel-input-and-preserve-session")
                } else {
                    print("[CONSOLE] WirelessTransport: control path loss decision=reconnect-triggered reason=tcp-eof-no-media action=cancel-input")
                }
                connection.cancel()
                return
            }
            self.scheduleInputReceive(connection)
        }
    }

    /// Extract complete length-prefixed messages from the TCP reassembly buffer.
    /// Format: [4 bytes big-endian length][payload of that length]
    private func drainTCPBuffer() {
        tcpDrainInvocationCount += 1
        let drainStart = CFAbsoluteTimeGetCurrent()
        let startCount = tcpBuffer.count
        let startOffset = tcpBufferReadOffset
        var deliveredThisDrain = 0

        while (tcpBuffer.count - tcpBufferReadOffset) >= 4 {
            let msgLen = tcpBuffer.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                var raw: UInt32 = 0
                memcpy(&raw, base.advanced(by: tcpBufferReadOffset), 4)
                return Int(UInt32(bigEndian: raw))
            }

            guard msgLen > 0, msgLen < Self.tcpMaxFrameLength else {
                // Invalid length — likely corrupt data, clear buffer
                print("[CONSOLE] WirelessTransport: invalid TCP frame length \(msgLen), clearing buffer")
                tcpBuffer.removeAll()
                tcpBufferReadOffset = 0
                tcpBufferReservedCapacity = 0
                return
            }

            guard (tcpBuffer.count - tcpBufferReadOffset) >= 4 + msgLen else {
                // Incomplete message — wait for more data
                let available = tcpBuffer.count - tcpBufferReadOffset
                if available >= (1 << 20) {
                    tcpPartialLogCount += 1
                    if tcpPartialLogCount <= 10 || tcpPartialLogCount % 16 == 0 {
                        print("[CONSOLE] WirelessTransport: tcp-drain partial msgLen=\(msgLen) available=\(available)B buffer=\(tcpBuffer.count)B readOffset=\(tcpBufferReadOffset) sample=\(tcpPartialLogCount)")
                    }
                }
                return
            }

            // Extract complete message without front-copy removal on each frame.
            let msgStart = tcpBufferReadOffset + 4
            let msgEnd = msgStart + msgLen
            // Copy the message payload out of the shared reassembly buffer before
            // invoking callbacks. Downstream processing can hop queues and must
            // not retain a view into storage that will be compacted/appended.
            let message = Data(tcpBuffer[msgStart..<msgEnd])
            tcpBufferReadOffset = msgEnd
            deliveredThisDrain += 1
            tcpDrainDeliveredCount += 1

            onInputReceived?(message)
        }

        // Compact only when enough bytes were consumed to justify O(n) copy.
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
            tcpCompactLogCount += 1
            if tcpCompactLogCount <= 10 || tcpCompactLogCount % 16 == 0 || compactElapsedMs > 4.0 {
                print("[CONSOLE] WirelessTransport: tcp-compact #\(tcpCompactionCount) consumed=\(consumedBytes)B unread=\(unreadBytes)B elapsed=\(String(format: "%.2f", compactElapsedMs))ms newBuffer=\(tcpBuffer.count)B sample=\(tcpCompactLogCount)")
            }
        }

        let drainElapsedMs = (CFAbsoluteTimeGetCurrent() - drainStart) * 1000.0
        if deliveredThisDrain > 0 &&
            (drainElapsedMs > 4.0 || deliveredThisDrain >= 8 || tcpDrainInvocationCount <= 8) {
            print("[CONSOLE] WirelessTransport: tcp-drain delivered=\(deliveredThisDrain) elapsed=\(String(format: "%.2f", drainElapsedMs))ms start=\(startCount)B/\(startOffset) end=\(tcpBuffer.count)B/\(tcpBufferReadOffset) totalMsgs=\(tcpDrainDeliveredCount)")
        }
    }

    private func reserveTCPBufferIfNeeded(incomingBytes: Int, currentCount: Int) {
        let required = currentCount + incomingBytes
        guard required > tcpBufferReservedCapacity else { return }

        let previousReserved = tcpBufferReservedCapacity
        let doubled = max(Self.tcpReserveBaseCapacity, previousReserved << 1)
        let target = max(required + (128 << 10), doubled)
        tcpBuffer.reserveCapacity(target)
        tcpBufferReservedCapacity = target
        print("[CONSOLE] WirelessTransport: tcp-buffer-grow required=\(required)B reserved=\(target)B prevReserved=\(previousReserved)B")
    }

    // MARK: - Private: Teardown

    private func tearDownConnections(clearServiceName: Bool = true, reason: String = "unspecified") {
        print("[CONSOLE] WirelessTransport: tearDownConnections reason=\(reason) clearServiceName=\(clearServiceName) connectedServiceName=\(connectedServiceName ?? "nil") isConnected=\(isConnected)")
        cancelControlPathRecovery(reason: "tearDownConnections")
        connectWatchdogWorkItem?.cancel()
        connectWatchdogWorkItem = nil
        mediaConnection?.cancel()
        mediaConnection = nil
        inputConnection?.cancel()
        inputConnection = nil
        if clearServiceName {
            connectedServiceName = nil
        }
        tcpBuffer.removeAll()
        tcpBufferReadOffset = 0
        tcpBufferReservedCapacity = 0
        isConnected = false
        isAWDL = false
        print("[CONSOLE] WirelessTransport: tearDownConnections exit reason=\(reason) connectedServiceName=\(connectedServiceName ?? "nil") isConnected=\(isConnected)")
    }

    private func scheduleBrowserRestart(reason: String) {
        guard browsingRequested else {
            print("[CONSOLE] WirelessTransport: browser restart skipped (\(reason)) browsingRequested=false")
            log.info("Browser restart skipped: browsing not requested (\(reason))")
            return
        }
        guard !isConnected, inputConnection == nil else {
            print("[CONSOLE] WirelessTransport: browser restart skipped (\(reason)) isConnected=\(isConnected) inputActive=\(inputConnection != nil)")
            log.info("Browser restart skipped: session active/pending (\(reason))")
            return
        }
        guard browser == nil else {
            print("[CONSOLE] WirelessTransport: browser restart skipped (\(reason)) browser already active")
            return
        }

        browserRestartAttempt += 1
        let cappedAttempt = min(browserRestartAttempt, 4)
        let delay = 0.25 * pow(2.0, Double(cappedAttempt - 1))
        print("[CONSOLE] WirelessTransport: scheduling browser restart attempt=\(browserRestartAttempt) reason=\(reason) delay=\(String(format: "%.2f", delay))s connectedServiceName=\(connectedServiceName ?? "nil")")
        log.info("Scheduling browser restart attempt=\(self.browserRestartAttempt) reason=\(reason)")

        transportQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard self.browsingRequested else {
                print("[CONSOLE] WirelessTransport: browser restart aborted (\(reason)) browsingRequested=false")
                return
            }
            guard self.browser == nil else {
                print("[CONSOLE] WirelessTransport: browser restart aborted (\(reason)) browser already active")
                return
            }
            if self.isConnected || self.inputConnection != nil {
                print("[CONSOLE] WirelessTransport: browser restart aborted (\(reason)) isConnected=\(self.isConnected) inputActive=\(self.inputConnection != nil)")
                return
            }
            print("[CONSOLE] WirelessTransport: browser restart firing attempt=\(self.browserRestartAttempt) reason=\(reason)")
            self.startBrowsing()
        }
    }

    private func scheduleConnectWatchdog(for connection: NWConnection) {
        connectWatchdogWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.inputConnection === connection else {
                print("[CONSOLE] WirelessTransport: connect watchdog ignored (stale connection)")
                return
            }
            guard !self.isConnected else {
                print("[CONSOLE] WirelessTransport: connect watchdog skipped (already connected)")
                return
            }

            print("[CONSOLE] WirelessTransport: connect watchdog timeout; cancelling pending TCP connection and clearing latch (connectedServiceName=\(self.connectedServiceName ?? "nil"))")
            self.log.error("Connect watchdog timed out; cancelling pending wireless TCP connection")
            connection.cancel()
            self.inputConnection = nil
            self.connectedServiceName = nil
            self.scheduleBrowserRestart(reason: "connect-watchdog-timeout")
        }
        connectWatchdogWorkItem = workItem
        transportQueue.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func cancelControlPathRecovery(reason: String) {
        controlRecoveryWorkItem?.cancel()
        controlRecoveryWorkItem = nil
        if let started = controlRecoveryStartedAt {
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            print("[CONSOLE] WirelessTransport: control recovery cancelled reason=\(reason) elapsedMs=\(elapsedMs)")
            log.info("Control recovery cancelled reason=\(reason) elapsedMs=\(elapsedMs)")
        }
        controlRecoveryStartedAt = nil
    }

    private func beginControlPathRecovery(reason: String, detail: String, wasAWDL: Bool) {
        if controlRecoveryStartedAt == nil {
            controlRecoveryStartedAt = .now()
        }
        connectedServiceName = nil

        if browser == nil {
            print("[CONSOLE] WirelessTransport: control recovery starting browser for replacement discovery reason=\(reason)")
            startBrowsing()
        } else {
            print("[CONSOLE] WirelessTransport: control recovery reusing active browser reason=\(reason)")
        }

        controlRecoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let inputConnection = self.inputConnection, case .ready = inputConnection.state {
                print("[CONSOLE] WirelessTransport: control path loss decision=preserved reason=control-path-recovered action=continue-session")
                self.log.info("Control path loss decision=preserved reason=control-path-recovered")
                self.cancelControlPathRecovery(reason: "control-recovered")
                return
            }

            let elapsedNs: UInt64
            if let started = self.controlRecoveryStartedAt {
                elapsedNs = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            } else {
                elapsedNs = 0
            }
            let elapsedSec = Double(elapsedNs) / 1_000_000_000.0
            let hasMediaPath = (self.mediaConnection != nil)
            if hasMediaPath && elapsedSec < self.controlRecoveryHardDeadline {
                print("[CONSOLE] WirelessTransport: control path loss decision=degraded reason=awaiting-control-replacement detail=\(detail) elapsedMs=\(elapsedNs / 1_000_000) deadlineMs=\(Int(self.controlRecoveryHardDeadline * 1000))")
                self.log.info("Control path loss decision=degraded reason=awaiting-control-replacement elapsedMs=\(elapsedNs / 1_000_000)")
                if let current = self.controlRecoveryWorkItem {
                    self.transportQueue.asyncAfter(deadline: .now() + self.controlRecoveryPollInterval, execute: current)
                }
                return
            }

            print("[CONSOLE] WirelessTransport: control path loss decision=reconnect-triggered reason=control-recovery-timeout action=drop-media-and-signal-disconnect trigger=\(reason) detail=\(detail) elapsedMs=\(elapsedNs / 1_000_000) mediaActive=\(hasMediaPath)")
            self.log.error("Control path loss decision=reconnect-triggered reason=control-recovery-timeout trigger=\(reason)")
            self.mediaConnection?.cancel()
            self.mediaConnection = nil
            self.inputConnection?.cancel()
            self.inputConnection = nil
            self.connectedServiceName = nil
            self.isConnected = false
            self.isAWDL = false
            self.tcpBuffer.removeAll()
            self.tcpBufferReadOffset = 0
            self.tcpBufferReservedCapacity = 0
            self.cancelControlPathRecovery(reason: "control-recovery-timeout")
            self.onConnectionChanged?(false, wasAWDL)
            self.scheduleBrowserRestart(reason: "control-recovery-timeout")
        }
        controlRecoveryWorkItem = workItem
        transportQueue.asyncAfter(deadline: .now() + controlRecoveryPollInterval, execute: workItem)
    }

    private func handleActiveMediaPathLoss(reason: String, detail: String) {
        cancelControlPathRecovery(reason: "media-path-loss")
        let hadInputConnection = (inputConnection != nil)
        let wasConnected = isConnected
        let wasAWDL = isAWDL
        let shouldRecover = hadInputConnection || wasConnected
        let inputReady: Bool
        if let inputConnection = inputConnection {
            if case .ready = inputConnection.state {
                inputReady = true
            } else {
                inputReady = false
            }
        } else {
            inputReady = false
        }
        let controlPathHealthy = hadInputConnection && wasConnected && inputReady

        print("[CONSOLE] WirelessTransport: media path loss observed reason=\(reason) detail=\(detail) hadInputConnection=\(hadInputConnection) wasConnected=\(wasConnected) browsingRequested=\(browsingRequested)")
        if controlPathHealthy {
            print("[CONSOLE] WirelessTransport: media path loss decision=degraded reason=control-path-healthy detail=\(detail) action=preserve-session-no-reconnect")
            log.info("Media path loss decision=degraded reason=control-path-healthy detail=\(detail)")
            return
        }
        if !shouldRecover {
            print("[CONSOLE] WirelessTransport: media path loss decision=ignored reason=no-active-session mediaReason=\(reason)")
            log.info("Media path loss decision=ignored reason=no-active-session mediaReason=\(reason)")
            return
        }

        connectWatchdogWorkItem?.cancel()
        connectWatchdogWorkItem = nil

        let staleInputConnection = inputConnection
        inputConnection = nil
        staleInputConnection?.cancel()

        connectedServiceName = nil
        isConnected = false
        isAWDL = false
        tcpBuffer.removeAll()
        tcpBufferReadOffset = 0
        tcpBufferReservedCapacity = 0

        print("[CONSOLE] WirelessTransport: media path loss decision=reconnect-triggered reason=\(reason) wasAWDL=\(wasAWDL) inputReady=\(inputReady)")
        log.error("Media path loss decision=reconnect-triggered reason=\(reason) inputReady=\(inputReady)")
        onConnectionChanged?(false, wasAWDL)
        scheduleBrowserRestart(reason: reason)
    }

    deinit {
        stopBrowsing()
    }
}
