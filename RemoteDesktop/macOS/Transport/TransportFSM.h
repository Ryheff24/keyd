#pragma once

#include <stdbool.h>

/* ---- Transport States ---- */
typedef enum {
    TRANSPORT_IDLE,
    TRANSPORT_USB_NCM,
    TRANSPORT_WIFI,
    TRANSPORT_AWDL,
    TRANSPORT_DISCONNECTED
} TransportState;

/* ---- Transport Events ---- */
typedef enum {
    TRANSPORT_EVT_WIRED_APPEARED,
    TRANSPORT_EVT_WIRED_DISAPPEARED,
    TRANSPORT_EVT_WIFI_AVAILABLE,
    TRANSPORT_EVT_WIFI_UNAVAILABLE,
    TRANSPORT_EVT_AWDL_AVAILABLE,
    TRANSPORT_EVT_AWDL_UNAVAILABLE,
    TRANSPORT_EVT_CONNECTED,
    TRANSPORT_EVT_DISCONNECTED,
    TRANSPORT_EVT_ERROR
} TransportEvent;

/* ---- Side Effects ---- */
typedef enum {
    EFFECT_NONE,
    EFFECT_BIND_USB_NCM,
    EFFECT_CONNECT_WIFI,
    EFFECT_CONNECT_AWDL,
    EFFECT_DISCONNECT_CURRENT,
    EFFECT_SWITCH_ENCODE_LZ4,
    EFFECT_SWITCH_ENCODE_HEVC,
    EFFECT_NOTIFY_TRANSPORT_CHANGE
} TransportEffect;

/* ---- Transition Result ---- */
#define TRANSPORT_MAX_EFFECTS 4

typedef struct {
    TransportState  next_state;
    TransportEffect effects[TRANSPORT_MAX_EFFECTS];
    int             effect_count;
} TransportTransition;

/**
 * Pure state machine transition function. No side effects.
 *
 * Given the current state and an event, returns the next state and
 * an array of side effects to execute. The caller is responsible
 * for executing the effects.
 */
TransportTransition transport_fsm_transition(TransportState current,
                                             TransportEvent event);

/**
 * Returns a human-readable name for a transport state.
 */
const char *transport_state_name(TransportState state);

/**
 * Returns a human-readable name for a transport event.
 */
const char *transport_event_name(TransportEvent event);

/**
 * Returns a human-readable name for a transport effect.
 */
const char *transport_effect_name(TransportEffect effect);
