#import "WirelessTransport.h"
#import "protocol.h"
#import "framing.h"
#import "crypto.h"
#import <os/log.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
#import <os/lock.h>
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
static const uint64_t kControlRecoveryPollIntervalNs = 750000000ULL;
static const uint64_t kControlRecoveryHardDeadlineNs = 6000000000ULL;
static const uint64_t kTransientMediaGapControlRecoveryGraceNs = 1500000000ULL;
/* Link liveness (tla/TransportConnections.tla SilenceDetect): a heartbeat each second on the
 * control connection; no byte from the iPad for the deadline means the link is lost. */
static const uint64_t kLinkHeartbeatIntervalNs = 1000000000ULL;
static const uint64_t kLinkSilenceDeadlineNs = 4000000000ULL;

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
    uint64_t _controlPathRecoveryStartedAtTicks; // first observed active control-path loss tick
    BOOL _advertisingRequested;           // true while caller expects Bonjour advertising to stay active
    dispatch_block_t _Nullable _controlPathRecoveryWorkItem; // delayed control replacement evaluator
    dispatch_source_t _Nullable _linkHeartbeatTimer;  // SilenceDetect heartbeat + deadline check
    NSUInteger _linkHeartbeatsSent;
    NSUInteger _linkHeartbeatsReceived;
    atomic_uint _queuedMediaChunks;        // paced UDP chunks waiting to be sent/completed
    atomic_ullong _sendGeneration;         // increments when media path resets; stale queued sends are discarded
    atomic_bool _mediaReady;               // SessionLanes FreshCheck: true only while the current media connection is ready
    /* tla/Lifecycle.tla.  Every log line tagged "LC <Action>" names the model action it is. */
    NSMutableArray *_pendingInputConnections; // AuthBeforeDisplace: accepted candidates, TLS not done
    NSMutableArray *_pendingInputConnIds;     // their cids, same order
    uint32_t _nextConnId;                     // cid of the next accepted candidate (logs only)
    uint32_t _inputConnId;                    // cid of _inputConnection, 0 = none
    atomic_uint _inputConnectionEpoch;        // RestartOnNewConn: bumps when a connection becomes current
    atomic_bool _inputReady;                  // CountOnSend: the current input connection is ready
    /* tla/FrameLoop.tla HsConn: _inputConnection and _inputConnectionEpoch change together under
     * this lock (writes are on the transport queue); epoch-checked senders read both under it. */
    os_unfair_lock _connLock;
}
@property (nonatomic) dispatch_queue_t transportQueue;
@property (nonatomic, nullable) nw_listener_t bonjourListener;
@property (nonatomic, nullable) nw_listener_t mediaListener;
@property (nonatomic, nullable) nw_connection_t mediaConnection;
@property (nonatomic, nullable) nw_connection_t inputConnection;
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, readwrite) BOOL isAWDL;
@end

static char kWirelessTransportQueueKey;

/* Diagnostic launch arg --no-peer-to-peer: leave AWDL out of the listeners, to tell AWDL
 * off-channel time apart from Wi-Fi power save in latency spikes. Default on. */
static bool wireless_include_peer_to_peer(void) {
    static bool on = true;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = ![[NSProcessInfo processInfo].arguments containsObject:@"--no-peer-to-peer"];
        os_log(wireless_log(), "includePeerToPeer=%{public}d", on);
    });
    return on;
}

@implementation WirelessTransport

- (BOOL)mediaChannelReady {
    return atomic_load(&_mediaReady);
}

- (uint32_t)inputConnectionEpoch {
    return atomic_load(&_inputConnectionEpoch);
}

- (BOOL)hasReadyInputConnection {
    return atomic_load(&_inputReady);
}

