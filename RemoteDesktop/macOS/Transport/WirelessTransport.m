#import "WirelessTransport.h"
#import "protocol.h"
#import "crypto.h"
#import <os/log.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
#include <mach/mach_time.h>

static os_log_t wireless_log(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.ryheff.keyd.remote.agent", "WirelessTransport");
    });
    return log;
}

/* Port number as C string for NWListener */
static const char *kMediaPortStr = "14567";
static const char *kInputPortStr = "14568";
static const uint64_t kDuplicateReplaceIdleThresholdNs = 2000000000ULL;
static const uint64_t kPendingConnectionReplaceThresholdNs = 1500000000ULL;

static uint64_t keydrd_mach_delta_ns(uint64_t newerTicks, uint64_t olderTicks) {
    if (newerTicks <= olderTicks) {
        return 0;
    }
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    return ((newerTicks - olderTicks) * timebase.numer) / timebase.denom;
}

static BOOL keydrd_is_transient_dtls_gap(nw_error_t _Nullable detail) {
    if (!detail) {
        return NO;
    }
    NSString *detailString = [NSString stringWithFormat:@"%@", detail];
    NSRange range = [detailString rangeOfString:@"No message available on STREAM"
                                         options:NSCaseInsensitiveSearch];
    return range.location != NSNotFound;
}

@interface WirelessTransport () {
    dispatch_queue_t _sendPacingQueue;     // serial queue for paced UDP sends
    uint64_t _pacingFastIntervalTicks;     // low-backlog chunk spacing
    uint64_t _pacingDefaultIntervalTicks;  // nominal chunk spacing
    uint64_t _pacingCongestedIntervalTicks;// high-backlog chunk spacing
    uint64_t _nextSendTime;               // next allowed send time (mach absolute time)
    uint64_t _inputAcceptedAtTicks;       // when current input candidate was accepted
    uint64_t _inputReadyAtTicks;          // when the current input connection reached ready
    uint64_t _lastInputActivityTicks;     // last time bytes were received on input connection
    BOOL _allowReconnectTakeover;         // allow replacing lingering input socket after disconnect
    BOOL _advertisingRequested;           // true while caller expects Bonjour advertising to stay active
    atomic_uint _queuedMediaChunks;        // paced UDP chunks waiting to be sent/completed
    atomic_ullong _sendGeneration;         // increments when media path resets; stale queued sends are discarded
}
@property (nonatomic) dispatch_queue_t transportQueue;
@property (nonatomic, nullable) nw_listener_t bonjourListener;
@property (nonatomic, nullable) nw_listener_t mediaListener;
@property (nonatomic, nullable) nw_connection_t mediaConnection;
@property (nonatomic, nullable) nw_connection_t inputConnection;
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, readwrite) BOOL isAWDL;
@end

@implementation WirelessTransport

- (instancetype)init {
    self = [super init];
    if (self) {
        _transportQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.wireless.transport",
                                                DISPATCH_QUEUE_SERIAL);
        _sendPacingQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.wireless.pacing",
                                                 DISPATCH_QUEUE_SERIAL);

        /* Convert chunk pacing intervals from nanoseconds to mach ticks.
         * Keep DTLS sends paced, but preserve a high enough operating point
         * that large HEVC bursts can drain without stretching frame delivery. */
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        _pacingFastIntervalTicks = (uint64_t)(90000ULL * timebase.denom / timebase.numer);
        _pacingDefaultIntervalTicks = (uint64_t)(120000ULL * timebase.denom / timebase.numer);
        _pacingCongestedIntervalTicks = (uint64_t)(160000ULL * timebase.denom / timebase.numer);
        _nextSendTime = 0;
        atomic_init(&_queuedMediaChunks, 0);
        atomic_init(&_sendGeneration, 1);
    }
    return self;
}

- (void)dealloc {
    [self stopAdvertising];
    if (_tlsIdentity) {
        CFRelease(_tlsIdentity);
        _tlsIdentity = NULL;
    }
}

#pragma mark - TLS Identity

- (void)setTlsIdentity:(SecIdentityRef)tlsIdentity {
    if (_tlsIdentity) {
        CFRelease(_tlsIdentity);
    }
    _tlsIdentity = tlsIdentity;
    if (_tlsIdentity) {
        CFRetain(_tlsIdentity);
    }
}

#pragma mark - Certificate Pinning

/**
 * Verify peer certificate against stored paired certificate from Keychain.
 * Returns YES if the peer cert matches, NO otherwise.
 */
