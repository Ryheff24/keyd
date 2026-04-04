#pragma once

#import <Foundation/Foundation.h>
#import "TransportFSM.h"

@class ScreenCapture;
@class HEVCEncoder;
@class USBNetworkTransport;
@class WirelessTransport;
@class PairingManager;

NS_ASSUME_NONNULL_BEGIN

/* ---- Session States ---- */
typedef NS_ENUM(NSInteger, SessionState) {
    SESSION_AWAITING_PERMISSIONS,
    SESSION_AWAITING_PAIRING,
    SESSION_CONNECTING,
    SESSION_STREAMING,
    SESSION_RECONNECTING,
    SESSION_STOPPED
};

/**
 * SessionManager orchestrates the entire remote desktop session lifecycle:
 *   permissions -> pairing -> connecting -> streaming
 *
 * Owns all pipeline components (capture, compress, encode, transport, pairing).
 * Feeds transport events through the FSM and switches encode mode accordingly.
 */
@interface SessionManager : NSObject

/** Current session state. */
@property (nonatomic, assign, readonly) SessionState sessionState;

/** Current transport state from the FSM. */
@property (nonatomic, assign, readonly) TransportState transportState;

/** Whether running in test mode (skips permissions, no real capture). */
@property (nonatomic, assign, readonly) BOOL testMode;

/** Whether running in automation mode (test mode writes payload + starts listener without showing QR window). */
@property (nonatomic, assign, readonly) BOOL automationMode;

/** Wired-only mode: disables WiFi/AWDL transport and Bonjour advertising. */
@property (nonatomic, assign, readonly) BOOL wiredOnly;

/** Wireless-only mode: disables USB monitoring and prefers WiFi/AWDL only. */
@property (nonatomic, assign, readonly) BOOL wirelessOnly;

/* ---- Callbacks to StatusBarController ---- */
@property (nonatomic, copy, nullable) void (^onTransportStateChanged)(TransportState state);
@property (nonatomic, copy, nullable) void (^onModeChanged)(BOOL isEco);
@property (nonatomic, copy, nullable) void (^onResolutionChanged)(uint32_t width, uint32_t height);
@property (nonatomic, copy, nullable) void (^onSessionStateChanged)(SessionState state);
@property (nonatomic, copy, nullable) void (^onPermissionStatusChanged)(BOOL screenGranted, BOOL accessibilityGranted);

- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly;
- (instancetype)initWithTestMode:(BOOL)testMode
                  automationMode:(BOOL)automationMode
                       wiredOnly:(BOOL)wiredOnly
                    wirelessOnly:(BOOL)wirelessOnly
             testCaptureFilePath:(nullable NSString *)testCaptureFilePath
           testCaptureStressMode:(BOOL)testCaptureStressMode;

/**
 * Start the session lifecycle.
 * Checks permissions, then proceeds to pairing/connecting/streaming.
 */
- (void)start;

/**
 * Stop all streaming and tear down transport connections.
 */
- (void)stop;

/**
 * Handle a transport event — feeds through the FSM and executes effects.
 */
- (void)handleTransportEvent:(TransportEvent)event;

/**
 * Generate and display QR code for iPad pairing.
 */
- (void)showPairingQR;

/**
 * Reset pairing state (delete from Keychain).
 */
- (void)resetPairing;

/**
 * Handle a received input event from iPad (via TCP).
 * Routes resolution match requests, eco mode changes, latency probes, etc.
 */
- (void)handleReceivedInputEvent:(const void *)data length:(size_t)length;

@end

NS_ASSUME_NONNULL_END