/* The current input connection is gone (any path): frames can no longer be queued on it. */
- (void)clearCurrentInputConnectionWithReason:(const char *)reason {
    if (_inputConnection || _inputConnId) {
        os_log(wireless_log(), "LC MacCurrentCleared cid=%u reason=%{public}s", _inputConnId, reason);
    }
    atomic_store(&_inputReady, false);
    os_unfair_lock_lock(&_connLock);
    _inputConnection = nil;
    os_unfair_lock_unlock(&_connLock);
    _inputConnId = 0;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _transportQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.wireless.transport",
                                                DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_transportQueue, &kWirelessTransportQueueKey,
                                    &kWirelessTransportQueueKey, NULL);
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
        _pendingInputConnections = [NSMutableArray array];
        _pendingInputConnIds = [NSMutableArray array];
        atomic_init(&_inputConnectionEpoch, 0);
        _connLock = OS_UNFAIR_LOCK_INIT;
        atomic_init(&_inputReady, false);
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
    /* Listener state is owned by the transport queue. The session queue (reconnect) and
     * main (delayed start) call this too: hop so two queues never both create a listener. */
    if (dispatch_get_specific(&kWirelessTransportQueueKey) == NULL) {
        __weak WirelessTransport *weakSelf = self;
        dispatch_async(_transportQueue, ^{ [weakSelf startAdvertising]; });
        return;
    }
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
    nw_parameters_set_include_peer_to_peer(tcpParams, wireless_include_peer_to_peer());
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
    if (dispatch_get_specific(&kWirelessTransportQueueKey) == NULL) {
        __weak WirelessTransport *weakSelf = self;
        dispatch_async(_transportQueue, ^{ [weakSelf beginReconnectWindow]; });
        return;
    }
    /* tla/Lifecycle.tla AuthBeforeDisplace: no takeover window any more; a candidate replaces the
     * current connection only at READY. Kept as a log point for callers. */
    os_log(wireless_log(),
           "Reconnect window requested (no-op: candidates replace only after TLS) inputConnection=%{public}p isConnected=%{public}d isAWDL=%{public}d",
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

- (nullable nw_connection_t)inputConnectionForEpoch:(uint32_t)epoch {
    os_unfair_lock_lock(&_connLock);
    nw_connection_t c = (epoch != 0 && epoch == atomic_load(&_inputConnectionEpoch)) ? _inputConnection : nil;
    os_unfair_lock_unlock(&_connLock);
    return c;
}

- (BOOL)sendMediaFrameViaTCP:(const void *)data
                      length:(size_t)len
                  completion:(void (^ _Nullable)(BOOL success))completion {
    return [self _sendMediaFrameViaTCP:data length:len connection:_inputConnection completion:completion];
}

- (BOOL)sendMediaFrameViaTCP:(const void *)data
                      length:(size_t)len
                     onEpoch:(uint32_t)epoch
                  completion:(void (^ _Nullable)(BOOL success))completion {
    return [self _sendMediaFrameViaTCP:data length:len connection:[self inputConnectionForEpoch:epoch]
                            completion:completion];
}

- (BOOL)_sendMediaFrameViaTCP:(const void *)data
                       length:(size_t)len
                   connection:(nullable nw_connection_t)conn
                   completion:(void (^ _Nullable)(BOOL success))completion {
    if (!conn || !atomic_load(&_inputReady)) {
        if (completion) completion(NO);
        return NO;
    }

    /* Copy the framed payload so nw_connection_send owns stable bytes until
     * the completion handler fires. The previous stack/borrowed-buffer path
     * was only safe if Network.framework copied synchronously, which is not a
     * contract we should rely on for large media frames. */
    size_t framedLen = 4 + len;
    uint8_t *framedBytes = malloc(framedLen);
    if (!framedBytes) {
        if (completion) completion(NO);
        return NO;
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
    return YES;
}

- (void)sendInputEvent:(const void *)data length:(size_t)len {
    [self _sendInputEvent:data length:len connection:_inputConnection];
}

- (BOOL)sendInputEvent:(const void *)data length:(size_t)len onEpoch:(uint32_t)epoch {
    nw_connection_t conn = [self inputConnectionForEpoch:epoch];
    if (!conn || !atomic_load(&_inputReady)) return NO;
    [self _sendInputEvent:data length:len connection:conn];
    return YES;
}

- (void)_sendInputEvent:(const void *)data length:(size_t)len connection:(nullable nw_connection_t)conn {
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
    uint32_t cid = ++_nextConnId;
    {
        nw_endpoint_t remote = nw_connection_copy_endpoint(connection);
        char *addr = (remote && nw_endpoint_get_type(remote) == nw_endpoint_type_address)
                         ? nw_endpoint_copy_address_string(remote) : NULL;
        uint16_t port = remote ? nw_endpoint_get_port(remote) : 0;
        /* PEER-ADDR: read by scratch ping probes to time-correlate Wi-Fi stalls. */
        os_log(wireless_log(), "TLS wireless connection accepted from iPad PEER-ADDR=%{public}s port=%u cid=%u",
               addr ? addr : "unknown", port, cid);
        free(addr);
    }

    /* tla/Lifecycle.tla AuthBeforeDisplace. A new candidate never touches the current connection
     * here: this runs before TLS, so the candidate may be anyone on the network (as built, an
     * unauthenticated dial replaced the owner's connection inside the reconnect window or once it
     * looked idle). It waits as pending and replaces the current connection only at READY, after
     * the verify block has checked the pin. Pending candidates are capped; the oldest goes first. */
    static const NSUInteger kMaxPendingInputConnections = 4;
    if (_pendingInputConnections.count >= kMaxPendingInputConnections) {
        nw_connection_t oldest = _pendingInputConnections.firstObject;
        uint32_t oldestCid = [_pendingInputConnIds.firstObject unsignedIntValue];
        [_pendingInputConnections removeObjectAtIndex:0];
        [_pendingInputConnIds removeObjectAtIndex:0];
        os_log(wireless_log(), "LC MacTlsFail cid=%u reason=pending-cap (cancelled before TLS)", oldestCid);
        nw_connection_cancel(oldest);
    }
    [_pendingInputConnections addObject:connection];
    [_pendingInputConnIds addObject:@(cid)];
    os_log(wireless_log(),
           "LC MacAccept cid=%u pending=%lu current=%u isConnected=%{public}d listener=%{public}d",
           cid, (unsigned long)_pendingInputConnections.count, _inputConnId, _isConnected,
           _bonjourListener != nil);

    nw_connection_set_queue(connection, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state,
                                                          nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        BOOL isActiveConnection = (self2.inputConnection == connection);
        NSUInteger pendingIndex = [self2->_pendingInputConnections indexOfObjectIdenticalTo:connection];
        BOOL isPending = (pendingIndex != NSNotFound);

        switch (state) {
        case nw_connection_state_ready: {
            if (!isPending) {
                os_log(wireless_log(),
                       "LC MacStaleReady cid=%u current=%u (not pending: ignored)", cid, self2->_inputConnId);
                break;
            }
            /* Pin verified (TLS is done): this candidate becomes current and replaces the old one. */
            [self2->_pendingInputConnections removeObjectAtIndex:pendingIndex];
            [self2->_pendingInputConnIds removeObjectAtIndex:pendingIndex];
            nw_connection_t replaced = self2->_inputConnection;
            uint32_t replacedCid = self2->_inputConnId;
            [self2 clearCurrentInputConnectionWithReason:"replaced-at-ready"];
            if (replaced) {
                [self2 stopLinkHeartbeatWithReason:"replaced"];
                nw_connection_cancel(replaced);
            }
            os_unfair_lock_lock(&self2->_connLock);
            self2->_inputConnection = connection;
            uint32_t epoch = atomic_fetch_add(&self2->_inputConnectionEpoch, 1) + 1;
            os_unfair_lock_unlock(&self2->_connLock);
            self2->_inputConnId = cid;
            self2->_inputAcceptedAtTicks = mach_absolute_time();
            isActiveConnection = YES;
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
                    /* awdl0 reports type wifi: only the name tells AWDL apart (ExactLabel,
                     * tla/TransportConnections.tla). llw0 is low-latency Wi-Fi, also peer-to-peer. */
                    BOOL p2p = name && (strncmp(name, "awdl", 4) == 0 || strncmp(name, "llw", 3) == 0);
                    if (p2p) hasPeerToPeer = YES;
                    else if (type == nw_interface_type_wifi) hasWiFi = YES;
                    return true;
                });

                detectedAWDL = hasPeerToPeer && !hasWiFi;
            }

            self2.isAWDL = detectedAWDL;
            self2.isConnected = YES;
            self2->_inputReadyAtTicks = mach_absolute_time();
            self2->_lastInputActivityTicks = self2->_inputReadyAtTicks;
            [self2 cancelControlPathRecoveryWithReason:"tcp-ready"];
            atomic_store(&self2->_inputReady, true);
            os_log(wireless_log(), "TLS wireless connection ready (AWDL=%d)", detectedAWDL);
            os_log(wireless_log(), "LC MacReady cid=%u replaced=%u epoch=%u AWDL=%{public}d",
                   cid, replacedCid, epoch, detectedAWDL);
            [self2 startLinkHeartbeatForConnection:connection];

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
            if (isPending) {
                /* Ended before READY: TLS failed (wrong pin, Outside) or the dial died. It never
                 * carried input and was never current, so nothing else changes. */
                [self2->_pendingInputConnections removeObjectAtIndex:pendingIndex];
                [self2->_pendingInputConnIds removeObjectAtIndex:pendingIndex];
                os_log(wireless_log(), "LC MacTlsFail cid=%u state=%{public}d error=%{public}@ current=%u",
                       cid, (int)state, error ?: (nw_error_t)@"none", self2->_inputConnId);
                break;
            }
            if (self2.onInputStreamEnded) self2.onInputStreamEnded();
            if (!isActiveConnection) {
                os_log(wireless_log(), "LC MacEnd cid=%u branch=stale current=%u", cid, self2->_inputConnId);
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
                BOOL hasMediaPath = (self2->_mediaConnection != nil);
                BOOL wasConnected = self2->_isConnected;
                BOOL shouldDegradeAndRecover = hasMediaPath && wasConnected;
                BOOL wasAWDL = self2->_isAWDL;
                os_log(wireless_log(), "LC MacEnd cid=%u branch=%{public}s",
                       cid, shouldDegradeAndRecover ? "degraded" : "disconnect");
                [self2 clearCurrentInputConnectionWithReason:"ended"];
                self2->_inputAcceptedAtTicks = 0;
                self2->_inputReadyAtTicks = 0;
                self2->_lastInputActivityTicks = 0;

                if (shouldDegradeAndRecover) {
                    os_log(wireless_log(),
                           "Control path loss decision=degraded reason=tcp-state-ended-media-active state=%{public}d error=%{public}@ action=preserve-session-and-recover-control",
                           (int)state,
                           error ?: (nw_error_t)@"none");
                    [self2 beginControlPathRecoveryForReason:"tcp-state-ended"
                                                      detail:error
                                                     wasAWDL:wasAWDL];
                    break;
                }

                self2.isConnected = NO;
                [self2 cancelControlPathRecoveryWithReason:"tcp-ended-no-media"];
                if (!self2->_bonjourListener) {
                    os_log(wireless_log(),
                           "Wireless connection ended without media; re-enabling Bonjour listener for reconnect discovery");
                    [self2 startAdvertising];
                } else {
                    os_log(wireless_log(),
                           "Wireless connection ended without media; Bonjour listener already active for reconnect discovery");
                }
                if (self2.onConnectionChanged) {
                    self2.onConnectionChanged(NO, wasAWDL);
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
    nw_parameters_set_include_peer_to_peer(udpParams, wireless_include_peer_to_peer());
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
        atomic_store(&self2->_mediaReady, false);
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
                    atomic_store(&self3->_mediaReady, true);
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
                    atomic_store(&self3->_mediaReady, false);
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
                    atomic_store(&self3->_mediaReady, false);
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
            BOOL transientDtlsGap = keydrd_is_transient_dtls_gap(error);
            uint64_t controlRecoveryElapsedNs = 0;
            BOOL controlRecoveryActive = (self2->_controlPathRecoveryStartedAtTicks > 0);
            BOOL controlRecoveryWithinGrace = NO;
            if (controlRecoveryActive) {
                controlRecoveryElapsedNs = keydrd_mach_delta_ns(mach_absolute_time(),
                                                                self2->_controlPathRecoveryStartedAtTicks);
                controlRecoveryWithinGrace =
                    (controlRecoveryElapsedNs <= kTransientMediaGapControlRecoveryGraceNs);
            }
            if (transientDtlsGap && (controlPathHealthy || controlRecoveryWithinGrace)) {
                os_log(wireless_log(),
                       "Media path loss decision=ignored reason=transient-dtls-recv-gap detail=%{public}@ controlPathHealthy=%{public}d controlRecoveryActive=%{public}d controlRecoveryElapsedMs=%{public}llums controlRecoveryGraceMs=%{public}llums inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums",
                       error,
                       controlPathHealthy,
                       controlRecoveryActive,
                       controlRecoveryElapsedNs / 1000000ULL,
                       kTransientMediaGapControlRecoveryGraceNs / 1000000ULL,
                       inputReady,
                       recentInputActivity,
                       inputIdleNs / 1000000ULL);
                [self2 scheduleMediaReceive:connection];
                return;
            }
            if (transientDtlsGap) {
                os_log(wireless_log(),
                       "Media path loss decision=escalating reason=transient-dtls-recv-gap-outside-grace detail=%{public}@ controlPathHealthy=%{public}d controlRecoveryActive=%{public}d controlRecoveryElapsedMs=%{public}llums controlRecoveryGraceMs=%{public}llums inputReady=%{public}d recentInput=%{public}d inputIdleMs=%{public}llums",
                       error,
                       controlPathHealthy,
                       controlRecoveryActive,
                       controlRecoveryElapsedNs / 1000000ULL,
                       kTransientMediaGapControlRecoveryGraceNs / 1000000ULL,
                       inputReady,
                       recentInputActivity,
                       inputIdleNs / 1000000ULL);
            }
            os_log_error(wireless_log(),
                         "DTLS media receive error on active connection: %{public}@",
                         error);
            atomic_store(&self2->_mediaReady, false);
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

/* Each connection's receive chain owns its reassembly buffer (tla/Framing.tla F2), so a
 * replaced connection's late callbacks never mix bytes into the new connection's stream. */
- (void)scheduleInputReceive:(nw_connection_t)connection {
    [self scheduleInputReceive:connection buffer:[NSMutableData data]];
}

- (void)scheduleInputReceive:(nw_connection_t)connection buffer:(NSMutableData *)rx {
    __weak WirelessTransport *weakSelf = self;
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t _Nullable content,
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
                [rx appendBytes:buffer length:size];
                return true;
            });
            /* Dispatch whole frames only; keep the partial tail (Framing.tla KeepPartial). */
            size_t off = 0;
            const uint8_t *bytes = (const uint8_t *)rx.bytes;
            for (;;) {
                size_t consumed = 0, plen = 0;
                const uint8_t *payload = NULL;
                int r = keydrd_frame_next(bytes + off, rx.length - off, &consumed, &payload, &plen);
                if (r == 0) break;
                if (r < 0) {
                    os_log_error(wireless_log(), "Input framing error: invalid length prefix (buffered=%lu), dropping connection",
                                 (unsigned long)(rx.length - off));
                    nw_connection_cancel(connection);
                    return;
                }
                if (plen >= 1 && payload[0] == KEYDRD_LINK_HEARTBEAT) {
                    self2->_linkHeartbeatsReceived++;
                    if (self2->_linkHeartbeatsReceived <= 3 || self2->_linkHeartbeatsReceived % 60 == 0) {
                        os_log(wireless_log(), "Link heartbeat received count=%lu",
                               (unsigned long)self2->_linkHeartbeatsReceived);
                    }
                } else if (self2.onInputReceived) {
                    self2.onInputReceived(payload, plen);
                }
                off += consumed;
            }
            if (off > 0) {
                [rx replaceBytesInRange:NSMakeRange(0, off) withBytes:NULL length:0];
            }
        }

        if (error) {
            os_log_error(wireless_log(), "TCP input receive error on active connection: %{public}@", error);
            nw_connection_cancel(connection);
            return;
        }
        if (is_complete) {
            BOOL hasMediaPath = (self2->_mediaConnection != nil);
            BOOL wasConnected = self2->_isConnected;
            if (hasMediaPath && wasConnected) {
                os_log(wireless_log(),
                       "Control path loss decision=degraded reason=tcp-eof-media-active action=cancel-input-and-preserve-session");
            } else {
                os_log(wireless_log(),
                       "Control path loss decision=reconnect-triggered reason=tcp-eof-no-media action=cancel-input");
            }
            nw_connection_cancel(connection);
            return;
        }
        [self2 scheduleInputReceive:connection buffer:rx];
    });
}