- (BOOL)verifyPeerCertificate:(sec_trust_t)trust {
    SecTrustRef secTrust = sec_trust_copy_ref(trust);
    if (!secTrust) {
        os_log_error(wireless_log(), "Certificate verify: no trust ref");
        return NO;
    }

    CFArrayRef certChain = SecTrustCopyCertificateChain(secTrust);
    CFRelease(secTrust);
    if (!certChain || CFArrayGetCount(certChain) == 0) {
        os_log_error(wireless_log(), "Certificate verify: no peer certificate chain");
        if (certChain) CFRelease(certChain);
        return NO;
    }
    SecCertificateRef peerCert = (SecCertificateRef)CFArrayGetValueAtIndex(certChain, 0);

    CFDataRef peerCertData = SecCertificateCopyData(peerCert);
    CFRelease(certChain);
    if (!peerCertData) {
        os_log_error(wireless_log(), "Certificate verify: cannot get cert data");
        return NO;
    }

    uint8_t peerHash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(peerCertData), (CC_LONG)CFDataGetLength(peerCertData), peerHash);
    CFRelease(peerCertData);

    NSData *storedFingerprint = [self loadStoredPeerFingerprint];
    if (!storedFingerprint || storedFingerprint.length != CC_SHA256_DIGEST_LENGTH) {
        os_log_error(wireless_log(), "Certificate verify: no stored peer fingerprint (not paired)");
        return NO;
    }

    BOOL match = (memcmp(peerHash, storedFingerprint.bytes, CC_SHA256_DIGEST_LENGTH) == 0);
    if (!match) {
        os_log_error(wireless_log(), "Certificate verify: peer cert fingerprint MISMATCH -- rejecting");
    } else {
        os_log(wireless_log(), "Certificate verify: peer cert fingerprint matches stored -- trusted");
    }
    return match;
}

- (NSData *)loadStoredPeerFingerprint {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @KEYDRD_KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: @"peer-cert-fingerprint",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) return nil;
    return (__bridge_transfer NSData *)result;
}

#pragma mark - TLS/DTLS Parameter Configuration

- (nw_parameters_t)createSecureTCPParameters {
    __weak WirelessTransport *weakSelf = self;
    SecIdentityRef identity = _tlsIdentity;

    nw_parameters_t tcpParams = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_protocol_options_set_peer_authentication_required(sec, true);

            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }
            /* Reject unknown peers; pin if fingerprint stored */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    WirelessTransport *self2 = weakSelf;
                    if (!self2) {
                        complete(false);
                        return;
                    }
                    NSData *stored = [self2 loadStoredPeerFingerprint];
                    if (stored && stored.length > 0) {
                        BOOL trusted = [self2 verifyPeerCertificate:trust];
                        complete(trusted);
                    } else {
                        complete(false);
                    }
                },
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        },
        ^(nw_protocol_options_t tcp_options) {
            nw_tcp_options_set_no_delay(tcp_options, true);
        });

    return tcpParams;
}

- (nw_parameters_t)createSecureUDPParameters {
    __weak WirelessTransport *weakSelf = self;
    SecIdentityRef identity = _tlsIdentity;

    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        ^(nw_protocol_options_t dtls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_protocol_options_set_peer_authentication_required(sec, true);

            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }

            /* Reject unknown peers; pin if fingerprint stored */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    WirelessTransport *self2 = weakSelf;
                    if (!self2) {
                        complete(false);
                        return;
                    }
                    NSData *stored = [self2 loadStoredPeerFingerprint];
                    if (stored && stored.length > 0) {
                        BOOL trusted = [self2 verifyPeerCertificate:trust];
                        complete(trusted);
                    } else {
                        complete(false);
                    }
                },
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    return udpParams;
}

#pragma mark - Public API

