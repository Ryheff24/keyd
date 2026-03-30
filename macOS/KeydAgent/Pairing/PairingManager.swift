import Foundation
import CryptoKit
import Security
import SharedProtocol

private let logger = KeydLogger(category: "PairingManager")

/// Manages the macOS side of the one-time QR pairing handshake.
/// Generates a Curve25519 key pair; encodes public key in QR payload;
/// completes ECDH exchange with iOS; stores derived shared secret in Keychain.
final class PairingManager {
    struct PairingPayload: Codable {
        let publicKeyBase64: String   // macOS Curve25519 public key
        let port: UInt16              // usbmuxd TCP port (12345)
        let agentID: String           // macOS machine identifier
        let version: Int              // Protocol version (1)
    }

    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private(set) var isPaired = false
    private(set) var pairedDeviceID: String?

    private let testMode: TestMode?
    private let keychainService = "com.ryheff.keyd.agent"
    private let keychainSharedSecretKey = "shared-secret"
    private let keychainPairedDeviceIDKey = "paired-device-id"

    init(testMode: TestMode? = nil) {
        self.testMode = testMode
        if testMode != nil {
            // Test mode: start unpaired, no Keychain reads — each test case is a clean slate.
            // Generate a stable keypair once so completePairing() can perform ECDH.
            // This keypair persists across resetInMemory() calls — it's the agent's
            // identity, not session state. Regenerating it on every reset would cause
            // agentKeyMismatch on iOS because the QR-payload public key (injected by
            // the test) wouldn't match the new key in the pairing response.
            isPaired = false
            pairedDeviceID = nil
            privateKey = Curve25519.KeyAgreement.PrivateKey()
        } else {
            // Check if already paired (restore shared secret from Keychain)
            if let _ = loadSharedSecretFromKeychain() {
                isPaired = true
                pairedDeviceID = loadPairedDeviceIDFromKeychain()
            }
        }
    }

    /// Clears in-memory pairing state without touching the Keychain.
    /// Called by TransportManager when it receives a TestReset message in test mode.
    /// Preserves the agent's keypair (generated once in init) so the agent identity
    /// stays stable across test resets — only session state is cleared.
    func resetInMemory() {
        isPaired = false
        pairedDeviceID = nil
    }

    var currentPublicKeyData: Data? {
        privateKey?.publicKey.rawRepresentation
    }

    /// Generate a new keypair and return the QR code payload string.
    func generatePairingQRPayload() -> String {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = key
        let publicKeyData = key.publicKey.rawRepresentation

        let payload = PairingPayload(
            publicKeyBase64: publicKeyData.base64EncodedString(),
            port: 12345,
            agentID: UUID().uuidString,
            version: 1
        )
        let jsonData = try! JSONEncoder().encode(payload)
        return String(data: jsonData, encoding: .utf8)!
    }

    /// Complete pairing when iOS sends its public key.
    /// Returns true if pairing succeeded.
    func completePairing(iOSPublicKeyData: Data, deviceID: String) -> Bool {
        guard let privateKey = privateKey else { return false }

        do {
            let iOSPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: iOSPublicKeyData)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: iOSPublicKey)
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: "keyd-v1".data(using: .utf8)!,
                sharedInfo: Data(),
                outputByteCount: 32
            )

            if testMode != nil {
                // Test mode: set pairing state in memory only — never write to Keychain.
                isPaired = true
                pairedDeviceID = deviceID
                logger.info("[TEST MODE] Paired with device \(deviceID) (in-memory only, no Keychain write)")
            } else {
                // Production: store shared secret in Keychain as usual.
                saveSharedSecretToKeychain(symmetricKey.withUnsafeBytes { Data($0) })
                isPaired = true
                pairedDeviceID = deviceID
                savePairedDeviceIDToKeychain(deviceID)
                logger.info("Paired with device \(deviceID)")
            }
            return true
        } catch {
            logger.error("Pairing failed: \(error)")
            return false
        }
    }

    func resetPairing() {
        clearFromKeychain(key: keychainSharedSecretKey)
        clearFromKeychain(key: keychainPairedDeviceIDKey)
        privateKey = nil
        isPaired = false
        pairedDeviceID = nil
        logger.info("Cleared stored pairing state")
    }

    @discardableResult
    func validateOrAdoptPairedDevice(_ deviceID: String) -> Bool {
        guard isPaired else { return false }

        if let pairedDeviceID {
            return pairedDeviceID == deviceID
        }

        pairedDeviceID = deviceID
        savePairedDeviceIDToKeychain(deviceID)
        logger.info("Recovered paired device identity from active session \(deviceID)")
        return true
    }

    // MARK: - Keychain

    private func saveSharedSecretToKeychain(_ secret: Data) {
        saveToKeychain(secret, key: keychainSharedSecretKey)
    }

    private func savePairedDeviceIDToKeychain(_ deviceID: String) {
        guard let data = deviceID.data(using: .utf8) else { return }
        saveToKeychain(data, key: keychainPairedDeviceIDKey)
    }

    private func saveToKeychain(_ data: Data, key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadSharedSecretFromKeychain() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainSharedSecretKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }

    private func loadPairedDeviceIDFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainPairedDeviceIDKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func clearFromKeychain(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