- (void)cancelControlPathRecoveryWithReason:(const char *)reason {
    if (_controlPathRecoveryWorkItem) {
        dispatch_block_cancel(_controlPathRecoveryWorkItem);
        _controlPathRecoveryWorkItem = nil;
    }
    if (_controlPathRecoveryStartedAtTicks > 0) {
        uint64_t elapsedNs = keydrd_mach_delta_ns(mach_absolute_time(), _controlPathRecoveryStartedAtTicks);
        os_log(wireless_log(),
               "Control recovery cancelled reason=%{public}s elapsedMs=%{public}llums",
               reason,
               elapsedNs / 1000000ULL);
    }
    _controlPathRecoveryStartedAtTicks = 0;
}

- (void)beginControlPathRecoveryForReason:(const char *)reason
                                   detail:(nw_error_t _Nullable)detail
                                  wasAWDL:(BOOL)wasAWDL {
    if (_controlPathRecoveryStartedAtTicks == 0) {
        _controlPathRecoveryStartedAtTicks = mach_absolute_time();
    }
    if (_advertisingRequested && !_bonjourListener) {
        os_log(wireless_log(),
               "Control recovery: enabling Bonjour listener for control-path replacement discovery");
        [self startAdvertising];
    } else {
        os_log(wireless_log(),
               "Control recovery: listener state preserved (advertisingRequested=%{public}d listener=%{public}p)",
               _advertisingRequested,
               _bonjourListener);
    }

    if (_controlPathRecoveryWorkItem) {
        dispatch_block_cancel(_controlPathRecoveryWorkItem);
        _controlPathRecoveryWorkItem = nil;
    }

    __weak WirelessTransport *weakSelf = self;
    __block dispatch_block_t evaluator = dispatch_block_create(0, ^{
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        if (self2->_inputConnection && self2->_inputReadyAtTicks > 0) {
            os_log(wireless_log(),
                   "Control path loss decision=preserved reason=control-path-recovered action=continue-session");
            [self2 cancelControlPathRecoveryWithReason:"control-recovered"];
            return;
        }

        uint64_t elapsedNs = self2->_controlPathRecoveryStartedAtTicks > 0 ?
            keydrd_mach_delta_ns(mach_absolute_time(), self2->_controlPathRecoveryStartedAtTicks) : 0;
        BOOL hasMediaPath = (self2->_mediaConnection != nil);
        if (hasMediaPath && elapsedNs < kControlRecoveryHardDeadlineNs) {
            os_log(wireless_log(),
                   "Control path loss decision=degraded reason=awaiting-control-replacement detail=%{public}@ elapsedMs=%{public}llums deadlineMs=%{public}llums",
                   detail ?: (nw_error_t)@"none",
                   elapsedNs / 1000000ULL,
                   kControlRecoveryHardDeadlineNs / 1000000ULL);
            dispatch_block_t nextEvaluator = self2->_controlPathRecoveryWorkItem;
            if (nextEvaluator) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kControlRecoveryPollIntervalNs),
                               self2->_transportQueue,
                               nextEvaluator);
            }
            return;
        }

        os_log_error(wireless_log(),
                     "Control path loss decision=reconnect-triggered reason=control-recovery-timeout trigger=%{public}s detail=%{public}@ elapsedMs=%{public}llums mediaActive=%{public}d",
                     reason,
                     detail ?: (nw_error_t)@"none",
                     elapsedNs / 1000000ULL,
                     hasMediaPath);
        nw_connection_t staleMedia = self2->_mediaConnection;
        atomic_store(&self2->_mediaReady, false);
        self2->_mediaConnection = nil;
        if (staleMedia) {
            nw_connection_cancel(staleMedia);
        }
        self2->_inputAcceptedAtTicks = 0;
        self2->_inputReadyAtTicks = 0;
        self2->_lastInputActivityTicks = 0;
        self2->_isConnected = NO;
        self2->_isAWDL = NO;
        [self2 cancelControlPathRecoveryWithReason:"control-recovery-timeout"];
        if (self2.onConnectionChanged) {
            self2.onConnectionChanged(NO, wasAWDL);
        }
        if (self2->_advertisingRequested && !self2->_bonjourListener) {
            [self2 startAdvertising];
        }
    });
    _controlPathRecoveryWorkItem = evaluator;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kControlRecoveryPollIntervalNs),
                   _transportQueue,
                   evaluator);
}

