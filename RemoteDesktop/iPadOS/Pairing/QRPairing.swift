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

struct PairingResponsePayload {
    let publicKey: Data
    let clientCertificateDER: Data?
    let clientPrivateKeyRepresentation: Data?
    let clientIdentityPKCS12: Data?
    let clientCertFingerprint: Data?

    static func parse(from data: Data) -> PairingResponsePayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publicKeyBase64 = json["publicKey"] as? String,
              let publicKey = Data(base64Encoded: publicKeyBase64) else {
            return nil
        }

        var clientCertificateDER: Data?
        var clientPrivateKeyRepresentation: Data?
        var clientIdentityPKCS12: Data?
        var clientCertFingerprint: Data?
        if let clientFingerprintHex = json["clientCertFingerprint"] as? String,
           let fingerprint = Data(hexString: clientFingerprintHex),
           fingerprint.count == 32 {
            clientCertFingerprint = fingerprint
        }
        if let certBase64 = json["clientCertificateDER"] as? String,
           let keyBase64 = json["clientPrivateKeyRepresentation"] as? String,
           let certDER = Data(base64Encoded: certBase64),
           let privateKey = Data(base64Encoded: keyBase64) {
            clientCertificateDER = certDER
            clientPrivateKeyRepresentation = privateKey
        }
        if let clientIdentityBase64 = json["clientIdentityPKCS12"] as? String,
           let pkcs12 = Data(base64Encoded: clientIdentityBase64) {
            clientIdentityPKCS12 = pkcs12
        }

        return PairingResponsePayload(
            publicKey: publicKey,
            clientCertificateDER: clientCertificateDER,
            clientPrivateKeyRepresentation: clientPrivateKeyRepresentation,
            clientIdentityPKCS12: clientIdentityPKCS12,
            clientCertFingerprint: clientCertFingerprint
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

    /// The Mac's host IP from the last QR payload (used for USB NCM direct connection).
    private(set) var pairedHost: String?

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
    private let clientIdentityPKCS12Account = "client-identity-p12"
    private let clientCertificateDERAccount = "client-cert-der"
    private let clientPrivateKeyRepresentationAccount = "client-private-key"
    private let provisionedClientIdentityPassphrase = "keydrd-client"

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

    private func receiveExact(connection: NWConnection,
                              length: Int,
                              accumulated: Data = Data(),
                              completion: @escaping (Data?, NWError?) -> Void) {
        if accumulated.count >= length {
            completion(Data(accumulated.prefix(length)), nil)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: length - accumulated.count) {
            [weak self] content, _, _, error in
            guard self != nil else { return }

            if let error = error {
                completion(nil, error)
                return
            }

            guard let content, !content.isEmpty else {
                completion(nil, nil)
                return
            }

            var nextData = accumulated
            nextData.append(content)
            self?.receiveExact(connection: connection, length: length, accumulated: nextData, completion: completion)
        }
    }

    private func receivePairingResponse(connection: NWConnection,
                                        completion: @escaping (PairingResponsePayload?, String?) -> Void) {
        receiveExact(connection: connection, length: 4) { [weak self] headerData, headerError in
            guard let self else { return }

            if let headerError {
                completion(nil, "recv failed: \(headerError)")
                return
            }

            guard let headerData, headerData.count == 4 else {
                completion(nil, "missing pairing response header")
                return
            }

            var rawLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &rawLength) { rawBuffer in
                headerData.copyBytes(to: rawBuffer)
            }
            let payloadLength = UInt32(bigEndian: rawLength)
            if payloadLength == 0 || payloadLength > 65536 {
                completion(nil, "invalid pairing response length: \(payloadLength)")
                return
            }

            self.receiveExact(connection: connection, length: Int(payloadLength)) { payloadData, payloadError in
                if let payloadError {
                    completion(nil, "recv failed: \(payloadError)")
                    return
                }

                guard let payloadData,
                      let response = PairingResponsePayload.parse(from: payloadData) else {
                    completion(nil, "invalid pairing response payload")
                    return
                }

                completion(response, nil)
            }
        }
    }