- (void)startAdvertising {
    _advertisingRequested = YES;
    if (_bonjourListener) {
        os_log(wireless_log(),
               "startAdvertising: listener already active (isConnected=%{public}d isAWDL=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)",
               _isConnected, _isAWDL, _inputConnection, _advertisingRequested);
        return;
    }

    if (!_tlsIdentity) {
        os_log_error(wireless_log(), "Cannot start advertising: tlsIdentity not set");
        return;
    }

    os_log(wireless_log(), "Starting Bonjour advertisement for %{public}s (TLS/DTLS enabled)", KEYDRD_SERVICE);

    /*
     * Create TCP listener with Bonjour advertisement and TLS 1.3.
     * Handles service discovery. Once connected, we establish a separate
     * DTLS-encrypted UDP path for media.
     */
    nw_parameters_t tcpParams = [self createSecureTCPParameters];

    /* Enable peer-to-peer for AWDL support (RD-TRANS-03) */
    nw_parameters_set_include_peer_to_peer(tcpParams, true);
    nw_parameters_set_reuse_local_address(tcpParams, true);
    nw_parameters_set_local_endpoint(tcpParams,
        nw_endpoint_create_host("::", kInputPortStr));

    _bonjourListener = nw_listener_create(tcpParams);
    nw_listener_t bonjourListener = _bonjourListener;

    /* Advertise via Bonjour */
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        NULL, /* auto-generate name */
        KEYDRD_SERVICE,
        "local.");
    nw_advertise_descriptor_set_no_auto_rename(advertise, false);
    nw_listener_set_advertise_descriptor(bonjourListener, advertise);

    nw_listener_set_queue(bonjourListener, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(bonjourListener, ^(nw_listener_state_t state,
                                                              nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        BOOL isActiveListener = (self2->_bonjourListener == bonjourListener);
        switch (state) {
        case nw_listener_state_ready:
            os_log(wireless_log(), "TLS Bonjour listener ready (advertising %{public}s)", KEYDRD_SERVICE);
            break;
        case nw_listener_state_failed:
            os_log_error(wireless_log(),
                         "TLS Bonjour listener failed: %{public}@ (active=%{public}d isConnected=%{public}d inputConnection=%{public}p)",
                         error ?: (nw_error_t)@"unknown",
                         isActiveListener, self2->_isConnected, self2->_inputConnection);
            if (isActiveListener) {
                self2->_bonjourListener = nil;
                if (self2->_advertisingRequested && !self2->_isConnected) {
                    os_log(wireless_log(),
                           "Bonjour listener failure recovery: restarting advertising for reconnect discovery");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   self2->_transportQueue, ^{
                        if (self2->_advertisingRequested && !self2->_bonjourListener && !self2->_isConnected) {
                            [self2 startAdvertising];
                        } else {
                            os_log(wireless_log(),
                                   "Bonjour listener restart skipped (listener=%{public}p isConnected=%{public}d advertisingRequested=%{public}d)",
                                   self2->_bonjourListener, self2->_isConnected, self2->_advertisingRequested);
                        }
                    });
                } else {
                    os_log(wireless_log(),
                           "Bonjour listener failure recovery skipped (advertisingRequested=%{public}d isConnected=%{public}d)",
                           self2->_advertisingRequested, self2->_isConnected);
                }
            }
            break;
        case nw_listener_state_cancelled:
            os_log(wireless_log(),
                   "TLS Bonjour listener cancelled (active=%{public}d isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)",
                   isActiveListener, self2->_isConnected, self2->_inputConnection, self2->_advertisingRequested);
            if (isActiveListener) {
                self2->_bonjourListener = nil;
                if (self2->_advertisingRequested && !self2->_isConnected && !self2->_inputConnection) {
                    os_log(wireless_log(),
                           "Bonjour listener cancelled unexpectedly while idle; restarting advertising for reconnect discovery");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                   self2->_transportQueue, ^{
                        if (self2->_advertisingRequested && !self2->_bonjourListener && !self2->_isConnected && !self2->_inputConnection) {
                            [self2 startAdvertising];
                        } else {
                            os_log(wireless_log(),
                                   "Cancelled-listener restart skipped (listener=%{public}p isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)",
                                   self2->_bonjourListener, self2->_isConnected, self2->_inputConnection, self2->_advertisingRequested);
                        }
                    });
                } else {
                    os_log(wireless_log(),
                           "Bonjour listener cancel treated as expected (isConnected=%{public}d inputConnection=%{public}p advertisingRequested=%{public}d)",
                           self2->_isConnected, self2->_inputConnection, self2->_advertisingRequested);
                }
            }
            break;
        default:
            break;
        }
    });

    nw_listener_set_new_connection_handler(bonjourListener, ^(nw_connection_t connection) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;

        [self2 handleNewConnection:connection];
    });

    nw_listener_start(bonjourListener);
}

- (void)beginReconnectWindow {
    _allowReconnectTakeover = YES;
    os_log(wireless_log(),
           "Reconnect window armed: allowReconnectTakeover=1 inputConnection=%{public}p isConnected=%{public}d isAWDL=%{public}d",
           _inputConnection, _isConnected, _isAWDL);
}

- (void)stopAdvertising {
    _advertisingRequested = NO;
    os_log(wireless_log(),
           "stopAdvertising: advertisingRequested=0 (listener=%{public}p isConnected=%{public}d inputConnection=%{public}p)",
           _bonjourListener, _isConnected, _inputConnection);
    if (_bonjourListener) {
        nw_listener_cancel(_bonjourListener);
        _bonjourListener = nil;
    }
    [self tearDownConnections];
}

