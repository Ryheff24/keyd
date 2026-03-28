#import "USBNetworkTransport.h"
#import "protocol.h"
#import <os/log.h>

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
}

#pragma mark - Public API

- (void)startMonitoring {
    if (_pathMonitor) return;

    os_log(transport_log(), "Starting USB NCM path monitor");

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

    os_log(transport_log(), "Binding listeners to USB NCM interface: %{public}s",
           nw_interface_get_name(interface));

    /* UDP listener for media (port 14567) */
    nw_parameters_t udpParams = nw_parameters_create_secure_udp(
        NW_PARAMETERS_DISABLE_PROTOCOL, /* No DTLS yet -- added in crypto plan */
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_require_interface(udpParams, interface);
    nw_parameters_set_reuse_local_address(udpParams, true);
    nw_parameters_set_local_endpoint(udpParams,
        nw_endpoint_create_host("::", kMediaPortStr));

    _mediaListener = nw_listener_create(udpParams);
    [self configureMediaListener];

    /* TCP listener for input (port 14568) */
    nw_parameters_t tcpParams = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, /* No TLS yet -- added in crypto plan */
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_require_interface(tcpParams, interface);
    nw_parameters_set_reuse_local_address(tcpParams, true);
    nw_parameters_set_local_endpoint(tcpParams,
        nw_endpoint_create_host("::", kInputPortStr));

    _inputListener = nw_listener_create(tcpParams);
    [self configureInputListener];

    os_log(transport_log(), "Listeners created on ports %s (UDP/media) and %s (TCP/input)",
           kMediaPortStr, kInputPortStr);
}

- (void)configureMediaListener {
    nw_listener_set_queue(_mediaListener, _transportQueue);

    __weak USBNetworkTransport *weakSelf = self;

    nw_listener_set_state_changed_handler(_mediaListener, ^(nw_listener_state_t state, nw_error_t _Nullable error) {
        if (state == nw_listener_state_ready) {
            os_log(transport_log(), "Media listener ready on port %s", kMediaPortStr);
        } else if (state == nw_listener_state_failed) {
            os_log_error(transport_log(), "Media listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_listener_set_new_connection_handler(_mediaListener, ^(nw_connection_t connection) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        os_log(transport_log(), "Media connection accepted from iPad");

        /* Replace any existing media connection */
        if (self2.mediaConnection) {
            nw_connection_cancel(self2.mediaConnection);
        }
        self2.mediaConnection = connection;
        self2.isConnected = YES;

        nw_connection_set_queue(connection, self2.transportQueue);

        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable connError) {
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                os_log(transport_log(), "Media connection ended");
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
            os_log(transport_log(), "Input listener ready on port %s", kInputPortStr);
        } else if (state == nw_listener_state_failed) {
            os_log_error(transport_log(), "Input listener failed: %{public}@",
                         error ?: (nw_error_t)@"unknown");
        }
    });

    nw_listener_set_new_connection_handler(_inputListener, ^(nw_connection_t connection) {
        USBNetworkTransport *self2 = weakSelf;
        if (!self2) return;

        os_log(transport_log(), "Input connection accepted from iPad");

        if (self2.inputConnection) {
            nw_connection_cancel(self2.inputConnection);
        }
        self2.inputConnection = connection;
        self2.isConnected = YES;

        nw_connection_set_queue(connection, self2.transportQueue);

        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable connError) {
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                os_log(transport_log(), "Input connection ended");
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
