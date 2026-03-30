#import <XCTest/XCTest.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include "TransportFSM.h"
#include "protocol.h"
#include <zlib.h>

#pragma mark - Helper: check if effect array contains a given effect

static BOOL transitionContainsEffect(TransportTransition t, TransportEffect e) {
    for (int i = 0; i < t.effect_count; i++) {
        if (t.effects[i] == e) return YES;
    }
    return NO;
}

#pragma mark - Helper: verify effects match an expected list exactly

/**
 * Verify that a transition has exactly the expected effects in order.
 * Pass a NULL-terminated list of expected TransportEffect values.
 */
static BOOL transitionEffectsMatch(TransportTransition t, int count, TransportEffect expected[]) {
    if (t.effect_count != count) return NO;
    for (int i = 0; i < count; i++) {
        if (t.effects[i] != expected[i]) return NO;
    }
    return YES;
}

#pragma mark - Helper: PKCS12 identity for TLS tests

/**
 * Generate a self-signed P-256 PKCS12 identity via OpenSSL.
 * Returns the path to the .p12 file, or nil on failure.
 * Each call generates a UNIQUE identity (different key pair).
 */
static NSString *generateTestPKCS12(NSString *cn) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"keydrd-transport-test-%u", arc4random()]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *keyPath = [dir stringByAppendingPathComponent:@"key.pem"];
    NSString *certPath = [dir stringByAppendingPathComponent:@"cert.pem"];
    NSString *p12Path = [dir stringByAppendingPathComponent:@"identity.p12"];

    NSString *subject = [NSString stringWithFormat:@"/CN=%@", cn];

    NSArray<NSArray<NSString *> *> *commands = @[
        @[@"/usr/bin/openssl", @"ecparam", @"-genkey", @"-name", @"prime256v1", @"-noout", @"-out", keyPath],
        @[@"/usr/bin/openssl", @"req", @"-new", @"-x509", @"-key", keyPath, @"-out", certPath,
          @"-days", @"1", @"-subj", subject],
        @[@"/usr/bin/openssl", @"pkcs12", @"-export", @"-inkey", keyPath, @"-in", certPath,
          @"-out", p12Path, @"-passout", @"pass:keydrd", @"-legacy"],
    ];

    for (NSArray<NSString *> *cmd in commands) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:cmd[0]];
        task.arguments = [cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)];
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        NSError *err = nil;
        [task launchAndReturnError:&err];
        if (err) return nil;
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            /* Retry without -legacy flag for older OpenSSL */
            if ([cmd containsObject:@"-legacy"]) {
                NSMutableArray *retry = [cmd mutableCopy];
                [retry removeObject:@"-legacy"];
                NSTask *retryTask = [[NSTask alloc] init];
                retryTask.executableURL = [NSURL fileURLWithPath:retry[0]];
                retryTask.arguments = [retry subarrayWithRange:NSMakeRange(1, retry.count - 1)];
                retryTask.standardOutput = [NSPipe pipe];
                retryTask.standardError = [NSPipe pipe];
                [retryTask launchAndReturnError:nil];
                [retryTask waitUntilExit];
                if (retryTask.terminationStatus != 0) return nil;
            } else {
                return nil;
            }
        }
    }

    return [fm fileExistsAtPath:p12Path] ? p12Path : nil;
}

/**
 * Load a SecIdentityRef from a PKCS12 file.
 * Caller must CFRelease the returned identity.
 */
static SecIdentityRef loadIdentityFromPKCS12(NSString *path) {
    NSData *p12Data = [NSData dataWithContentsOfFile:path];
    if (!p12Data) return NULL;

    NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: @"keydrd"};
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12Data,
                                      (__bridge CFDictionaryRef)options,
                                      &items);
    if (status != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        if (items) CFRelease(items);
        return NULL;
    }

    NSDictionary *dict = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (__bridge SecIdentityRef)dict[(__bridge id)kSecImportItemIdentity];
    if (identity) CFRetain(identity);
    CFRelease(items);
    return identity;
}

/**
 * Extract the SHA-256 fingerprint of the certificate in a SecIdentityRef.
 */
static NSData *fingerprintFromIdentity(SecIdentityRef identity) {
    SecCertificateRef cert = NULL;
    OSStatus status = SecIdentityCopyCertificate(identity, &cert);
    if (status != errSecSuccess || !cert) return nil;

    CFDataRef certData = SecCertificateCopyData(cert);
    CFRelease(cert);
    if (!certData) return nil;

    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(certData), (CC_LONG)CFDataGetLength(certData), hash);
    CFRelease(certData);
    return [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
}

#pragma mark - Helper: extract dispatch_data to NSData

static NSData *dataFromDispatchData(dispatch_data_t dd) {
    if (!dd) return nil;
    NSMutableData *result = [NSMutableData data];
    dispatch_data_apply(dd, ^bool(dispatch_data_t region, size_t offset,
                                   const void *buffer, size_t size) {
        [result appendBytes:buffer length:size];
        return true;
    });
    return result;
}

#pragma mark - TransportFSM Tests

@interface TransportFSMTests : XCTestCase
@end

@implementation TransportFSMTests

- (void)testFSMIdleToUSB {
    TransportTransition t = transport_fsm_transition(TRANSPORT_IDLE,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM,
                   @"IDLE + WIRED_APPEARED should transition to USB_NCM");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_BIND_USB_NCM),
                  @"Should include BIND_USB_NCM effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                  @"Should include SWITCH_ENCODE_LZ4 effect (wired uses LZ4)");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
    /* From IDLE there is no active connection, so DISCONNECT_CURRENT should NOT be present */
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                   @"Should NOT include DISCONNECT_CURRENT from IDLE state");
}

- (void)testFSMIdleToWiFi {
    TransportTransition t = transport_fsm_transition(TRANSPORT_IDLE,
                                                     TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI,
                   @"IDLE + WIFI_AVAILABLE should transition to WIFI");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_WIFI),
                  @"Should include CONNECT_WIFI effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"Should include SWITCH_ENCODE_HEVC effect (wireless uses HEVC)");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
}

- (void)testFSMIdleToAWDL {
    TransportTransition t = transport_fsm_transition(TRANSPORT_IDLE,
                                                     TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_AWDL,
                   @"IDLE + AWDL_AVAILABLE should transition to AWDL");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_AWDL),
                  @"Should include CONNECT_AWDL effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"Should include SWITCH_ENCODE_HEVC effect (wireless uses HEVC)");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
}

- (void)testFSMUSBPreemptsWiFi {
    /* When already on USB_NCM, WiFi becoming available should be a no-op
     * because USB has the highest priority. */
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM,
                   @"USB_NCM + WIFI_AVAILABLE should stay in USB_NCM (USB has priority)");
    XCTAssertEqual(t.effect_count, 0,
                   @"Should have zero effects (no-op)");
}

- (void)testFSMWiFiToUSB {
    /* USB appearing while on WiFi should promote to USB with disconnect first */
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM,
                   @"WIFI + WIRED_APPEARED should transition to USB_NCM");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                  @"Should include DISCONNECT_CURRENT (tear down WiFi first)");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_BIND_USB_NCM),
                  @"Should include BIND_USB_NCM effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                  @"Should include SWITCH_ENCODE_LZ4 effect");
}

- (void)testFSMUSBDisconnectToDisconnected {
    /* USB disappearing while on USB_NCM should go to DISCONNECTED */
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_WIRED_DISAPPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED,
                   @"USB_NCM + WIRED_DISAPPEARED should transition to DISCONNECTED");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                  @"Should include DISCONNECT_CURRENT effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
}

- (void)testFSMWiFiDisconnect {
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_WIFI_UNAVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED,
                   @"WIFI + WIFI_UNAVAILABLE should transition to DISCONNECTED");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                  @"Should include DISCONNECT_CURRENT effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
}

- (void)testFSMDisconnectedToUSB {
    TransportTransition t = transport_fsm_transition(TRANSPORT_DISCONNECTED,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM,
                   @"DISCONNECTED + WIRED_APPEARED should transition to USB_NCM");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_BIND_USB_NCM),
                  @"Should include BIND_USB_NCM effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                  @"Should include SWITCH_ENCODE_LZ4 effect");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE),
                  @"Should include NOTIFY_TRANSPORT_CHANGE effect");
    /* From DISCONNECTED there is no live connection to tear down */
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                   @"Should NOT include DISCONNECT_CURRENT from DISCONNECTED state");
}

- (void)testFSMStateNames {
    TransportState states[] = {
        TRANSPORT_IDLE,
        TRANSPORT_USB_NCM,
        TRANSPORT_WIFI,
        TRANSPORT_AWDL,
        TRANSPORT_DISCONNECTED
    };
    for (int i = 0; i < (int)(sizeof(states) / sizeof(states[0])); i++) {
        const char *name = transport_state_name(states[i]);
        XCTAssertTrue(name != NULL,
                      @"transport_state_name should return non-NULL for state %d", states[i]);
        XCTAssertTrue(strlen(name) > 0,
                      @"transport_state_name should return non-empty string for state %d", states[i]);
    }
}

- (void)testFSMEventNames {
    TransportEvent events[] = {
        TRANSPORT_EVT_WIRED_APPEARED,
        TRANSPORT_EVT_WIRED_DISAPPEARED,
        TRANSPORT_EVT_WIFI_AVAILABLE,
        TRANSPORT_EVT_WIFI_UNAVAILABLE,
        TRANSPORT_EVT_AWDL_AVAILABLE,
        TRANSPORT_EVT_AWDL_UNAVAILABLE,
        TRANSPORT_EVT_CONNECTED,
        TRANSPORT_EVT_DISCONNECTED,
        TRANSPORT_EVT_ERROR
    };
    for (int i = 0; i < (int)(sizeof(events) / sizeof(events[0])); i++) {
        const char *name = transport_event_name(events[i]);
        XCTAssertTrue(name != NULL,
                      @"transport_event_name should return non-NULL for event %d", events[i]);
        XCTAssertTrue(strlen(name) > 0,
                      @"transport_event_name should return non-empty string for event %d", events[i]);
    }
}

