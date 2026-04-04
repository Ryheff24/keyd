#import "USBNetworkTransport.h"
#import "UDPChunker.h"
#import "protocol.h"
#import "crypto.h"
#import <os/log.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

static os_log_t transport_log(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.ryheff.keyd.remote.agent", "USBTransport");
    });
    return log;
}

/* Port number as C string for NWListener */
static const char *kMediaPortStr = "14567";
static const char *kInputPortStr = "14568";

@interface USBNetworkTransport ()
@property (nonatomic) dispatch_queue_t monitorQueue;
@property (nonatomic) dispatch_queue_t transportQueue;
@property (nonatomic, nullable) nw_listener_t mediaListener;
@property (nonatomic, nullable) nw_listener_t inputListener;
@property (nonatomic, nullable) nw_connection_t mediaConnection;
@property (nonatomic, nullable) nw_connection_t inputConnection;
@property (nonatomic, readwrite, nullable) nw_interface_t activeInterface;
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, nullable) dispatch_source_t pollTimer;
@property (nonatomic, copy, nullable) NSString *detectedLocalIP;
@end

@implementation USBNetworkTransport

- (NSString *)localIPAddress {
    return _detectedLocalIP;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _monitorQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.usb.monitor",
                                              DISPATCH_QUEUE_SERIAL);
        _transportQueue = dispatch_queue_create("com.ryheff.keyd.remote.agent.usb.transport",
                                                DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
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
 * Returns YES if the peer cert matches the stored cert, NO otherwise.
 * If no paired cert is stored (not yet paired), rejects the connection.
 */
- (BOOL)verifyPeerCertificate:(sec_trust_t)trust {
    SecTrustRef secTrust = sec_trust_copy_ref(trust);
    if (!secTrust) {
        os_log_error(transport_log(), "Certificate verify: no trust ref");
        return NO;
    }

    /* Get the peer's leaf certificate via SecTrustCopyCertificateChain (macOS 12+) */
    CFArrayRef certChain = SecTrustCopyCertificateChain(secTrust);
    CFRelease(secTrust);
    if (!certChain || CFArrayGetCount(certChain) == 0) {
        os_log_error(transport_log(), "Certificate verify: no peer certificate chain");
        if (certChain) CFRelease(certChain);
        return NO;
    }
    SecCertificateRef peerCert = (SecCertificateRef)CFArrayGetValueAtIndex(certChain, 0);

    /* Compute SHA-256 fingerprint of peer cert */
    CFDataRef peerCertData = SecCertificateCopyData(peerCert);
    CFRelease(certChain);
    if (!peerCertData) {
        os_log_error(transport_log(), "Certificate verify: cannot get cert data");
        return NO;
    }

    uint8_t peerHash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(peerCertData), (CC_LONG)CFDataGetLength(peerCertData), peerHash);
    CFRelease(peerCertData);

    /* Load stored peer certificate fingerprint from Keychain */
    NSData *storedFingerprint = [self loadStoredPeerFingerprint];
    if (!storedFingerprint || storedFingerprint.length != CC_SHA256_DIGEST_LENGTH) {
        os_log_error(transport_log(), "Certificate verify: no stored peer fingerprint (not paired)");
        return NO;
    }

    BOOL match = (memcmp(peerHash, storedFingerprint.bytes, CC_SHA256_DIGEST_LENGTH) == 0);
    if (!match) {
        os_log_error(transport_log(), "Certificate verify: peer cert fingerprint MISMATCH -- rejecting");
    } else {
        os_log(transport_log(), "Certificate verify: peer cert fingerprint matches stored -- trusted");
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

/**
 * Configure TLS 1.3 parameters for TCP connections.
 * Uses the Mac's self-signed TLS identity as server identity.
 * Certificate pinning verify block rejects unknown peer certs.
 * No cleartext fallback.
 */
- (nw_parameters_t)createSecureTCPParameters {
    __weak USBNetworkTransport *weakSelf = self;
    SecIdentityRef identity = _tlsIdentity;
    nw_parameters_t tcpParams = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t tls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_protocol_options_set_peer_authentication_required(sec, true);

            /* Set server identity (Mac's self-signed cert) */
            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }
            /* Certificate verify: accept self-signed, pin if fingerprint stored */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    USBNetworkTransport *self2 = weakSelf;
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
            /* Disable Nagle's algorithm — send data immediately without
             * waiting to coalesce small writes. Critical for low-latency
             * input events and framed media delivery. */
            nw_tcp_options_set_no_delay(tcp_options, true);
        });

    return tcpParams;
}