#pragma mark - Private: Link liveness (tla/TransportConnections.tla SilenceDetect)

- (void)startLinkHeartbeatForConnection:(nw_connection_t)connection {
    [self stopLinkHeartbeatWithReason:"restart"];
    _linkHeartbeatsSent = 0;
    _linkHeartbeatsReceived = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _transportQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)kLinkHeartbeatIntervalNs),
                              kLinkHeartbeatIntervalNs, kLinkHeartbeatIntervalNs / 10);
    __weak WirelessTransport *weakSelf = self;
    /* Strong capture: the timer is cancelled on every stop, which releases the connection. */
    dispatch_source_set_event_handler(timer, ^{
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;
        [self2 linkHeartbeatTickForConnection:connection];
    });
    _linkHeartbeatTimer = timer;
    dispatch_resume(timer);
    os_log(wireless_log(), "Link heartbeat started intervalMs=%llu deadlineMs=%llu",
           kLinkHeartbeatIntervalNs / 1000000ULL, kLinkSilenceDeadlineNs / 1000000ULL);
}

- (void)stopLinkHeartbeatWithReason:(const char *)reason {
    if (!_linkHeartbeatTimer) return;
    dispatch_source_cancel(_linkHeartbeatTimer);
    _linkHeartbeatTimer = nil;
    os_log(wireless_log(), "Link heartbeat stopped reason=%{public}s sent=%lu received=%lu",
           reason, (unsigned long)_linkHeartbeatsSent, (unsigned long)_linkHeartbeatsReceived);
}

