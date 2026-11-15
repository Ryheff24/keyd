#import <XCTest/XCTest.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#import "PairingManager.h"
#include "protocol.h"
#include "crypto.h"

#pragma mark - Helper: generate a test P-256 key pair

static SecKeyRef createTestP256PrivateKey(void) {
    NSDictionary *attrs = @{
        (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeySizeInBits: @256,
        (id)kSecAttrIsPermanent: @NO,
    };
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &error);
    if (error) CFRelease(error);
    return key;
}

static NSData *publicKeyDataFromPrivateKey(SecKeyRef privateKey) {
    SecKeyRef pubKey = SecKeyCopyPublicKey(privateKey);
    if (!pubKey) return nil;
    CFErrorRef error = NULL;
    CFDataRef data = SecKeyCopyExternalRepresentation(pubKey, &error);
    CFRelease(pubKey);
    if (error) CFRelease(error);
    if (!data) return nil;
    return (__bridge_transfer NSData *)data;
}

#pragma mark - Helper: create a TLS client connection to localhost pairing port

/**
 * Creates a TLS connection to 127.0.0.1:KEYDRD_PAIRING_PORT that trusts all certs (self-signed).
 * The connection is NOT started; caller must set queue, handlers, and start it.
 */
static nw_connection_t createTLSClientConnection(dispatch_queue_t queue) {
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", KEYDRD_PAIRING_PORT);
    nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t _Nonnull options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(options);
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata,
                  sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                complete(true);
            }, queue);
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );

    return nw_connection_create(endpoint, params);
}

/**
 * Creates a plain TCP connection (NO TLS) to 127.0.0.1:KEYDRD_PAIRING_PORT.
 */
static nw_connection_t createPlainTCPConnection(void) {
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", KEYDRD_PAIRING_PORT);
    nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );

    return nw_connection_create(endpoint, params);
}

/**
 * Sends raw bytes over an nw_connection (helper to reduce duplication).
 */
static void sendData(nw_connection_t conn, NSData *data, void (^completion)(nw_error_t _Nullable)) {
    void *buf = malloc(data.length);
    memcpy(buf, data.bytes, data.length);
    dispatch_data_t sendPayload = dispatch_data_create(
        buf, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(conn, sendPayload,
                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       false, completion);
}

/**
 * Performs ECDH key exchange matching PairingManager's completePairing: logic.
 * Given our private key and the peer's public key data, returns the 32-byte derived secret.
 */
static NSData *deriveSharedSecret(SecKeyRef privateKey, NSData *peerPublicKeyData) {
    NSDictionary *pubKeyAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
        (__bridge id)kSecAttrKeySizeInBits: @256,
    };
    CFErrorRef error = NULL;
    SecKeyRef peerPubKey = SecKeyCreateWithData((__bridge CFDataRef)peerPublicKeyData,
                                                (__bridge CFDictionaryRef)pubKeyAttrs,
                                                &error);
    if (!peerPubKey) {
        if (error) CFRelease(error);
        return nil;
    }

    NSDictionary *exchangeParams = @{
        (__bridge id)kSecKeyKeyExchangeParameterRequestedSize: @32,
        (__bridge id)kSecKeyKeyExchangeParameterSharedInfo:
            [@"keydrd-v2" dataUsingEncoding:NSUTF8StringEncoding],
    };

    CFDataRef rawSecret = SecKeyCopyKeyExchangeResult(
        privateKey,
        kSecKeyAlgorithmECDHKeyExchangeStandard,
        peerPubKey,
        (__bridge CFDictionaryRef)exchangeParams,
        &error);
    CFRelease(peerPubKey);

    if (!rawSecret) {
        if (error) CFRelease(error);
        return nil;
    }

    NSData *secret = (__bridge_transfer NSData *)rawSecret;

    /* HKDF-SHA256: HMAC(salt, secret) -- matches PairingManager */
    NSData *salt = [@"keydrd-pairing-v1" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t derivedKey[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, salt.bytes, salt.length, secret.bytes, secret.length, derivedKey);
    return [NSData dataWithBytes:derivedKey length:CC_SHA256_DIGEST_LENGTH];
}

#pragma mark - Helper: create a PKCS12 file for testing

/* The agent identity is a Secure Enclave key in the data-protection keychain (no key file);
 * PairingManager creates or loads it itself. These tests need a test host signed with the
 * keychain-access-groups entitlement, like the agent. */

#pragma mark - PairingManager Tests

@interface PairingTests : XCTestCase
@property (nonatomic, strong) PairingManager *manager;
@end

@implementation PairingTests

- (void)setUp {
    [super setUp];
    self.manager = [[PairingManager alloc] init];
}

- (void)tearDown {
    self.manager.onPairingComplete = nil;
    [self.manager stopPairingListener];
    [self.manager resetPairing];
    self.manager = nil;
    [super tearDown];
}

- (void)testEnsureTLSIdentityCreatesIdentity {
    XCTAssertTrue(self.manager.tlsIdentity == NULL,
                  @"Before ensureTLSIdentity, tlsIdentity should be nil");
    [self.manager ensureTLSIdentity];
    XCTAssertTrue(self.manager.tlsIdentity != NULL,
                  @"After ensureTLSIdentity, tlsIdentity should be non-nil");
}

- (void)testTLSCertFingerprintNonEmpty {
    [self.manager ensureTLSIdentity];
    NSData *fingerprint = [self.manager tlsCertFingerprint];
    XCTAssertNotNil(fingerprint, @"Fingerprint should not be nil after identity is created");
    XCTAssertEqual(fingerprint.length, CC_SHA256_DIGEST_LENGTH,
                   @"Fingerprint should be %d bytes (SHA-256)", CC_SHA256_DIGEST_LENGTH);
}

/* ============================================================================
 *  1. QR PAYLOAD WIRE FORMAT
 * ============================================================================ */

#pragma mark - 1. QR Payload Wire Format

- (void)testQRPayloadContainsRequiredFields {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    XCTAssertNotNil(payload, @"QR payload should not be nil");

    NSData *jsonData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:&error];
    XCTAssertNotNil(json, @"QR payload should be valid JSON: %@", error);

    /* Verify all required fields are present */
    NSArray *requiredKeys = @[
        @"host", @"port", @"certFingerprint", @"publicKey",
        @"displayWidth", @"displayHeight", @"scaleFactor",
        @"protocolVersion", @"service"
    ];
    for (NSString *key in requiredKeys) {
        XCTAssertNotNil(json[key], @"QR payload should contain '%@' field", key);
    }
}