/**
 * Configure DTLS parameters for UDP connections.
 * Same certificate pinning as TLS. No cleartext fallback.
 */
- (nw_parameters_t)createSecureUDPParameters {
    __weak USBNetworkTransport *weakSelf = self;
    SecIdentityRef identity = _tlsIdentity;
    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        ^(nw_protocol_options_t dtls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);
            sec_protocol_options_set_peer_authentication_required(sec, true);

            /* Set server identity */
            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }
            /* Certificate verify: accept self-signed, pin if fingerprint stored */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    USBNetworkTransport *self2 = weakSelf;
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

/**
 * Scan system interfaces for a USB NCM link-local address.
 *
 * NWPathMonitor cannot detect USB NCM interfaces because they only have
 * 169.254.x.x link-local IPs with no routes, making them "unsatisfied."
 * We use getifaddrs() to directly enumerate kernel interfaces.
 *
 * Returns the IPv4 link-local address (e.g., "169.254.129.221") and the
 * interface name, or nil if no USB NCM interface is found.
 */
- (NSDictionary *)detectUSBNCMInterface {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return nil;

    NSDictionary *result = nil;
    for (struct ifaddrs *ifa = ifap; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_RUNNING)) continue;
        if (ifa->ifa_flags & IFF_LOOPBACK) continue;

        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        uint32_t ip = ntohl(sin->sin_addr.s_addr);

        /* Link-local range: 169.254.0.0/16 */
        if ((ip & 0xFFFF0000) != 0xA9FE0000) continue;

        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        /* Skip known non-USB interfaces */
        if ([name isEqualToString:@"en0"]) continue;       /* Wi-Fi */
        if ([name hasPrefix:@"awdl"]) continue;
        if ([name hasPrefix:@"llw"]) continue;
        if ([name hasPrefix:@"utun"]) continue;
        if ([name hasPrefix:@"lo"]) continue;
        if ([name hasPrefix:@"bridge"]) continue;           /* Thunderbolt Bridge */
        if ([name hasPrefix:@"ap"]) continue;               /* Access point */

        char addrBuf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sin->sin_addr, addrBuf, sizeof(addrBuf));
        NSString *addrStr = [NSString stringWithUTF8String:addrBuf];

        os_log(transport_log(), "USB NCM candidate: %{public}s = %{public}s (flags=0x%x)",
               ifa->ifa_name, addrBuf, ifa->ifa_flags);

        result = @{@"ip": addrStr, @"name": name};
        break;  /* Take the first match */
    }

    freeifaddrs(ifap);
    return result;
}

- (void)startMonitoring {
    if (_pollTimer) return;

    if (!_tlsIdentity) {
        os_log_error(transport_log(), "Cannot start monitoring: tlsIdentity not set");
        return;
    }

    os_log(transport_log(), "Starting USB NCM interface polling via getifaddrs (TLS/DTLS enabled)");

    /* Poll every 500ms for USB NCM interface appearance/disappearance.
     * NWPathMonitor cannot detect these interfaces (link-local only, no routes).
     * Fast polling for quick transport handoff (WiFi→USB in <2s). */
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _monitorQueue);
    dispatch_source_set_timer(_pollTimer,
                              DISPATCH_TIME_NOW,
                              500 * NSEC_PER_MSEC,
                              100 * NSEC_PER_MSEC);

    __weak USBNetworkTransport *weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        NSDictionary *ncm = [self2 detectUSBNCMInterface];

        if (ncm) {
            NSString *ip = ncm[@"ip"];
            NSString *name = ncm[@"name"];

            if (![ip isEqualToString:self2.detectedLocalIP]) {
                /* New or changed USB NCM interface */
                os_log(transport_log(), "USB NCM interface detected: %{public}@ = %{public}@", name, ip);
                self2.detectedLocalIP = ip;
                [self2 bindToLocalIP:ip];

                if (self2.onInterfaceChanged) {
                    self2.onInterfaceChanged(YES, nil);
                }
            }
        } else {
            if (self2.detectedLocalIP) {
                /* USB NCM interface disappeared */
                os_log(transport_log(), "USB NCM interface disappeared");
                [self2 tearDownListeners];
                self2.activeInterface = nil;
                self2.detectedLocalIP = nil;
                self2.isConnected = NO;

                if (self2.onInterfaceChanged) {
                    self2.onInterfaceChanged(NO, nil);
                }
            }
        }
    });

    dispatch_resume(_pollTimer);
}