- (void)linkHeartbeatTickForConnection:(nw_connection_t _Nullable)connection {
    if (!connection || _inputConnection != connection || !_isConnected || _lastInputActivityTicks == 0) {
        [self stopLinkHeartbeatWithReason:"connection-not-current"];
        return;
    }
    uint64_t silentNs = keydrd_mach_delta_ns(mach_absolute_time(), _lastInputActivityTicks);
    if (silentNs >= kLinkSilenceDeadlineNs) {
        [self handleSilentLinkLossAfterNs:silentNs];
        return;
    }
    uint8_t beat[9] = { KEYDRD_LINK_HEARTBEAT };
    uint64_t ticks = mach_absolute_time();
    memcpy(beat + 1, &ticks, sizeof ticks);
    [self sendInputEvent:beat length:sizeof beat];
    _linkHeartbeatsSent++;
    if (silentNs >= 2 * kLinkHeartbeatIntervalNs) {
        os_log(wireless_log(), "Link quiet silentMs=%llu deadlineMs=%llu AWDL=%d",
               silentNs / 1000000ULL, kLinkSilenceDeadlineNs / 1000000ULL, _isAWDL);
    }
}

/* A connection that delivers no byte for the deadline is lost, whatever TCP thinks: drop input and
 * media, end the session (STREAMING -> RECONNECTING), and advertise for the iPad's redial. */