- (void)sendMediaFrame:(const void *)data length:(size_t)len {
    nw_connection_t conn = _mediaConnection;
    if (!conn) {
        static int noConnCount = 0;
        if (noConnCount < 3) {
            os_log_error(wireless_log(), "sendMediaFrame: no media connection (len=%zu)", len);
        }
        noConnCount++;
        return;
    }

    static int mediaSendCount = 0;
    if (mediaSendCount < 5) {
        os_log(wireless_log(), "sendMediaFrame: sending %zu bytes via UDP/DTLS (paced)", len);
    }
    mediaSendCount++;

    /* Copy data — the caller (chunk_frame) frees the original buffer after this returns.
     * DISPATCH_DATA_DESTRUCTOR_FREE tells dispatch_data to free() our copy when done. */
    void *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, data, len);
    size_t copyLen = len;
    uint64_t generation = atomic_load_explicit(&_sendGeneration, memory_order_relaxed);
    atomic_fetch_add_explicit(&_queuedMediaChunks, 1, memory_order_relaxed);

    /* Pace sends on a dedicated serial queue.
     * Without pacing, a single keyframe (~100KB = 73 chunks) gets blasted
     * via nw_connection_send in rapid succession, overwhelming WiFi AP
     * buffers and causing burst packet loss. We space chunk sends by
     * _pacingIntervalTicks (~0.56ms at 20 Mbps for 1400-byte chunks). */
    dispatch_async(_sendPacingQueue, ^{
        if (generation != atomic_load_explicit(&self->_sendGeneration, memory_order_relaxed) ||
            conn != self->_mediaConnection) {
            atomic_fetch_sub_explicit(&self->_queuedMediaChunks, 1, memory_order_relaxed);
            free(copy);
            return;
        }

        /* Wait until our scheduled send time */
        uint64_t now = mach_absolute_time();
        if (self->_nextSendTime > now) {
            mach_wait_until(self->_nextSendTime);
        }

        /* Schedule next send relative to NOW (not _nextSendTime) to avoid
         * accumulating delay if we fell behind. Use a faster pace while the
         * queue is shallow so large UI bursts do not monopolize the sender. */
        uint32_t queued = atomic_load_explicit(&self->_queuedMediaChunks, memory_order_relaxed);
        uint64_t pacingTicks = self->_pacingDefaultIntervalTicks;
        if (queued <= 96) {
            pacingTicks = self->_pacingFastIntervalTicks;
        } else if (queued >= 320) {
            pacingTicks = self->_pacingCongestedIntervalTicks;
        }
        self->_nextSendTime = mach_absolute_time() + pacingTicks;

        dispatch_data_t ddata = dispatch_data_create(copy, copyLen, self->_transportQueue,
                                                     DISPATCH_DATA_DESTRUCTOR_FREE);
        /* For DTLS/UDP, each datagram is a complete message.
         * is_complete=true is required (false gives "Operation not supported"). */
        nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                           true, ^(nw_error_t _Nullable error) {
            atomic_fetch_sub_explicit(&self->_queuedMediaChunks, 1, memory_order_relaxed);
            if (error) {
                os_log_error(wireless_log(), "Wireless media send error: %{public}@", error);
            }
        });
    });
}

- (void)afterPendingSends:(void (^)(void))completion {
    dispatch_async(_sendPacingQueue, ^{
        if (completion) completion();
    });
}

- (void)resetSendPacing {
    _nextSendTime = 0;
    atomic_fetch_add_explicit(&_sendGeneration, 1, memory_order_relaxed);
}

- (NSUInteger)queuedMediaChunkCount {
    return (NSUInteger)atomic_load_explicit(&_queuedMediaChunks, memory_order_relaxed);
}

- (void)handleCongestionFeedback:(float)lossRate {
    os_log(wireless_log(), "Congestion feedback: loss=%.1f%%", lossRate * 100);
    if (self.onCongestionStats) {
        self.onCongestionStats(lossRate, 0, 0);
    }
}

- (void)sendMediaFrameViaTCP:(const void *)data length:(size_t)len {
    [self sendMediaFrameViaTCP:data length:len completion:nil];
}

- (void)sendMediaFrameViaTCP:(const void *)data
                      length:(size_t)len
                  completion:(void (^ _Nullable)(BOOL success))completion {
    nw_connection_t conn = _inputConnection;
    if (!conn) {
        if (completion) completion(NO);
        return;
    }

    /* Copy the framed payload so nw_connection_send owns stable bytes until
     * the completion handler fires. The previous stack/borrowed-buffer path
     * was only safe if Network.framework copied synchronously, which is not a
     * contract we should rely on for large media frames. */
    size_t framedLen = 4 + len;
    uint8_t *framedBytes = malloc(framedLen);
    if (!framedBytes) {
        if (completion) completion(NO);
        return;
    }

    uint32_t netLen = htonl((uint32_t)len);
    memcpy(framedBytes, &netLen, 4);
    memcpy(framedBytes + 4, data, len);

    dispatch_data_t framed = dispatch_data_create(framedBytes, framedLen, _transportQueue,
                                                  DISPATCH_DATA_DESTRUCTOR_FREE);

    nw_connection_send(conn, framed, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(wireless_log(), "TCP media frame send error: %{public}@", error);
            if (completion) completion(NO);
        } else if (completion) {
            completion(YES);
        }
    });
}

- (void)sendInputEvent:(const void *)data length:(size_t)len {
    nw_connection_t conn = _inputConnection;
    if (!conn) {
        os_log_error(wireless_log(), "sendInputEvent: no input connection (len=%zu)", len);
        return;
    }

    static int sendCount = 0;
    if (sendCount < 5) {
        os_log(wireless_log(), "sendInputEvent: sending %zu bytes over TCP (framed)", len);
    }
    sendCount++;

    /* See sendMediaFrameViaTCP: send a copied, framed payload so the bytes stay
     * valid until Network.framework finishes with them. */
    size_t framedLen = 4 + len;
    uint8_t *framedBytes = malloc(framedLen);
    if (!framedBytes) return;

    uint32_t netLen = htonl((uint32_t)len);
    memcpy(framedBytes, &netLen, 4);
    memcpy(framedBytes + 4, data, len);

    dispatch_data_t framed = dispatch_data_create(framedBytes, framedLen, _transportQueue,
                                                  DISPATCH_DATA_DESTRUCTOR_FREE);

    nw_connection_send(conn, framed, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(wireless_log(), "Wireless input send error: %{public}@", error);
        }
    });
}