    private func importProvisionedClientIdentity(from pkcs12Data: Data) -> SecIdentity? {
        var status: OSStatus = errSecSuccess
        guard let identity = KeydPKCS12ImportCopyIdentity(
            pkcs12Data,
            provisionedClientIdentityPassphrase,
            &status
        ) else {
            log.error("Failed to import provisioned client identity during pairing: \(status), bytes=\(pkcs12Data.count)")
            print("[CONSOLE] QRPairing: client identity import FAILED: status=\(status), bytes=\(pkcs12Data.count)")
            return nil
        }
        if status != errSecSuccess {
            log.warning("SecPKCS12Import returned status \(status), but an identity was still provided")
            print("[CONSOLE] QRPairing: client identity import returned status=\(status) but produced an identity")
        }
        return identity
    }

    private func importProvisionedClientIdentity(certificateDER: Data,
                                                 privateKeyRepresentation: Data) -> SecIdentity? {
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
            print("[CONSOLE] QRPairing: client private key import FAILED")
            return nil
        }

        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            log.error("Failed to import provisioned client certificate")
            print("[CONSOLE] QRPairing: client certificate import FAILED")
            return nil
        }

        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            log.error("Failed to assemble provisioned client identity from certificate + private key")
            print("[CONSOLE] QRPairing: client identity assembly FAILED")
            return nil
        }

        return identity
    }

    private func validateAndStoreProvisionedClientIdentity(_ pkcs12Data: Data) -> Bool {
        guard importProvisionedClientIdentity(from: pkcs12Data) != nil else {
            return false
        }
        saveToKeychain(data: pkcs12Data, account: clientIdentityPKCS12Account)
        return true
    }

    private func validateAndStoreProvisionedClientIdentity(certificateDER: Data,
                                                           privateKeyRepresentation: Data,
                                                           expectedFingerprint: Data) -> Bool {
        guard importProvisionedClientIdentity(
            certificateDER: certificateDER,
            privateKeyRepresentation: privateKeyRepresentation
        ) != nil else {
            return false
        }

        let actualFingerprint = Data(SHA256.hash(data: certificateDER))
        guard actualFingerprint == expectedFingerprint else {
            log.error("Provisioned client certificate fingerprint mismatch")
            print("[CONSOLE] QRPairing: client certificate fingerprint MISMATCH")
            return false
        }

        saveToKeychain(data: certificateDER, account: clientCertificateDERAccount)
        saveToKeychain(data: privateKeyRepresentation, account: clientPrivateKeyRepresentationAccount)
        deleteFromKeychain(account: clientIdentityPKCS12Account)
        return true
    }

    // MARK: - Test Mode Auto-Pairing

    /// Auto-pair without QR camera scan (test mode only).
    ///
    /// Reads QR payload from --qr-payload launch argument (base64-encoded JSON,
    /// passed by run-e2e-tests.sh which reads it from /tmp/keydrd-test-qr.json on the Mac).
    ///
    /// 1. Decode QR payload from launch argument.
    /// 2. Connect to the Mac's pairing port over TLS, accepting any cert (test mode only).
    /// 3. Perform ECDH key exchange.
    /// 4. Call completion on success.
    func autoPairViaBonjourForTestMode(testRunner: DeviceTestRunner?,
                                       completion: @escaping () -> Void) {
        print("[CONSOLE] autoPairViaBonjourForTestMode: entry")

        let queue = DispatchQueue(label: "com.ryheff.keyd.remote.app.testpair")
        queue.async { [weak self] in
            guard let self = self else { return }

            // Read QR payload from --qr-payload launch argument (base64-encoded JSON)
            var payload: QRPayload?
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "--qr-payload"), idx + 1 < args.count {
                let b64 = args[idx + 1]
                print("[CONSOLE] autoPairViaBonjourForTestMode: found --qr-payload arg (length: \(b64.count))")
                if let data = Data(base64Encoded: b64),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    print("[CONSOLE] autoPairViaBonjourForTestMode: decoded JSON (length: \(jsonStr.count))")
                    payload = QRPayload.parse(from: jsonStr)
                }
            }

            guard let qrPayload = payload else {
                print("[CONSOLE] autoPairViaBonjourForTestMode: FAILED -- no valid --qr-payload argument")
                testRunner?.reportTLSConnection(success: false, detail: "QR payload not in launch args")
                return
            }

            print("[CONSOLE] autoPairViaBonjourForTestMode: parsed payload, host=\(qrPayload.host), port=\(qrPayload.port)")

            // Store display geometry and host for USB NCM
            self.displayWidth = qrPayload.displayWidth
            self.displayHeight = qrPayload.displayHeight
            self.scaleFactor = qrPayload.scaleFactor
            self.pairedHost = qrPayload.host

            // Connect with TLS, accepting any cert (TEST MODE ONLY)
            self.completePairingTestMode(qrPayload: qrPayload,
                                          testRunner: testRunner,
                                          completion: completion)
        }
    }

    /// Complete pairing in test mode -- accepts any TLS cert (no fingerprint verification).
    private func completePairingTestMode(qrPayload: QRPayload,
                                          testRunner: DeviceTestRunner?,
                                          completion: @escaping () -> Void) {
        print("[CONSOLE] completePairingTestMode: entry, port=\(qrPayload.port)")
        isPairingInProgress = true

        // TLS with accept-any-cert verify block (TEST MODE ONLY)
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { _, _, complete in
                // TEST MODE: accept any certificate
                print("[CONSOLE] TEST MODE TLS verify: accepting any cert")
                complete(true)
            }, DispatchQueue.global())

        let tcpParams = NWParameters(tls: tlsOptions, tcp: .init())

        let host = NWEndpoint.Host(qrPayload.host)
        let port = NWEndpoint.Port(rawValue: qrPayload.port)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let connection = NWConnection(to: endpoint, using: tcpParams)
        let pairingQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.testpairing")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[CONSOLE] test pairing connection state: \(state)")

            switch state {
            case .ready:
                print("[CONSOLE] TEST MODE: TLS connection ready")
                testRunner?.reportTLSConnection(success: true, detail: "TLS 1.3 handshake complete")
                self.performECDHExchangeTestMode(connection: connection,
                                                  macPublicKey: qrPayload.publicKey,
                                                  macCertFingerprint: qrPayload.certFingerprint,
                                                  testRunner: testRunner,
                                                  completion: completion)

            case .failed(let error):
                print("[CONSOLE] test pairing TLS connection FAILED: \(error)")
                testRunner?.reportTLSConnection(success: false, detail: "failed: \(error)")
                self.isPairingInProgress = false

            case .cancelled:
                print("[CONSOLE] test pairing connection cancelled")
                self.isPairingInProgress = false

            default:
                break
            }
        }

        connection.start(queue: pairingQueue)

        // Timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isPairingInProgress else { return }
            print("[CONSOLE] test pairing TIMEOUT after 10s")
            connection.cancel()
            self.isPairingInProgress = false
            testRunner?.reportTLSConnection(success: false, detail: "timeout after 10s")
        }
    }

    /// Perform ECDH exchange in test mode and report results to test runner.
    private func performECDHExchangeTestMode(connection: NWConnection,
                                             macPublicKey _: Data,
                                             macCertFingerprint: Data,
                                             testRunner: DeviceTestRunner?,
                                             completion: @escaping () -> Void) {
        // Generate iPad's P-256 ECDH key pair
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
        ]

        var error: Unmanaged<CFError>?
        guard let iPadPrivateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let detail = "key gen failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")"
            testRunner?.reportECDHExchange(success: false, detail: detail)
            return
        }

        guard let iPadPublicKey = SecKeyCopyPublicKey(iPadPrivateKey) else {
            testRunner?.reportECDHExchange(success: false, detail: "public key extraction failed")
            return
        }

        guard let iPadPubKeyData = SecKeyCopyExternalRepresentation(iPadPublicKey, &error) as Data? else {
            testRunner?.reportECDHExchange(success: false, detail: "public key export failed")
            return
        }

        // Send iPad's public key
        print("[CONSOLE] TEST ECDH: sending iPad public key (\(iPadPubKeyData.count) bytes)")
        connection.send(content: iPadPubKeyData, completion: .contentProcessed { [weak self] sendError in
            guard let self = self else { return }

            if let sendError = sendError {
                testRunner?.reportECDHExchange(success: false, detail: "send failed: \(sendError)")
                return
            }

            // Receive Mac's ECDH public key
            self.receivePairingResponse(connection: connection) { [weak self] response, recvDetail in
                guard let self = self else { return }

                if let recvDetail {
                    testRunner?.reportECDHExchange(success: false, detail: recvDetail)
                    return
                }

                guard let response else {
                    testRunner?.reportECDHExchange(success: false, detail: "empty Mac key")
                    return
                }
                let macECDHPubKeyData = response.publicKey

                // Perform ECDH key agreement
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
                    testRunner?.reportECDHExchange(success: false, detail: "invalid Mac key")
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
                    testRunner?.reportECDHExchange(success: false, detail: "ECDH failed")
                    return
                }

                // Derive symmetric key
                let salt = "keydrd-pairing-v1".data(using: .utf8)!
                let derivedKey = self.hmacSHA256(key: salt, data: sharedSecretData)

                // Store in Keychain
                self.saveToKeychain(data: derivedKey, account: "pairing")
                self.saveToKeychain(data: macCertFingerprint, account: "peer-cert-fingerprint")
                if let certDER = response.clientCertificateDER,
                   let privateKey = response.clientPrivateKeyRepresentation,
                   let fingerprint = response.clientCertFingerprint {
                    if !self.validateAndStoreProvisionedClientIdentity(
                        certificateDER: certDER,
                        privateKeyRepresentation: privateKey,
                        expectedFingerprint: fingerprint
                    ) {
                        print("[CONSOLE] QRPairing: client identity validation failed — continuing without mTLS")
                    }
                } else if let clientPKCS12 = response.clientIdentityPKCS12 {
                    if !self.validateAndStoreProvisionedClientIdentity(clientPKCS12) {
                        print("[CONSOLE] QRPairing: client identity validation failed — continuing without mTLS")
                    }
                } else {
                    print("[CONSOLE] QRPairing: no client identity in pairing response — mTLS not available")
                }

                let secretPrefix = derivedKey.prefix(4).map { String(format: "%02x", $0) }.joined()
                testRunner?.reportECDHExchange(success: true, detail: "secret: \(secretPrefix)")

                print("[CONSOLE] TEST MODE: PAIRING COMPLETE")
                connection.cancel()
                self.isPairingInProgress = false

                DispatchQueue.main.async {
                    completion()
                }
            }
        })
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

        /* Store display geometry and host for USB NCM */
        displayWidth = payload.displayWidth
        displayHeight = payload.displayHeight
        scaleFactor = payload.scaleFactor
        pairedHost = payload.host

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
                                     macPublicKey _: Data,
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
        print("[CONSOLE] ECDH: sending iPad public key (\(iPadPubKeyData.count) bytes)")
        connection.send(content: iPadPubKeyData, completion: .contentProcessed { [weak self] sendError in
            guard let self = self else { return }

            if let sendError = sendError {
                print("[CONSOLE] ECDH: send FAILED: \(sendError)")
                self.onPairingFailed?("Failed to send public key")
                return
            }

            print("[CONSOLE] ECDH: sent iPad public key, now receiving Mac key...")

            /* Step 2: Receive Mac's ECDH public key */
            self.receivePairingResponse(connection: connection) { [weak self] response, recvDetail in
                guard let self = self else { return }

                if let recvDetail {
                    print("[CONSOLE] ECDH: receive FAILED: \(recvDetail)")
                    self.onPairingFailed?("Failed to receive Mac's key")
                    return
                }

                guard let response else {
                    print("[CONSOLE] ECDH: empty Mac public key received")
                    self.onPairingFailed?("Empty response from Mac")
                    return
                }
                let macECDHPubKeyData = response.publicKey

                print("[CONSOLE] ECDH: received Mac public key (\(macECDHPubKeyData.count) bytes)")

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
                if let certDER = response.clientCertificateDER,
                   let privateKey = response.clientPrivateKeyRepresentation,
                   let fingerprint = response.clientCertFingerprint {
                    if !self.validateAndStoreProvisionedClientIdentity(
                        certificateDER: certDER,
                        privateKeyRepresentation: privateKey,
                        expectedFingerprint: fingerprint
                    ) {
                        self.log.warning("Client identity validation failed — continuing without mTLS")
                    }
                } else if let clientPKCS12 = response.clientIdentityPKCS12 {
                    if !self.validateAndStoreProvisionedClientIdentity(clientPKCS12) {
                        self.log.warning("Client identity validation failed — continuing without mTLS")
                    }
                }

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
        deleteFromKeychain(account: clientIdentityPKCS12Account)
        deleteFromKeychain(account: clientCertificateDERAccount)
        deleteFromKeychain(account: clientPrivateKeyRepresentationAccount)
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