- (void)stopMonitoring {
    if (_pollTimer) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
    [self tearDownListeners];
    _activeInterface = nil;
    _detectedLocalIP = nil;
    _isConnected = NO;
}

- (void)sendMediaFrame:(const void *)data length:(size_t)len {
    nw_connection_t conn = _mediaConnection;
    if (!conn) return;

    /* Copy data — the caller (chunk_frame) frees the original buffer after this returns.
     * DISPATCH_DATA_DESTRUCTOR_FREE tells dispatch_data to free() our copy when done. */
    void *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, data, len);

    dispatch_data_t ddata = dispatch_data_create(copy, len, _transportQueue,
                                                 DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(transport_log(), "Media send error: %{public}@",
                         error);
        }
    });
}

- (void)sendMediaFramePaced:(const void *)data length:(size_t)len mtu:(size_t)mtu {
    nw_connection_t conn = _mediaConnection;
    if (!conn || len < sizeof(MediaFrameHeader)) return;

    const MediaFrameHeader *originalHeader = (const MediaFrameHeader *)data;
    const void *payload = (const uint8_t *)data + sizeof(MediaFrameHeader);
    size_t payloadLen = len - sizeof(MediaFrameHeader);

    /* Collect all chunks into an array first, since chunk_frame's callback
     * buffer is only valid during the callback. */
    NSMutableArray<NSData *> *chunks = [NSMutableArray array];
    chunk_frame(payload, payloadLen, originalHeader->seq, mtu,
                originalHeader, ^(const void *chunk, size_t chunkLen) {
        [chunks addObject:[NSData dataWithBytes:chunk length:chunkLen]];
    });

    if (chunks.count == 0) return;

    /* Send chunks sequentially — each waits for the previous completion.
     * This paces sends at the rate the USB NCM driver can accept them. */
    [self _sendChunkAtIndex:0 fromChunks:chunks connection:conn];
}

- (void)_sendChunkAtIndex:(NSUInteger)idx
               fromChunks:(NSArray<NSData *> *)chunks
               connection:(nw_connection_t)conn {
    if (idx >= chunks.count) return;

    NSData *chunk = chunks[idx];
    dispatch_data_t ddata = dispatch_data_create(chunk.bytes, chunk.length,
                                                 _transportQueue,
                                                 DISPATCH_DATA_DESTRUCTOR_DEFAULT);

    __weak USBNetworkTransport *weakSelf = self;
    nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(transport_log(), "Paced media chunk %lu/%lu send error: %{public}@",
                         (unsigned long)idx, (unsigned long)chunks.count, error);
            return;  /* Stop sending remaining chunks on error */
        }
        /* Send next chunk after this one completes */
        USBNetworkTransport *self2 = weakSelf;
        if (self2) {
            [self2 _sendChunkAtIndex:idx + 1 fromChunks:chunks connection:conn];
        }
    });
}

- (void)sendInputEvent:(const void *)data length:(size_t)len {
    nw_connection_t conn = _inputConnection;
    if (!conn) return;

    /* Prepend 4-byte big-endian length prefix for TCP message framing */
    uint32_t netLen = htonl((uint32_t)len);
    dispatch_data_t lenData = dispatch_data_create(&netLen, 4, _transportQueue,
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t payloadData = dispatch_data_create(data, len, _transportQueue,
                                                       DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t framed = dispatch_data_create_concat(lenData, payloadData);

    nw_connection_send(conn, framed, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(transport_log(), "Input send error: %{public}@",
                         error);
        }
    });
}