- (void)handleSilentLinkLossAfterNs:(uint64_t)silentNs {
    BOOL wasAWDL = _isAWDL;
    os_log_error(wireless_log(),
                 "Link silent decision=lost silentMs=%llu deadlineMs=%llu AWDL=%d heartbeatsSent=%lu heartbeatsReceived=%lu action=drop-and-advertise",
                 silentNs / 1000000ULL, kLinkSilenceDeadlineNs / 1000000ULL, wasAWDL,
                 (unsigned long)_linkHeartbeatsSent, (unsigned long)_linkHeartbeatsReceived);
    [self stopLinkHeartbeatWithReason:"silent"];
    [self cancelControlPathRecoveryWithReason:"link-silent"];
    nw_connection_t staleMedia = _mediaConnection;
    atomic_store(&_mediaReady, false);
    _mediaConnection = nil;
    if (staleMedia) nw_connection_cancel(staleMedia);
    nw_connection_t staleInput = _inputConnection;
    os_log(wireless_log(), "LC MacSilent cid=%u silentMs=%llu", _inputConnId, silentNs / 1000000ULL);
    [self clearCurrentInputConnectionWithReason:"silent"];
    if (staleInput) nw_connection_cancel(staleInput);
    _inputAcceptedAtTicks = 0;
    _inputReadyAtTicks = 0;
    _lastInputActivityTicks = 0;
    _isConnected = NO;
    _isAWDL = NO;
    if (self.onConnectionChanged) {
        self.onConnectionChanged(NO, wasAWDL);
    }
    if (_advertisingRequested && !_bonjourListener) {
        [self startAdvertising];
    }
}

