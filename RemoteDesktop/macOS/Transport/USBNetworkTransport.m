#import "USBNetworkTransport.h"
#import "protocol.h"
#import "crypto.h"
#import <os/log.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

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
@property (nonatomic) nw_path_monitor_t pathMonitor;
@property (nonatomic) dispatch_queue_t monitorQueue;
@property (nonatomic) dispatch_queue_t transportQueue;
@property (nonatomic, nullable) nw_listener_t mediaListener;
@property (nonatomic, nullable) nw_listener_t inputListener;
@property (nonatomic, nullable) nw_connection_t mediaConnection;
@property (nonatomic, nullable) nw_connection_t inputConnection;
@property (nonatomic, readwrite, nullable) nw_interface_t activeInterface;
@property (nonatomic, readwrite) BOOL isConnected;
@end

@implementation USBNetworkTransport

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

            /* Set server identity (Mac's self-signed cert) */
            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }

            /* Certificate pinning: verify block rejects unknown certs */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    USBNetworkTransport *self2 = weakSelf;
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

            /* Set server identity */
            if (identity) {
                sec_identity_t secIdentity = sec_identity_create(identity);
                if (secIdentity) {
                    sec_protocol_options_set_local_identity(sec, secIdentity);
                }
            }

            /* Certificate pinning verify block */
            sec_protocol_options_set_verify_block(sec,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
                  sec_protocol_verify_complete_t complete) {
                    USBNetworkTransport *self2 = weakSelf;
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

- (void)startMonitoring {
    if (_pathMonitor) return;

    if (!_tlsIdentity) {
        os_log_error(transport_log(), "Cannot start monitoring: tlsIdentity not set");
        return;
    }

    os_log(transport_log(), "Starting USB NCM path monitor (TLS/DTLS enabled)");

    _pathMonitor = nw_path_monitor_create_with_type(nw_interface_type_wired);
    nw_path_monitor_set_queue(_pathMonitor, _monitorQueue);

    __weak USBNetworkTransport *weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        nw_path_status_t status = nw_path_get_status(path);
        os_log(transport_log(), "USB NCM path update: status=%d", (int)status);

        if (status == nw_path_status_satisfied || status == nw_path_status_satisfiable) {
            /* Extract the exact NWInterface object -- NEVER hardcode name */
            __block nw_interface_t foundInterface = nil;
            nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
                if (nw_interface_get_type(interface) == nw_interface_type_wired) {
                    foundInterface = interface;
                    return false; /* stop enumeration */
                }
                return true;
            });

            if (foundInterface) {
                os_log(transport_log(), "USB NCM interface found: %{public}s (index %u)",
                       nw_interface_get_name(foundInterface),
                       nw_interface_get_index(foundInterface));

                if (!self2.activeInterface ||
                    nw_interface_get_index(foundInterface) != nw_interface_get_index(self2.activeInterface)) {
                    self2.activeInterface = foundInterface;
                    [self2 bindToInterface:foundInterface];

                    if (self2.onInterfaceChanged) {
                        self2.onInterfaceChanged(YES, foundInterface);
                    }
                }
            }
        } else {
            if (self2.activeInterface) {
                os_log(transport_log(), "USB NCM interface disappeared");
                [self2 tearDownListeners];
                self2.activeInterface = nil;
                self2.isConnected = NO;

                if (self2.onInterfaceChanged) {
                    self2.onInterfaceChanged(NO, nil);
                }
            }
        }
    });

    nw_path_monitor_start(_pathMonitor);
}

- (void)stopMonitoring {
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
    [self tearDownListeners];
    _activeInterface = nil;
    _isConnected = NO;
}

- (void)sendMediaFrame:(const void *)data length:(size_t)len {
    nw_connection_t conn = _mediaConnection;
    if (!conn) return;

    dispatch_data_t ddata = dispatch_data_create(data, len, _transportQueue,
                                                 DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(conn, ddata, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       true, ^(nw_error_t _Nullable error) {
        if (error) {
            os_log_error(transport_log(), "Media send error: %{public}@",
                         error);
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
            os_log_error(transport_log(), "Input send error: %{public}@",
                         error);
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
        self2.isConnected = YES;

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

        nw_connection_set_queue(connection, self2.transportQueue);

        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable connError) {
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                os_log(transport_log(), "TLS input connection ended");
                USBNetworkTransport *self3 = weakSelf;
                if (self3 && self3.inputConnection == connection) {
                    self3.inputConnection = nil;
                    if (!self3.mediaConnection) {
                        self3.isConnected = NO;
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