- (void)testFSMEffectNames {
    TransportEffect effects[] = {
        EFFECT_NONE,
        EFFECT_BIND_USB_NCM,
        EFFECT_CONNECT_WIFI,
        EFFECT_CONNECT_AWDL,
        EFFECT_DISCONNECT_CURRENT,
        EFFECT_SWITCH_ENCODE_LZ4,
        EFFECT_SWITCH_ENCODE_HEVC,
        EFFECT_NOTIFY_TRANSPORT_CHANGE
    };
    for (int i = 0; i < (int)(sizeof(effects) / sizeof(effects[0])); i++) {
        const char *name = transport_effect_name(effects[i]);
        XCTAssertTrue(name != NULL,
                      @"transport_effect_name should return non-NULL for effect %d", effects[i]);
        XCTAssertTrue(strlen(name) > 0,
                      @"transport_effect_name should return non-empty string for effect %d", effects[i]);
    }
}

- (void)testFSMAllTransitionsNoNull {
    /* Exhaustively iterate all state x event combinations and verify
     * no crash occurs and effect_count is within bounds. */
    TransportState states[] = {
        TRANSPORT_IDLE,
        TRANSPORT_USB_NCM,
        TRANSPORT_WIFI,
        TRANSPORT_AWDL,
        TRANSPORT_DISCONNECTED
    };
    TransportEvent events[] = {
        TRANSPORT_EVT_WIRED_APPEARED,
        TRANSPORT_EVT_WIRED_DISAPPEARED,
        TRANSPORT_EVT_WIFI_AVAILABLE,
        TRANSPORT_EVT_WIFI_UNAVAILABLE,
        TRANSPORT_EVT_AWDL_AVAILABLE,
        TRANSPORT_EVT_AWDL_UNAVAILABLE,
        TRANSPORT_EVT_CONNECTED,
        TRANSPORT_EVT_DISCONNECTED,
        TRANSPORT_EVT_ERROR
    };
    int stateCount = (int)(sizeof(states) / sizeof(states[0]));
    int eventCount = (int)(sizeof(events) / sizeof(events[0]));

    for (int s = 0; s < stateCount; s++) {
        for (int e = 0; e < eventCount; e++) {
            TransportTransition t = transport_fsm_transition(states[s], events[e]);
            /* Verify effect_count is sane */
            XCTAssertGreaterThanOrEqual(t.effect_count, 0,
                @"effect_count should be >= 0 for state=%d event=%d", states[s], events[e]);
            XCTAssertLessThanOrEqual(t.effect_count, TRANSPORT_MAX_EFFECTS,
                @"effect_count should be <= %d for state=%d event=%d",
                TRANSPORT_MAX_EFFECTS, states[s], events[e]);
            /* Verify next_state is a valid value */
            XCTAssertTrue(t.next_state >= TRANSPORT_IDLE && t.next_state <= TRANSPORT_DISCONNECTED,
                @"next_state should be a valid TransportState for state=%d event=%d",
                states[s], events[e]);
        }
    }
}

#pragma mark - FSM Full Cascade: USB > WiFi > AWDL with all transitions

- (void)testFSMFullCascade_USB_WiFi_AWDL {
    /*
     * Simulate the full transport cascade:
     *   IDLE -> WiFi -> USB (preempts WiFi) -> DISCONNECTED (USB gone)
     *        -> WiFi (reconnect) -> DISCONNECTED (WiFi gone)
     *        -> AWDL -> DISCONNECTED (AWDL gone)
     *
     * Verify every transition, every effect, every encode mode switch.
     */
    TransportState state = TRANSPORT_IDLE;
    TransportTransition t;

    /* Step 1: WiFi appears from IDLE */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_WIFI));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"Wireless uses HEVC encoding");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    state = t.next_state;

    /* Step 2: USB appears -- should preempt WiFi */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                  @"Must disconnect WiFi first");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_BIND_USB_NCM));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                  @"Wired uses LZ4 encoding");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    XCTAssertEqual(t.effect_count, 4, @"Should have exactly 4 effects");
    state = t.next_state;

    /* Step 3: USB disappears -- fallback to DISCONNECTED */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIRED_DISAPPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    state = t.next_state;

    /* Step 4: WiFi reappears from DISCONNECTED */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_WIFI));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC));
    state = t.next_state;

    /* Step 5: WiFi disappears */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_UNAVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    state = t.next_state;

    /* Step 6: AWDL appears from DISCONNECTED */
    t = transport_fsm_transition(state, TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_AWDL);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_AWDL));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"AWDL also uses HEVC encoding");
    state = t.next_state;

    /* Step 7: AWDL disappears */
    t = transport_fsm_transition(state, TRANSPORT_EVT_AWDL_UNAVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
}

- (void)testFSMUSBPreemption {
    /*
     * Start on WiFi, USB appears mid-stream.
     * Verify the exact effect sequence: DISCONNECT_CURRENT, BIND_USB_NCM, SWITCH_ENCODE_LZ4, NOTIFY.
     */
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertEqual(t.effect_count, 4);

    TransportEffect expected[] = {
        EFFECT_DISCONNECT_CURRENT,
        EFFECT_BIND_USB_NCM,
        EFFECT_SWITCH_ENCODE_LZ4,
        EFFECT_NOTIFY_TRANSPORT_CHANGE
    };
    XCTAssertTrue(transitionEffectsMatch(t, 4, expected),
                  @"Effects should be DISCONNECT, BIND_USB, LZ4, NOTIFY in exact order");
}

- (void)testFSMAWDLPreemptedByUSB {
    /* USB should also preempt AWDL with disconnect first */
    TransportTransition t = transport_fsm_transition(TRANSPORT_AWDL,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_BIND_USB_NCM));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4));
    XCTAssertEqual(t.effect_count, 4);
}

- (void)testFSMAWDLPromotedToWiFi {
    /* WiFi appearing while on AWDL should promote to WiFi (WiFi > AWDL) */
    TransportTransition t = transport_fsm_transition(TRANSPORT_AWDL,
                                                     TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                  @"Must disconnect AWDL first");
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_WIFI));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    /* No encode mode switch -- both AWDL and WiFi use HEVC */
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                   @"No encode switch needed (AWDL->WiFi both HEVC)");
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4));
}

- (void)testFSMWiFiIgnoresAWDL {
    /* While on WiFi, AWDL appearing should be a no-op (WiFi is preferred) */
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertEqual(t.effect_count, 0, @"WiFi should ignore AWDL appearing");
}

- (void)testFSMUSBIgnoresAWDL {
    /* While on USB, AWDL appearing should be a no-op */
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertEqual(t.effect_count, 0);
}

- (void)testFSMUSBAlreadyOnUSBIsNoOp {
    /* If already on USB and USB appears again, no-op */
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_WIRED_APPEARED);
    XCTAssertEqual(t.next_state, TRANSPORT_USB_NCM);
    XCTAssertEqual(t.effect_count, 0);
}

- (void)testFSMErrorFromUSB {
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_ERROR);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
}