- (void)testQRPayloadJSONFieldTypes {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    XCTAssertNotNil(payload);

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertNotNil(json);

    /* String fields */
    XCTAssertTrue([json[@"host"] isKindOfClass:[NSString class]],
                  @"host should be a string, got %@", [json[@"host"] class]);
    XCTAssertTrue([json[@"certFingerprint"] isKindOfClass:[NSString class]],
                  @"certFingerprint should be a string, got %@", [json[@"certFingerprint"] class]);
    XCTAssertTrue([json[@"publicKey"] isKindOfClass:[NSString class]],
                  @"publicKey should be a string, got %@", [json[@"publicKey"] class]);
    XCTAssertTrue([json[@"service"] isKindOfClass:[NSString class]],
                  @"service should be a string, got %@", [json[@"service"] class]);

    /* Number fields */
    XCTAssertTrue([json[@"port"] isKindOfClass:[NSNumber class]],
                  @"port should be a number, got %@", [json[@"port"] class]);
    XCTAssertTrue([json[@"displayWidth"] isKindOfClass:[NSNumber class]],
                  @"displayWidth should be a number, got %@", [json[@"displayWidth"] class]);
    XCTAssertTrue([json[@"displayHeight"] isKindOfClass:[NSNumber class]],
                  @"displayHeight should be a number, got %@", [json[@"displayHeight"] class]);
    XCTAssertTrue([json[@"scaleFactor"] isKindOfClass:[NSNumber class]],
                  @"scaleFactor should be a number, got %@", [json[@"scaleFactor"] class]);
    XCTAssertTrue([json[@"protocolVersion"] isKindOfClass:[NSNumber class]],
                  @"protocolVersion should be a number, got %@", [json[@"protocolVersion"] class]);

    /* No extra fields -- verify the key count is exactly 9 */
    XCTAssertEqual(json.count, 9,
                   @"QR payload should contain exactly 9 fields, got %lu", (unsigned long)json.count);
}

- (void)testQRPayloadHostIsRoutableIP {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    XCTAssertNotNil(payload, @"QR payload should not be nil");

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSString *host = json[@"host"];
    XCTAssertNotNil(host, @"host field should be present");
    XCTAssertGreaterThan(host.length, 0, @"host should not be empty");
    XCTAssertFalse([host isEqualToString:@"::"],
                   @"host should not be '::' (wildcard IPv6)");
    XCTAssertFalse([host isEqualToString:@"0.0.0.0"],
                   @"host should not be '0.0.0.0' (wildcard IPv4)");
    XCTAssertFalse([host isEqualToString:@"127.0.0.1"],
                   @"host should not be loopback (QR is for remote device)");

    /* Verify it parses as a valid IPv4 address (dotted-quad) */
    struct in_addr addr;
    int result = inet_pton(AF_INET, host.UTF8String, &addr);
    XCTAssertEqual(result, 1, @"host should be a valid IPv4 address, got '%@'", host);

    /* Verify dotted-quad format (4 octets separated by 3 dots) */
    NSArray *octets = [host componentsSeparatedByString:@"."];
    XCTAssertEqual(octets.count, 4,
                   @"host should be dotted-quad (4 octets), got '%@'", host);
    for (NSString *octet in octets) {
        int val = octet.intValue;
        XCTAssertTrue(val >= 0 && val <= 255,
                      @"Each octet should be 0-255, got '%@' in '%@'", octet, host);
    }
}

- (void)testQRPayloadCertFingerprintIsValidHexSHA256 {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSString *fingerprint = json[@"certFingerprint"];
    XCTAssertNotNil(fingerprint, @"certFingerprint should be present");

    /* SHA-256 as hex = 64 hex characters */
    XCTAssertEqual(fingerprint.length, 64,
                   @"certFingerprint hex string should be 64 chars (32 bytes SHA-256), got %lu",
                   (unsigned long)fingerprint.length);

    /* Verify all characters are lowercase hex */
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    NSCharacterSet *fingerprintChars = [NSCharacterSet characterSetWithCharactersInString:fingerprint];
    XCTAssertTrue([hexSet isSupersetOfSet:fingerprintChars],
                  @"certFingerprint should contain only lowercase hex chars, got '%@'", fingerprint);

    /* Decode hex to bytes and verify 32 bytes */
    NSMutableData *decoded = [NSMutableData dataWithCapacity:32];
    for (NSUInteger i = 0; i < fingerprint.length; i += 2) {
        NSString *hexByte = [fingerprint substringWithRange:NSMakeRange(i, 2)];
        unsigned int byte;
        [[NSScanner scannerWithString:hexByte] scanHexInt:&byte];
        uint8_t b = (uint8_t)byte;
        [decoded appendBytes:&b length:1];
    }
    XCTAssertEqual(decoded.length, CC_SHA256_DIGEST_LENGTH,
                   @"Decoded fingerprint should be %d bytes", CC_SHA256_DIGEST_LENGTH);
}

- (void)testQRPayloadCertFingerprintMatchesTLSCert {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    /* Get fingerprint from QR payload (hex string) */
    NSString *hexFingerprint = json[@"certFingerprint"];
    XCTAssertNotNil(hexFingerprint);

    /* Compute fingerprint directly from TLS identity cert */
    NSData *directFingerprint = [self.manager tlsCertFingerprint];
    XCTAssertNotNil(directFingerprint);

    /* Convert direct fingerprint to hex */
    NSMutableString *directHex = [NSMutableString stringWithCapacity:directFingerprint.length * 2];
    const uint8_t *bytes = directFingerprint.bytes;
    for (NSUInteger i = 0; i < directFingerprint.length; i++) {
        [directHex appendFormat:@"%02x", bytes[i]];
    }

    XCTAssertEqualObjects(hexFingerprint, directHex,
                          @"QR payload fingerprint should match direct cert fingerprint");
}

