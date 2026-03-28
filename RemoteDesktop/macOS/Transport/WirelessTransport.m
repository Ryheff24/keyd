#import "WirelessTransport.h"
#import "protocol.h"
#import "crypto.h"
#import <os/log.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

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

@interface WirelessTransport ()
@property (nonatomic) dispatch_queue_t transportQueue;
@property (nonatomic, nullable) nw_listener_t bonjourListener;
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

            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }

            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    WirelessTransport *self2 = weakSelf;
                    if (!self2) {
                        complete(false);
                        return;
                    }
                    BOOL trusted = [self2 verifyPeerCertificate:trust];
                    complete(trusted);
                },
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    return tcpParams;
}

- (nw_parameters_t)createSecureUDPParameters {
    __weak WirelessTransport *weakSelf = self;
    SecIdentityRef identity = _tlsIdentity;

    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        ^(nw_protocol_options_t dtls_options) {
            sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(dtls_options);
            sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv13);

            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }

            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    WirelessTransport *self2 = weakSelf;
                    if (!self2) {
                        complete(false);
                        return;
                    }
                    BOOL trusted = [self2 verifyPeerCertificate:trust];
                    complete(trusted);
                },
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        },
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

    return udpParams;
}

#pragma mark - Public API

- (void)startAdvertising {
    if (_bonjourListener) return;

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

    /* Advertise via Bonjour */
    nw_advertise_descriptor_t advertise = nw_advertise_descriptor_create_bonjour_service(
        NULL, /* auto-generate name */
        KEYDRD_SERVICE,
        "local.");
    nw_advertise_descriptor_set_no_auto_rename(advertise, false);
    nw_listener_set_advertise_descriptor(_bonjourListener, advertise);

    nw_listener_set_queue(_bonjourListener, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(_bonjourListener, ^(nw_listener_state_t state,
                                                               nw_error_t _Nullable error) {
        switch (state) {
        case nw_listener_state_ready:
            os_log(wireless_log(), "TLS Bonjour listener ready (advertising %{public}s)", KEYDRD_SERVICE);
            break;
        case nw_listener_state_failed:
            os_log_error(wireless_log(), "TLS Bonjour listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
            break;
        case nw_listener_state_cancelled:
            os_log(wireless_log(), "TLS Bonjour listener cancelled");
            break;
        default:
            break;
        }
    });

    nw_listener_set_new_connection_handler(_bonjourListener, ^(nw_connection_t connection) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;

        [self2 handleNewConnection:connection];
    });

    nw_listener_start(_bonjourListener);
}

- (void)stopAdvertising {
    if (_bonjourListener) {
        nw_listener_cancel(_bonjourListener);
        _bonjourListener = nil;
    }
    [self tearDownConnections];
}

- (void)sendMediaFrame:(const void *)data length:(size_t)len {
    nw_connection_t conn = _mediaConnection;
    if (!conn) return;

    dispatch_data_t ddata = dispatch_data_create(data, len, _transportQueue,
                                                 DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(wireless_log(), "Wireless media send error: %{public}@", error);
        }
    });
}

- (void)sendInputEvent:(const void *)data length:(size_t)len {
    nw_connection_t conn = _inputConnection;
    if (!conn) return;

    dispatch_data_t ddata = dispatch_data_create(data, len, _transportQueue,
                                                 DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(wireless_log(), "Wireless input send error: %{public}@", error);
        }
    });
}

#pragma mark - Private: Connection Handling

- (void)handleNewConnection:(nw_connection_t)connection {
    os_log(wireless_log(), "TLS wireless connection accepted from iPad");

    /* Replace existing input connection */
    if (_inputConnection) {
        nw_connection_cancel(_inputConnection);
    }
    _inputConnection = connection;

    nw_connection_set_queue(connection, _transportQueue);

    __weak WirelessTransport *weakSelf = self;

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state,
                                                          nw_error_t _Nullable error) {
        WirelessTransport *self2 = weakSelf;
        if (!self2) return;

        switch (state) {
        case nw_connection_state_ready: {
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
            os_log(wireless_log(), "TLS wireless connection ready (AWDL=%d)", detectedAWDL);

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
            os_log(wireless_log(), "TLS wireless connection ended");
            if (self2.inputConnection == connection) {
                self2.inputConnection = nil;
                self2.isConnected = NO;
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
     * After the TLS TCP control connection is established, create a DTLS-encrypted
     * UDP connection to the iPad's address for media frames.
     */
    nw_path_t path = nw_connection_copy_current_path(tcpConnection);
    if (!path) return;

    nw_endpoint_t remoteEndpoint = nw_path_copy_effective_remote_endpoint(path);
    if (!remoteEndpoint) return;

    const char *host = nw_endpoint_get_hostname(remoteEndpoint);
    if (!host) return;

    nw_endpoint_t mediaEndpoint = nw_endpoint_create_host(host, kMediaPortStr);

    nw_parameters_t udpParams = [self createSecureUDPParameters];
    nw_parameters_set_include_peer_to_peer(udpParams, true);

    /* Bind to the same interface as the TCP connection */
    __block nw_interface_t pathInterface = nil;
    nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
        pathInterface = interface;
        return false;
    });
    if (pathInterface) {
        nw_parameters_require_interface(udpParams, pathInterface);
    }

    nw_connection_t mediaConn = nw_connection_create(mediaEndpoint, udpParams);
    if (_mediaConnection) {
        nw_connection_cancel(_mediaConnection);
    }
    _mediaConnection = mediaConn;

    nw_connection_set_queue(mediaConn, _transportQueue);

    __weak WirelessTransport *weakSelf = self;
    nw_connection_set_state_changed_handler(mediaConn, ^(nw_connection_state_t state,
                                                          nw_error_t _Nullable error) {
        if (state == nw_connection_state_ready) {
            os_log(wireless_log(), "DTLS wireless media UDP connection ready");
            WirelessTransport *self2 = weakSelf;
            if (self2) {
                [self2 scheduleMediaReceive:mediaConn];
            }
        } else if (state == nw_connection_state_failed) {
            os_log_error(wireless_log(), "DTLS wireless media UDP connection failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_connection_start(mediaConn);
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
        [self2 scheduleMediaReceive:connection];
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

- (void)tearDownConnections {
    if (_mediaConnection) {
        nw_connection_cancel(_mediaConnection);
        _mediaConnection = nil;
    }
    if (_inputConnection) {
        nw_connection_cancel(_inputConnection);
        _inputConnection = nil;
    }
    _isConnected = NO;
    _isAWDL = NO;
}

@end