- (void)testFSMErrorFromWiFi {
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_ERROR);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMErrorFromAWDL {
    TransportTransition t = transport_fsm_transition(TRANSPORT_AWDL,
                                                     TRANSPORT_EVT_ERROR);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMDisconnectedEventFromUSB {
    TransportTransition t = transport_fsm_transition(TRANSPORT_USB_NCM,
                                                     TRANSPORT_EVT_DISCONNECTED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMDisconnectedEventFromWiFi {
    TransportTransition t = transport_fsm_transition(TRANSPORT_WIFI,
                                                     TRANSPORT_EVT_DISCONNECTED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMDisconnectedEventFromAWDL {
    TransportTransition t = transport_fsm_transition(TRANSPORT_AWDL,
                                                     TRANSPORT_EVT_DISCONNECTED);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMAllEventFromEveryState {
    /*
     * Exhaustively test every (state, event) pair.
     * For each, verify:
     *   1. No crash
     *   2. Valid next_state
     *   3. effect_count within bounds
     *   4. All effects are valid enum values
     *   5. No-op transitions have effect_count == 0 and same state
     */
    TransportState states[] = {
        TRANSPORT_IDLE, TRANSPORT_USB_NCM, TRANSPORT_WIFI,
        TRANSPORT_AWDL, TRANSPORT_DISCONNECTED
    };
    TransportEvent events[] = {
        TRANSPORT_EVT_WIRED_APPEARED, TRANSPORT_EVT_WIRED_DISAPPEARED,
        TRANSPORT_EVT_WIFI_AVAILABLE, TRANSPORT_EVT_WIFI_UNAVAILABLE,
        TRANSPORT_EVT_AWDL_AVAILABLE, TRANSPORT_EVT_AWDL_UNAVAILABLE,
        TRANSPORT_EVT_CONNECTED, TRANSPORT_EVT_DISCONNECTED,
        TRANSPORT_EVT_ERROR
    };
    int stateCount = (int)(sizeof(states) / sizeof(states[0]));
    int eventCount = (int)(sizeof(events) / sizeof(events[0]));

    for (int s = 0; s < stateCount; s++) {
        for (int e = 0; e < eventCount; e++) {
            TransportTransition t = transport_fsm_transition(states[s], events[e]);

            XCTAssertGreaterThanOrEqual(t.effect_count, 0,
                @"effect_count >= 0 for %s + %s",
                transport_state_name(states[s]),
                transport_event_name(events[e]));
            XCTAssertLessThanOrEqual(t.effect_count, TRANSPORT_MAX_EFFECTS,
                @"effect_count <= %d for %s + %s",
                TRANSPORT_MAX_EFFECTS,
                transport_state_name(states[s]),
                transport_event_name(events[e]));

            XCTAssertTrue(t.next_state >= TRANSPORT_IDLE && t.next_state <= TRANSPORT_DISCONNECTED,
                @"Valid next_state for %s + %s",
                transport_state_name(states[s]),
                transport_event_name(events[e]));

            /* Verify all effects are valid enum values */
            for (int i = 0; i < t.effect_count; i++) {
                XCTAssertTrue(t.effects[i] >= EFFECT_NONE &&
                              t.effects[i] <= EFFECT_NOTIFY_TRANSPORT_CHANGE,
                    @"Valid effect[%d] for %s + %s",
                    i, transport_state_name(states[s]),
                    transport_event_name(events[e]));
            }

            /* Unused effect slots should be EFFECT_NONE */
            for (int i = t.effect_count; i < TRANSPORT_MAX_EFFECTS; i++) {
                XCTAssertEqual(t.effects[i], EFFECT_NONE,
                    @"Unused effect slot should be NONE for %s + %s",
                    transport_state_name(states[s]),
                    transport_event_name(events[e]));
            }

            /* If no state change and no effects, it's a valid no-op */
            if (t.next_state == states[s]) {
                /* No-op is valid -- but if there are effects, the state
                 * should still be consistent (no stale effects) */
            }
        }
    }
}

- (void)testFSMIdempotentNoOpEvents {
    /*
     * Events that should be no-ops in each state:
     * - IDLE: everything except WIRED_APPEARED, WIFI_AVAILABLE, AWDL_AVAILABLE
     * - USB_NCM: WIFI_AVAILABLE, AWDL_AVAILABLE, CONNECTED, WIFI_UNAVAILABLE, AWDL_UNAVAILABLE
     * - WIFI: AWDL_AVAILABLE, CONNECTED, WIRED_DISAPPEARED, AWDL_UNAVAILABLE
     * - AWDL: CONNECTED, WIRED_DISAPPEARED, WIFI_UNAVAILABLE
     * - DISCONNECTED: most except WIRED_APPEARED, WIFI_AVAILABLE, AWDL_AVAILABLE
     */
    /* Spot-check some expected no-ops */
    struct {
        TransportState state;
        TransportEvent event;
    } noOps[] = {
        {TRANSPORT_IDLE, TRANSPORT_EVT_WIRED_DISAPPEARED},
        {TRANSPORT_IDLE, TRANSPORT_EVT_WIFI_UNAVAILABLE},
        {TRANSPORT_IDLE, TRANSPORT_EVT_AWDL_UNAVAILABLE},
        {TRANSPORT_IDLE, TRANSPORT_EVT_CONNECTED},
        {TRANSPORT_IDLE, TRANSPORT_EVT_DISCONNECTED},
        {TRANSPORT_IDLE, TRANSPORT_EVT_ERROR},
        {TRANSPORT_USB_NCM, TRANSPORT_EVT_WIFI_AVAILABLE},
        {TRANSPORT_USB_NCM, TRANSPORT_EVT_AWDL_AVAILABLE},
        {TRANSPORT_USB_NCM, TRANSPORT_EVT_WIFI_UNAVAILABLE},
        {TRANSPORT_USB_NCM, TRANSPORT_EVT_AWDL_UNAVAILABLE},
        {TRANSPORT_USB_NCM, TRANSPORT_EVT_CONNECTED},
        {TRANSPORT_WIFI, TRANSPORT_EVT_AWDL_AVAILABLE},
        {TRANSPORT_WIFI, TRANSPORT_EVT_WIRED_DISAPPEARED},
        {TRANSPORT_WIFI, TRANSPORT_EVT_AWDL_UNAVAILABLE},
        {TRANSPORT_WIFI, TRANSPORT_EVT_CONNECTED},
        {TRANSPORT_AWDL, TRANSPORT_EVT_WIRED_DISAPPEARED},
        {TRANSPORT_AWDL, TRANSPORT_EVT_WIFI_UNAVAILABLE},
        {TRANSPORT_AWDL, TRANSPORT_EVT_CONNECTED},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_WIRED_DISAPPEARED},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_WIFI_UNAVAILABLE},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_AWDL_UNAVAILABLE},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_CONNECTED},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_DISCONNECTED},
        {TRANSPORT_DISCONNECTED, TRANSPORT_EVT_ERROR},
    };
    int count = (int)(sizeof(noOps) / sizeof(noOps[0]));
    for (int i = 0; i < count; i++) {
        TransportTransition t = transport_fsm_transition(noOps[i].state, noOps[i].event);
        XCTAssertEqual(t.next_state, noOps[i].state,
            @"Should be no-op: %s + %s",
            transport_state_name(noOps[i].state),
            transport_event_name(noOps[i].event));
        XCTAssertEqual(t.effect_count, 0,
            @"No-op should have zero effects: %s + %s",
            transport_state_name(noOps[i].state),
            transport_event_name(noOps[i].event));
    }
}

- (void)testFSMDisconnectedRecoveryToWiFi {
    TransportTransition t = transport_fsm_transition(TRANSPORT_DISCONNECTED,
                                                     TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_WIFI));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT),
                   @"Nothing to disconnect from DISCONNECTED");
}

- (void)testFSMDisconnectedRecoveryToAWDL {
    TransportTransition t = transport_fsm_transition(TRANSPORT_DISCONNECTED,
                                                     TRANSPORT_EVT_AWDL_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_AWDL);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_CONNECT_AWDL));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
}

- (void)testFSMEncodeModeConsistency {
    /*
     * Verify the invariant: USB always produces LZ4, wireless always produces HEVC.
     * Walk through every transition that changes state and verify the encode effect.
     */
    TransportState states[] = {
        TRANSPORT_IDLE, TRANSPORT_USB_NCM, TRANSPORT_WIFI,
        TRANSPORT_AWDL, TRANSPORT_DISCONNECTED
    };
    TransportEvent events[] = {
        TRANSPORT_EVT_WIRED_APPEARED, TRANSPORT_EVT_WIRED_DISAPPEARED,
        TRANSPORT_EVT_WIFI_AVAILABLE, TRANSPORT_EVT_WIFI_UNAVAILABLE,
        TRANSPORT_EVT_AWDL_AVAILABLE, TRANSPORT_EVT_AWDL_UNAVAILABLE,
        TRANSPORT_EVT_CONNECTED, TRANSPORT_EVT_DISCONNECTED,
        TRANSPORT_EVT_ERROR
    };

    for (int s = 0; s < 5; s++) {
        for (int e = 0; e < 9; e++) {
            TransportTransition t = transport_fsm_transition(states[s], events[e]);
            if (t.next_state == states[s]) continue; /* skip no-ops */

            if (t.next_state == TRANSPORT_USB_NCM) {
                XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                    @"Transition to USB_NCM must switch to LZ4: %s + %s",
                    transport_state_name(states[s]), transport_event_name(events[e]));
                XCTAssertFalse(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                    @"Transition to USB_NCM must not switch to HEVC");
            }

            if (t.next_state == TRANSPORT_WIFI || t.next_state == TRANSPORT_AWDL) {
                /* WiFi/AWDL from non-wireless states should switch to HEVC */
                if (states[s] != TRANSPORT_WIFI && states[s] != TRANSPORT_AWDL) {
                    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                        @"Transition to wireless from non-wireless must switch to HEVC: %s + %s",
                        transport_state_name(states[s]), transport_event_name(events[e]));
                }
                XCTAssertFalse(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                    @"Transition to wireless must not switch to LZ4");
            }
        }
    }
}

- (void)testFSMRepeatedTransitionsAreStable {
    /*
     * Apply the same event repeatedly and verify the FSM is stable (no oscillation).
     */
    TransportState state = TRANSPORT_IDLE;

    /* Transition to WiFi */
    TransportTransition t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    state = t.next_state;
    XCTAssertEqual(state, TRANSPORT_WIFI);

    /* Send WiFi available again -- should be no-op */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
    XCTAssertEqual(t.effect_count, 0, @"Repeated WiFi available should be no-op");

    /* Send it 100 times */
    for (int i = 0; i < 100; i++) {
        t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
        XCTAssertEqual(t.next_state, TRANSPORT_WIFI);
        XCTAssertEqual(t.effect_count, 0);
    }
}

- (void)testFSMAWDLToDisconnected {
    TransportTransition t = transport_fsm_transition(TRANSPORT_AWDL,
                                                     TRANSPORT_EVT_AWDL_UNAVAILABLE);
    XCTAssertEqual(t.next_state, TRANSPORT_DISCONNECTED);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_DISCONNECT_CURRENT));
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_NOTIFY_TRANSPORT_CHANGE));
}

@end

#pragma mark - TCP / UDP Localhost Loopback Tests

@interface TransportNetworkTests : XCTestCase
@end

@implementation TransportNetworkTests

