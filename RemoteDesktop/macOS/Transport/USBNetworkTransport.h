#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * USB NCM transport for the macOS agent.
 *
 * Detects USB NCM (wiredEthernet) interfaces via NWPathMonitor, then creates
 * separate NWListener instances for UDP (media, port 14567) and TCP (input,
 * port 14568) bound to the exact NWInterface object (never hardcoded name).
 *
 * All connections use TLS 1.3 (TCP) and DTLS (UDP) with certificate pinning.
 * No cleartext fallback exists.
 *
 * Mac is the LISTENER side -- iPad connects to these listeners.
 */
@interface USBNetworkTransport : NSObject

/** Whether a USB NCM interface is currently detected and listeners are active. */
@property (nonatomic, readonly) BOOL isConnected;

/** The active USB NCM interface (nil if none detected). */
@property (nonatomic, readonly, nullable) nw_interface_t activeInterface;

/** The Mac's current USB NCM link-local IP (e.g. "169.254.180.202"). */
@property (nonatomic, readonly, nullable) NSString *localIPAddress;

/** The Mac's TLS identity (SecIdentityRef) used as server identity for all listeners. */
@property (nonatomic, nullable) SecIdentityRef tlsIdentity;

/** Callback fired when raw media frame data arrives over UDP. */
@property (nonatomic, copy, nullable) void (^onMediaReceived)(const void *data, size_t length);

/** Callback fired when raw input event data arrives over TCP. */
@property (nonatomic, copy, nullable) void (^onInputReceived)(const void *data, size_t length);

/** Callback fired when the USB NCM interface appears or disappears. */
@property (nonatomic, copy, nullable) void (^onInterfaceChanged)(BOOL appeared, nw_interface_t _Nullable interface);

/** Callback fired when the TCP input connection is accepted (ready to send handshake). */
@property (nonatomic, copy, nullable) void (^onInputConnectionReady)(void);

/** Callback fired when the TCP input connection is lost (iPad disconnected).
 *  SessionManager uses this to trigger transport FSM disconnect event. */
@property (nonatomic, copy, nullable) void (^onInputConnectionLost)(void);

/**
 * Start monitoring for USB NCM interfaces.
 * When an interface is detected, listeners are created automatically.
 * Requires tlsIdentity to be set before calling.
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
 * Send a complete HEVC frame as paced UDP chunks over DTLS.
 *
 * Chunks the frame using the given MTU, then sends each chunk sequentially —
 * each chunk waits for the previous one's send completion before dispatching.
 * This prevents overwhelming the USB NCM driver's tx queue, which drops
 * packets when datagrams arrive faster than it can drain.
 *
 * @param data       Complete frame data (MediaFrameHeader + payload).
 * @param len        Total length of data.
 * @param mtu        Maximum transmission unit for chunking.
 */
- (void)sendMediaFramePaced:(const void *)data length:(size_t)len mtu:(size_t)mtu;

/**
 * Send an input event response over TCP to the connected iPad.
 * No-op if no connection is established.
 */
- (void)sendInputEvent:(const void *)data length:(size_t)len;

@end

NS_ASSUME_NONNULL_END