- (void)_sendTCPFramedChunkAtIndex:(NSUInteger)idx
                        fromChunks:(NSArray<NSData *> *)chunks
                        connection:(nw_connection_t)conn
                        completion:(void (^)(BOOL success))completion {
    if (idx >= chunks.count) {
        if (completion) completion(YES);
        return;
    }

    NSData *chunk = chunks[idx];
    uint32_t netLen = htonl((uint32_t)chunk.length);
    dispatch_data_t lenData = dispatch_data_create(&netLen, 4, _transportQueue,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t payloadData = dispatch_data_create(chunk.bytes, chunk.length,
                                                       _transportQueue,
                                                       DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t framed = dispatch_data_create_concat(lenData, payloadData);

    __weak USBNetworkTransport *weakSelf = self;
    nw_connection_send(conn, framed, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(transport_log(), "Media TCP chunk %lu/%lu send error: %{public}@",
                         (unsigned long)idx, (unsigned long)chunks.count, error);
            if (completion) completion(NO);
            return;
        }

        USBNetworkTransport *self2 = weakSelf;
        if (!self2) {
            if (completion) completion(NO);
            return;
        }
        [self2 _sendTCPFramedChunkAtIndex:idx + 1
                               fromChunks:chunks
                               connection:conn
                               completion:completion];
    });
}

- (void)sendMediaViaTCP:(const void *)data length:(size_t)len completion:(void (^)(BOOL success))completion {
    nw_connection_t conn = _inputConnection;
    if (!conn) {
        os_log_error(transport_log(), "USB media send skipped: no TCP input connection");
        if (completion) completion(NO);
        return;
    }

    const MediaFrameHeader *originalHeader = NULL;
    uint16_t frameSeq = 0;
    BOOL hasFrameSeq = NO;
    BOOL isHEVC = NO;
    if (len >= sizeof(MediaFrameHeader)) {
        originalHeader = (const MediaFrameHeader *)data;
        frameSeq = originalHeader->seq;
        hasFrameSeq = YES;
        isHEVC = (originalHeader->flags & KEYDRD_FLAG_HEVC) != 0;
        os_log(transport_log(), "USB media send entry: seq=%u bytes=%zu hevc=%{public}s",
               frameSeq, len, isHEVC ? "yes" : "no");
    }

    if (isHEVC && len >= sizeof(MediaFrameHeader)) {
        /* USB media still uses reliable TCP, but frame-level writes make the iPad
         * wait for multi-megabyte blobs before it can parse anything. Reframe them
         * into chunked MediaFrameHeader packets so the existing reassembler can
         * consume them incrementally over TCP. */
        const void *payload = (const uint8_t *)data + sizeof(MediaFrameHeader);
        size_t payloadLen = len - sizeof(MediaFrameHeader);
        const size_t tcpChunkMTU = 64 * 1024;

        NSMutableArray<NSData *> *chunks = [NSMutableArray array];
        chunk_frame(payload, payloadLen, originalHeader->seq, tcpChunkMTU,
                    originalHeader, ^(const void *chunk, size_t chunkLen) {
            [chunks addObject:[NSData dataWithBytes:chunk length:chunkLen]];
        });

        if (chunks.count > 0) {
            os_log(transport_log(), "USB media chunking enabled: seq=%u mtu=%zu chunks=%lu",
                   frameSeq, tcpChunkMTU, (unsigned long)chunks.count);
            [self _sendTCPFramedChunkAtIndex:0
                                   fromChunks:chunks
                                   connection:conn
                                   completion:completion];
            return;
        }
    }
    if (hasFrameSeq && !isHEVC) {
        os_log(transport_log(), "USB media sending unchunked LZ4 frame: seq=%u bytes=%zu",
               frameSeq, len);
    }

    /* Copy data — caller may free immediately after return */
    void *copy = malloc(len);
    if (!copy) {
        if (completion) completion(NO);
        return;
    }
    memcpy(copy, data, len);

    /* Prepend 4-byte big-endian length prefix for TCP message framing */
    uint32_t netLen = htonl((uint32_t)len);
    dispatch_data_t lenData = dispatch_data_create(&netLen, 4, _transportQueue,
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t payloadData = dispatch_data_create(copy, len, _transportQueue,
                                                       DISPATCH_DATA_DESTRUCTOR_FREE);
    dispatch_data_t framed = dispatch_data_create_concat(lenData, payloadData);

    nw_connection_send(conn, framed, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (completion) {
            completion(error == nil);
        }
        if (!error && hasFrameSeq) {
            os_log(transport_log(), "USB media send success: seq=%u bytes=%zu", frameSeq, len);
        }
        if (error) {
            os_log_error(transport_log(), "Media TCP send error: %{public}@", error);
        }
    });
}