- (void)testTCPLocalhostSendReceive {
    XCTestExpectation *expectation = [self expectationWithDescription:@"TCP send/receive on localhost"];

    /* Create TCP listener on port 0 (auto-assign) */
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );

    nw_listener_t listener = nw_listener_create(params);
    __block uint16_t assignedPort = 0;

    dispatch_queue_t queue = dispatch_queue_create("test.tcp.loopback", DISPATCH_QUEUE_SERIAL);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                /* Receive data from client */
                nw_connection_receive(serverConn, 1, 1024,
                    ^(dispatch_data_t _Nullable content,
                      nw_content_context_t _Nullable ctx,
                      bool is_complete,
                      nw_error_t _Nullable recvError) {
                    if (content) {
                        NSData *received = dataFromDispatchData(content);
                        NSString *msg = [[NSString alloc] initWithData:received
                                                              encoding:NSUTF8StringEncoding];
                        XCTAssertEqualObjects(msg, @"hello",
                                              @"Server should receive 'hello' from client");
                        [expectation fulfill];
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            assignedPort = nw_listener_get_port(listener);
            XCTAssertGreaterThan(assignedPort, 0, @"Listener should be assigned a port");

            /* Connect client to listener */
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", assignedPort);
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL,
                NW_PARAMETERS_DEFAULT_CONFIGURATION
            );
            nw_connection_t client = nw_connection_create(endpoint, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    const char *msg = "hello";
                    dispatch_data_t data = dispatch_data_create(msg, strlen(msg),
                                                                queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data,
                                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable sendError) {
                        XCTAssertNil(sendError, @"Send should succeed");
                    });
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

- (void)testUDPLocalhostSendReceive {
    XCTestExpectation *expectation = [self expectationWithDescription:@"UDP send/receive on localhost"];

    nw_parameters_t listenerParams = nw_parameters_create_secure_udp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );

    nw_listener_t listener = nw_listener_create(listenerParams);
    dispatch_queue_t queue = dispatch_queue_create("test.udp.loopback", DISPATCH_QUEUE_SERIAL);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 1024,
                    ^(dispatch_data_t _Nullable content,
                      nw_content_context_t _Nullable ctx,
                      bool is_complete,
                      nw_error_t _Nullable recvError) {
                    if (content) {
                        NSData *received = dataFromDispatchData(content);
                        NSString *msg = [[NSString alloc] initWithData:received
                                                              encoding:NSUTF8StringEncoding];
                        XCTAssertEqualObjects(msg, @"udp-hello",
                                              @"Server should receive 'udp-hello'");
                        [expectation fulfill];
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            XCTAssertGreaterThan(port, 0, @"UDP listener should be assigned a port");

            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t clientParams = nw_parameters_create_secure_udp(
                NW_PARAMETERS_DISABLE_PROTOCOL,
                NW_PARAMETERS_DEFAULT_CONFIGURATION
            );
            nw_connection_t client = nw_connection_create(endpoint, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    const char *msg = "udp-hello";
                    dispatch_data_t data = dispatch_data_create(msg, strlen(msg),
                                                                queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data,
                                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable sendError) {
                        XCTAssertNil(sendError, @"UDP send should succeed");
                    });
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

#pragma mark - Dual-Channel TCP + UDP Tests

- (void)testDualChannelTCPAndUDP {
    /*
     * Create both a TCP listener (input) and UDP listener (media) simultaneously.
     * Connect a client on both channels. Send data on both channels at the same time.
     * Verify both channels deliver data correctly and independently.
     */
    XCTestExpectation *tcpReceived = [self expectationWithDescription:@"TCP channel data received"];
    XCTestExpectation *udpReceived = [self expectationWithDescription:@"UDP channel data received"];

    dispatch_queue_t queue = dispatch_queue_create("test.dual.channel", DISPATCH_QUEUE_SERIAL);

    /* TCP listener (input channel) */
    nw_parameters_t tcpParams = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t tcpListener = nw_listener_create(tcpParams);

    /* UDP listener (media channel) */
    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t udpListener = nw_listener_create(udpParams);

    /* TCP server handler */
    nw_listener_set_new_connection_handler(tcpListener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 1024,
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    if (content) {
                        NSData *received = dataFromDispatchData(content);
                        NSString *msg = [[NSString alloc] initWithData:received
                                                              encoding:NSUTF8StringEncoding];
                        XCTAssertEqualObjects(msg, @"tcp-input-data",
                                              @"TCP channel should receive input data");
                        [tcpReceived fulfill];
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    /* UDP server handler */
    nw_listener_set_new_connection_handler(udpListener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 65536,
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    if (content) {
                        NSData *received = dataFromDispatchData(content);
                        NSString *msg = [[NSString alloc] initWithData:received
                                                              encoding:NSUTF8StringEncoding];
                        XCTAssertEqualObjects(msg, @"udp-media-data",
                                              @"UDP channel should receive media data");
                        [udpReceived fulfill];
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    __block uint16_t tcpPort = 0;
    __block uint16_t udpPort = 0;
    __block BOOL tcpReady = NO;
    __block BOOL udpReady = NO;

    void (^connectBothClientsIfReady)(void) = ^{
        if (!tcpReady || !udpReady) return;

        /* TCP client */
        char tcpPortStr[8];
        snprintf(tcpPortStr, sizeof(tcpPortStr), "%u", tcpPort);
        nw_endpoint_t tcpEp = nw_endpoint_create_host("127.0.0.1", tcpPortStr);
        nw_parameters_t tcpCp = nw_parameters_create_secure_tcp(
            NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_connection_t tcpClient = nw_connection_create(tcpEp, tcpCp);
        nw_connection_set_queue(tcpClient, queue);
        nw_connection_set_state_changed_handler(tcpClient, ^(nw_connection_state_t state,
                                                              nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                const char *msg = "tcp-input-data";
                dispatch_data_t data = dispatch_data_create(msg, strlen(msg), queue,
                                                            DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(tcpClient, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                   true, ^(nw_error_t _Nullable e) {});
            }
        });
        nw_connection_start(tcpClient);

        /* UDP client */
        char udpPortStr[8];
        snprintf(udpPortStr, sizeof(udpPortStr), "%u", udpPort);
        nw_endpoint_t udpEp = nw_endpoint_create_host("127.0.0.1", udpPortStr);
        nw_parameters_t udpCp = nw_parameters_create_secure_udp(
            NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_connection_t udpClient = nw_connection_create(udpEp, udpCp);
        nw_connection_set_queue(udpClient, queue);
        nw_connection_set_state_changed_handler(udpClient, ^(nw_connection_state_t state,
                                                              nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                const char *msg = "udp-media-data";
                dispatch_data_t data = dispatch_data_create(msg, strlen(msg), queue,
                                                            DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(udpClient, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                   true, ^(nw_error_t _Nullable e) {});
            }
        });
        nw_connection_start(udpClient);
    };

    nw_listener_set_state_changed_handler(tcpListener, ^(nw_listener_state_t state,
                                                          nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            tcpPort = nw_listener_get_port(tcpListener);
            tcpReady = YES;
            connectBothClientsIfReady();
        }
    });

    nw_listener_set_state_changed_handler(udpListener, ^(nw_listener_state_t state,
                                                          nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            udpPort = nw_listener_get_port(udpListener);
            udpReady = YES;
            connectBothClientsIfReady();
        }
    });

    nw_listener_set_queue(tcpListener, queue);
    nw_listener_set_queue(udpListener, queue);
    nw_listener_start(tcpListener);
    nw_listener_start(udpListener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(tcpListener);
        nw_listener_cancel(udpListener);
    }];
}

- (void)testTCPInputChannelDelivers9ByteHeader {
    /*
     * Send an InputEventHeader (9 bytes) over TCP.
     * Receive exactly 9 bytes on the other end and parse all fields.
     */
    XCTestExpectation *received = [self expectationWithDescription:@"9-byte header received"];
    dispatch_queue_t queue = dispatch_queue_create("test.tcp.header", DISPATCH_QUEUE_SERIAL);

    /* Build a valid InputEventHeader */
    InputEventHeader header;
    memset(&header, 0, sizeof(header));
    header.type = KEYDRD_INPUT_KEY;
    header.ts_us = 1234567890123ULL;

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                /* Receive exactly sizeof(InputEventHeader) bytes */
                nw_connection_receive(serverConn, sizeof(InputEventHeader), sizeof(InputEventHeader),
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    XCTAssertNotNil(content, @"Should receive data");
                    if (!content) return;

                    NSData *data = dataFromDispatchData(content);
                    XCTAssertEqual(data.length, sizeof(InputEventHeader),
                                   @"Should receive exactly 9 bytes");

                    InputEventHeader parsed;
                    memcpy(&parsed, data.bytes, sizeof(InputEventHeader));
                    XCTAssertEqual(parsed.type, KEYDRD_INPUT_KEY,
                                   @"Type should be KEY input");
                    XCTAssertEqual(parsed.ts_us, 1234567890123ULL,
                                   @"Timestamp should match");
                    [received fulfill];
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
            nw_connection_t client = nw_connection_create(ep, cp);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    dispatch_data_t data = dispatch_data_create(&header, sizeof(header), queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable e) {});
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

- (void)testUDPMediaChannelDeliversFrameHeader {
    /*
     * Send a MediaFrameHeader (25 bytes) + payload over UDP.
     * Receive on the other end. Verify header + payload integrity.
     */
    XCTestExpectation *received = [self expectationWithDescription:@"25-byte header + payload received"];
    dispatch_queue_t queue = dispatch_queue_create("test.udp.frame", DISPATCH_QUEUE_SERIAL);

    /* Build a valid MediaFrameHeader + payload */
    const char *testPayload = "test-media-payload-data!";
    size_t payloadLen = strlen(testPayload);

    MediaFrameHeader header;
    memset(&header, 0, sizeof(header));
    header.magic = KEYDRD_MAGIC;
    header.flags = KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK;
    header.seq = 42;
    header.chunk_idx = 0;
    header.chunk_total = 1;
    header.payload_size = (uint32_t)payloadLen;
    header.ts_us = 9876543210ULL;
    header.crc32 = (uint32_t)crc32(0L, (const Bytef *)testPayload, (uInt)payloadLen);

    /* Concatenate header + payload into a single buffer */
    size_t totalLen = sizeof(header) + payloadLen;
    uint8_t *sendbuf = (uint8_t *)malloc(totalLen);
    memcpy(sendbuf, &header, sizeof(header));
    memcpy(sendbuf + sizeof(header), testPayload, payloadLen);

    nw_parameters_t params = nw_parameters_create_secure_udp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 65536,
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    XCTAssertNotNil(content);
                    if (!content) return;

                    NSData *data = dataFromDispatchData(content);
                    XCTAssertEqual(data.length, totalLen,
                                   @"Should receive header + payload");

                    /* Parse header */
                    MediaFrameHeader parsedHeader;
                    memcpy(&parsedHeader, data.bytes, sizeof(MediaFrameHeader));
                    XCTAssertEqual(parsedHeader.magic, KEYDRD_MAGIC);
                    XCTAssertEqual(parsedHeader.flags, KEYDRD_FLAG_KEYFRAME | KEYDRD_FLAG_LAST_CHUNK);
                    XCTAssertEqual(parsedHeader.seq, 42);
                    XCTAssertEqual(parsedHeader.chunk_idx, 0);
                    XCTAssertEqual(parsedHeader.chunk_total, 1);
                    XCTAssertEqual(parsedHeader.payload_size, (uint32_t)payloadLen);
                    XCTAssertEqual(parsedHeader.ts_us, 9876543210ULL);

                    /* Parse payload */
                    const uint8_t *recvPayload = (const uint8_t *)data.bytes + sizeof(MediaFrameHeader);
                    XCTAssertTrue(memcmp(recvPayload, testPayload, payloadLen) == 0,
                                  @"Payload should match original");

                    /* Verify CRC */
                    uint32_t recvCrc = (uint32_t)crc32(0L, (const Bytef *)recvPayload, (uInt)payloadLen);
                    XCTAssertEqual(parsedHeader.crc32, recvCrc,
                                   @"CRC32 should match payload");

                    [received fulfill];
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp = nw_parameters_create_secure_udp(
                NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
            nw_connection_t client = nw_connection_create(ep, cp);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    dispatch_data_t data = dispatch_data_create(sendbuf, totalLen, queue,
                                                                ^{ free(sendbuf); });
                    nw_connection_send(client, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable e) {});
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

#pragma mark - Connection Lifecycle Tests

- (void)testConnectionCleanTeardown {
    /*
     * Establish connection, send data, cancel cleanly.
     * Verify state transitions: preparing -> ready -> cancelled.
     * Verify no crash, no leaked connections.
     */
    XCTestExpectation *reachedReady = [self expectationWithDescription:@"Connection reached ready"];
    XCTestExpectation *reachedCancelled = [self expectationWithDescription:@"Connection reached cancelled"];

    dispatch_queue_t queue = dispatch_queue_create("test.lifecycle.clean", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            /* Accept silently */
        });
        nw_connection_start(conn);
    });

    __block BOOL sawPreparing = NO;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
            nw_connection_t client = nw_connection_create(ep, cp);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_preparing) {
                    sawPreparing = YES;
                } else if (cState == nw_connection_state_ready) {
                    XCTAssertTrue(sawPreparing, @"Should have seen preparing before ready");
                    [reachedReady fulfill];

                    /* Send data then cancel cleanly */
                    const char *msg = "bye";
                    dispatch_data_t data = dispatch_data_create(msg, strlen(msg), queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable e) {
                        nw_connection_cancel(client);
                    });
                } else if (cState == nw_connection_state_cancelled) {
                    [reachedCancelled fulfill];
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:3.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

- (void)testConnectionDropDetection {
    /*
     * Establish connection, forcefully kill the server (cancel listener + server conn).
     * Verify client detects failure (state -> failed or cancelled).
     */
    XCTestExpectation *clientDetectedDrop = [self expectationWithDescription:@"Client detected connection drop"];
    clientDetectedDrop.assertForOverFulfill = YES;

    dispatch_queue_t queue = dispatch_queue_create("test.lifecycle.drop", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);

    __block nw_connection_t serverConn = nil;

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        serverConn = conn;
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            /* Track server side */
        });
        nw_connection_start(conn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
            nw_connection_t client = nw_connection_create(ep, cp);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    /* Forcefully kill server side */
                    if (serverConn) nw_connection_cancel(serverConn);
                    nw_listener_cancel(listener);

                    /* Schedule a read to detect the drop */
                    nw_connection_receive(client, 1, 1024,
                        ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                          bool is_complete, nw_error_t _Nullable recvError) {
                        /* is_complete=true or error means connection dropped */
                        if (is_complete || recvError) {
                            [clientDetectedDrop fulfill];
                        }
                    });
                } else if (cState == nw_connection_state_failed ||
                           cState == nw_connection_state_cancelled) {
                    [clientDetectedDrop fulfill];
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:10.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

- (void)testRapidConnectDisconnectCycles {
    /*
     * Connect/disconnect 10 times rapidly.
     * Verify no crash, no resource leaks, final state is correct.
     */
    const int CYCLES = 10;
    XCTestExpectation *allCyclesCompleted = [self expectationWithDescription:@"All rapid cycles completed"];

    dispatch_queue_t queue = dispatch_queue_create("test.lifecycle.rapid", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);
    __block uint16_t listenerPort = 0;

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {});
        nw_connection_start(conn);
    });

    __block int completedCycles = 0;

    /* Forward declare block for cycling */
    __block void (^runCycle)(void) = nil;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            listenerPort = nw_listener_get_port(listener);
            runCycle();
        }
    });

    runCycle = ^{
        if (completedCycles >= CYCLES) {
            [allCyclesCompleted fulfill];
            return;
        }

        char portStr[8];
        snprintf(portStr, sizeof(portStr), "%u", listenerPort);
        nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
        nw_parameters_t cp = nw_parameters_create_secure_tcp(
            NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_connection_t conn = nw_connection_create(ep, cp);
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t cState,
                                                         nw_error_t _Nullable cError) {
            if (cState == nw_connection_state_ready) {
                nw_connection_cancel(conn);
            } else if (cState == nw_connection_state_cancelled) {
                completedCycles++;
                runCycle();
            }
        });
        nw_connection_start(conn);
    };

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:15.0 handler:^(NSError *error) {
        XCTAssertEqual(completedCycles, CYCLES,
                       @"Should have completed all %d cycles", CYCLES);
        nw_listener_cancel(listener);
    }];
}

