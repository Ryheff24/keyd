#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * USB NCM transport for the macOS agent.
 *
 * Detects USB NCM (wiredEthernet) interfaces via NWPathMonitor, then creates
 * separate NWListener instances for UDP (media, port 14567) and TCP (input,
 * port 14568) bound to the exact NWInterface object (never hardcoded name).
 *
 * Mac is the LISTENER side -- iPad connects to these listeners.
 */
@interface USBNetworkTransport : NSObject

/** Whether a USB NCM interface is currently detected and listeners are active. */
@property (nonatomic, readonly) BOOL isConnected;

/** The active USB NCM interface (nil if none detected). */
@property (nonatomic, readonly, nullable) nw_interface_t activeInterface;

/** Callback fired when raw media frame data arrives over UDP. */
@property (nonatomic, copy, nullable) void (^onMediaReceived)(const void *data, size_t length);

/** Callback fired when raw input event data arrives over TCP. */
@property (nonatomic, copy, nullable) void (^onInputReceived)(const void *data, size_t length);

/** Callback fired when the USB NCM interface appears or disappears. */
@property (nonatomic, copy, nullable) void (^onInterfaceChanged)(BOOL appeared, nw_interface_t _Nullable interface);

/**
 * Start monitoring for USB NCM interfaces.
 * When an interface is detected, listeners are created automatically.
 */
- (void)startMonitoring;

/**
 * Stop monitoring and tear down all listeners/connections.
 */
- (void)stopMonitoring;

/**
 * Send a media frame over UDP to the connected iPad.
 * No-op if no connection is established.
 */
- (void)sendMediaFrame:(const void *)data length:(size_t)len;

/**
 * Send an input event response over TCP to the connected iPad.
 * No-op if no connection is established.
 */
- (void)sendInputEvent:(const void *)data length:(size_t)len;

@end

NS_ASSUME_NONNULL_END