#pragma mark - Private: Connection Handling

- (void)handleNewConnection:(nw_connection_t)connection {
    os_log(wireless_log(), "TLS wireless connection accepted from iPad");

    /* Ignore duplicate candidates while an existing session is still active.
     * During reconnect/rotation, the old TCP socket can remain "connected" for
     * a while after the iPad has moved on. Replace stale sockets once they have
     * been idle long enough so reconnect can complete without waiting for TCP timeout. */
    if (_inputConnection) {
        uint64_t nowTicks = mach_absolute_time();
        uint64_t idleNs = _lastInputActivityTicks > 0 ? keydrd_mach_delta_ns(nowTicks, _lastInputActivityTicks) : 0;
        uint64_t ageNs = _inputReadyAtTicks > 0 ? keydrd_mach_delta_ns(nowTicks, _inputReadyAtTicks) : 0;
        uint64_t pendingAgeNs = _inputAcceptedAtTicks > 0 ? keydrd_mach_delta_ns(nowTicks, _inputAcceptedAtTicks) : 0;
        BOOL hasInputActivity = (_lastInputActivityTicks > 0);
        BOOL staleByIdle = (_lastInputActivityTicks > 0) && (idleNs >= kDuplicateReplaceIdleThresholdNs);
        BOOL staleByNoInput = (_lastInputActivityTicks == 0) &&
                              (_inputReadyAtTicks > 0) &&
                              (ageNs >= kDuplicateReplaceIdleThresholdNs);
        BOOL stalePendingConnect = (!_isConnected) &&
                                   (_inputReadyAtTicks == 0) &&
                                   (_inputAcceptedAtTicks > 0) &&
                                   (pendingAgeNs >= kPendingConnectionReplaceThresholdNs);
        BOOL shouldReplace = _allowReconnectTakeover || staleByIdle || staleByNoInput || stalePendingConnect;

        os_log(wireless_log(),
               "Duplicate wireless candidate: existing inputConnection=%{public}p isConnected=%{public}d isAWDL=%{public}d hasInputActivity=%{public}d idle=%.2fs age=%.2fs pendingAge=%.2fs allowReconnectTakeover=%{public}d staleByIdle=%{public}d staleByNoInput=%{public}d stalePendingConnect=%{public}d shouldReplace=%{public}d",
               _inputConnection, _isConnected, _isAWDL,
               hasInputActivity,
               (double)idleNs / 1000000000.0, (double)ageNs / 1000000000.0, (double)pendingAgeNs / 1000000000.0,
               _allowReconnectTakeover, staleByIdle, staleByNoInput, stalePendingConnect, shouldReplace);
        if (shouldReplace) {
            const char *reason = _allowReconnectTakeover ? "reconnect-window" :
                (stalePendingConnect ? "pending-timeout" : (staleByIdle ? "idle-timeout" : "no-input-timeout"));
            os_log(wireless_log(), "Replacing stale wireless input connection (%{public}s)", reason);
            nw_connection_cancel(_inputConnection);
            _inputConnection = nil;
            _inputAcceptedAtTicks = 0;
            _inputReadyAtTicks = 0;
            _lastInputActivityTicks = 0;
            _allowReconnectTakeover = NO;
        } else {
            os_log(wireless_log(), "Ignoring duplicate wireless candidate while an existing session is active");
            nw_connection_cancel(connection);
            return;
        }
    }
    _inputConnection = connection;
    _inputAcceptedAtTicks = mach_absolute_time();
    os_log(wireless_log(),
           "Accepted wireless candidate as current input connection (inputConnection=%{public}p isConnected=%{public}d)",
           _inputConnection, _isConnected);

    nw_connection_set_queue(connection, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state,
                                                          nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        BOOL isActiveConnection = (self2.inputConnection == connection);

        switch (state) {
        case nw_connection_state_ready: {
            if (!isActiveConnection) {
                os_log(wireless_log(),
                       "Ignoring READY from stale wireless connection (activeInput=%{public}p staleConnection=%{public}p isConnected=%{public}d)",
                       self2.inputConnection, connection, self2.isConnected);
                break;
            }
            /* Determine if connection is AWDL or Wi-Fi via interface type */
            nw_path_t path = nw_connection_copy_current_path(connection);
            BOOL detectedAWDL = NO;

            if (path) {
                __block BOOL hasWiFi = NO;
                __block BOOL hasPeerToPeer = NO;
                nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
                    nw_interface_type_t type = nw_interface_get_type(interface);
                    const char *name = nw_interface_get_name(interface);
                    os_log(wireless_log(), "Connection interface: %{public}s (type=%d)",
                           name, (int)type);
                    if (type == nw_interface_type_wifi) hasWiFi = YES;
                    if (type == nw_interface_type_other) hasPeerToPeer = YES;
                    return true;
                });

                /* AWDL connections show up as type_other; Wi-Fi as type_wifi */
                detectedAWDL = hasPeerToPeer && !hasWiFi;
            }

            self2.isAWDL = detectedAWDL;
            self2.isConnected = YES;
            self2->_allowReconnectTakeover = NO;
            self2->_inputReadyAtTicks = mach_absolute_time();
            self2->_lastInputActivityTicks = self2->_inputReadyAtTicks;
            os_log(wireless_log(), "TLS wireless connection ready (AWDL=%d)", detectedAWDL);

            if (self2->_bonjourListener) {
                os_log(wireless_log(),
                       "Suspending Bonjour listener while wireless session is active (inputConnection=%{public}p)",
                       self2->_inputConnection);
                nw_listener_cancel(self2->_bonjourListener);
                self2->_bonjourListener = nil;
            } else {
                os_log(wireless_log(),
                       "Bonjour listener already suspended when connection became ready (inputConnection=%{public}p)",
                       self2->_inputConnection);
            }

            if (self2.onConnectionChanged) {
                self2.onConnectionChanged(YES, detectedAWDL);
            }

            /* Start receive loop */
            [self2 scheduleInputReceive:connection];

            /* Establish DTLS-encrypted UDP media connection to the iPad's address */
            [self2 establishMediaConnection:connection];
            break;
        }
        case nw_connection_state_failed:
        case nw_connection_state_cancelled:
            if (!isActiveConnection) {
                os_log(wireless_log(),
                       "Ignoring end-state from stale wireless connection (state=%{public}d error=%{public}@ activeInput=%{public}p staleConnection=%{public}p isConnected=%{public}d)",
                       (int)state,
                       error ?: (nw_error_t)@"none",
                       self2.inputConnection, connection, self2.isConnected);
                break;
            }
            os_log(wireless_log(),
                   "TLS wireless connection ended (state=%{public}d error=%{public}@ wasAWDL=%{public}d)",
                   (int)state,
                   error ?: (nw_error_t)@"none",
                   self2.isAWDL);
            if (self2.inputConnection == connection) {
                self2.inputConnection = nil;
                self2.isConnected = NO;
                self2->_allowReconnectTakeover = NO;
                self2->_inputAcceptedAtTicks = 0;
                self2->_inputReadyAtTicks = 0;
                self2->_lastInputActivityTicks = 0;
                if (!self2->_bonjourListener) {
                    os_log(wireless_log(),
                           "Wireless connection ended; re-enabling Bonjour listener for reconnect discovery");
                    [self2 startAdvertising];
                } else {
                    os_log(wireless_log(),
                           "Wireless connection ended; Bonjour listener already active for reconnect discovery");
                }
                if (self2.onConnectionChanged) {
                    self2.onConnectionChanged(NO, self2.isAWDL);
                }
            }
            break;
        default:
            break;
        }
    });

    nw_connection_start(connection);
}