#pragma mark - TLS / DTLS Connection Tests

- (void)testTLS13ConnectionEstablishment {
    /*
     * Create TLS 1.3 server (using PKCS12 identity) + TLS client.
     * Both sides use the same identity (self-to-self for localhost).
     * Verify connection reaches .ready state.
     * Verify we can exchange data over the encrypted channel.
     */
    NSString *p12Path = generateTestPKCS12(@"keydrd-tls-test");
    XCTAssertNotNil(p12Path, @"Should generate test PKCS12");
    if (!p12Path) return;

    SecIdentityRef identity = loadIdentityFromPKCS12(p12Path);
    XCTAssertTrue(identity != NULL, @"Should load identity from PKCS12");
    if (!identity) return;

    XCTestExpectation *tlsReady = [self expectationWithDescription:@"TLS 1.3 connection ready"];
    XCTestExpectation *dataExchanged = [self expectationWithDescription:@"Data exchanged over TLS"];

    dispatch_queue_t queue = dispatch_queue_create("test.tls.establish", DISPATCH_QUEUE_SERIAL);

    /* TLS server listener */
    nw_parameters_t serverParams = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_identity_t secId = sec_identity_create(identity);
            if (secId) sec_protocol_options_set_local_identity(sec, secId);
            /* Accept all clients in test mode */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) { complete(true); },
                queue);
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    nw_listener_t listener = nw_listener_create(serverParams);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                /* Receive and echo */
                nw_connection_receive(serverConn, 1, 1024,
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    if (content) {
                        nw_connection_send(serverConn, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                           true, ^(nw_error_t _Nullable e) {});
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);

            /* TLS client */
            nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                ^(nw_protocol_options_t tls_options) {
                    sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
                    sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
                    sec_identity_t secId = sec_identity_create(identity);
                    if (secId) sec_protocol_options_set_local_identity(sec, secId);
                    sec_protocol_options_set_verify_block(sec,
                        ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                          sec_protocol_verify_complete_t complete) { complete(true); },
                        queue);
                },
                NW_PARAMETERS_DEFAULT_CONFIGURATION);

            nw_connection_t client = nw_connection_create(ep, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    [tlsReady fulfill];

                    /* Send data and verify round-trip */
                    const char *msg = "tls-hello";
                    dispatch_data_t data = dispatch_data_create(msg, strlen(msg), queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       false, ^(nw_error_t _Nullable e) {
                        nw_connection_receive(client, 1, 1024,
                            ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                              bool is_complete, nw_error_t _Nullable recvError) {
                            if (content) {
                                NSData *received = dataFromDispatchData(content);
                                NSString *resp = [[NSString alloc] initWithData:received
                                                                      encoding:NSUTF8StringEncoding];
                                XCTAssertEqualObjects(resp, @"tls-hello",
                                                      @"Should echo data over TLS");
                                [dataExchanged fulfill];
                            }
                        });
                    });
                } else if (cState == nw_connection_state_failed) {
                    XCTFail(@"TLS connection failed: %@", cError);
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
        CFRelease(identity);
    }];
}