#pragma mark - Private: Listener Setup

- (void)bindToInterface:(nw_interface_t)interface {
    /* Tear down any existing listeners first */
    [self tearDownListeners];

    os_log(transport_log(), "Binding TLS/DTLS listeners to USB NCM interface: %{public}s",
           nw_interface_get_name(interface));

    /* UDP listener for media (port 14567) -- DTLS encrypted */
    nw_parameters_t udpParams = [self createSecureUDPParameters];
    nw_parameters_require_interface(udpParams, interface);
    nw_parameters_set_reuse_local_address(udpParams, true);
    nw_parameters_set_local_endpoint(udpParams,
        nw_endpoint_create_host("::", kMediaPortStr));

    _mediaListener = nw_listener_create(udpParams);
    [self configureMediaListener];

    /* TCP listener for input (port 14568) -- TLS 1.3 encrypted */
    nw_parameters_t tcpParams = [self createSecureTCPParameters];
    nw_parameters_require_interface(tcpParams, interface);
    nw_parameters_set_reuse_local_address(tcpParams, true);
    nw_parameters_set_local_endpoint(tcpParams,
        nw_endpoint_create_host("::", kInputPortStr));

    _inputListener = nw_listener_create(tcpParams);
    [self configureInputListener];

    os_log(transport_log(), "Secure listeners created on ports %s (DTLS/media) and %s (TLS/input)",
           kMediaPortStr, kInputPortStr);
}

/**
 * Bind listeners to a specific local IP (for USB NCM detected via getifaddrs).
 *
 * NWPathMonitor can't provide an nw_interface_t for USB NCM interfaces since
 * it doesn't detect them. Instead we bind to the specific link-local IP
 * which effectively constrains traffic to the USB NCM interface.
 */
- (void)bindToLocalIP:(NSString *)localIP {
    [self tearDownListeners];

    const char *ip = [localIP UTF8String];
    os_log(transport_log(), "Binding TLS/DTLS listeners to USB NCM local IP: %{public}s", ip);

    /* UDP listener for media (port 14567) -- DTLS encrypted */
    nw_parameters_t udpParams = [self createSecureUDPParameters];
    nw_parameters_set_reuse_local_address(udpParams, true);
    nw_parameters_set_local_endpoint(udpParams,
        nw_endpoint_create_host(ip, kMediaPortStr));

    _mediaListener = nw_listener_create(udpParams);
    [self configureMediaListener];

    /* TCP listener for input (port 14568) -- TLS 1.3 encrypted */
    nw_parameters_t tcpParams = [self createSecureTCPParameters];
    nw_parameters_set_reuse_local_address(tcpParams, true);
    nw_parameters_set_local_endpoint(tcpParams,
        nw_endpoint_create_host(ip, kInputPortStr));

    _inputListener = nw_listener_create(tcpParams);
    [self configureInputListener];

    os_log(transport_log(), "USB NCM listeners created on %{public}s ports %s (DTLS) and %s (TLS)",
           ip, kMediaPortStr, kInputPortStr);
}

