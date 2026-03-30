#include "TransportFSM.h"

/* ---- Helper: build a TransportTransition ---- */

static TransportTransition make_transition(TransportState next,
                                           int count, ...) {
    TransportTransition t;
    t.next_state = next;
    t.effect_count = count > TRANSPORT_MAX_EFFECTS ? TRANSPORT_MAX_EFFECTS : count;

    __builtin_va_list ap;
    __builtin_va_start(ap, count);
    for (int i = 0; i < t.effect_count; i++) {
        t.effects[i] = (TransportEffect)__builtin_va_arg(ap, int);
    }
    __builtin_va_end(ap);

    /* Zero remaining slots */
    for (int i = t.effect_count; i < TRANSPORT_MAX_EFFECTS; i++) {
        t.effects[i] = EFFECT_NONE;
    }
    return t;
}

/* ---- No-op transition (stay in current state) ---- */

static TransportTransition noop(TransportState current) {
    return make_transition(current, 0);
}

/* ---- Pure FSM transition function ---- */

TransportTransition transport_fsm_transition(TransportState current,
                                             TransportEvent event) {
    /*
     * Priority rule: WIRED_APPEARED from ANY state always promotes to USB_NCM.
     * This takes precedence over per-state transitions below.
     */
    if (event == TRANSPORT_EVT_WIRED_APPEARED) {
        if (current == TRANSPORT_USB_NCM) {
            /* Already on USB NCM -- no-op */
            return noop(current);
        }
        if (current == TRANSPORT_IDLE || current == TRANSPORT_DISCONNECTED) {
            /* No active connection to disconnect */
            return make_transition(TRANSPORT_USB_NCM, 3,
                EFFECT_BIND_USB_NCM,
                EFFECT_SWITCH_ENCODE_HEVC,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        }
        /* From WIFI or AWDL: disconnect current, then bind USB */
        return make_transition(TRANSPORT_USB_NCM, 4,
            EFFECT_DISCONNECT_CURRENT,
            EFFECT_BIND_USB_NCM,
            EFFECT_SWITCH_ENCODE_LZ4,
            EFFECT_NOTIFY_TRANSPORT_CHANGE);
    }

    /* Per-state transitions */
    switch (current) {
    case TRANSPORT_IDLE:
        switch (event) {
        case TRANSPORT_EVT_WIFI_AVAILABLE:
            return make_transition(TRANSPORT_WIFI, 3,
                EFFECT_CONNECT_WIFI,
                EFFECT_SWITCH_ENCODE_HEVC,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_AWDL_AVAILABLE:
            return make_transition(TRANSPORT_AWDL, 3,
                EFFECT_CONNECT_AWDL,
                EFFECT_SWITCH_ENCODE_HEVC,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        default:
            return noop(current);
        }

    case TRANSPORT_USB_NCM:
        switch (event) {
        case TRANSPORT_EVT_WIRED_DISAPPEARED:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_ERROR:
        case TRANSPORT_EVT_DISCONNECTED:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        default:
            return noop(current);
        }

    case TRANSPORT_WIFI:
        switch (event) {
        case TRANSPORT_EVT_WIFI_UNAVAILABLE:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_AWDL_AVAILABLE:
            /* Stay on Wi-Fi -- Wi-Fi is preferred over AWDL */
            return noop(current);
        case TRANSPORT_EVT_ERROR:
        case TRANSPORT_EVT_DISCONNECTED:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        default:
            return noop(current);
        }

    case TRANSPORT_AWDL:
        switch (event) {
        case TRANSPORT_EVT_WIFI_AVAILABLE:
            /* Promote from AWDL to Wi-Fi */
            return make_transition(TRANSPORT_WIFI, 3,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_CONNECT_WIFI,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_AWDL_UNAVAILABLE:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_ERROR:
        case TRANSPORT_EVT_DISCONNECTED:
            return make_transition(TRANSPORT_DISCONNECTED, 2,
                EFFECT_DISCONNECT_CURRENT,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        default:
            return noop(current);
        }

    case TRANSPORT_DISCONNECTED:
        switch (event) {
        case TRANSPORT_EVT_WIFI_AVAILABLE:
            return make_transition(TRANSPORT_WIFI, 3,
                EFFECT_CONNECT_WIFI,
                EFFECT_SWITCH_ENCODE_HEVC,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        case TRANSPORT_EVT_AWDL_AVAILABLE:
            return make_transition(TRANSPORT_AWDL, 3,
                EFFECT_CONNECT_AWDL,
                EFFECT_SWITCH_ENCODE_HEVC,
                EFFECT_NOTIFY_TRANSPORT_CHANGE);
        default:
            return noop(current);
        }
    }

    return noop(current);
}

/* ---- Name helpers for logging ---- */

const char *transport_state_name(TransportState state) {
    switch (state) {
    case TRANSPORT_IDLE:         return "Idle";
    case TRANSPORT_USB_NCM:     return "USB-NCM";
    case TRANSPORT_WIFI:        return "Wi-Fi";
    case TRANSPORT_AWDL:        return "AWDL";
    case TRANSPORT_DISCONNECTED: return "Disconnected";
    }
    return "Unknown";
}

const char *transport_event_name(TransportEvent event) {
    switch (event) {
    case TRANSPORT_EVT_WIRED_APPEARED:       return "WiredAppeared";
    case TRANSPORT_EVT_WIRED_DISAPPEARED:    return "WiredDisappeared";
    case TRANSPORT_EVT_WIFI_AVAILABLE:       return "WiFiAvailable";
    case TRANSPORT_EVT_WIFI_UNAVAILABLE:     return "WiFiUnavailable";
    case TRANSPORT_EVT_AWDL_AVAILABLE:       return "AWDLAvailable";
    case TRANSPORT_EVT_AWDL_UNAVAILABLE:     return "AWDLUnavailable";
    case TRANSPORT_EVT_CONNECTED:            return "Connected";
    case TRANSPORT_EVT_DISCONNECTED:         return "Disconnected";
    case TRANSPORT_EVT_ERROR:                return "Error";
    }
    return "Unknown";
}

const char *transport_effect_name(TransportEffect effect) {
    switch (effect) {
    case EFFECT_NONE:                    return "None";
    case EFFECT_BIND_USB_NCM:            return "BindUSBNCM";
    case EFFECT_CONNECT_WIFI:            return "ConnectWiFi";
    case EFFECT_CONNECT_AWDL:            return "ConnectAWDL";
    case EFFECT_DISCONNECT_CURRENT:      return "DisconnectCurrent";
    case EFFECT_SWITCH_ENCODE_LZ4:       return "SwitchEncodeLZ4";
    case EFFECT_SWITCH_ENCODE_HEVC:      return "SwitchEncodeHEVC";
    case EFFECT_NOTIFY_TRANSPORT_CHANGE: return "NotifyTransportChange";
    }
    return "Unknown";
}