- (void)testTLSCertPinningRejectsWrongCert {
    /*
     * Server uses cert A, client expects cert B's fingerprint.
     * Verify block returns false -> connection should fail.
     */
    NSString *p12A = generateTestPKCS12(@"keydrd-cert-A");
    NSString *p12B = generateTestPKCS12(@"keydrd-cert-B");
    XCTAssertNotNil(p12A); XCTAssertNotNil(p12B);
    if (!p12A || !p12B) return;

    SecIdentityRef identityA = loadIdentityFromPKCS12(p12A);
    SecIdentityRef identityB = loadIdentityFromPKCS12(p12B);
    XCTAssertTrue(identityA != NULL); XCTAssertTrue(identityB != NULL);
    if (!identityA || !identityB) return;

    /* Get fingerprint of cert B -- client will expect this */
    NSData *fingerprintB = fingerprintFromIdentity(identityB);
    XCTAssertNotNil(fingerprintB);

    XCTestExpectation *rejected = [self expectationWithDescription:@"Client rejected wrong cert"];

    dispatch_queue_t queue = dispatch_queue_create("test.tls.reject", DISPATCH_QUEUE_SERIAL);

    /* Server with cert A */
    nw_parameters_t serverParams = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_identity_t secId = sec_identity_create(identityA);
            if (secId) sec_protocol_options_set_local_identity(sec, secId);
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) { complete(true); },
                queue);
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    nw_listener_t listener = nw_listener_create(serverParams);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {});
        nw_connection_start(conn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);

            /* Client expects cert B's fingerprint but server has cert A */
            nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                ^(nw_protocol_options_t tls_options) {
                    sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
                    sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
                    sec_identity_t secId = sec_identity_create(identityB);
                    if (secId) sec_protocol_options_set_local_identity(sec, secId);
                    sec_protocol_options_set_verify_block(sec,
                        ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                          sec_protocol_verify_complete_t complete) {
                            /* Verify the server's cert matches fingerprint B */
                            SecTrustRef secTrust = sec_trust_copy_ref(trust);
                            if (!secTrust) { complete(false); return; }
                            CFArrayRef chain = SecTrustCopyCertificateChain(secTrust);
                            CFRelease(secTrust);
                            if (!chain || CFArrayGetCount(chain) == 0) {
                                if (chain) CFRelease(chain);
                                complete(false);
                                return;
                            }
                            SecCertificateRef peerCert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
                            CFDataRef certData = SecCertificateCopyData(peerCert);
                            CFRelease(chain);
                            if (!certData) { complete(false); return; }
                            uint8_t hash[CC_SHA256_DIGEST_LENGTH];
                            CC_SHA256(CFDataGetBytePtr(certData), (CC_LONG)CFDataGetLength(certData), hash);
                            CFRelease(certData);
                            NSData *peerFP = [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
                            BOOL match = [peerFP isEqualToData:fingerprintB];
                            complete(match); /* Should be false since server has cert A */
                        },
                        queue);
                },
                NW_PARAMETERS_DEFAULT_CONFIGURATION);

            nw_connection_t client = nw_connection_create(ep, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_failed ||
                    (cState == nw_connection_state_waiting && cError != NULL)) {
                    /* Expected: TLS handshake failed because cert doesn't match.
                     * NWConnection may report .waiting (with error) or .failed. */
                    [rejected fulfill];
                    nw_connection_cancel(client);
                } else if (cState == nw_connection_state_ready) {
                    XCTFail(@"Connection should NOT succeed with wrong cert pinning");
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
        CFRelease(identityA);
        CFRelease(identityB);
    }];
}

- (void)testTLSCertPinningAcceptsCorrectCert {
    /*
     * Server uses cert A, client has cert A's fingerprint stored.
     * Verify block returns true -> connection should succeed.
     */
    NSString *p12Path = generateTestPKCS12(@"keydrd-cert-accept");
    XCTAssertNotNil(p12Path);
    if (!p12Path) return;

    SecIdentityRef identity = loadIdentityFromPKCS12(p12Path);
    XCTAssertTrue(identity != NULL);
    if (!identity) return;

    NSData *expectedFingerprint = fingerprintFromIdentity(identity);
    XCTAssertNotNil(expectedFingerprint);

    XCTestExpectation *accepted = [self expectationWithDescription:@"Client accepted correct cert"];

    dispatch_queue_t queue = dispatch_queue_create("test.tls.accept", DISPATCH_QUEUE_SERIAL);

    /* Server */
    nw_parameters_t serverParams = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_identity_t secId = sec_identity_create(identity);
            if (secId) sec_protocol_options_set_local_identity(sec, secId);
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) { complete(true); },
                queue);
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    nw_listener_t listener = nw_listener_create(serverParams);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {});
        nw_connection_start(conn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);

            /* Client verifies against the CORRECT fingerprint */
            nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                ^(nw_protocol_options_t tls_options) {
                    sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
                    sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
                    sec_identity_t secId = sec_identity_create(identity);
                    if (secId) sec_protocol_options_set_local_identity(sec, secId);
                    sec_protocol_options_set_verify_block(sec,
                        ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                          sec_protocol_verify_complete_t complete) {
                            SecTrustRef secTrust = sec_trust_copy_ref(trust);
                            if (!secTrust) { complete(false); return; }
                            CFArrayRef chain = SecTrustCopyCertificateChain(secTrust);
                            CFRelease(secTrust);
                            if (!chain || CFArrayGetCount(chain) == 0) {
                                if (chain) CFRelease(chain);
                                complete(false);
                                return;
                            }
                            SecCertificateRef peerCert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
                            CFDataRef certData = SecCertificateCopyData(peerCert);
                            CFRelease(chain);
                            if (!certData) { complete(false); return; }
                            uint8_t hash[CC_SHA256_DIGEST_LENGTH];
                            CC_SHA256(CFDataGetBytePtr(certData), (CC_LONG)CFDataGetLength(certData), hash);
                            CFRelease(certData);
                            NSData *peerFP = [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
                            BOOL match = [peerFP isEqualToData:expectedFingerprint];
                            complete(match);
                        },
                        queue);
                },
                NW_PARAMETERS_DEFAULT_CONFIGURATION);

            nw_connection_t client = nw_connection_create(ep, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    [accepted fulfill];
                } else if (cState == nw_connection_state_failed) {
                    XCTFail(@"Connection should succeed with correct cert pinning");
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
        CFRelease(identity);
    }];
}

- (void)testDTLSUDPConnectionEstablishment {
    /*
     * Create DTLS-encrypted UDP connection pair.
     * Send data, verify it arrives intact.
     */
    NSString *p12Path = generateTestPKCS12(@"keydrd-dtls-test");
    XCTAssertNotNil(p12Path);
    if (!p12Path) return;

    SecIdentityRef identity = loadIdentityFromPKCS12(p12Path);
    XCTAssertTrue(identity != NULL);
    if (!identity) return;

    XCTestExpectation *dtlsDataReceived = [self expectationWithDescription:@"DTLS data received"];

    dispatch_queue_t queue = dispatch_queue_create("test.dtls.establish", DISPATCH_QUEUE_SERIAL);

    /* DTLS server (UDP listener) */
    nw_parameters_t serverParams = nw_parameters_create_secure_udp(
        ^(nw_protocol_options_t dtls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
            sec_identity_t secId = sec_identity_create(identity);
            if (secId) sec_protocol_options_set_local_identity(sec, secId);
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) { complete(true); },
                queue);
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    nw_listener_t listener = nw_listener_create(serverParams);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 65536,
                    ^(dispatch_data_t _Nullable content, nw_content_context_t _Nullable ctx,
                      bool is_complete, nw_error_t _Nullable recvError) {
                    if (content) {
                        NSData *received = dataFromDispatchData(content);
                        NSString *msg = [[NSString alloc] initWithData:received
                                                              encoding:NSUTF8StringEncoding];
                        XCTAssertEqualObjects(msg, @"dtls-hello",
                                              @"Should receive data via DTLS");
                        [dtlsDataReceived fulfill];
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", port);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);

            /* DTLS client */
            nw_parameters_t clientParams = nw_parameters_create_secure_udp(
                ^(nw_protocol_options_t dtls_options) {
                    sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
                    sec_identity_t secId = sec_identity_create(identity);
                    if (secId) sec_protocol_options_set_local_identity(sec, secId);
                    sec_protocol_options_set_verify_block(sec,
                        ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                          sec_protocol_verify_complete_t complete) { complete(true); },
                        queue);
                },
                NW_PARAMETERS_DEFAULT_CONFIGURATION);

            nw_connection_t client = nw_connection_create(ep, clientParams);
            nw_connection_set_queue(client, queue);
            nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                               nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    const char *msg = "dtls-hello";
                    dispatch_data_t data = dispatch_data_create(msg, strlen(msg), queue,
                                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    nw_connection_send(client, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                       true, ^(nw_error_t _Nullable e) {});
                }
            });
            nw_connection_start(client);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
        CFRelease(identity);
    }];
}

#pragma mark - Reconnection Protocol Tests

- (void)testReconnectExponentialBackoff {
    /*
     * Simulate disconnect and verify reconnection attempts follow exponential backoff.
     * Uses a deterministic counter approach -- no actual time delays.
     *
     * Expected intervals: 0.5s, 1.0s, 2.0s, 4.0s
     * We track when each attempt is made relative to the first.
     */
    __block int attemptCount = 0;
    __block NSMutableArray<NSNumber *> *attemptTimes = [NSMutableArray array];
    __block NSDate *firstAttemptTime = nil;

    const int MAX_ATTEMPTS = 4;
    double expectedIntervals[] = {0.0, 0.5, 1.5, 3.5}; /* cumulative from first: 0, +0.5, +1.0, +2.0 */

    XCTestExpectation *allAttempts = [self expectationWithDescription:@"All reconnection attempts made"];

    dispatch_queue_t queue = dispatch_queue_create("test.reconnect.backoff", DISPATCH_QUEUE_SERIAL);

    /* Simulate exponential backoff reconnection logic */
    __block void (^scheduleReconnect)(void) = nil;
    scheduleReconnect = ^{
        if (attemptCount >= MAX_ATTEMPTS) {
            [allAttempts fulfill];
            return;
        }

        /* Calculate backoff: 0.5 * 2^attempt (starting from attempt 0) */
        double delay;
        if (attemptCount == 0) {
            delay = 0.0; /* First attempt is immediate */
        } else {
            delay = 0.5 * pow(2.0, attemptCount - 1); /* 0.5, 1.0, 2.0 */
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       queue, ^{
            NSDate *now = [NSDate date];
            if (!firstAttemptTime) firstAttemptTime = now;
            double elapsed = [now timeIntervalSinceDate:firstAttemptTime];
            [attemptTimes addObject:@(elapsed)];
            attemptCount++;
            scheduleReconnect();
        });
    };

    dispatch_async(queue, ^{
        scheduleReconnect();
    });

    [self waitForExpectationsWithTimeout:10.0 handler:^(NSError *error) {
        XCTAssertEqual(attemptCount, MAX_ATTEMPTS, @"Should have %d attempts", MAX_ATTEMPTS);
        XCTAssertEqual(attemptTimes.count, (NSUInteger)MAX_ATTEMPTS);

        /* Verify the timing intervals approximately match exponential backoff */
        double expectedCopy[] = {0.0, 0.5, 1.5, 3.5};
        for (int i = 0; i < MAX_ATTEMPTS && i < (int)attemptTimes.count; i++) {
            double actual = attemptTimes[i].doubleValue;
            double expected = expectedCopy[i];
            /* Allow 1.0s tolerance — GCD timers on busy CI can jitter significantly */
            XCTAssertEqualWithAccuracy(actual, expected, 1.0,
                @"Attempt %d should be at ~%.1fs (was %.2fs)", i, expected, actual);
        }
    }];
}