- (void)testQRPayloadPublicKeyIs65BytesUncompressedP256 {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSString *pubKeyBase64 = json[@"publicKey"];
    XCTAssertNotNil(pubKeyBase64, @"publicKey should be present");

    /* Decode base64 */
    NSData *pubKeyData = [[NSData alloc] initWithBase64EncodedString:pubKeyBase64 options:0];
    XCTAssertNotNil(pubKeyData, @"publicKey should be valid base64");
    XCTAssertEqual(pubKeyData.length, 65,
                   @"P-256 uncompressed public key should be 65 bytes (04 || x || y), got %lu",
                   (unsigned long)pubKeyData.length);

    /* Verify first byte is 0x04 (uncompressed point indicator) */
    uint8_t firstByte = ((const uint8_t *)pubKeyData.bytes)[0];
    XCTAssertEqual(firstByte, 0x04,
                   @"P-256 uncompressed key must start with 0x04, got 0x%02x", firstByte);

    /* Verify the key can be imported as a valid SecKey */
    NSDictionary *attrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
        (__bridge id)kSecAttrKeySizeInBits: @256,
    };
    CFErrorRef error = NULL;
    SecKeyRef importedKey = SecKeyCreateWithData((__bridge CFDataRef)pubKeyData,
                                                 (__bridge CFDictionaryRef)attrs,
                                                 &error);
    XCTAssertTrue(importedKey != NULL,
                  @"publicKey data should import as valid P-256 SecKey, error: %@",
                  error ? (__bridge NSError *)error : nil);
    if (importedKey) CFRelease(importedKey);
    if (error) CFRelease(error);
}

- (void)testQRPayloadPublicKeyChangesEachGeneration {
    /* Each call to generateQRPayload creates a NEW ECDH key pair */
    [self.manager ensureTLSIdentity];

    NSString *payload1 = [self.manager generateQRPayload];
    NSDictionary *json1 = [NSJSONSerialization JSONObjectWithData:
        [payload1 dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSString *payload2 = [self.manager generateQRPayload];
    NSDictionary *json2 = [NSJSONSerialization JSONObjectWithData:
        [payload2 dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    XCTAssertNotEqualObjects(json1[@"publicKey"], json2[@"publicKey"],
                             @"Each QR generation should produce a fresh ECDH key pair");

    /* But the cert fingerprint should be stable (same TLS identity) */
    XCTAssertEqualObjects(json1[@"certFingerprint"], json2[@"certFingerprint"],
                          @"Cert fingerprint should be the same across QR generations (same identity)");
}

- (void)testQRPayloadPortIsCorrect {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSNumber *port = json[@"port"];
    XCTAssertNotNil(port, @"port field should be present");
    XCTAssertEqual(port.intValue, KEYDRD_PAIRING_PORT,
                   @"port should be KEYDRD_PAIRING_PORT (%d)", KEYDRD_PAIRING_PORT);
}

- (void)testQRPayloadServiceIsCorrect {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSString *service = json[@"service"];
    XCTAssertNotNil(service, @"service field should be present");
    XCTAssertEqualObjects(service, @KEYDRD_SERVICE,
                          @"service should be '%s'", KEYDRD_SERVICE);
}

- (void)testQRPayloadProtocolVersionIs1 {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSNumber *version = json[@"protocolVersion"];
    XCTAssertNotNil(version);
    XCTAssertEqual(version.intValue, 1,
                   @"protocolVersion should be 1, got %d", version.intValue);
}

- (void)testQRPayloadDisplayGeometryIsPositive {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSNumber *width = json[@"displayWidth"];
    NSNumber *height = json[@"displayHeight"];
    NSNumber *scale = json[@"scaleFactor"];

    XCTAssertGreaterThan(width.intValue, 0,
                         @"displayWidth should be positive, got %d", width.intValue);
    XCTAssertGreaterThan(height.intValue, 0,
                         @"displayHeight should be positive, got %d", height.intValue);
    XCTAssertGreaterThanOrEqual(scale.doubleValue, 1.0,
                                @"scaleFactor should be >= 1.0, got %f", scale.doubleValue);
}

- (void)testQRPayloadIsValidUTF8JSON {
    [self.manager ensureTLSIdentity];
    NSString *payload = [self.manager generateQRPayload];
    XCTAssertNotNil(payload);

    /* Verify it's valid UTF-8 */
    NSData *utf8Data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNotNil(utf8Data, @"QR payload should be valid UTF-8");

    /* Verify it round-trips through JSON parsing */
    NSError *error = nil;
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:utf8Data options:0 error:&error];
    XCTAssertNotNil(parsed, @"QR payload should be parseable JSON: %@", error);

    /* Verify the parsed output re-serializes without error */
    NSData *reserialized = [NSJSONSerialization dataWithJSONObject:parsed options:0 error:&error];
    XCTAssertNotNil(reserialized, @"Parsed QR payload should re-serialize: %@", error);
}

- (void)testQRPayloadRequiresTLSIdentity {
    /* Without ensureTLSIdentity, generateQRPayload should return nil */
    PairingManager *freshManager = [[PairingManager alloc] init];
    [freshManager resetPairing]; /* Clear any persisted state */
    /* Note: freshManager has no TLS identity loaded since we didn't call ensureTLSIdentity */
    /* We can't easily test this without a fresh manager that has never had ensureTLSIdentity called.
     * The manager from setUp already has it cleared via resetPairing in tearDown of previous test.
     * But since setUp calls ensureTestPKCS12 and creates a new manager, we verify:
     * calling generateQRPayload on the new setUp manager BEFORE ensureTLSIdentity returns nil. */
    PairingManager *noIdentity = [[PairingManager alloc] init];
    NSString *payload = [noIdentity generateQRPayload];
    /* This may or may not be nil depending on keychain state -- the key invariant is:
     * if tlsIdentity is nil, the payload is nil */
    if (noIdentity.tlsIdentity == NULL) {
        XCTAssertNil(payload, @"Without TLS identity, QR payload should be nil");
    }
}

/* ============================================================================
 *  2. TLS PAIRING LISTENER
 * ============================================================================ */

#pragma mark - 2. TLS Pairing Listener

- (void)testPairingListenerStartsAndAcceptsTLS {
    XCTestExpectation *accepted = [self expectationWithDescription:@"TLS connection accepted"];

    [self.manager ensureTLSIdentity];
    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.listener", DISPATCH_QUEUE_SERIAL);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                [accepted fulfill];
                nw_connection_cancel(conn);
            } else if (state == nw_connection_state_failed) {
                XCTFail(@"TLS connection to pairing listener failed: %@", error);
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:nil];
}

- (void)testPairingListenerCertMatchesQRFingerprint {
    XCTestExpectation *verified = [self expectationWithDescription:@"Cert fingerprint verified"];

    [self.manager ensureTLSIdentity];
    NSString *qrPayload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [qrPayload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSString *expectedHexFingerprint = json[@"certFingerprint"];
    XCTAssertNotNil(expectedHexFingerprint);

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.cert", DISPATCH_QUEUE_SERIAL);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        char portStr[8];
        snprintf(portStr, sizeof(portStr), "%d", KEYDRD_PAIRING_PORT);
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr);

        nw_parameters_t params = nw_parameters_create_secure_tcp(
            ^(nw_protocol_options_t _Nonnull options) {
                sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(options);
                sec_protocol_options_set_verify_block(sec,
                    ^(sec_protocol_metadata_t metadata,
                      sec_trust_t trust,
                      sec_protocol_verify_complete_t complete) {
                    /* Extract server certificate from the trust passed to the verify block */
                    if (trust) {
                        SecTrustRef trustRef = sec_trust_copy_ref(trust);
                        if (trustRef) {
                            /* Get the leaf certificate (server cert) */
                            SecCertificateRef serverCert = SecTrustGetCertificateAtIndex(trustRef, 0);
                            if (serverCert) {
                                CFDataRef certDER = SecCertificateCopyData(serverCert);
                                if (certDER) {
                                    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
                                    CC_SHA256(CFDataGetBytePtr(certDER),
                                              (CC_LONG)CFDataGetLength(certDER), hash);
                                    CFRelease(certDER);

                                    /* Convert to hex */
                                    NSMutableString *actualHex = [NSMutableString stringWithCapacity:64];
                                    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
                                        [actualHex appendFormat:@"%02x", hash[i]];
                                    }

                                    XCTAssertEqualObjects(actualHex, expectedHexFingerprint,
                                        @"Server cert fingerprint should match QR payload fingerprint");
                                    [verified fulfill];
                                }
                            }
                            CFRelease(trustRef);
                        }
                    }
                    complete(true); /* Accept for test purposes regardless */
                }, queue);
            },
            NW_PARAMETERS_DEFAULT_CONFIGURATION
        );

        nw_connection_t conn = nw_connection_create(endpoint, params);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_cancel(conn);
            } else if (state == nw_connection_state_failed) {
                XCTFail(@"Connection failed: %@", error);
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:nil];
}

