---
status: resolved
trigger: "iPad app freezes when scanning Mac's QR code during pairing"
created: 2026-03-28T00:00:00Z
updated: 2026-03-28T21:25:00Z
resolved: 2026-03-28T21:25:32Z
---

## Resolution

QR pairing now works end-to-end. **7 distinct bugs** were found and fixed across the pairing flow.

## Root Causes (ordered by discovery)

### 1. QR payload missing host IP
- **File:** `PairingManager.m` generateQRPayload
- **Bug:** QR JSON had `port` but no `host` field
- **Effect:** iPad connected to `NWEndpoint.Host("::")` (IPv6 unspecified) — not routable
- **Fix:** Added `bestRoutableIPv4Address` using `getifaddrs()`, included `host` in QR JSON
- **Commit:** `b69ab80`

### 2. No TLS pairing listener on Mac
- **File:** `PairingManager.m`
- **Bug:** Mac generated QR but had no listener for incoming pairing connections
- **Effect:** Even with correct IP, iPad had nothing to connect to
- **Fix:** Added `startPairingListener`/`stopPairingListener` on dedicated `KEYDRD_PAIRING_PORT` (14569), wired `onPairingComplete` through SessionManager
- **Commits:** `b69ab80`, `b4f0752`

### 3. Port 14568 conflict
- **File:** `protocol.h`, `PairingManager.m`
- **Bug:** Pairing listener and transport listeners both used `KEYDRD_INPUT_PORT` (14568)
- **Effect:** "Address already in use" — pairing listener couldn't bind
- **Fix:** Added `KEYDRD_PAIRING_PORT` (14569) for pairing only
- **Commit:** `b4f0752`

### 4. Keychain ACL prompts (dev-only)
- **Files:** `PairingManager.m`, `mac-debug.sh`
- **Bug:** Login keychain prompts for signing with changed code signatures between rebuilds. `SecItemDelete` also prompts for items with stale ACL. `kSecUseDataProtectionKeychain` requires provisioning profile. Temp keychain approach failed (identity matching broken with custom DER).
- **Effect:** "RemoteDesktopAgent wants to sign using key 'Apple Development'" dialog on every rebuild
- **Fix:** OpenSSL generates PKCS12 identity in `mac-debug.sh`, app loads via `SecPKCS12Import` from `/tmp/keydrd-tls/identity.p12`. No login keychain involvement for TLS.
- **Commit:** `2ce5632`

### 5. Self-signed cert DER encoding bug
- **File:** `PairingManager.m` buildSelfSignedCertDERWithPublicKey
- **Bug:** Issuer/Subject UTF8String declared length=13 (`0x0D`) but "keydrd-agent" is 12 chars. All outer SEQUENCE lengths cascaded wrong.
- **Effect:** `SecCertificateCreateWithData` returned NULL (invalid DER). Also `SecIdentityCreateWithCertificate` returned -25300 (SubjectPublicKeyInfo hash mismatch).
- **Fix:** Corrected all DER lengths. Then switched to OpenSSL-generated certs (see #4) which bypasses DER entirely.
- **Commit:** `4d238c4`

### 6. `dispatch_data_create` memory bug
- **File:** `PairingManager.m` handlePairingConnection
- **Bug:** `dispatch_data_create(macPubKey.bytes, ..., dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT)` — `DISPATCH_DATA_DESTRUCTOR_DEFAULT` tries to `free()` NSData's internal bytes (not from malloc). Undefined behavior.
- **Effect:** `nw_connection_send` completion handler never fired. Mac's ECDH public key never actually sent.
- **Fix:** `malloc` + `memcpy` the key data, use `DISPATCH_DATA_DESTRUCTOR_FREE`
- **Commit:** `ce8dfbe`

### 7. ECDH key released before extraction
- **File:** `PairingManager.m` handlePairingConnection
- **Bug:** `completePairing:` released `_ecdhPrivateKey` (cleanup after exchange). Then `ecdhPublicKeyData` returned nil because key was already freed.
- **Effect:** Mac's public key was silently nil — send was skipped entirely
- **Fix:** Call `ecdhPublicKeyData` BEFORE `completePairing:`
- **Commit:** `6a173c3`

## Additional Fixes

- **iPad 10s pairing timeout too short:** TLS handshake with self-signed cert took seconds. Increased to 30s.
- **Debug script lockfile handling:** Scripts refused to start if stale lockfile existed. Now auto-kills previous instance.
- **Debug script exit code:** `set -e` + `kill`/`wait` non-zero exit caused script to exit with code 1 during cleanup. Fixed with `|| true` in cleanup function.
- **metadataOutput re-entry guard:** Added `isPairingInProgress` flag to prevent 30fps delegate calls from spawning duplicate connections.

## Verification

Final successful run (2026-03-28 21:25:32Z):
- iPad: QR scanned → TLS fingerprint matched → ECDH sent 65B → received 65B → **PAIRING COMPLETE** → state: connecting
- Mac: Listener ready → iPad connected → TLS ready → ECDH successful → sent 65B → **Pairing complete** → QR closed → CONNECTING → STREAMING

## Key Learnings

1. **macOS login keychain is hostile to dev workflows.** Code signature changes between rebuilds invalidate ACLs. `SecItemDelete` and `SecItemAdd` both prompt. The only reliable approach is external cert generation (OpenSSL PKCS12) loaded at runtime.
2. **`dispatch_data_create` with NSData bytes is a trap.** The destructor tries to `free()` memory not from `malloc()`. Always `malloc`+`memcpy` or use a custom destructor block that retains the NSData.
3. **Order of operations in cleanup code matters.** If a method frees state (like ECDH keys) as cleanup, any code that depends on that state must run first.
4. **Hand-crafted ASN.1 DER is fragile.** Off-by-one in any length field cascades to invalid cert. Use established tools (OpenSSL) for cert generation.
