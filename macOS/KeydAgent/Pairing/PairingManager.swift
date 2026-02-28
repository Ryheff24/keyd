import Foundation
import CryptoKit
import Security

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

    private let keychainService = "com.keyd.agent"
    private let keychainSharedSecretKey = "shared-secret"

    init() {
        // Check if already paired (restore shared secret from Keychain)
        if let _ = loadSharedSecretFromKeychain() {
            isPaired = true
        }
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

            // Store shared secret in Keychain
            saveSharedSecretToKeychain(symmetricKey.withUnsafeBytes { Data($0) })
            isPaired = true
            pairedDeviceID = deviceID
            print("[PairingManager] Paired with device \(deviceID)")
            return true
        } catch {
            print("[PairingManager] Pairing failed: \(error)")
            return false
        }
    }

    // MARK: - Keychain

    private func saveSharedSecretToKeychain(_ secret: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainSharedSecretKey,
            kSecValueData: secret
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
}