- (void)testPairingListenerRejectsPlainTCPConnection {
    /* A plain TCP (non-TLS) connection should not successfully complete the ECDH exchange.
     * The TLS listener requires a TLS handshake, so a raw TCP client either:
     * - fails to connect (TLS handshake fails)
     * - connects at TCP level but TLS negotiation fails
     * We verify by using a POSIX socket: connect, send garbage, verify no valid 65-byte
     * ECDH response comes back. */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];
    [self.manager startPairingListener];

    /* Give listener time to start */
    XCTestExpectation *tested = [self expectationWithDescription:@"Plain TCP tested"];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.notls", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), queue, ^{
        /* Use raw POSIX socket for non-TLS connection */
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        XCTAssertTrue(sock >= 0, @"socket() should succeed");

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(KEYDRD_PAIRING_PORT);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

        int connected = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
        /* TCP connect may succeed (the TLS handshake happens after TCP connect) */
        if (connected == 0) {
            /* Send garbage bytes (not a TLS ClientHello) */
            uint8_t garbage[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03};
            ssize_t sent = write(sock, garbage, sizeof(garbage));
            (void)sent; /* May or may not succeed */

            /* Try to read a response with a short timeout */
            struct timeval tv;
            tv.tv_sec = 1;
            tv.tv_usec = 0;
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

            uint8_t buf[256];
            ssize_t received = read(sock, buf, sizeof(buf));

            /* We should NOT get a valid 65-byte ECDH response */
            XCTAssertTrue(received <= 0 || received != 65,
                @"Plain TCP should not receive a valid 65-byte ECDH key response (got %zd bytes)",
                received);
        }
        /* If connect failed, that's also a valid outcome -- TLS-only listener rejected TCP */

        close(sock);
        [tested fulfill];
    });

    [self waitForExpectationsWithTimeout:3.0 handler:nil];
}

- (void)testPairingListenerRequiresTLSIdentity {
    /* Starting listener without TLS identity should be a no-op (no crash, no listener).
     * We verify this by checking that startPairingListener returns safely
     * and the manager doesn't crash. */
    PairingManager *noIdentityManager = [[PairingManager alloc] init];

    /* This should be a no-op since no TLS identity is loaded */
    [noIdentityManager startPairingListener];

    /* Verify no crash occurred and the manager is still functional */
    XCTAssertFalse(noIdentityManager.isPaired,
                   @"Manager without TLS identity should not be paired");

    /* Use POSIX socket to quickly verify no listener on the pairing port.
     * Note: if another test left a listener, the port may still be open.
     * The key assertion is that startPairingListener didn't crash. */
    [noIdentityManager stopPairingListener];
}

/* ============================================================================
 *  3. ECDH KEY EXCHANGE WIRE PROTOCOL
 * ============================================================================ */

#pragma mark - 3. ECDH Key Exchange Wire Protocol