- (void)establishMediaConnection:(nw_connection_t)tcpConnection {
    /*
     * Create a DTLS-encrypted UDP LISTENER on the media port.
     * The iPad connects to this port after its TCP connection is ready.
     * Mac is the LISTENER, iPad is the CONNECTOR (same pattern as TCP).
     */
    if (_mediaListener) {
        nw_listener_cancel(_mediaListener);
        _mediaListener = nil;
    }

    nw_parameters_t udpParams = [self createSecureUDPParameters];
    nw_parameters_set_include_peer_to_peer(udpParams, true);
    nw_parameters_set_reuse_local_address(udpParams, true);
    nw_parameters_set_local_endpoint(udpParams,
        nw_endpoint_create_host("::", kMediaPortStr));

    /* Bind to same interface as TCP */
    nw_path_t path = nw_connection_copy_current_path(tcpConnection);
    if (path) {
        __block nw_interface_t pathInterface = nil;
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
            pathInterface = interface;
            return false;
        });
        if (pathInterface) {
            nw_parameters_require_interface(udpParams, pathInterface);
        }
    }

    nw_listener_t mediaListener = nw_listener_create(udpParams);
    _mediaListener = mediaListener;

    nw_listener_set_queue(mediaListener, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(mediaListener, ^(nw_listener_state_t state,
                                                            nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            os_log(wireless_log(), "DTLS media listener ready on port %{public}s", kMediaPortStr);
        } else if (state == nw_listener_state_failed) {
            os_log_error(wireless_log(), "DTLS media listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_listener_set_new_connection_handler(mediaListener, ^(nw_connection_t conn) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;

        os_log(wireless_log(), "DTLS media connection accepted from iPad");

        if (self2->_mediaConnection) {
            nw_connection_cancel(self2->_mediaConnection);
        }
        self2->_mediaConnection = conn;

        nw_connection_set_queue(conn, self2->_transportQueue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t cState,
                                                         nw_error_t _Nullable cError) {
            if (cState == nw_connection_state_ready) {
                WirelessTransport *self3 = weakSelf;
                BOOL isActiveMediaConnection = (self3 && self3->_mediaConnection == conn);
                if (!isActiveMediaConnection) {
                    os_log(wireless_log(),
                           "Ignoring READY from stale DTLS media connection (activeMedia=%{public}p staleConnection=%{public}p)",
                           self3 ? self3->_mediaConnection : nil, conn);
                    return;
                }
                os_log(wireless_log(), "DTLS wireless media UDP connection ready");
                if (self3) {
                    [self3 resetSendPacing];
                    [self3 scheduleMediaReceive:conn];
                    if (self3.onMediaChannelReady) {
                        self3.onMediaChannelReady();
                    }
                }
            } else if (cState == nw_connection_state_failed) {
                WirelessTransport *self3 = weakSelf;
                BOOL isActiveMediaConnection = (self3 && self3->_mediaConnection == conn);
                if (!isActiveMediaConnection) {
                    os_log(wireless_log(),
                           "Ignoring FAILED from stale DTLS media connection (error=%{public}@ activeMedia=%{public}p staleConnection=%{public}p)",
                           cError ?: (nw_error_t)@"unknown",
                           self3 ? self3->_mediaConnection : nil, conn);
                    return;
                }
                os_log_error(wireless_log(), "DTLS wireless media connection failed: %{public}@",
                             cError ?: (nw_error_t)@"unknown");
                if (self3) {
                    self3->_mediaConnection = nil;
                    [self3 handleActiveMediaPathLossWithReason:"media-failed"
                                                         detail:cError ?: (nw_error_t)@"unknown"];
                }
            } else if (cState == nw_connection_state_cancelled) {
                WirelessTransport *self3 = weakSelf;
                BOOL isActiveMediaConnection = (self3 && self3->_mediaConnection == conn);
                if (!isActiveMediaConnection) {
                    os_log(wireless_log(),
                           "Ignoring CANCELLED from stale DTLS media connection (activeMedia=%{public}p staleConnection=%{public}p)",
                           self3 ? self3->_mediaConnection : nil, conn);
                    return;
                }
                os_log(wireless_log(), "DTLS wireless media connection cancelled");
                if (self3) {
                    self3->_mediaConnection = nil;
                    [self3 handleActiveMediaPathLossWithReason:"media-cancelled"
                                                         detail:(nw_error_t)@"dtls-state-cancelled"];
                }
            }
        });
        nw_connection_start(conn);
    });

    nw_listener_start(mediaListener);
}