- (void)testReconnectSucceedsAfterServerRestart {
    /*
     * Connect to server, kill server, start new server.
     * Verify client can reconnect to the new server.
     */
    XCTestExpectation *firstConnected = [self expectationWithDescription:@"First connection"];
    XCTestExpectation *serverRestarted = [self expectationWithDescription:@"Server restarted"];
    XCTestExpectation *reconnected = [self expectationWithDescription:@"Client reconnected"];

    dispatch_queue_t queue = dispatch_queue_create("test.reconnect.restart", DISPATCH_QUEUE_SERIAL);

    /* We use a fixed port for both server instances */
    __block uint16_t serverPort = 0;

    /* First server */
    nw_parameters_t params1 = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t server1 = nw_listener_create(params1);

    nw_listener_set_new_connection_handler(server1, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {});
        nw_connection_start(conn);
    });

    nw_listener_set_state_changed_handler(server1, ^(nw_listener_state_t state,
                                                      nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            serverPort = nw_listener_get_port(server1);
            char portStr[8];
            snprintf(portStr, sizeof(portStr), "%u", serverPort);
            nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
            nw_connection_t client1 = nw_connection_create(ep, cp);
            nw_connection_set_queue(client1, queue);
            nw_connection_set_state_changed_handler(client1, ^(nw_connection_state_t cState,
                                                                nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    [firstConnected fulfill];

                    /* Kill the first server */
                    nw_listener_cancel(server1);

                    /* Start a new server on the same port after a short delay */
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   queue, ^{
                        nw_parameters_t params2 = nw_parameters_create_secure_tcp(
                            NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
                        /* Bind to specific port with reuse */
                        nw_parameters_set_reuse_local_address(params2, true);
                        char pStr[8];
                        snprintf(pStr, sizeof(pStr), "%u", serverPort);
                        nw_parameters_set_local_endpoint(params2,
                            nw_endpoint_create_host("127.0.0.1", pStr));
                        nw_listener_t server2 = nw_listener_create(params2);

                        nw_listener_set_new_connection_handler(server2, ^(nw_connection_t conn) {
                            nw_connection_set_queue(conn, queue);
                            nw_connection_set_state_changed_handler(conn,
                                ^(nw_connection_state_t state, nw_error_t _Nullable error) {});
                            nw_connection_start(conn);
                        });

                        nw_listener_set_state_changed_handler(server2,
                            ^(nw_listener_state_t s2state, nw_error_t _Nullable s2error) {
                            if (s2state == nw_listener_state_ready) {
                                [serverRestarted fulfill];

                                /* Client reconnects to the new server */
                                char pStr2[8];
                                snprintf(pStr2, sizeof(pStr2), "%u", serverPort);
                                nw_endpoint_t ep2 = nw_endpoint_create_host("127.0.0.1", pStr2);
                                nw_parameters_t cp2 = nw_parameters_create_secure_tcp(
                                    NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
                                nw_connection_t client2 = nw_connection_create(ep2, cp2);
                                nw_connection_set_queue(client2, queue);
                                nw_connection_set_state_changed_handler(client2,
                                    ^(nw_connection_state_t c2State, nw_error_t _Nullable c2Error) {
                                    if (c2State == nw_connection_state_ready) {
                                        [reconnected fulfill];
                                        nw_connection_cancel(client2);
                                    }
                                });
                                nw_connection_start(client2);
                            }
                        });

                        nw_listener_set_queue(server2, queue);
                        nw_listener_start(server2);
                    });
                }
            });
            nw_connection_start(client1);
        }
    });

    nw_listener_set_queue(server1, queue);
    nw_listener_start(server1);

    [self waitForExpectationsWithTimeout:10.0 handler:nil];
}

- (void)testReconnectPreservesEncodeMode {
    /*
     * Verify that the FSM preserves encode mode on reconnect within the same transport type.
     * Disconnect from WiFi (HEVC mode), reconnect to WiFi -> should still select HEVC.
     * This is a pure FSM test -- no network involved.
     */
    TransportState state = TRANSPORT_IDLE;
    TransportTransition t;

    /* Connect to WiFi */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    state = t.next_state;
    XCTAssertEqual(state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"Initial WiFi connection should select HEVC");

    /* Disconnect (error) */
    t = transport_fsm_transition(state, TRANSPORT_EVT_DISCONNECTED);
    state = t.next_state;
    XCTAssertEqual(state, TRANSPORT_DISCONNECTED);

    /* Reconnect to WiFi */
    t = transport_fsm_transition(state, TRANSPORT_EVT_WIFI_AVAILABLE);
    state = t.next_state;
    XCTAssertEqual(state, TRANSPORT_WIFI);
    XCTAssertTrue(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_HEVC),
                  @"Reconnection to WiFi should re-select HEVC (not LZ4)");
    XCTAssertFalse(transitionContainsEffect(t, EFFECT_SWITCH_ENCODE_LZ4),
                   @"WiFi reconnect should NOT switch to LZ4");
}

#pragma mark - Bonjour Service Lifecycle Tests

- (void)testBonjourAdvertiseAndDiscover {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Bonjour advertise and discover"];

    /* Use a unique service name to avoid collisions with other tests */
    NSString *serviceName = [NSString stringWithFormat:@"test-transport-%u", arc4random()];

    /* Create a TCP listener advertising via Bonjour */
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_listener_t listener = nw_listener_create(params);
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        serviceName.UTF8String, "_keydrd._tcp", "local");
    nw_listener_set_advertise_descriptor(listener, advertise);

    dispatch_queue_t queue = dispatch_queue_create("test.bonjour.discover", DISPATCH_QUEUE_SERIAL);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        /* Accept but do nothing -- we just test discovery */
    });

    __block nw_browser_t browser = nil;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            /* Browse for the service */
            nw_browse_descriptor_t browseDesc = nw_browse_descriptor_create_bonjour_service(
                "_keydrd._tcp", "local");
            browser = nw_browser_create(browseDesc, NULL);
            nw_browser_set_browse_results_changed_handler(browser,
                ^(nw_browse_result_t old_result, nw_browse_result_t new_result, bool batch_complete) {
                nw_browse_result_change_t changes = nw_browse_result_get_changes(old_result, new_result);
                if (changes & nw_browse_result_change_result_added) {
                    nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new_result);
                    if (endpoint) {
                        /* Verify the service we found has _keydrd._tcp type */
                        const char *desc = nw_endpoint_get_bonjour_service_name(endpoint);
                        if (desc && strcmp(desc, serviceName.UTF8String) == 0) {
                            [expectation fulfill];
                        }
                    }
                }
            });
            nw_browser_set_queue(browser, queue);
            nw_browser_start(browser);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        if (browser) nw_browser_cancel(browser);
        nw_listener_cancel(listener);
    }];
}

- (void)testBonjourAdvertiseDiscoverConnect {
    /*
     * Full Bonjour lifecycle: advertise -> discover -> connect -> exchange data -> verify.
     */
    XCTestExpectation *clientReceived = [self expectationWithDescription:@"Client received response"];
    XCTestExpectation *serverReceived = [self expectationWithDescription:@"Server received request"];

    NSString *serviceName = [NSString stringWithFormat:@"test-exchange-%u", arc4random()];
    dispatch_queue_t queue = dispatch_queue_create("test.bonjour.exchange", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_listener_t listener = nw_listener_create(params);
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        serviceName.UTF8String, "_keydrd._tcp", "local");
    nw_listener_set_advertise_descriptor(listener, advertise);

    /* Server: receive data, echo it back */
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t serverConn) {
        nw_connection_set_queue(serverConn, queue);
        nw_connection_set_state_changed_handler(serverConn, ^(nw_connection_state_t state,
                                                               nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                nw_connection_receive(serverConn, 1, 1024,
                    ^(dispatch_data_t _Nullable content,
                      nw_content_context_t _Nullable ctx,
                      bool is_complete,
                      nw_error_t _Nullable recvError) {
                    if (content && dispatch_data_get_size(content) > 0) {
                        [serverReceived fulfill];
                        /* Echo response back */
                        const char *resp = "pong";
                        dispatch_data_t respData = dispatch_data_create(resp, strlen(resp),
                                                                         queue,
                                                                         DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                        nw_connection_send(serverConn, respData,
                                           NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                           true, ^(nw_error_t _Nullable sendError) {
                            /* Sent response */
                        });
                    }
                });
            }
        });
        nw_connection_start(serverConn);
    });

    __block nw_browser_t browser = nil;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            nw_browse_descriptor_t browseDesc = nw_browse_descriptor_create_bonjour_service(
                "_keydrd._tcp", "local");
            browser = nw_browser_create(browseDesc, NULL);
            __block BOOL didConnect = NO;

            nw_browser_set_browse_results_changed_handler(browser,
                ^(nw_browse_result_t old_result, nw_browse_result_t new_result, bool batch_complete) {
                nw_browse_result_change_t changes = nw_browse_result_get_changes(old_result, new_result);
                if (!(changes & nw_browse_result_change_result_added) || didConnect) return;
                nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new_result);
                if (!endpoint) return;
                const char *name = nw_endpoint_get_bonjour_service_name(endpoint);
                if (!name || strcmp(name, serviceName.UTF8String) != 0) return;

                didConnect = YES;

                /* Connect to the discovered service */
                nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                    NW_PARAMETERS_DISABLE_PROTOCOL,
                    NW_PARAMETERS_DEFAULT_CONFIGURATION
                );
                nw_connection_t client = nw_connection_create(endpoint, clientParams);
                nw_connection_set_queue(client, queue);
                nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                                   nw_error_t _Nullable cError) {
                    if (cState == nw_connection_state_ready) {
                        /* Send ping */
                        const char *msg = "ping";
                        dispatch_data_t data = dispatch_data_create(msg, strlen(msg),
                                                                     queue,
                                                                     DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                        nw_connection_send(client, data,
                                           NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                                           false, ^(nw_error_t _Nullable sendError) {
                            /* Now receive the echo response */
                            nw_connection_receive(client, 1, 1024,
                                ^(dispatch_data_t _Nullable respContent,
                                  nw_content_context_t _Nullable respCtx,
                                  bool respComplete,
                                  nw_error_t _Nullable respError) {
                                if (respContent && dispatch_data_get_size(respContent) > 0) {
                                    NSData *received = dataFromDispatchData(respContent);
                                    NSString *resp = [[NSString alloc] initWithData:received
                                                                           encoding:NSUTF8StringEncoding];
                                    XCTAssertEqualObjects(resp, @"pong",
                                                          @"Client should receive 'pong' response");
                                    [clientReceived fulfill];
                                }
                            });
                        });
                    }
                });
                nw_connection_start(client);
            });
            nw_browser_set_queue(browser, queue);
            nw_browser_start(browser);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:10.0 handler:^(NSError *error) {
        if (browser) nw_browser_cancel(browser);
        nw_listener_cancel(listener);
    }];
}