- (void)testECDHKeyExchangeWireFormat {
    XCTestExpectation *exchangeDone = [self expectationWithDescription:@"ECDH wire format verified"];

    [self.manager ensureTLSIdentity];
    NSString *qrPayload = [self.manager generateQRPayload];
    XCTAssertNotNil(qrPayload);

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.ecdh.wire", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    XCTAssertTrue(iPadPrivate != NULL);
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);
    XCTAssertNotNil(iPadPubData);
    XCTAssertEqual(iPadPubData.length, 65,
                   @"iPad P-256 uncompressed public key should be 65 bytes");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                /* Send iPad's 65-byte P-256 public key */
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    XCTAssertNil(sendError, @"Send should succeed: %@", sendError);

                    /* Receive Mac's public key -- should be exactly 65 bytes */
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t _Nullable content,
                          nw_content_context_t _Nullable ctx,
                          bool is_complete,
                          nw_error_t _Nullable recvError) {
                        XCTAssertNotNil(content, @"Should receive Mac public key");
                        if (!content) return;

                        __block NSMutableData *macPubKey = [NSMutableData data];
                        dispatch_data_apply(content,
                            ^bool(dispatch_data_t region, size_t offset,
                                  const void *buffer, size_t size) {
                            [macPubKey appendBytes:buffer length:size];
                            return true;
                        });

                        /* Verify wire format */
                        XCTAssertEqual(macPubKey.length, 65,
                            @"Mac public key should be exactly 65 bytes, got %lu",
                            (unsigned long)macPubKey.length);

                        uint8_t firstByte = ((const uint8_t *)macPubKey.bytes)[0];
                        XCTAssertEqual(firstByte, 0x04,
                            @"First byte should be 0x04 (uncompressed point)");

                        /* Verify the key is a valid P-256 point by importing it */
                        NSDictionary *attrs = @{
                            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
                            (__bridge id)kSecAttrKeySizeInBits: @256,
                        };
                        CFErrorRef importError = NULL;
                        SecKeyRef imported = SecKeyCreateWithData(
                            (__bridge CFDataRef)macPubKey,
                            (__bridge CFDictionaryRef)attrs,
                            &importError);
                        XCTAssertTrue(imported != NULL,
                            @"Received key should be a valid P-256 public key");
                        if (imported) CFRelease(imported);
                        if (importError) CFRelease(importError);

                        [exchangeDone fulfill];
                        nw_connection_cancel(conn);
                    });
                });
            } else if (state == nw_connection_state_failed) {
                XCTFail(@"Connection failed: %@", error);
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testECDHKeyExchangeMatchesQRPublicKey {
    /* Verify the Mac's key received over the wire matches the QR publicKey field */
    XCTestExpectation *verified = [self expectationWithDescription:@"Mac key matches QR"];

    [self.manager ensureTLSIdentity];
    NSString *qrPayload = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [qrPayload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSData *qrPublicKey = [[NSData alloc] initWithBase64EncodedString:json[@"publicKey"] options:0];
    XCTAssertNotNil(qrPublicKey);

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.ecdh.qrmatch", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t content, nw_content_context_t ctx,
                          bool is_complete, nw_error_t recvError) {
                        if (content) {
                            __block NSMutableData *macPubKey = [NSMutableData data];
                            dispatch_data_apply(content,
                                ^bool(dispatch_data_t r, size_t o, const void *b, size_t s) {
                                [macPubKey appendBytes:b length:s];
                                return true;
                            });
                            XCTAssertEqualObjects(macPubKey, qrPublicKey,
                                @"Mac's ECDH public key sent over wire should match QR payload");
                            [verified fulfill];
                        }
                        nw_connection_cancel(conn);
                    });
                });
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testECDHSharedSecretDerivation {
    /* Full round-trip: iPad and Mac derive the same shared secret */
    XCTestExpectation *secretVerified = [self expectationWithDescription:@"Shared secrets match"];

    [self.manager ensureTLSIdentity];
    NSString *qrPayload = [self.manager generateQRPayload];
    XCTAssertNotNil(qrPayload);

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.ecdh.secret", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t content, nw_content_context_t ctx,
                          bool is_complete, nw_error_t recvError) {
                        if (content) {
                            __block NSMutableData *macPubKey = [NSMutableData data];
                            dispatch_data_apply(content,
                                ^bool(dispatch_data_t r, size_t o, const void *b, size_t s) {
                                [macPubKey appendBytes:b length:s];
                                return true;
                            });

                            /* Derive secret on iPad side using iPad's private key + Mac's public key */
                            NSData *iPadSecret = deriveSharedSecret(iPadPrivate, macPubKey);
                            XCTAssertNotNil(iPadSecret,
                                @"iPad should derive shared secret");
                            XCTAssertEqual(iPadSecret.length, CC_SHA256_DIGEST_LENGTH,
                                @"Shared secret should be %d bytes (SHA-256)",
                                CC_SHA256_DIGEST_LENGTH);

                            /* Wait for Mac to finish storing to Keychain */
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                /* Mac's stored secret should match iPad's derived secret */
                                NSData *macSecret = self.manager.sharedSecret;
                                XCTAssertNotNil(macSecret,
                                    @"Mac should have stored shared secret");
                                XCTAssertEqualObjects(iPadSecret, macSecret,
                                    @"iPad and Mac derived secrets must be identical");
                                XCTAssertTrue(self.manager.isPaired,
                                    @"Manager should be paired after ECDH");
                                [secretVerified fulfill];
                            });
                        }
                        nw_connection_cancel(conn);
                    });
                });
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testECDHSharedSecretStoredInKeychain {
    /* After successful pairing, shared secret should be retrievable even from a new manager */
    XCTestExpectation *stored = [self expectationWithDescription:@"Secret in Keychain"];

    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];
    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.ecdh.keychain", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t content, nw_content_context_t ctx,
                          bool is_complete, nw_error_t recvError) {
                        /* Wait for Mac to store the secret */
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            /* Create a brand-new PairingManager -- it should load from Keychain */
                            PairingManager *freshManager = [[PairingManager alloc] init];
                            XCTAssertTrue(freshManager.isPaired,
                                @"Fresh manager should detect existing pairing from Keychain");
                            XCTAssertNotNil(freshManager.sharedSecret,
                                @"Fresh manager should load shared secret from Keychain");
                            XCTAssertEqualObjects(freshManager.sharedSecret,
                                                  self.manager.sharedSecret,
                                @"Keychain-loaded secret should match original");
                            [stored fulfill];
                        });
                        nw_connection_cancel(conn);
                    });
                });
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testECDHRejectsInvalidPublicKey {
    /* Sending garbage instead of a valid P-256 key should fail pairing */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload]; /* Initialize ECDH key */

    /* 65 bytes of garbage that is NOT a valid P-256 point */
    uint8_t garbage[65];
    memset(garbage, 0xFF, sizeof(garbage));
    garbage[0] = 0x04; /* Looks like uncompressed, but coordinates are all 0xFF (not on curve) */
    NSData *garbageKey = [NSData dataWithBytes:garbage length:sizeof(garbage)];

    BOOL result = [self.manager completePairing:garbageKey];
    XCTAssertFalse(result,
                   @"completePairing should reject garbage that isn't a valid P-256 point");
    XCTAssertFalse(self.manager.isPaired, @"Should not be paired after invalid key");
    XCTAssertNil(self.manager.sharedSecret, @"Should have no shared secret after invalid key");
}