#pragma mark - Private: Teardown

- (void)tearDownConnections {
    [self cancelControlPathRecoveryWithReason:"tearDownConnections"];
    [self stopLinkHeartbeatWithReason:"teardown"];
    [self resetSendPacing];
    if (_mediaListener) {
        nw_listener_cancel(_mediaListener);
        _mediaListener = nil;
    }
    if (_mediaConnection) {
        nw_connection_cancel(_mediaConnection);
        atomic_store(&_mediaReady, false);
        _mediaConnection = nil;
    }
    if (_inputConnection) {
        nw_connection_cancel(_inputConnection);
    }
    [self clearCurrentInputConnectionWithReason:"teardown"];
    for (nw_connection_t pending in _pendingInputConnections) {
        nw_connection_cancel(pending);
    }
    [_pendingInputConnections removeAllObjects];
    [_pendingInputConnIds removeAllObjects];
    _inputAcceptedAtTicks = 0;
    _inputReadyAtTicks = 0;
    _lastInputActivityTicks = 0;
    _isConnected = NO;
    _isAWDL = NO;
}

- (void)handleActiveMediaPathLossWithReason:(const char *)reason detail:(nw_error_t _Nullable)detail {
    [self cancelControlPathRecoveryWithReason:"media-path-loss"];
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
    os_log(wireless_log(), "LC MediaEnd branch=disconnect cid=%u reason=%{public}s", _inputConnId, reason);
    [self clearCurrentInputConnectionWithReason:"media-path-loss"];
    if (staleInput) {
        nw_connection_cancel(staleInput);
    }
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