#pragma mark - Private: Receive Loops

- (void)scheduleMediaReceive:(nw_connection_t)connection {
    __weak WirelessTransport *weakSelf = self;
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t _Nullable content,
                                                   nw_content_context_t _Nullable context,
                                                   bool is_complete,
                                                   nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        if (self2->_mediaConnection != connection) {
            if (error || is_complete) {
                os_log(wireless_log(),
                       "Dropping stale media receive callback (activeMedia=%{public}p staleConnection=%{public}p is_complete=%{public}d error=%{public}@)",
                       self2->_mediaConnection, connection, is_complete, error ?: (nw_error_t)@"none");
            }
            return;
        }

        if (!error) {
            /* Keep DTLS receive armed before media processing to avoid
             * callback starvation during heavy decode/reassembly work. */
            [self2 scheduleMediaReceive:connection];
        }

        if (content && dispatch_data_get_size(content) > 0) {
            dispatch_data_apply(content, ^bool(dispatch_data_t _Nonnull region,
                                                size_t offset,
                                                const void *_Nonnull buffer,
                                                size_t size) {
                if (self2.onMediaReceived) {
                    self2.onMediaReceived(buffer, size);
                }
                return true;
            });
        }

        if (error) {
            BOOL hasInputConnection = (self2->_inputConnection != nil);
            BOOL inputReady = (self2->_inputReadyAtTicks > 0);
            uint64_t inputIdleNs = 0;
            BOOL recentInputActivity = NO;
            if (self2->_lastInputActivityTicks > 0) {
                inputIdleNs = keydrd_mach_delta_ns(mach_absolute_time(), self2->_lastInputActivityTicks);
                recentInputActivity = (inputIdleNs <= kDuplicateReplaceIdleThresholdNs);
            }
            BOOL controlPathHealthy = hasInputConnection &&
                                      self2->_isConnected &&
                                      (recentInputActivity || inputReady);
            if (controlPathHealthy && keydrd_is_transient_dtls_gap(error)) {
                os_log(wireless_log(),
                       "Media path loss decision=ignored reason=transient-dtls-recv-gap detail=%{public}@ controlPathHealthy=%{public}d inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums",
                       error,
                       controlPathHealthy,
                       inputReady,
                       recentInputActivity,
                       inputIdleNs / 1000000ULL);
                [self2 scheduleMediaReceive:connection];
                return;
            }
            os_log_error(wireless_log(),
                         "DTLS media receive error on active connection: %{public}@",
                         error);
            self2->_mediaConnection = nil;
            [self2 handleActiveMediaPathLossWithReason:"media-receive-error" detail:error];
            return;
        }
        if (is_complete) {
            os_log(wireless_log(),
                   "DTLS media receive delivered is_complete=1 on active connection; treating as datagram completion and keeping receive loop armed");
        }
        /* For DTLS/UDP: is_complete marks datagram boundary and is not
         * a connection-closed signal. */
    });
}