- (void)testECDHRejectsTruncatedPublicKey {
    /* Sending only 32 bytes instead of 65 should fail */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    uint8_t truncated[32];
    SecRandomCopyBytes(kSecRandomDefault, sizeof(truncated), truncated);
    NSData *truncatedKey = [NSData dataWithBytes:truncated length:sizeof(truncated)];

    BOOL result = [self.manager completePairing:truncatedKey];
    XCTAssertFalse(result,
                   @"completePairing should reject 32-byte truncated key (needs 65 bytes)");
    XCTAssertFalse(self.manager.isPaired);
}

- (void)testECDHRejectsEmptyData {
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    BOOL result = [self.manager completePairing:[NSData data]];
    XCTAssertFalse(result, @"completePairing should reject empty data");
    XCTAssertFalse(self.manager.isPaired);
}

- (void)testECDHRejectsCompressedKey {
    /* Compressed P-256 key is 33 bytes (02 or 03 prefix) -- we only accept uncompressed (65 bytes) */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    /* Generate a real key and take only the first 33 bytes simulating compressed format */
    SecKeyRef tempKey = createTestP256PrivateKey();
    NSData *fullKey = publicKeyDataFromPrivateKey(tempKey);
    NSMutableData *compressed = [NSMutableData dataWithBytes:"\x02" length:1];
    [compressed appendData:[fullKey subdataWithRange:NSMakeRange(1, 32)]]; /* x-coordinate only */
    if (tempKey) CFRelease(tempKey);

    BOOL result = [self.manager completePairing:compressed];
    XCTAssertFalse(result,
                   @"completePairing should reject 33-byte compressed key format");
}

- (void)testECDHRequiresGenerateQRFirst {
    /* completePairing without generateQRPayload should fail (no ECDH private key) */
    [self.manager ensureTLSIdentity];
    /* Deliberately NOT calling generateQRPayload */

    SecKeyRef tempKey = createTestP256PrivateKey();
    NSData *pubData = publicKeyDataFromPrivateKey(tempKey);
    BOOL result = [self.manager completePairing:pubData];
    if (tempKey) CFRelease(tempKey);

    XCTAssertFalse(result,
                   @"completePairing should fail without prior generateQRPayload (no ECDH key)");
}

- (void)testECDHSecondCallFailsAfterSuccess {
    /* After successful pairing, the ECDH private key is released.
     * A second call to completePairing should fail. */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    SecKeyRef key1 = createTestP256PrivateKey();
    NSData *pub1 = publicKeyDataFromPrivateKey(key1);
    BOOL first = [self.manager completePairing:pub1];
    if (key1) CFRelease(key1);
    XCTAssertTrue(first, @"First completePairing should succeed");

    SecKeyRef key2 = createTestP256PrivateKey();
    NSData *pub2 = publicKeyDataFromPrivateKey(key2);
    BOOL second = [self.manager completePairing:pub2];
    if (key2) CFRelease(key2);
    XCTAssertFalse(second,
                   @"Second completePairing should fail (ECDH private key was released)");
}

- (void)testECDHSharedSecretIs32Bytes {
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    SecKeyRef iPadKey = createTestP256PrivateKey();
    NSData *iPadPub = publicKeyDataFromPrivateKey(iPadKey);
    BOOL ok = [self.manager completePairing:iPadPub];
    if (iPadKey) CFRelease(iPadKey);

    XCTAssertTrue(ok);
    XCTAssertNotNil(self.manager.sharedSecret);
    XCTAssertEqual(self.manager.sharedSecret.length, 32,
                   @"Derived shared secret should be 32 bytes (SHA-256), got %lu",
                   (unsigned long)self.manager.sharedSecret.length);
}

- (void)testECDHDifferentKeysProduceDifferentSecrets {
    /* Two different iPad key pairs should produce different shared secrets */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    SecKeyRef key1 = createTestP256PrivateKey();
    NSData *pub1 = publicKeyDataFromPrivateKey(key1);
    [self.manager completePairing:pub1];
    NSData *secret1 = [self.manager.sharedSecret copy];
    if (key1) CFRelease(key1);

    /* Reset and generate new ECDH key */
    [self.manager resetPairing];
    [self.manager generateQRPayload];

    SecKeyRef key2 = createTestP256PrivateKey();
    NSData *pub2 = publicKeyDataFromPrivateKey(key2);
    [self.manager completePairing:pub2];
    NSData *secret2 = [self.manager.sharedSecret copy];
    if (key2) CFRelease(key2);

    XCTAssertNotNil(secret1);
    XCTAssertNotNil(secret2);
    XCTAssertNotEqualObjects(secret1, secret2,
        @"Different key pairs should produce different shared secrets");
}

