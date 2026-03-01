import Foundation
import CryptoKit
import Security
import UIKit
import SharedProtocol

private let logger = KeydLogger(category: "PairingManager")

/// Manages the iOS side of the one-time QR pairing handshake.
/// Decodes QR payload; generates iOS Curve25519 key; completes ECDH;
/// stores shared secret in Keychain for future auto-connections.
@MainActor
final class PairingManager: ObservableObject {
    @Published var isPaired = false
    @Published var isPairing = false
    @Published var pairingError: String? = nil

    private let installMarkerDefaultsKey = "pairing-install-marker"
    private let keychainService = "com.keyd.app"
    private let keychainSharedSecretKey = "shared-secret"
    private let keychainMacAgentKey = "mac-agent-public-key"

    struct QRPayload: Codable {
        let publicKeyBase64: String
        let port: UInt16
        let agentID: String
        let version: Int
    }

    init() {
        purgeStalePairingAfterFreshInstall()
        isPaired = loadSharedSecretFromKeychain() != nil
    }

    /// Decode QR code string and complete pairing with macOS agent.
    /// The transport connection must already be established before calling this.
    func completeQRPairing(qrString: String, transportManager: TransportManager) async {
        isPairing = true
        pairingError = nil

        do {
            transportManager.logConnectionEvent("QR scan received")

            // Decode QR payload
            guard let qrData = qrString.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(QRPayload.self, from: qrData) else {
                throw PairingError.invalidQRCode
            }

            guard payload.version == 1 else {
                throw PairingError.unsupportedVersion(payload.version)
            }

            guard let macPublicKeyData = Data(base64Encoded: payload.publicKeyBase64) else {
                throw PairingError.invalidQRCode
            }

            // Generate iOS key pair
            let iOSPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let iOSPublicKey = iOSPrivateKey.publicKey

            transportManager.logConnectionEvent("Waiting for pairing transport")
            try await transportManager.waitForConnection()

            // Send pairing request to macOS
            let request = PairingRequest(
                publicKeyData: iOSPublicKey.rawRepresentation,
                deviceID: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            )
            try await transportManager.sendPairingRequest(request)

            transportManager.logConnectionEvent("Waiting for pairing response")
            let response = try await transportManager.awaitPairingResponse()
            guard response.accepted else {
                throw PairingError.rejectedByMac
            }

            let confirmedMacPublicKeyData = response.publicKeyData.isEmpty
                ? macPublicKeyData
                : response.publicKeyData

            guard confirmedMacPublicKeyData == macPublicKeyData else {
                throw PairingError.agentKeyMismatch
            }

            // Complete ECDH
            let macPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: confirmedMacPublicKeyData
            )
            let sharedSecret = try iOSPrivateKey.sharedSecretFromKeyAgreement(with: macPublicKey)
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: "keyd-v1".data(using: .utf8)!,
                sharedInfo: Data(),
                outputByteCount: 32
            )

            // Store in Keychain
            let secretData = symmetricKey.withUnsafeBytes { Data($0) }
            saveSharedSecretToKeychain(secretData)
            saveToKeychain(macPublicKeyData, key: keychainMacAgentKey)

            isPaired = true
            await transportManager.finalizePairingTransportState()
            isPairing = false
            logger.info("Pairing complete")
        } catch {
            isPairing = false
            pairingError = error.localizedDescription
            logger.error("Pairing failed: \(error)")
        }
    }

    func resetPairing() {
        clearFromKeychain(key: keychainSharedSecretKey)
        clearFromKeychain(key: keychainMacAgentKey)
        isPaired = false
        isPairing = false
        pairingError = nil
        logger.info("Cleared stored pairing state")
    }

    // MARK: - Keychain

    private func saveSharedSecretToKeychain(_ data: Data) {
        saveToKeychain(data, key: keychainSharedSecretKey)
    }

    // Keychain items survive app uninstall on iOS, so use a sandboxed install marker
    // to detect a fresh install and discard any stale pairing state before app boot.
    private func purgeStalePairingAfterFreshInstall() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: installMarkerDefaultsKey) == nil else {
            return
        }

        clearFromKeychain(key: keychainSharedSecretKey)
        clearFromKeychain(key: keychainMacAgentKey)
        defaults.set(UUID().uuidString, forKey: installMarkerDefaultsKey)
        logger.info("Fresh install detected; cleared stale pairing state")
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

    private func clearFromKeychain(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
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

    enum PairingError: LocalizedError {
        case invalidQRCode
        case unsupportedVersion(Int)
        case connectionNotReady
        case rejectedByMac
        case agentKeyMismatch

        var errorDescription: String? {
            switch self {
            case .invalidQRCode: return "Invalid QR code. Please scan the code shown by the KeydAgent app on your Mac."
            case .unsupportedVersion(let v): return "Unsupported protocol version \(v)."
            case .connectionNotReady: return "Not connected to Mac. Ensure USB cable is connected and KeydAgent is running."
            case .rejectedByMac: return "The Mac rejected this pairing request. Open a fresh QR code in KeydAgent and scan again."
            case .agentKeyMismatch: return "The scanned QR code does not match the Mac's pairing response. Generate a new QR code and try again."
            }
        }
    }
}
