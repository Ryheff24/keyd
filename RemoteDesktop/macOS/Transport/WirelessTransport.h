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
/** Any iPad input connection (current or stale) reached failed/cancelled: EOF, error, framing
 *  error or replacement. Fired on the transport queue. InputPath ReleaseOnLoss hook. */
@property (nonatomic, copy, nullable) void (^onInputStreamEnded)(void);


/**
 * Callback fired when a wireless connection is established or lost.
 * isAWDL distinguishes Wi-Fi from AWDL connections.
 */
@property (nonatomic, copy, nullable) void (^onConnectionChanged)(BOOL connected, BOOL isAWDL);

/** Callback fired when the DTLS media channel (UDP) becomes ready.
 *  SessionManager should wait for this before starting capture. */
@property (nonatomic, copy, nullable) void (^onMediaChannelReady)(void);

/** True while the current media connection has reached ready and has not since failed,
 *  been cancelled or been replaced. Safe to read from any queue (atomic). SessionManager
 *  re-checks it on its session queue before starting capture (SessionLanes FreshCheck). */
@property (nonatomic, readonly) BOOL mediaChannelReady;

/** Callback fired when congestion feedback is received from the iPad.
 *  Parameters: lossRate (0.0-1.0), framesDelivered, framesLost. */
@property (nonatomic, copy, nullable) void (^onCongestionStats)(float lossRate, int framesDelivered, int framesLost);

/** Number of media chunks currently queued in the wireless pacing path. */
@property (nonatomic, readonly) NSUInteger queuedMediaChunkCount;

/**
 * Start advertising the Bonjour service and listening for connections.
 * Enables peer-to-peer (AWDL) discovery.
 * Requires tlsIdentity to be set before calling.
 */
- (void)startAdvertising;

/**
 * Arm reconnect takeover mode so the next accepted wireless candidate can
 * replace a lingering connection from a lost session.
 */
- (void)beginReconnectWindow;

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
 * Execute a block after all pending paced sends have completed.
 * Used for backpressure: the caller increments an in-flight counter
 * before sending chunks, then calls this to decrement after the
 * last chunk passes through the pacing queue.
 */
- (void)afterPendingSends:(void (^)(void))completion;

/**
 * Send an input event response over TCP to the connected iPad.
 * No-op if no connection is established.
 */
- (void)sendInputEvent:(const void *)data length:(size_t)len;

/**
 * Reset the UDP send pacing timer. Call when media connection is
 * re-established to avoid stale delay accumulation.
 */
- (void)resetSendPacing;

/**
 * Handle congestion feedback from the iPad (loss rate 0.0-1.0).
 * Logs the feedback and fires onCongestionStats callback.
 */
- (void)handleCongestionFeedback:(float)lossRate;

/**
 * Send a media frame over TCP (with 4-byte length prefix framing).
 * Used for large frames where UDP chunking would create too many datagrams.
 * The iPad's TCP receive path handles framing and routes to handleReceivedFrame.
 */
- (void)sendMediaFrameViaTCP:(const void *)data length:(size_t)len;

/**
 * Send a media frame over TCP (with 4-byte length prefix framing) and report
 * send completion. completion(success=YES) means Network.framework accepted
 * the payload; success=NO means send failed.
 * Returns YES if the frame was queued on a ready current connection, NO if there was
 * none (completion(NO) has then already run): tla/Lifecycle.tla CountOnSend.
 */
- (BOOL)sendMediaFrameViaTCP:(const void *)data
                      length:(size_t)len
                  completion:(void (^ _Nullable)(BOOL success))completion;

/** Bumps each time a new input connection becomes current (READY, TLS pin verified).
 *  tla/Lifecycle.tla RestartOnNewConn: the session restarts on every new epoch. */
@property (nonatomic, readonly) uint32_t inputConnectionEpoch;

/** tla/FrameLoop.tla HsConn: send only on the ready connection that epoch names; NO (and, for
 *  media, completion(NO)) if it is no longer current, so a handshake and the frames after it
 *  share one connection. */
- (BOOL)sendInputEvent:(const void *)data length:(size_t)len onEpoch:(uint32_t)epoch;
- (BOOL)sendMediaFrameViaTCP:(const void *)data
                      length:(size_t)len
                     onEpoch:(uint32_t)epoch
                  completion:(void (^ _Nullable)(BOOL success))completion;

/** YES while the current input connection is ready (tla/Lifecycle.tla CountOnSend). */
@property (nonatomic, readonly) BOOL hasReadyInputConnection;

@end

NS_ASSUME_NONNULL_END