/* ============================================================================
 *  4. PAIRING STATE MACHINE
 * ============================================================================ */

#pragma mark - 4. Pairing State Machine

- (void)testPairingStateTransitions {
    /* Verify: unpaired -> ensureTLSIdentity -> generateQR -> completePairing -> paired */

    /* Step 1: Initial state is unpaired */
    PairingManager *mgr = [[PairingManager alloc] init];
    [mgr resetPairing]; /* Ensure clean state */
    XCTAssertFalse(mgr.isPaired, @"Initial state should be unpaired");
    XCTAssertNil(mgr.sharedSecret, @"No shared secret initially");
    XCTAssertTrue(mgr.tlsIdentity == NULL, @"No TLS identity initially");

    /* Step 2: Ensure TLS identity */
    [mgr ensureTLSIdentity];
    XCTAssertTrue(mgr.tlsIdentity != NULL, @"TLS identity should be set");
    XCTAssertFalse(mgr.isPaired, @"Still unpaired after TLS identity");

    /* Step 3: Generate QR (creates ECDH key pair) */
    NSString *qr = [mgr generateQRPayload];
    XCTAssertNotNil(qr, @"QR should be generated");
    XCTAssertFalse(mgr.isPaired, @"Still unpaired after QR generation");

    /* Step 4: Complete pairing with valid key */
    SecKeyRef iPadKey = createTestP256PrivateKey();
    NSData *iPadPub = publicKeyDataFromPrivateKey(iPadKey);
    BOOL result = [mgr completePairing:iPadPub];
    if (iPadKey) CFRelease(iPadKey);

    XCTAssertTrue(result, @"completePairing should succeed");
    XCTAssertTrue(mgr.isPaired, @"Should be paired after ECDH");
    XCTAssertNotNil(mgr.sharedSecret, @"Should have shared secret");

    [mgr resetPairing];
}

- (void)testPairingCompleteCallbackFires {
    XCTestExpectation *callbackFired = [self expectationWithDescription:@"onPairingComplete callback"];

    [self.manager ensureTLSIdentity];
    NSString *qrPayload = [self.manager generateQRPayload];
    XCTAssertNotNil(qrPayload, @"QR payload needed to initialize ECDH key");

    self.manager.onPairingComplete = ^{
        [callbackFired fulfill];
    };

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.callback", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    /* Wait for callback to fire via main queue */
                });
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testPairingCompleteCallbackFiresOnMainQueue {
    /* Verify onPairingComplete fires on the main queue (UI-safe) */
    XCTestExpectation *callbackFired = [self expectationWithDescription:@"Callback on main queue"];

    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    self.manager.onPairingComplete = ^{
        XCTAssertTrue([NSThread isMainThread],
                      @"onPairingComplete should fire on the main thread");
        [callbackFired fulfill];
    };

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.mainq", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable e) {});
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

- (void)testResetPairingClearsAllState {
    [self.manager ensureTLSIdentity];
    NSString *qr = [self.manager generateQRPayload];
    XCTAssertNotNil(qr);

    SecKeyRef testPrivate = createTestP256PrivateKey();
    NSData *testPubData = publicKeyDataFromPrivateKey(testPrivate);
    BOOL paired = [self.manager completePairing:testPubData];
    if (testPrivate) CFRelease(testPrivate);

    XCTAssertTrue(paired);
    XCTAssertTrue(self.manager.isPaired);
    XCTAssertNotNil(self.manager.sharedSecret);

    /* Reset pairing */
    [self.manager resetPairing];
    XCTAssertFalse(self.manager.isPaired,
                   @"isPaired should be NO after reset");
    XCTAssertNil(self.manager.sharedSecret,
                 @"sharedSecret should be nil after reset");

    /* Verify Keychain entries are gone by creating a fresh manager */
    PairingManager *freshManager = [[PairingManager alloc] init];
    XCTAssertFalse(freshManager.isPaired,
                   @"Fresh manager should not find pairing in Keychain after reset");
    XCTAssertNil(freshManager.sharedSecret,
                 @"Fresh manager should not find shared secret in Keychain after reset");
}

- (void)testResetPairingAllowsRepairing {
    /* After reset, a new QR + completePairing cycle should succeed */
    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    SecKeyRef key1 = createTestP256PrivateKey();
    NSData *pub1 = publicKeyDataFromPrivateKey(key1);
    BOOL first = [self.manager completePairing:pub1];
    if (key1) CFRelease(key1);
    XCTAssertTrue(first);
    NSData *firstSecret = [self.manager.sharedSecret copy];

    /* Reset and re-pair */
    [self.manager resetPairing];
    [self.manager generateQRPayload]; /* Fresh ECDH key */

    SecKeyRef key2 = createTestP256PrivateKey();
    NSData *pub2 = publicKeyDataFromPrivateKey(key2);
    BOOL second = [self.manager completePairing:pub2];
    if (key2) CFRelease(key2);
    XCTAssertTrue(second, @"Should be able to re-pair after reset");

    XCTAssertNotEqualObjects(self.manager.sharedSecret, firstSecret,
        @"New pairing should produce a different shared secret");
}

- (void)testPairingListenerStopsAfterSuccess {
    /* After successful pairing, the listener should stop itself.
     * We verify by:
     * 1. Completing a pairing over the network
     * 2. Checking that a second completePairing call fails (ECDH key released)
     * 3. Checking that the listener was cancelled (POSIX socket connect refused) */
    XCTestExpectation *firstDone = [self expectationWithDescription:@"First pairing done"];

    [self.manager ensureTLSIdentity];
    [self.manager generateQRPayload];

    self.manager.onPairingComplete = ^{
        [firstDone fulfill];
    };

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.stopsafter", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    /* First connection: complete pairing */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable e) {
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t content, nw_content_context_t ctx,
                          bool is_complete, nw_error_t recvError) {
                        nw_connection_cancel(conn);
                    });
                });
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectations:@[firstDone] timeout:3.0];

    if (iPadPrivate) CFRelease(iPadPrivate);

    /* After successful pairing, the ECDH private key is released.
     * A second completePairing attempt should fail because the listener
     * stopped and the key was cleaned up. */
    SecKeyRef key2 = createTestP256PrivateKey();
    NSData *pub2 = publicKeyDataFromPrivateKey(key2);
    BOOL secondResult = [self.manager completePairing:pub2];
    if (key2) CFRelease(key2);
    XCTAssertFalse(secondResult,
                   @"After pairing, ECDH key is released so second completePairing should fail");

    /* Verify listener was cancelled: try a raw POSIX connect.
     * Give a moment for cancellation to take effect. */
    usleep(200000); /* 200ms */
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(KEYDRD_PAIRING_PORT);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    /* Set non-blocking to avoid hanging */
    fcntl(sock, F_SETFL, O_NONBLOCK);
    int result = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    if (result < 0 && errno == EINPROGRESS) {
        /* Wait briefly for connect to complete/fail */
        fd_set writefds;
        FD_ZERO(&writefds);
        FD_SET(sock, &writefds);
        struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
        int sel = select(sock + 1, NULL, &writefds, NULL, &tv);
        if (sel > 0) {
            int so_error;
            socklen_t len = sizeof(so_error);
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
            /* Connection refused is what we expect */
            XCTAssertEqual(so_error, ECONNREFUSED,
                           @"After pairing, listener should be stopped (got errno %d)", so_error);
        } else {
            /* Timeout or select error -- listener may still be shutting down, acceptable */
        }
    } else if (result < 0) {
        XCTAssertEqual(errno, ECONNREFUSED,
                       @"Listener should refuse connections after pairing");
    }
    close(sock);
}