- (void)configureMediaListener {
    nw_listener_set_queue(_mediaListener, _transportQueue);

    __weak USBNetworkTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(_mediaListener, ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            os_log(transport_log(), "DTLS media listener ready on port %s", kMediaPortStr);
        } else if (state == nw_listener_state_failed) {
            os_log_error(transport_log(), "DTLS media listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_listener_set_new_connection_handler(_mediaListener, ^(nw_connection_t connection) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        os_log(transport_log(), "DTLS media connection accepted from iPad");

        /* Replace any existing media connection */
        if (self2.mediaConnection) {
            nw_connection_cancel(self2.mediaConnection);
        }
        self2.mediaConnection = connection;
        /* Don't set isConnected here — wait for TCP input connection.
         * The handshake is sent via TCP, so isConnected must mean TCP is ready. */

        nw_connection_set_queue(connection, self2.transportQueue);

        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable connError) {
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                os_log(transport_log(), "DTLS media connection ended");
                USBNetworkTransport *self3 = weakSelf;
                if (self3 && self3.mediaConnection == connection) {
                    self3.mediaConnection = nil;
                    if (!self3.inputConnection) {
                        self3.isConnected = NO;
                    }
                }
            }
        });

        nw_connection_start(connection);
        [self2 scheduleMediaReceive:connection];
    });

    nw_listener_start(_mediaListener);
}

- (void)configureInputListener {
    nw_listener_set_queue(_inputListener, _transportQueue);

    __weak USBNetworkTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(_inputListener, ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            os_log(transport_log(), "TLS input listener ready on port %s", kInputPortStr);
        } else if (state == nw_listener_state_failed) {
            os_log_error(transport_log(), "TLS input listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_listener_set_new_connection_handler(_inputListener, ^(nw_connection_t connection) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        os_log(transport_log(), "TLS input connection accepted from iPad");

        if (self2.inputConnection) {
            nw_connection_cancel(self2.inputConnection);
        }
        self2.inputConnection = connection;
        self2.isConnected = YES;

        /* Notify SessionManager that TCP is ready — handshake can now be sent */
        if (self2.onInputConnectionReady) {
            self2.onInputConnectionReady();
        }

        nw_connection_set_queue(connection, self2.transportQueue);

        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable connError) {
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                os_log(transport_log(), "TLS input connection ended");
                USBNetworkTransport *self3 = weakSelf;
                if (self3 && self3.inputConnection == connection) {
                    self3.inputConnection = nil;
                    self3.isConnected = NO;
                    if (self3.mediaConnection) {
                        nw_connection_cancel(self3.mediaConnection);
                        self3.mediaConnection = nil;
                    }
                    if (self3.onInputConnectionLost) {
                        self3.onInputConnectionLost();
                    }
                }
            }
        });

        nw_connection_start(connection);
        [self2 scheduleInputReceive:connection];
    });

    nw_listener_start(_inputListener);
}

#pragma mark - Private: Receive Loops

- (void)scheduleMediaReceive:(nw_connection_t)connection {
    __weak USBNetworkTransport *weakSelf = self;
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t _Nullable content,
                                                   nw_content_context_t _Nullable context,
                                                   bool is_complete,
                                                   nw_error_t _Nullable error) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

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

        if (error || is_complete) return;

        /* Schedule next receive */
        [self2 scheduleMediaReceive:connection];
    });
}

- (void)scheduleInputReceive:(nw_connection_t)connection {
    __weak USBNetworkTransport *weakSelf = self;
    nw_connection_receive(connection, 1, 4096, ^(dispatch_data_t _Nullable content,
                                                  nw_content_context_t _Nullable context,
                                                  bool is_complete,
                                                  nw_error_t _Nullable error) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        if (content && dispatch_data_get_size(content) > 0) {
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

        if (error || is_complete) return;

        [self2 scheduleInputReceive:connection];
    });
}

#pragma mark - Private: Teardown

- (void)tearDownListeners {
    if (_mediaListener) {
        nw_listener_cancel(_mediaListener);
        _mediaListener = nil;
    }
    if (_inputListener) {
        nw_listener_cancel(_inputListener);
        _inputListener = nil;
    }
    if (_mediaConnection) {
        nw_connection_cancel(_mediaConnection);
        _mediaConnection = nil;
    }
    if (_inputConnection) {
        nw_connection_cancel(_inputConnection);
        _inputConnection = nil;
    }
}

@end
