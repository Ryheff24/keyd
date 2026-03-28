import Foundation
import AVFoundation
import Network
import Security
import CryptoKit
import os.log

/// QR code payload parsed from the Mac's QR display.
struct QRPayload {
    let certFingerprint: Data      // SHA-256 of Mac's self-signed TLS cert (32 bytes)
    let publicKey: Data            // Mac's P-256 ECDH public key (65 bytes uncompressed)
    let displayWidth: Int          // Mac capture width in pixels
    let displayHeight: Int         // Mac capture height in pixels
    let scaleFactor: Double        // Mac display scale (e.g. 2.0 for Retina)
    let protocolVersion: Int       // Protocol version (1)
    let service: String            // Bonjour service type (_keydrd._tcp)
    let port: UInt16               // TCP pairing port
    let host: String               // Mac's routable IP address

    /// Parse a QR payload from a JSON string.
    static func parse(from jsonString: String) -> QRPayload? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let certFingerprintHex = json["certFingerprint"] as? String,
              let publicKeyBase64 = json["publicKey"] as? String,
              let displayWidth = json["displayWidth"] as? Int,
              let displayHeight = json["displayHeight"] as? Int,
              let scaleFactor = json["scaleFactor"] as? Double,
              let protocolVersion = json["protocolVersion"] as? Int,
              let service = json["service"] as? String,
              let port = json["port"] as? Int,
              let host = json["host"] as? String
        else { return nil }

        guard let certFingerprint = Data(hexString: certFingerprintHex),
              certFingerprint.count == 32,
              let publicKey = Data(base64Encoded: publicKeyBase64)
        else { return nil }

        return QRPayload(
            certFingerprint: certFingerprint,
            publicKey: publicKey,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            scaleFactor: scaleFactor,
            protocolVersion: protocolVersion,
            service: service,
            port: UInt16(port),
            host: host
        )
    }
}

/// Extension for parsing hex strings into Data.
private extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}

/// Manages the iPadOS side of the QR pairing handshake for keyd-rd.
///
/// Scans a QR code from the Mac using the back camera, extracts the Mac's
/// TLS cert fingerprint and ECDH public key, performs cert-pinned TLS
/// connection and ECDH key exchange, and stores the shared secret in Keychain.
///
/// No cleartext connection ever exists. The QR code provides the trust anchor.
final class QRPairing: NSObject, AVCaptureMetadataOutputObjectsDelegate {

    // MARK: - Properties

    /// Whether a successful pairing exists (shared secret in Keychain).
    var isPaired: Bool {
        loadSharedSecret() != nil
    }

    /// Display geometry from the last successful QR scan (persisted for render setup).
    private(set) var displayWidth: Int = 0
    private(set) var displayHeight: Int = 0
    private(set) var scaleFactor: Double = 1.0

    /// Callback fired when pairing completes successfully.
    var onPairingComplete: (() -> Void)?

    /// Callback fired when pairing fails.
    var onPairingFailed: ((String) -> Void)?

    /// Callback fired when a QR code is detected (before pairing attempt).
    var onQRDetected: ((QRPayload) -> Void)?

    /// Callback fired when the capture session starts running (main thread).
    var onSessionStarted: (() -> Void)?

    /// Whether the capture session is currently running.
    var isSessionRunning: Bool { captureSession?.isRunning ?? false }

    // MARK: - Private

    private var captureSession: AVCaptureSession?
    private let keychainService = "com.ryheff.keyd.remote.app"