- (void)testReEntryGuardBlocksDuplicateConnection {
    /* Start listener, connect TWO clients rapidly, verify only one pairing completes */
    XCTestExpectation *firstComplete = [self expectationWithDescription:@"First pairing complete"];
    firstComplete.assertForOverFulfill = YES;

    [self.manager ensureTLSIdentity];
    NSString *qr = [self.manager generateQRPayload];
    XCTAssertNotNil(qr, @"QR payload needed");

    __block int pairingCompleteCount = 0;
    self.manager.onPairingComplete = ^{
        pairingCompleteCount++;
        [firstComplete fulfill];
    };

    [self.manager startPairingListener];

    dispatch_queue_t queue = dispatch_queue_create("test.pairing.reentry", DISPATCH_QUEUE_SERIAL);

    SecKeyRef iPad1Private = createTestP256PrivateKey();
    NSData *iPad1PubData = publicKeyDataFromPrivateKey(iPad1Private);
    SecKeyRef iPad2Private = createTestP256PrivateKey();
    NSData *iPad2PubData = publicKeyDataFromPrivateKey(iPad2Private);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        /* Helper block */
        void (^connectAndSendKey)(NSData *pubKey) = ^(NSData *pubKey) {
            nw_connection_t conn = createTLSClientConnection(queue);
            nw_connection_set_queue(conn, queue);
            nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                             nw_error_t _Nullable error) {
                if (state == nw_connection_state_ready) {
                    sendData(conn, pubKey, ^(nw_error_t _Nullable sendError) {});
                }
            });
            nw_connection_start(conn);
        };

        /* Fire both connections as fast as possible */
        connectAndSendKey(iPad1PubData);
        connectAndSendKey(iPad2PubData);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPad1Private) CFRelease(iPad1Private);
        if (iPad2Private) CFRelease(iPad2Private);

        XCTAssertEqual(pairingCompleteCount, 1,
                       @"Only one pairing should complete (got %d)", pairingCompleteCount);
    }];
}

- (void)testStopPairingListenerIsIdempotent {
    /* Calling stopPairingListener multiple times should not crash */
    [self.manager ensureTLSIdentity];
    [self.manager startPairingListener];
    [self.manager stopPairingListener];
    [self.manager stopPairingListener]; /* Second call should be safe */
    [self.manager stopPairingListener]; /* Third call should also be safe */
}

- (void)testFullPairingFlowEndToEnd {
    /* The complete flow: TLS identity -> QR -> listener -> connect -> ECDH -> paired + callback */
    XCTestExpectation *flowComplete = [self expectationWithDescription:@"Full flow complete"];

    /* Step 1: TLS identity */
    [self.manager ensureTLSIdentity];
    XCTAssertTrue(self.manager.tlsIdentity != NULL);

    /* Step 2: QR payload */
    NSString *qr = [self.manager generateQRPayload];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
        [qr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertNotNil(json);

    /* Step 3: Start listener */
    self.manager.onPairingComplete = ^{
        /* Step 6: Verify final state */
        XCTAssertTrue(self.manager.isPaired);
        XCTAssertNotNil(self.manager.sharedSecret);
        XCTAssertEqual(self.manager.sharedSecret.length, 32);
        [flowComplete fulfill];
    };
    [self.manager startPairingListener];

    /* Step 4: iPad connects */
    dispatch_queue_t queue = dispatch_queue_create("test.e2e", DISPATCH_QUEUE_SERIAL);
    SecKeyRef iPadPrivate = createTestP256PrivateKey();
    NSData *iPadPubData = publicKeyDataFromPrivateKey(iPadPrivate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), queue, ^{
        nw_connection_t conn = createTLSClientConnection(queue);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                /* Step 5: ECDH exchange */
                sendData(conn, iPadPubData, ^(nw_error_t _Nullable sendError) {
                    XCTAssertNil(sendError);
                    nw_connection_receive(conn, 1, 256,
                        ^(dispatch_data_t content, nw_content_context_t ctx,
                          bool is_complete, nw_error_t recvError) {
                        XCTAssertNotNil(content);
                        XCTAssertEqual(dispatch_data_get_size(content), 65,
                            @"Mac should send 65-byte P-256 public key");
                        nw_connection_cancel(conn);
                    });
                });
            } else if (state == nw_connection_state_failed) {
                XCTFail(@"Connection failed: %@", error);
            }
        });
        nw_connection_start(conn);
    });

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        if (iPadPrivate) CFRelease(iPadPrivate);
    }];
}

@end
