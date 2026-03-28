#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Manages the macOS side of the QR pairing handshake for keyd-rd.
 *
 * Generates a self-signed P-256 TLS certificate (persisted in Keychain),
 * computes its SHA-256 fingerprint for inclusion in the QR code payload,
 * performs ECDH key exchange over a cert-pinned TLS channel, and stores
 * the derived shared secret in Keychain.
 *
 * The QR code is the trust anchor: physical proximity (scanning) proves the
 * cert fingerprint is authentic. All subsequent connections use certificate
 * pinning -- no cleartext exists.
 */
@interface PairingManager : NSObject

/** Whether a successful pairing has completed (shared secret in Keychain). */
@property (nonatomic, readonly) BOOL isPaired;

/** The derived shared secret from ECDH key exchange (nil if not paired). */
@property (nonatomic, readonly, nullable) NSData *sharedSecret;

/** The Mac's self-signed TLS identity (SecIdentityRef), persisted in Keychain. */
@property (nonatomic, readonly, nullable) SecIdentityRef tlsIdentity;

/**
 * Ensure a TLS identity exists. On first run, generates a P-256 key pair,
 * creates a self-signed X.509 certificate, packages as SecIdentity, and
 * stores in Keychain. On subsequent runs, loads from Keychain.
 *
 * Must be called before generateQRPayload or startPairingListener.
 */
- (void)ensureTLSIdentity;

/**
 * Returns SHA-256 fingerprint of the self-signed certificate's DER encoding.
 * This fingerprint goes into the QR code as the trust anchor.
 */
- (nullable NSData *)tlsCertFingerprint;

/**
 * Generate the QR code payload string containing:
 *   - Mac's self-signed cert SHA-256 fingerprint (hex string)
 *   - Mac's Curve25519 public key (base64)
 *   - Display geometry (width, height, scale factor)
 *   - Protocol version (1)
 *   - Service name (_keydrd._tcp)
 *   - TCP pairing port (KEYDRD_INPUT_PORT)
 *
 * Format: JSON (this is the ONE place JSON is used; all data path is binary).
 * Returns nil if TLS identity not yet created.
 */
- (nullable NSString *)generateQRPayload;

/**
 * Handle an incoming pairing connection from the iPad.
 * Receives iPad's Curve25519 public key, performs ECDH, derives shared secret,
 * stores both the shared secret and peer cert fingerprint in Keychain.
 *
 * @param conn The cert-pinned TLS connection accepted from the iPad.
 */
- (void)handlePairingConnection:(nw_connection_t)conn;

/**
 * Complete the ECDH key exchange with iPad's public key data.
 *
 * @param iPadPublicKey Raw 32-byte Curve25519 public key from iPad.
 * @return YES if pairing succeeded and shared secret was stored.
 */
- (BOOL)completePairing:(NSData *)iPadPublicKey;

/**
 * Delete all pairing state from Keychain (shared secret + peer cert).
 */
- (void)resetPairing;

/**
 * Start a TLS listener for incoming pairing connections on KEYDRD_INPUT_PORT.
 * Call before showing the QR code. Calls handlePairingConnection: when iPad connects.
 */
- (void)startPairingListener;

/**
 * Stop the pairing listener.
 */
- (void)stopPairingListener;

/**
 * Callback fired when pairing completes (ECDH done, secret stored).
 */
@property (nonatomic, copy, nullable) void (^onPairingComplete)(void);

/**
 * Load stored peer certificate fingerprint for cert pinning on subsequent connections.
 */
- (nullable NSData *)loadStoredPeerCertificate;

@end

NS_ASSUME_NONNULL_END