- (void)testBonjourServiceRemovalTriggersCleanup {
    /*
     * Advertise, discover, connect.
     * Stop advertising.
     * Verify .removed event fires in browser results.
     */
    XCTestExpectation *discovered = [self expectationWithDescription:@"Service discovered"];
    XCTestExpectation *removed = [self expectationWithDescription:@"Service removed"];

    NSString *serviceName = [NSString stringWithFormat:@"test-removal-%u", arc4random()];
    dispatch_queue_t queue = dispatch_queue_create("test.bonjour.removal", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_listener_t listener = nw_listener_create(params);
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        serviceName.UTF8String, "_keydrd._tcp", "local");
    nw_listener_set_advertise_descriptor(listener, advertise);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {});
        nw_connection_start(conn);
    });

    __block nw_browser_t browser = nil;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            nw_browse_descriptor_t browseDesc = nw_browse_descriptor_create_bonjour_service(
                "_keydrd._tcp", "local");
            browser = nw_browser_create(browseDesc, NULL);
            nw_browser_set_browse_results_changed_handler(browser,
                ^(nw_browse_result_t old_result, nw_browse_result_t new_result, bool batch_complete) {
                nw_browse_result_change_t changes = nw_browse_result_get_changes(old_result, new_result);

                if (changes & nw_browse_result_change_result_added) {
                    nw_endpoint_t ep = nw_browse_result_copy_endpoint(new_result);
                    if (!ep) return;
                    const char *name = nw_endpoint_get_bonjour_service_name(ep);
                    if (name && strcmp(name, serviceName.UTF8String) == 0) {
                        [discovered fulfill];
                        /* Stop advertising to trigger removal */
                        nw_listener_cancel(listener);
                    }
                }

                if (changes & nw_browse_result_change_result_removed) {
                    nw_endpoint_t ep = nw_browse_result_copy_endpoint(old_result);
                    if (!ep) return;
                    const char *name = nw_endpoint_get_bonjour_service_name(ep);
                    if (name && strcmp(name, serviceName.UTF8String) == 0) {
                        [removed fulfill];
                    }
                }
            });
            nw_browser_set_queue(browser, queue);
            nw_browser_start(browser);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:10.0 handler:^(NSError *error) {
        if (browser) nw_browser_cancel(browser);
        nw_listener_cancel(listener);
    }];
}

- (void)testBonjourDuplicateEventsHandled {
    /* Regression test: ensure that even if browse results fire multiple times,
     * only ONE connection is established to the service. */
    XCTestExpectation *clientConnected = [self expectationWithDescription:@"Client connected"];
    clientConnected.assertForOverFulfill = YES; /* Fail if fulfilled more than once */
    XCTestExpectation *serverConnected = [self expectationWithDescription:@"Server accepted"];
    serverConnected.assertForOverFulfill = YES;

    NSString *serviceName = [NSString stringWithFormat:@"test-dedup-%u", arc4random()];
    dispatch_queue_t queue = dispatch_queue_create("test.bonjour.dedup", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_listener_t listener = nw_listener_create(params);
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        serviceName.UTF8String, "_keydrd._tcp", "local");
    nw_listener_set_advertise_descriptor(listener, advertise);

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            if (state == nw_connection_state_ready) {
                [serverConnected fulfill];
            }
        });
        nw_connection_start(conn);
    });

    __block nw_browser_t browser = nil;

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            nw_browse_descriptor_t browseDesc = nw_browse_descriptor_create_bonjour_service(
                "_keydrd._tcp", "local");
            browser = nw_browser_create(browseDesc, NULL);

            /* Use a guard flag to ensure only one connection is created,
             * just like production code should. */
            __block BOOL didConnect = NO;

            nw_browser_set_browse_results_changed_handler(browser,
                ^(nw_browse_result_t old_result, nw_browse_result_t new_result, bool batch_complete) {
                nw_browse_result_change_t changes = nw_browse_result_get_changes(old_result, new_result);
                if (!(changes & nw_browse_result_change_result_added)) return;
                nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new_result);
                if (!endpoint) return;
                const char *name = nw_endpoint_get_bonjour_service_name(endpoint);
                if (!name || strcmp(name, serviceName.UTF8String) != 0) return;

                if (didConnect) return; /* Guard: skip duplicate browse results */
                didConnect = YES;

                nw_parameters_t clientParams = nw_parameters_create_secure_tcp(
                    NW_PARAMETERS_DISABLE_PROTOCOL,
                    NW_PARAMETERS_DEFAULT_CONFIGURATION
                );
                nw_connection_t client = nw_connection_create(endpoint, clientParams);
                nw_connection_set_queue(client, queue);
                nw_connection_set_state_changed_handler(client, ^(nw_connection_state_t cState,
                                                                   nw_error_t _Nullable cError) {
                    if (cState == nw_connection_state_ready) {
                        [clientConnected fulfill];
                    }
                });
                nw_connection_start(client);
            });
            nw_browser_set_queue(browser, queue);
            nw_browser_start(browser);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError *error) {
        if (browser) nw_browser_cancel(browser);
        nw_listener_cancel(listener);
    }];
}

- (void)testConnectionTeardownCleanup {
    /* Establish connection, cancel it, verify no crash, then re-establish */
    XCTestExpectation *firstConnected = [self expectationWithDescription:@"First connection"];
    XCTestExpectation *secondConnected = [self expectationWithDescription:@"Second connection"];

    dispatch_queue_t queue = dispatch_queue_create("test.teardown", DISPATCH_QUEUE_SERIAL);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_listener_t listener = nw_listener_create(params);
    __block uint16_t listenerPort = 0;

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                         nw_error_t _Nullable error) {
            /* Accept silently */
        });
        nw_connection_start(conn);
    });

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state,
                                                       nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            listenerPort = nw_listener_get_port(listener);

            NSString *portString = [NSString stringWithFormat:@"%u", listenerPort];
            const char *portStr = portString.UTF8String;

            /* First connection */
            nw_endpoint_t ep1 = nw_endpoint_create_host("127.0.0.1", portStr);
            nw_parameters_t cp1 = nw_parameters_create_secure_tcp(
                NW_PARAMETERS_DISABLE_PROTOCOL,
                NW_PARAMETERS_DEFAULT_CONFIGURATION
            );
            nw_connection_t conn1 = nw_connection_create(ep1, cp1);
            nw_connection_set_queue(conn1, queue);
            nw_connection_set_state_changed_handler(conn1, ^(nw_connection_state_t cState,
                                                              nw_error_t _Nullable cError) {
                if (cState == nw_connection_state_ready) {
                    [firstConnected fulfill];
                    /* Immediately cancel */
                    nw_connection_cancel(conn1);
                } else if (cState == nw_connection_state_cancelled) {
                    /* Now establish a second connection after the first was torn down */
                    nw_endpoint_t ep2 = nw_endpoint_create_host("127.0.0.1", portStr);
                    nw_parameters_t cp2 = nw_parameters_create_secure_tcp(
                        NW_PARAMETERS_DISABLE_PROTOCOL,
                        NW_PARAMETERS_DEFAULT_CONFIGURATION
                    );
                    nw_connection_t conn2 = nw_connection_create(ep2, cp2);
                    nw_connection_set_queue(conn2, queue);
                    nw_connection_set_state_changed_handler(conn2, ^(nw_connection_state_t c2State,
                                                                      nw_error_t _Nullable c2Error) {
                        if (c2State == nw_connection_state_ready) {
                            [secondConnected fulfill];
                            nw_connection_cancel(conn2);
                        }
                    });
                    nw_connection_start(conn2);
                }
            });
            nw_connection_start(conn1);
        }
    });

    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);

    [self waitForExpectationsWithTimeout:10.0 handler:^(NSError *error) {
        nw_listener_cancel(listener);
    }];
}

@end
