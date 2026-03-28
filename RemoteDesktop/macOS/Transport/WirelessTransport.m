#import "WirelessTransport.h"
#import "protocol.h"
#import <os/log.h>

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
}

#pragma mark - Public API

- (void)startAdvertising {
    if (_bonjourListener) return;

    os_log(wireless_log(), "Starting Bonjour advertisement for %{public}s", KEYDRD_SERVICE);

    /*
     * Create TCP listener with Bonjour advertisement.
     * We use TCP for the Bonjour listener since it handles the service
     * discovery. Once connected, we establish a separate UDP path for media.
     */
    nw_parameters_t tcpParams = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, /* No TLS yet -- added in crypto plan */
        NW_PARAMETERS_DEFAULT_CONFIGURATION);

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
            os_log(wireless_log(), "Bonjour listener ready (advertising %{public}s)", KEYDRD_SERVICE);
            break;
        case nw_listener_state_failed:
            os_log_error(wireless_log(), "Bonjour listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
            break;
        case nw_listener_state_cancelled:
            os_log(wireless_log(), "Bonjour listener cancelled");
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
    os_log(wireless_log(), "Wireless connection accepted from iPad");

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
            os_log(wireless_log(), "Wireless connection ready (AWDL=%d)", detectedAWDL);

            if (self2.onConnectionChanged) {
                self2.onConnectionChanged(YES, detectedAWDL);
            }

            /* Start receive loop */
            [self2 scheduleInputReceive:connection];

            /* Establish UDP media connection to the iPad's address */
            [self2 establishMediaConnection:connection];
            break;
        }
        case nw_connection_state_failed:
        case nw_connection_state_cancelled:
            os_log(wireless_log(), "Wireless connection ended");
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
     * After the TCP control connection is established, create a UDP
     * connection to the iPad's address for media frames. We extract
     * the remote endpoint from the TCP connection path.
     */
    nw_path_t path = nw_connection_copy_current_path(tcpConnection);
    if (!path) return;

    nw_endpoint_t remoteEndpoint = nw_path_copy_effective_remote_endpoint(path);
    if (!remoteEndpoint) return;

    /* Get the remote host and create a UDP endpoint on the media port */
    const char *host = nw_endpoint_get_hostname(remoteEndpoint);
    if (!host) return;

    nw_endpoint_t mediaEndpoint = nw_endpoint_create_host(host, kMediaPortStr);

    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
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
            os_log(wireless_log(), "Wireless media UDP connection ready");
            WirelessTransport *self2 = weakSelf;
            if (self2) {
                [self2 scheduleMediaReceive:mediaConn];
            }
        } else if (state == nw_connection_state_failed) {
            os_log_error(wireless_log(), "Wireless media UDP connection failed: %{public}@",
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
