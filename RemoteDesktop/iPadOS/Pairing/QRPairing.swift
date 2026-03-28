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
              let port = json["port"] as? Int
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
            port: UInt16(port)
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

    // MARK: - Private

    private var captureSession: AVCaptureSession?
    private let keychainService = "com.ryheff.keyd.remote.app"

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "QRPairing")

    // MARK: - QR Scanning

    /// Start the camera session for QR code scanning.
    /// The caller should add `captureSession.previewLayer` to their view.
    func startScanning() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .video) else {
            log.error("No video capture device available")
            onPairingFailed?("No camera available")
            return nil
        }

        let session = AVCaptureSession()
        captureSession = session

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            log.error("Failed to create camera input: \(error)")
            onPairingFailed?("Camera access denied")
            return nil
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        session.startRunning()
        log.info("QR scanner started")
        return session
    }

    /// Stop the camera session.
    func stopScanning() {
        captureSession?.stopRunning()
        captureSession = nil
        log.info("QR scanner stopped")
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue else {
            return
        }

        guard let payload = QRPayload.parse(from: stringValue) else {
            log.warning("QR code detected but payload format invalid")
            return
        }

        log.info("QR code parsed: protocol v\(payload.protocolVersion), \(payload.displayWidth)x\(payload.displayHeight)@\(payload.scaleFactor)x")

        /* Store display geometry for rendering */
        displayWidth = payload.displayWidth
        displayHeight = payload.displayHeight
        scaleFactor = payload.scaleFactor

        /* Stop scanning -- only one pairing at a time */
        stopScanning()

        onQRDetected?(payload)

        /* Initiate cert-pinned TLS connection and ECDH key exchange */
        completePairing(qrPayload: payload)
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

        log.info("Starting cert-pinned TLS connection to Mac for pairing")

        /* Create TLS parameters with fingerprint-pinned verify block */
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                guard let self = self else {
                    complete(false)
                    return
                }

                /* Extract server certificate and compare fingerprint against QR value */
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let serverCert = certChain.first else {
                    self.log.error("Pairing verify: no server certificate")
                    complete(false)
                    return
                }

                let certData = SecCertificateCopyData(serverCert) as Data
                let fingerprint = SHA256.hash(data: certData)
                let serverFingerprint = Data(fingerprint)

                let trusted = serverFingerprint == expectedFingerprint
                if trusted {
                    self.log.info("Pairing verify: server cert fingerprint matches QR -- trusted")
                } else {
                    self.log.error("Pairing verify: server cert fingerprint MISMATCH -- rejecting (MITM?)")
                }
                complete(trusted)
            }, DispatchQueue.global())

        let tcpParams = NWParameters(tls: tlsOptions, tcp: .init())

        /* Connect to Mac's input/pairing port */
        let host = NWEndpoint.Host("::")
        let port = NWEndpoint.Port(rawValue: qrPayload.port)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let connection = NWConnection(to: endpoint, using: tcpParams)
        let pairingQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.pairing")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                self.log.info("Cert-pinned TLS connection to Mac ready for ECDH")
                self.performECDHExchange(connection: connection,
                                         macPublicKey: qrPayload.publicKey,
                                         macCertFingerprint: qrPayload.certFingerprint)

            case .failed(let error):
                self.log.error("Pairing TLS connection failed: \(error)")
                self.onPairingFailed?("Connection to Mac failed: \(error)")

            case .cancelled:
                self.log.info("Pairing connection cancelled")

            default:
                break
            }
        }

        connection.start(queue: pairingQueue)
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

                self.log.info("Pairing complete -- shared secret and Mac cert fingerprint stored")

                connection.cancel()

                DispatchQueue.main.async {
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
