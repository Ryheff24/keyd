#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Wireless transport for the macOS agent (Wi-Fi + AWDL).
 *
 * Advertises a Bonjour service (_keydrd._tcp) with peer-to-peer enabled
 * so the iPad can discover the Mac over Wi-Fi or AWDL. When the iPad
 * connects, this module accepts the connections and determines whether
 * the path is Wi-Fi or AWDL via the connection's interface type.
 *
 * All connections use TLS 1.3 (TCP) and DTLS (UDP) with certificate pinning.
 * No cleartext fallback exists.
 *
 * Mac is the LISTENER side -- iPad discovers and connects.
 */
@interface WirelessTransport : NSObject

/** Whether a wireless connection is currently active. */
@property (nonatomic, readonly) BOOL isConnected;

/** Whether the current connection is over AWDL (vs Wi-Fi). */
@property (nonatomic, readonly) BOOL isAWDL;

/** The Mac's TLS identity (SecIdentityRef) used as server identity for all listeners. */
@property (nonatomic, nullable) SecIdentityRef tlsIdentity;

/** Callback fired when raw media frame data arrives over UDP. */
@property (nonatomic, copy, nullable) void (^onMediaReceived)(const void *data, size_t length);

/** Callback fired when raw input event data arrives over TCP. */
@property (nonatomic, copy, nullable) void (^onInputReceived)(const void *data, size_t length);

/**
 * Callback fired when a wireless connection is established or lost.
 * isAWDL distinguishes Wi-Fi from AWDL connections.
 */
@property (nonatomic, copy, nullable) void (^onConnectionChanged)(BOOL connected, BOOL isAWDL);

/** Callback fired when the DTLS media channel (UDP) becomes ready.
 *  SessionManager should wait for this before starting capture. */
@property (nonatomic, copy, nullable) void (^onMediaChannelReady)(void);

/**
 * Start advertising the Bonjour service and listening for connections.
 * Enables peer-to-peer (AWDL) discovery.
 * Requires tlsIdentity to be set before calling.
 */
- (void)startAdvertising;

/**
 * Stop advertising and tear down all connections.
 */
- (void)stopAdvertising;

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
