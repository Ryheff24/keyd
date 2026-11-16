#pragma once

#import <Cocoa/Cocoa.h>
#import "TransportFSM.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * StatusBarController manages the macOS menu bar icon and menu.
 *
 * Displays connection state, mode, resolution, permission status,
 * and pairing controls. Pattern-copy from keyd v1.0 StatusBarController.swift
 * rewritten in ObjC for the C+ObjC macOS agent.
 */
@interface StatusBarController : NSObject

/* ---- Actions (callbacks to SessionManager) ---- */
@property (nonatomic, copy, nullable) void (^onPairRequested)(void);
@property (nonatomic, copy, nullable) void (^onResetPairingRequested)(void);
@property (nonatomic, copy, nullable) void (^onFixLoginItemRequested)(void);

/**
 * Update the connection state display (icon + menu item).
 */
- (void)updateConnectionState:(TransportState)state;

/**
 * Update whether a session is streaming to the iPad. The menu says "Connected"
 * only while streaming; a link without a session says it is waiting for the iPad.
 */
- (void)updateSessionStreaming:(BOOL)streaming;

/**
 * Update the encode mode display.
 */
- (void)updateMode:(BOOL)isEco;

/**
 * Update the resolution info display.
 */
- (void)updateResolution:(uint32_t)width height:(uint32_t)height;

/**
 * Re-check and update the permission status menu items (Screen Recording, Accessibility).
 */
- (void)updatePermissionStatus;

/**
 * Show the fail-closed state: the Secure Enclave TLS identity is unavailable, so the agent will
 * not pair or serve. Sticky: later connection-state updates do not hide it.
 */
- (void)showIdentityFailure;

@end

NS_ASSUME_NONNULL_END