- (void)scheduleInputReceive:(nw_connection_t)connection {
    __weak WirelessTransport *weakSelf = self;
    nw_connection_receive(connection, 1, 4096, ^(dispatch_data_t _Nullable content,
                                                  nw_content_context_t _Nullable context,
                                                  bool is_complete,
                                                  nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        if (self2->_inputConnection != connection) {
            if (error || is_complete) {
                os_log(wireless_log(),
                       "Dropping stale input receive callback (activeInput=%{public}p staleConnection=%{public}p is_complete=%{public}d error=%{public}@)",
                       self2->_inputConnection, connection, is_complete, error ?: (nw_error_t)@"none");
            }
            return;
        }

        if (content && dispatch_data_get_size(content) > 0) {
            self2->_lastInputActivityTicks = mach_absolute_time();
            dispatch_data_apply(content, ^bool(dispatch_data_t _Nonnull region,
                                                size_t offset,
                                                const void *_Nonnull buffer,
                                                size_t size) {
                if (self2.onInputReceived) {
                    self2.onInputReceived(buffer, size);
                }
                return true;
            });
        }

        if (error) {
            os_log_error(wireless_log(), "TCP input receive error on active connection: %{public}@", error);
            nw_connection_cancel(connection);
            return;
        }
        if (is_complete) {
            os_log(wireless_log(), "TCP input receive completed (EOF) on active connection; cancelling to force lifecycle transition");
            nw_connection_cancel(connection);
            return;
        }
        [self2 scheduleInputReceive:connection];
    });
}

#pragma mark - Private: Teardown

- (void)tearDownConnections {
    [self resetSendPacing];
    if (_mediaListener) {
        nw_listener_cancel(_mediaListener);
        _mediaListener = nil;
    }
    if (_mediaConnection) {
        nw_connection_cancel(_mediaConnection);
        _mediaConnection = nil;
    }
    if (_inputConnection) {
        nw_connection_cancel(_inputConnection);
        _inputConnection = nil;
    }
    _allowReconnectTakeover = NO;
    _inputAcceptedAtTicks = 0;
    _inputReadyAtTicks = 0;
    _lastInputActivityTicks = 0;
    _isConnected = NO;
    _isAWDL = NO;
}

- (void)handleActiveMediaPathLossWithReason:(const char *)reason detail:(nw_error_t _Nullable)detail {
    BOOL hadInputConnection = (_inputConnection != nil);
    BOOL wasConnected = _isConnected;
    BOOL wasAWDL = _isAWDL;
    BOOL shouldRecover = hadInputConnection || wasConnected;
    BOOL inputReady = (_inputReadyAtTicks > 0);
    uint64_t inputIdleNs = 0;
    BOOL recentInputActivity = NO;
    if (_lastInputActivityTicks > 0) {
        inputIdleNs = keydrd_mach_delta_ns(mach_absolute_time(), _lastInputActivityTicks);
        recentInputActivity = (inputIdleNs <= kDuplicateReplaceIdleThresholdNs);
    }
    BOOL controlPathHealthy = hadInputConnection &&
                              wasConnected &&
                              (recentInputActivity || inputReady);

    os_log(wireless_log(),
           "Media path loss observed: reason=%{public}s detail=%{public}@ hadInputConnection=%{public}d wasConnected=%{public}d advertisingRequested=%{public}d",
           reason,
           detail ?: (nw_error_t)@"none",
           hadInputConnection,
           wasConnected,
           _advertisingRequested);
    if (controlPathHealthy) {
        os_log(wireless_log(),
               "Media path loss decision=degraded reason=control-path-healthy detail=%{public}@ inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums action=preserve-session-no-reconnect",
               detail ?: (nw_error_t)@"none",
               inputReady,
               recentInputActivity,
               inputIdleNs / 1000000ULL);
        return;
    }
    if (!shouldRecover) {
        os_log(wireless_log(),
               "Media path loss decision=ignored reason=no-active-session mediaReason=%{public}s",
               reason);
        return;
    }

    nw_connection_t staleInput = _inputConnection;
    _inputConnection = nil;
    if (staleInput) {
        nw_connection_cancel(staleInput);
    }
    _allowReconnectTakeover = NO;
    _inputAcceptedAtTicks = 0;
    _inputReadyAtTicks = 0;
    _lastInputActivityTicks = 0;
    _isConnected = NO;
    _isAWDL = NO;

    os_log_error(wireless_log(),
                 "Media path loss decision=reconnect-triggered reason=%{public}s wasAWDL=%{public}d inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums",
                 reason,
                 wasAWDL,
                 inputReady,
                 recentInputActivity,
                 inputIdleNs / 1000000ULL);
    if (self.onConnectionChanged) {
        self.onConnectionChanged(NO, wasAWDL);
    }
    if (_advertisingRequested && !_bonjourListener) {
        os_log(wireless_log(),
               "Media path loss recovery: starting Bonjour listener for reconnect discovery");
        [self startAdvertising];
    } else {
        os_log(wireless_log(),
               "Media path loss recovery: listener restart skipped (advertisingRequested=%{public}d listener=%{public}p)",
               _advertisingRequested,
               _bonjourListener);
    }
}

@end