    /// Guard against re-entrant metadataOutput calls while pairing is in progress.
    private var isPairingInProgress = false

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "QRPairing")

    // MARK: - Notification Observers

    private var notificationObservers: [NSObjectProtocol] = []

    /// Register observers for all AVCaptureSession notifications on a given session.
    private func registerSessionNotificationObservers(for session: AVCaptureSession) {
        // Remove any previous observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        let center = NotificationCenter.default

        let didStart = center.addObserver(forName: .AVCaptureSessionDidStartRunning, object: session, queue: nil) { [weak self] notification in
            self?.log.info("[QRPairing] NOTIFICATION: AVCaptureSessionDidStartRunning fired, object=\(String(describing: notification.object)), thread=\(Thread.isMainThread ? "main" : "background")")
            DispatchQueue.main.async {
                print("[CONSOLE] NOTIFICATION: didStartRunning -> calling onSessionStarted on main thread")
                self?.log.info("[QRPairing] calling onSessionStarted callback on main thread")
                self?.onSessionStarted?()
            }
        }
        notificationObservers.append(didStart)

        let didStop = center.addObserver(forName: .AVCaptureSessionDidStopRunning, object: session, queue: nil) { [weak self] notification in
            self?.log.warning("[QRPairing] NOTIFICATION: AVCaptureSessionDidStopRunning fired, object=\(String(describing: notification.object))")
        }
        notificationObservers.append(didStop)

        let runtimeError = center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.log.error("[QRPairing] NOTIFICATION: AVCaptureSessionRuntimeError fired, error=\(String(describing: error)), userInfo=\(String(describing: notification.userInfo))")
        }
        notificationObservers.append(runtimeError)

        let wasInterrupted = center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            self?.log.warning("[QRPairing] NOTIFICATION: AVCaptureSessionWasInterrupted fired, reason=\(String(describing: reason))")
        }
        notificationObservers.append(wasInterrupted)

        // Also register a wildcard observer (object: nil) to catch if notification fires with wrong object
        let wildcardDidStart = center.addObserver(forName: .AVCaptureSessionDidStartRunning, object: nil, queue: nil) { [weak self] notification in
            self?.log.info("[QRPairing] NOTIFICATION (wildcard): AVCaptureSessionDidStartRunning fired, object=\(String(describing: notification.object)), objectType=\(type(of: notification.object)), thread=\(Thread.isMainThread ? "main" : "background")")
            if let notifSession = notification.object as? AVCaptureSession {
                let isSameSession = notifSession === session
                self?.log.info("[QRPairing] NOTIFICATION (wildcard): isSameSession=\(isSameSession), notifSession.isRunning=\(notifSession.isRunning)")
            }
        }
        notificationObservers.append(wildcardDidStart)

        log.info("[QRPairing] registered 5 notification observers for session \(String(describing: session))")
    }

    // MARK: - QR Scanning

    /// Start the camera session for QR code scanning.
    /// The caller should add `captureSession.previewLayer` to their view.
    func startScanning() -> AVCaptureSession? {
        log.info("[QRPairing] startScanning() entry")
        print("[CONSOLE] startScanning() entry")

        // Log camera authorization status
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        log.info("[QRPairing] camera authorization status: \(authStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        guard let device = AVCaptureDevice.default(for: .video) else {
            log.error("[QRPairing] No video capture device available")
            onPairingFailed?("No camera available")
            return nil
        }
        log.info("[QRPairing] got capture device: \(device.localizedName), uniqueID=\(device.uniqueID), position=\(device.position.rawValue)")

        let session = AVCaptureSession()
        captureSession = session
        log.info("[QRPairing] created AVCaptureSession: \(String(describing: session))")

        do {
            let input = try AVCaptureDeviceInput(device: device)
            log.info("[QRPairing] created AVCaptureDeviceInput successfully")
            if session.canAddInput(input) {
                session.addInput(input)
                log.info("[QRPairing] added input to session")
            } else {
                log.error("[QRPairing] session.canAddInput returned false")
            }
        } catch {
            log.error("[QRPairing] Failed to create camera input: \(error)")
            onPairingFailed?("Camera access denied")
            return nil
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
            log.info("[QRPairing] added metadata output with QR type, delegate set")
        } else {
            log.error("[QRPairing] session.canAddOutput returned false for metadata output")
        }

        log.info("[QRPairing] session configuration complete. inputs=\(session.inputs.count), outputs=\(session.outputs.count)")
        log.info("[QRPairing] session.isRunning=\(session.isRunning) before startRunning dispatch")

        // Register notification observers BEFORE starting the session
        registerSessionNotificationObservers(for: session)

        // NOTE: Do NOT call startRunning() here. The caller must assign the session
        // to a preview layer first, then call beginRunning(). Starting here races with
        // the preview layer assignment which triggers internal beginConfiguration/commitConfiguration.
        log.info("[QRPairing] startScanning() returning configured (not yet running) session")
        return session
    }

    /// Start the capture session on a background thread.
    /// Call AFTER assigning the session to the preview layer.
    func beginRunning() {
        guard let session = captureSession else {
            log.error("[QRPairing] beginRunning() called but captureSession is nil")
            return
        }
        log.info("[QRPairing] beginRunning() dispatching startRunning to background thread")
        print("[CONSOLE] beginRunning() dispatching startRunning")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            print("[CONSOLE] about to call session.startRunning()")
            self?.log.info("[QRPairing] about to call session.startRunning() on background thread")
            session.startRunning()
            print("[CONSOLE] session.startRunning() returned, isRunning=\(session.isRunning)")
            self?.log.info("[QRPairing] session.startRunning() returned, session.isRunning=\(session.isRunning)")
        }
    }

    /// Stop the camera session.
    func stopScanning() {
        log.info("[QRPairing] stopScanning() called, session=\(String(describing: self.captureSession)), isRunning=\(self.captureSession?.isRunning ?? false)")
        captureSession?.stopRunning()
        captureSession = nil
        // Remove notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        log.info("[QRPairing] QR scanner stopped, observers removed")
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        log.info("[QRPairing] metadataOutput delegate called, metadataObjects.count=\(metadataObjects.count)")

        /* Re-entry guard: prevent multiple completePairing() calls while camera drains */
        guard !isPairingInProgress else {
            print("[CONSOLE] metadataOutput: SKIPPING -- isPairingInProgress=true")
            log.info("[QRPairing] metadataOutput: skipping, pairing already in progress")
            return
        }

        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue else {
            log.info("[QRPairing] metadataOutput: no valid QR code in objects")
            return
        }

        log.info("[QRPairing] metadataOutput: QR string detected (length=\(stringValue.count))")
        print("[CONSOLE] QR string detected, length=\(stringValue.count)")

        guard let payload = QRPayload.parse(from: stringValue) else {
            log.warning("[QRPairing] QR code detected but payload format invalid")
            print("[CONSOLE] QR payload parse FAILED -- invalid format")
            return
        }

        log.info("[QRPairing] QR code parsed: protocol v\(payload.protocolVersion), \(payload.displayWidth)x\(payload.displayHeight)@\(payload.scaleFactor)x")
        print("[CONSOLE] QR parsed OK: v\(payload.protocolVersion), \(payload.displayWidth)x\(payload.displayHeight)@\(payload.scaleFactor)x, port=\(payload.port)")

        /* Lock out further delegate calls */
        isPairingInProgress = true

        /* Store display geometry for rendering */
        displayWidth = payload.displayWidth
        displayHeight = payload.displayHeight
        scaleFactor = payload.scaleFactor

        /* Stop scanning -- only one pairing at a time.
         * Must dispatch off main thread: stopRunning() blocks, and we're inside
         * the metadataOutput delegate which runs on main queue. Calling stopRunning()
         * synchronously here deadlocks. */
        print("[CONSOLE] QR detected, dispatching stopScanning to background")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.stopScanning()
            print("[CONSOLE] stopScanning completed")
        }

        onQRDetected?(payload)

        /* Initiate cert-pinned TLS connection and ECDH key exchange */
        print("[CONSOLE] starting completePairing")
        completePairing(qrPayload: payload)
        print("[CONSOLE] completePairing returned (async connection started)")
    }

    // MARK: - Pairing Connection

    /// Complete the pairing handshake over a cert-pinned TLS connection.
    ///
    /// 1. Open TLS connection to Mac, pinning to the cert fingerprint from QR.
    /// 2. Generate iPad's P-256 ECDH key pair.
    /// 3. Send iPad's public key to Mac.
    /// 4. Receive Mac's ECDH public key.
    /// 5. Perform ECDH key agreement.
    /// 6. Derive and store shared secret + Mac cert fingerprint in Keychain.
    func completePairing(qrPayload: QRPayload) {
        let expectedFingerprint = qrPayload.certFingerprint

        print("[CONSOLE] completePairing: entry, port=\(qrPayload.port), thread=\(Thread.isMainThread ? "main" : "bg")")
        log.info("Starting cert-pinned TLS connection to Mac for pairing")

        /* Create TLS parameters with fingerprint-pinned verify block */
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                guard let self = self else {
                    print("[CONSOLE] TLS verify block: self is nil, rejecting")
                    complete(false)
                    return
                }

                print("[CONSOLE] TLS verify block: entered, checking server cert fingerprint")

                /* Extract server certificate and compare fingerprint against QR value */
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let serverCert = certChain.first else {
                    self.log.error("Pairing verify: no server certificate")
                    print("[CONSOLE] TLS verify block: no server cert in chain")
                    complete(false)
                    return
                }

                let certData = SecCertificateCopyData(serverCert) as Data
                let fingerprint = SHA256.hash(data: certData)
                let serverFingerprint = Data(fingerprint)

                let trusted = serverFingerprint == expectedFingerprint
                if trusted {
                    self.log.info("Pairing verify: server cert fingerprint matches QR -- trusted")
                    print("[CONSOLE] TLS verify block: fingerprint MATCHES -- trusted")
                } else {
                    self.log.error("Pairing verify: server cert fingerprint MISMATCH -- rejecting (MITM?)")
                    print("[CONSOLE] TLS verify block: fingerprint MISMATCH -- REJECTING")
                }
                complete(trusted)
            }, DispatchQueue.global())

        let tcpParams = NWParameters(tls: tlsOptions, tcp: .init())

        let host = NWEndpoint.Host(qrPayload.host)
        let port = NWEndpoint.Port(rawValue: qrPayload.port)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        print("[CONSOLE] completePairing: connecting to endpoint=\(endpoint) (host=\(qrPayload.host))")
        log.info("[QRPairing] completePairing: connecting to \(String(describing: endpoint))")

        let connection = NWConnection(to: endpoint, using: tcpParams)
        let pairingQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.pairing")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[CONSOLE] pairing connection state: \(state)")

            switch state {
            case .ready:
                print("[CONSOLE] TLS connection ready, starting ECDH exchange")
                self.log.info("Cert-pinned TLS connection to Mac ready for ECDH")
                self.performECDHExchange(connection: connection,
                                         macPublicKey: qrPayload.publicKey,
                                         macCertFingerprint: qrPayload.certFingerprint)

            case .failed(let error):
                print("[CONSOLE] pairing TLS connection FAILED: \(error)")
                self.log.error("Pairing TLS connection failed: \(error)")
                self.isPairingInProgress = false
                self.onPairingFailed?("Connection to Mac failed: \(error)")

            case .cancelled:
                print("[CONSOLE] pairing connection cancelled")
                self.log.info("Pairing connection cancelled")
                self.isPairingInProgress = false

            case .preparing:
                print("[CONSOLE] pairing connection state: preparing (waiting for TCP handshake + TLS)")

            case .waiting(let error):
                print("[CONSOLE] pairing connection state: waiting -- error=\(error)")

            default:
                print("[CONSOLE] pairing connection state: \(state)")
            }
        }

        print("[CONSOLE] starting pairing connection to \(endpoint)")
        connection.start(queue: pairingQueue)
        print("[CONSOLE] connection.start() returned (async)")

        /* Timeout: cancel if pairing doesn't complete in 30s
         * (TLS 1.3 handshake with self-signed cert takes ~7s alone) */
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self, self.isPairingInProgress else { return }
            print("[CONSOLE] pairing connection TIMEOUT after 30s")
            self.log.error("[QRPairing] pairing connection timed out after 30 seconds")
            connection.cancel()
            self.isPairingInProgress = false
            DispatchQueue.main.async {
                self.onPairingFailed?("Connection to Mac timed out")
            }
        }
    }

    // MARK: - ECDH Key Exchange

    private func performECDHExchange(connection: NWConnection,
                                      macPublicKey: Data,
                                      macCertFingerprint: Data) {
        /* Generate iPad's P-256 ECDH key pair */
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
        ]

        var error: Unmanaged<CFError>?
        guard let iPadPrivateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            log.error("Failed to generate iPad ECDH key pair: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            onPairingFailed?("Key generation failed")
            return
        }

        guard let iPadPublicKey = SecKeyCopyPublicKey(iPadPrivateKey) else {
            log.error("Failed to extract iPad public key")
            onPairingFailed?("Key extraction failed")
            return
        }

        guard let iPadPubKeyData = SecKeyCopyExternalRepresentation(iPadPublicKey, &error) as Data? else {
            log.error("Failed to export iPad public key")
            onPairingFailed?("Key export failed")
            return
        }

        /* Step 1: Send iPad's public key to Mac */
        connection.send(content: iPadPubKeyData, completion: .contentProcessed { [weak self] sendError in
            guard let self = self else { return }

            if let sendError = sendError {
                self.log.error("Failed to send iPad public key: \(sendError)")
                self.onPairingFailed?("Failed to send public key")
                return
            }

            self.log.info("Sent iPad ECDH public key to Mac (\(iPadPubKeyData.count) bytes)")

            /* Step 2: Receive Mac's ECDH public key */
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) {
                [weak self] content, _, _, recvError in
                guard let self = self else { return }

                if let recvError = recvError {
                    self.log.error("Failed to receive Mac public key: \(recvError)")
                    self.onPairingFailed?("Failed to receive Mac's key")
                    return
                }

                guard let macECDHPubKeyData = content, !macECDHPubKeyData.isEmpty else {
                    self.log.error("Empty Mac public key received")
                    self.onPairingFailed?("Empty response from Mac")
                    return
                }

                self.log.info("Received Mac ECDH public key (\(macECDHPubKeyData.count) bytes)")

                /* Step 3: Perform ECDH key agreement */
                let pubKeyAttrs: [CFString: Any] = [
                    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPublic,
                    kSecAttrKeySizeInBits: 256,
                ]

                var importError: Unmanaged<CFError>?
                guard let macECDHPubKey = SecKeyCreateWithData(
                    macECDHPubKeyData as CFData,
                    pubKeyAttrs as CFDictionary,
                    &importError
                ) else {
                    self.log.error("Failed to import Mac ECDH public key")
                    self.onPairingFailed?("Invalid Mac key")
                    return
                }

                let exchangeParams: [String: Any] = [
                    SecKeyKeyExchangeParameter.requestedSize.rawValue as String: 32,
                    SecKeyKeyExchangeParameter.sharedInfo.rawValue as String: "keydrd-v2".data(using: .utf8)!,
                ]

                var exchangeError: Unmanaged<CFError>?
                guard let sharedSecretData = SecKeyCopyKeyExchangeResult(
                    iPadPrivateKey,
                    .ecdhKeyExchangeStandard,
                    macECDHPubKey,
                    exchangeParams as CFDictionary,
                    &exchangeError
                ) as Data? else {
                    self.log.error("ECDH key exchange failed")
                    self.onPairingFailed?("Key exchange failed")
                    return
                }

                /* Step 4: Derive symmetric key via HKDF (HMAC-SHA256 with salt) */
                let salt = "keydrd-pairing-v1".data(using: .utf8)!
                let derivedKey = self.hmacSHA256(key: salt, data: sharedSecretData)

                /* Step 5: Store shared secret + Mac cert fingerprint in Keychain */
                self.saveToKeychain(data: derivedKey, account: "pairing")
                self.saveToKeychain(data: macCertFingerprint, account: "peer-cert-fingerprint")

                print("[CONSOLE] PAIRING COMPLETE -- shared secret stored in Keychain")
                self.log.info("Pairing complete -- shared secret and Mac cert fingerprint stored")

                connection.cancel()

                DispatchQueue.main.async {
                    print("[CONSOLE] calling onPairingComplete callback on main thread")
                    self.onPairingComplete?()
                }
            }
        })
    }

    // MARK: - Crypto Helpers

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    // MARK: - Reset

    /// Delete all pairing state from Keychain.
    func resetPairing() {
        deleteFromKeychain(account: "pairing")
        deleteFromKeychain(account: "peer-cert-fingerprint")
        log.info("Pairing state cleared from Keychain")
    }

    // MARK: - Keychain Helpers

    private func loadSharedSecret() -> Data? {
        return loadFromKeychain(account: "pairing")
    }

    private func saveToKeychain(data: Data, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
