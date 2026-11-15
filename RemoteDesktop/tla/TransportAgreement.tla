------------------------- MODULE TransportAgreement -------------------------
(***************************************************************************)
(* B3, H3, C3 in PLAN.md: transport switching on both sides at once.  The  *)
(* owner moves between USB and Wi-Fi every day; the worst past bugs were    *)
(* state bugs in switching (Wi-Fi->USB, wireless<->wireless, wired<->       *)
(* wireless, re-plug).  This module models both transport FSMs, their       *)
(* session-layer fallback, the USB peer-address update, and each side       *)
(* noticing link changes on its own schedule.  Method: METHOD.md.           *)
(*                                                                         *)
(* As built [C] (read 2026-10-29):                                         *)
(*   FSM table: macOS/Transport/TransportFSM.c:62-160 and                  *)
(*     iPadOS/Transport/TransportFSM.swift:58-128, identical.  Fsm below.  *)
(*   Mac: handleTransportEvent, SessionManager.m:737-795.  WIRED_APPEARED  *)
(*     first sends the peer address over the current route (:2415-2440).  *)
(*     Immediate fallback only while STREAMING, and it fires WIFI_AVAILABLE *)
(*     for any wireless link, AWDL included.  Otherwise, in CONNECTING or  *)
(*     RECONNECTING with any transport connected: onTransportConnected     *)
(*     (handshake, STREAMING).  Connection effects are no-ops.            *)
(*   Mac codec = whether the HEVC encoder is active (configureFrameDelivery,*)
(*     :1091-1131).  switchToLZ4Mode stops it; switchToHEVCMode starts it  *)
(*     only if a viewport is known (:797-870); onTransportConnected starts *)
(*     it if USB is not connected and a viewport is known (:897-930); the  *)
(*     iPad's viewport report (sent after each handshake) starts it unless *)
(*     it is off and USB is connected (:2626-2672).                        *)
(*   Mac event sources (:631-690): USB interface appear/disappear ->       *)
(*     WIRED_APPEARED/DISAPPEARED; USB input ready -> WIRED_APPEARED, or   *)
(*     onTransportConnected if already USB_NCM; USB input lost ->          *)
(*     DISCONNECTED, with no link tag; wireless ready/lost -> WIFI/AWDL    *)
(*     AVAILABLE/UNAVAILABLE.                                              *)
(*   Mac routing: USB if its USB transport is connected, else wireless    *)
(*     (:1294, :1761) - not the FSM state.                                 *)
(*   Mac reconnection: bounded attempts, each checks isConnected (:3044).  *)
(*   Mac wireless: one connection; Bonjour listener suspended while it is  *)
(*     up, restarted after it ends (WirelessTransport.m:660-760).          *)
(*   iPad: handleTransportEvent, SessionManager.swift:568-631; returns     *)
(*     early when the FSM neither moves nor has effects; same fallback     *)
(*     (WIFI_AVAILABLE for any wireless); else DISCONNECTED while          *)
(*     streaming -> reconnecting.  Routing: USB if connected, else         *)
(*     wireless (:1349).  USB TCP loss fires no FSM event.                 *)
(*   iPad USB (USBNetworkTransport.swift:388-480): polls the interface     *)
(*     every 500 ms; connects only to a stored link-local Mac address,     *)
(*     cleared only by a pairing reset; on appear with an address it connects and *)
(*     fires wiredAppeared; setPeerAddress connects if the interface is up *)
(*     and USB is not connected.  A connect that fails is not retried (one *)
(*     still waiting is re-dialled every 0.5 s to the same address).        *)
(*                                                                         *)
(* Assumptions:                                                             *)
(*   T1 [I] One TCP connection per channel (usb, wl).  Each side sees it  *)
(*        become ready, and later die, on its own schedule.                *)
(*   T2 [I] A message sent on an open connection is queued (TCP buffers   *)
(*        it) and read once the receiver sees the connection; it is lost  *)
(*        if the connection dies first.  Receivers key on message headers, *)
(*        so cross-channel reordering is not modelled.  Frames flow        *)
(*        continuously, so one is modelled only when it changes state.     *)
(*   T3 [I] The Mac's USB link-local address may change on re-plug        *)
(*        (addrGen), up to MaxGen.                                         *)
(*   T4 [I] A wireless connection runs over Wi-Fi or AWDL, chosen by the   *)
(*        system among links that are up.                                  *)
(*   T5 [I] The environment flaps links at most MaxFlaps times, so every   *)
(*        behaviour reaches a state where the system has nothing left to   *)
(*        do (Rest).  Security is SecureSession.tla's job, not this one's. *)
(*   T6 [I] Scope: the iPad app stays in the foreground, nobody resets      *)
(*        pairing, and the iPad's 8 s connecting timeout (which resets     *)
(*        pairing, SessionManager.swift:344) does not fire; Eco mode       *)
(*        (HEVC on USB by request, SessionManager.m:2818) is off.          *)
(*   T7 [I] One connection per channel carries control and media together;  *)
(*        each message arrives whole (no TCP framing).  As built, control  *)
(*        and media are separate connections that fail separately, and     *)
(*        input reads are unframed (PLAN.md, open findings).  On USB TCP   *)
(*        loss the iPad here stops routing to USB; as built it keeps       *)
(*        isConnected while a media connection exists                      *)
(*        (USBNetworkTransport.swift:672-675), so this is generous.        *)
(*   T8 [U] AddrOnLink abstracts address discovery on the USB link (e.g.   *)
(*        DNS-SD scoped to the NCM interface) as one step that cannot      *)
(*        fail.  MacCommit is one atomic step: the code must make route,   *)
(*        label, codec and handshake change together (PLAN.md).           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxFlaps, MaxGen, MaxAttempts,
    InitPeerKnown,   \* the iPad starts with the Mac's current USB address
    \* mechanisms (all TRUE in Design)
    RouteResync,     \* after every Mac event the codec is the route's, and a change
                     \* of route re-sends the handshake on the new one
    AddrOnLink,      \* the iPad learns the Mac's USB address on the USB link
                     \* itself and retries USB while the cable is in
    DerivedState,    \* each side's transport state, and its session's reaction,
                     \* are computed from its live connections after every event,
                     \* not kept as a separate FSM fed by events
    IpadResync       \* when the iPad's route changes mid-session, it re-sends its
                     \* viewport report on the new route

ASSUME Bounds == {MaxFlaps, MaxGen, MaxAttempts} \subseteq Nat /\ MaxGen >= 1
ASSUME Switches == {InitPeerKnown, RouteResync, AddrOnLink, DerivedState, IpadResync}
                   \subseteq BOOLEAN

Links  == {"usb", "wifi", "awdl"}
WLinks == {"wifi", "awdl"}
Chans  == {"usb", "wl"}
States == {"idle", "usb", "wifi", "awdl", "disc"}
Events == {"wiredAppeared", "wiredDisappeared", "wifiAvail", "wifiUnavail",
           "awdlAvail", "awdlUnavail", "disconnected"}
Sess   == {"connecting", "streaming", "reconnecting"}

VARIABLES env, net, mac, ipad
vars == <<env, net, mac, ipad>>

-----------------------------------------------------------------------------
(* The shared FSM table (TransportFSM.c).  codec: the last codec effect.   *)

T(s, c, e) == [s |-> s, codec |-> c, eff |-> e]
Fsm(cur, ev) ==
    IF ev = "wiredAppeared"
    THEN IF cur = "usb" THEN T(cur, "none", FALSE) ELSE T("usb", "lz4", TRUE)
    ELSE CASE cur \in {"idle", "disc"} /\ ev = "wifiAvail" -> T("wifi", "hevc", TRUE)
           [] cur \in {"idle", "disc"} /\ ev = "awdlAvail" -> T("awdl", "hevc", TRUE)
           [] cur = "usb"  /\ ev \in {"wiredDisappeared", "disconnected"} -> T("disc", "none", TRUE)
           [] cur = "wifi" /\ ev \in {"wifiUnavail", "disconnected"}      -> T("disc", "none", TRUE)
           [] cur = "awdl" /\ ev = "wifiAvail"                            -> T("wifi", "none", TRUE)
           [] cur = "awdl" /\ ev \in {"awdlUnavail", "disconnected"}      -> T("disc", "none", TRUE)
           [] OTHER -> T(cur, "none", FALSE)

LinkOf(ch) == IF ch = "usb" THEN "usb" ELSE net.wlKind
\* The link a side sends on: USB if it sees the USB connection, else wireless.
Route(sees) == IF sees["usb"] THEN "usb" ELSE IF sees["wl"] THEN "wl" ELSE "none"
Codec(ch)   == IF ch = "usb" THEN "lz4" ELSE "hevc"
FsmLink(s)  == CASE s = "usb" -> "usb" [] s \in WLinks -> "wl" [] OTHER -> "none"
\* The exact link a label names, and the exact link a route runs over.
Label(s)    == IF s \in Links THEN s ELSE "none"
LinkOn(r)   == CASE r = "usb" -> "usb" [] r = "wl" -> net.wlKind [] OTHER -> "none"
Delivered(ch) == ch # "none" /\ net.conn[ch] = "open" /\ ipad.sees[ch]
Open(ch)      == ch # "none" /\ net.conn[ch] = "open"

-----------------------------------------------------------------------------
TypeOK ==
    /\ env \in [phys : [Links -> BOOLEAN], flaps : 0..MaxFlaps, addrGen : 1..MaxGen,
                last : Links \cup {"none"}, lastGen : 1..MaxGen, cut : BOOLEAN]
    /\ net \in [conn : [Chans -> {"none", "open", "dead"}], wlKind : WLinks,
                hs : [Chans -> BOOLEAN], addr : [Chans -> 0..MaxGen], vp : [Chans -> BOOLEAN]]
    /\ mac \in [fsm : States, sess : Sess, mode : {"lz4", "hevc"}, vpKnown : BOOLEAN,
                iface : BOOLEAN, sees : [Chans -> BOOLEAN], attempts : 0..MaxAttempts]
    /\ ipad \in [fsm : States, sess : Sess, iface : BOOLEAN, sees : [Chans -> BOOLEAN],
                 peerGen : 0..MaxGen, usbPending : BOOLEAN, hsOK : BOOLEAN]

Init ==
    /\ env = [phys |-> [l \in Links |-> FALSE], flaps |-> 0, addrGen |-> 1, last |-> "none",
              lastGen |-> 1, cut |-> FALSE]
    /\ net = [conn |-> [c \in Chans |-> "none"], wlKind |-> "wifi",
              hs |-> [c \in Chans |-> FALSE], addr |-> [c \in Chans |-> 0],
              vp |-> [c \in Chans |-> FALSE]]
    /\ mac = [fsm |-> "idle", sess |-> "connecting", mode |-> "lz4", vpKnown |-> FALSE,
              iface |-> FALSE,
              sees |-> [c \in Chans |-> FALSE], attempts |-> 0]
    /\ ipad = [fsm |-> "idle", sess |-> "connecting", iface |-> FALSE,
               sees |-> [c \in Chans |-> FALSE],
               peerGen |-> IF InitPeerKnown THEN 1 ELSE 0, usbPending |-> FALSE,
               hsOK |-> FALSE]

-----------------------------------------------------------------------------
(* Mac: handleTransportEvent with its effects and immediate fallback.      *)
(* Returns the new mac record plus what it delivers to the iPad.           *)

\* The Mac's codec after an FSM codec effect: HEVC only if a viewport is known.
MacMode(m, codec) ==
    CASE codec = "lz4" -> "lz4"
      [] codec = "hevc" /\ m.vpKnown -> "hevc"
      [] OTHER -> m.mode

\* onTransportConnected: STREAMING, handshake on the route; starts HEVC if USB
\* is not connected and a viewport is known.
Connected(m) ==
    [m EXCEPT !.sess = "streaming", !.attempts = 0,
              !.mode = IF ~m.sees["usb"] /\ m.vpKnown THEN "hevc" ELSE m.mode]

\* Queue a message on channel ch if it is open (T2).
Queue(n, f, ch, v) == IF Open(ch) THEN [n EXCEPT ![f][ch] = v] ELSE n

\* The transport state a side's live connections imply.
StateOf(r, cur) == CASE r = "usb" -> "usb"
                     [] r = "wl"  -> net.wlKind
                     [] OTHER     -> IF cur = "idle" THEN "idle" ELSE "disc"

\* Every Mac action ends here.  With DerivedState, the transport state is
\* the route's, the session stops when the route is gone and connects (with
\* a handshake) when one appears.  With RouteResync, a change of route sets
\* that route's codec and re-sends the handshake on it.
MacCommit(m, n) ==
    LET r0 == Route(mac.sees)
        r1 == Route(m.sees)
        md == IF ~DerivedState THEN m
              ELSE IF r1 = "none" /\ m.sess = "streaming"
              THEN [m EXCEPT !.fsm = StateOf(r1, m.fsm), !.sess = "reconnecting", !.attempts = 0]
              ELSE IF r1 # "none" /\ m.sess \in {"connecting", "reconnecting"}
              THEN [Connected(m) EXCEPT !.fsm = StateOf(r1, m.fsm)]
              ELSE [m EXCEPT !.fsm = StateOf(r1, m.fsm)]
        nd == IF DerivedState /\ md.sess = "streaming" /\ m.sess # "streaming"
              THEN Queue(n, "hs", r1, TRUE) ELSE n
    IN /\ mac' = IF RouteResync /\ r1 # "none" THEN [md EXCEPT !.mode = Codec(r1)] ELSE md
       /\ net' = IF RouteResync /\ r1 # r0 /\ r1 # "none" /\ md.sess = "streaming"
                 THEN Queue(nd, "hs", r1, TRUE) ELSE nd

\* One FSM step, then the fallback or connect check of SessionManager.m:768-794.
MacStep(m, ev) ==
    LET t  == Fsm(m.fsm, ev)
        m1 == [m EXCEPT !.fsm = t.s, !.mode = MacMode(m, t.codec)]
        fbWl  == Fsm("disc", "wifiAvail")
        fbUsb == Fsm("disc", "wiredAppeared")
    IN IF m1.fsm = "disc" /\ m1.sess = "streaming" /\ m1.sees["wl"]
       THEN [m1 EXCEPT !.fsm = fbWl.s, !.mode = MacMode(m1, fbWl.codec)]
       ELSE IF m1.fsm = "disc" /\ m1.sess = "streaming" /\ m1.sees["usb"]
       THEN [m1 EXCEPT !.fsm = fbUsb.s, !.mode = MacMode(m1, fbUsb.codec)]
       ELSE IF m1.fsm = "disc" /\ m1.sess = "streaming"
       THEN [m1 EXCEPT !.sess = "reconnecting", !.attempts = 0]
       ELSE IF m1.fsm \notin {"idle", "disc"} /\ m1.sess \in {"connecting", "reconnecting"}
               /\ (m1.sees["usb"] \/ m1.sees["wl"])
       THEN Connected(m1)
       ELSE m1

\* The Mac handles event ev (from channel ch).  It queues the peer address
\* (on wiredAppeared, before the step, on the route at that moment) and the
\* handshake (if the step connected) for the iPad.
MacHandle(ev, ch, m) ==
    LET m2 == MacStep(m, ev)
        n1 == IF ev = "wiredAppeared" THEN Queue(net, "addr", Route(m.sees), env.addrGen) ELSE net
        hs == m2.sess = "streaming" /\ m.sess # "streaming"
    IN /\ MacCommit(m2, IF hs THEN Queue(n1, "hs", Route(m2.sees), TRUE) ELSE n1)
       /\ UNCHANGED ipad

-----------------------------------------------------------------------------
(* iPad: handleTransportEvent (SessionManager.swift:568-631).              *)

IpadStep(p, ev) ==
    LET t == Fsm(p.fsm, ev)
        p1 == [p EXCEPT !.fsm = t.s]
    IN IF t.s = p.fsm /\ ~t.eff THEN p
       ELSE IF p1.fsm = "disc" /\ p1.sess = "streaming" /\ p1.sees["wl"]
       THEN [p1 EXCEPT !.fsm = Fsm("disc", "wifiAvail").s]
       ELSE IF p1.fsm = "disc" /\ p1.sess = "streaming" /\ p1.sees["usb"]
       THEN [p1 EXCEPT !.fsm = "usb"]
       ELSE IF p1.fsm = "disc" /\ p1.sess = "streaming"
       THEN [p1 EXCEPT !.sess = "reconnecting"]
       ELSE p1

\* Every iPad action that changes what it sees ends here, with n the network
\* after the action's own sends.  With DerivedState, the transport state is
\* the route's and the session drops to reconnecting when the route is gone.
\* With IpadResync, a change of route while streaming re-sends the viewport
\* report on the new route.  hsOK records that the iPad holds the current
\* session's handshake: it is lost whenever the iPad drops to reconnecting
\* (a property ghost, in every configuration).
IpadSet(p, n) ==
    LET r  == Route(p.sees)
        p2 == IF ~DerivedState THEN p
              ELSE [p EXCEPT !.fsm = StateOf(r, p.fsm),
                             !.sess = IF r = "none" /\ p.sess = "streaming" THEN "reconnecting" ELSE p.sess]
    IN /\ ipad' = [p2 EXCEPT !.hsOK = p2.hsOK /\ p2.sess # "reconnecting"]
       /\ net' = IF IpadResync /\ r # Route(ipad.sees) /\ r # "none" /\ p2.sess = "streaming"
                 THEN Queue(n, "vp", r, TRUE) ELSE n

-----------------------------------------------------------------------------
(* Connections on a link that goes down are dead until both sides notice. *)

Kill(c, ch) == IF c[ch] = "open" THEN "dead" ELSE c[ch]
\* Queued messages on a dying connection are lost.
Drain(n, ch) == [n EXCEPT !.conn[ch] = Kill(n.conn, ch), !.hs[ch] = FALSE,
                          !.addr[ch] = 0, !.vp[ch] = FALSE]

-----------------------------------------------------------------------------
(* Mac event sources (SessionManager.m:631-690).                            *)

MacIfaceUp ==
    /\ env.phys["usb"] /\ ~mac.iface
    /\ MacHandle("wiredAppeared", "usb", [mac EXCEPT !.iface = TRUE])
    /\ UNCHANGED env

MacIfaceDown ==
    /\ ~env.phys["usb"] /\ mac.iface
    /\ MacHandle("wiredDisappeared", "usb", [mac EXCEPT !.iface = FALSE])
    /\ UNCHANGED env

\* USB input connection ready: WIRED_APPEARED unless already USB_NCM, else
\* onTransportConnected directly (handshake, whatever the session state).
MacUsbReady ==
    /\ net.conn["usb"] = "open" /\ ~mac.sees["usb"]
    /\ LET m == [mac EXCEPT !.sees["usb"] = TRUE] IN
       IF m.fsm # "usb" THEN MacHandle("wiredAppeared", "usb", m)
       ELSE /\ MacCommit(Connected(m), Queue(net, "hs", "usb", TRUE))
            /\ UNCHANGED ipad
    /\ UNCHANGED env

MacUsbLost ==
    /\ net.conn["usb"] = "dead" /\ mac.sees["usb"]
    /\ MacHandle("disconnected", "usb", [mac EXCEPT !.sees["usb"] = FALSE])
    /\ UNCHANGED env

MacWlReady ==
    /\ net.conn["wl"] = "open" /\ ~mac.sees["wl"]
    /\ MacHandle(IF net.wlKind = "wifi" THEN "wifiAvail" ELSE "awdlAvail", "wl",
                 [mac EXCEPT !.sees["wl"] = TRUE])
    /\ UNCHANGED env

MacWlLost ==
    /\ net.conn["wl"] = "dead" /\ mac.sees["wl"]
    /\ MacHandle(IF net.wlKind = "wifi" THEN "wifiUnavail" ELSE "awdlUnavail", "wl",
                 [mac EXCEPT !.sees["wl"] = FALSE])
    /\ UNCHANGED env

\* Reconnect timer: bounded attempts, each checks whether any transport is up.
MacReconnectTimer ==
    /\ mac.sess = "reconnecting" /\ mac.attempts < MaxAttempts
    /\ LET m == [mac EXCEPT !.attempts = @ + 1]
           up == m.sees["usb"] \/ m.sees["wl"]
       IN MacCommit(IF up THEN Connected(m) ELSE m,
                    IF up THEN Queue(net, "hs", Route(m.sees), TRUE) ELSE net)
    /\ UNCHANGED <<env, ipad>>

\* While streaming, frames flow on the route; a frame that reaches the iPad
\* brings it to streaming (first frame, C5).
MacFrame ==
    /\ mac.sess = "streaming" /\ ipad.sess # "streaming"
    /\ Delivered(Route(mac.sees))
    /\ ipad' = [ipad EXCEPT !.sess = "streaming"]
    /\ UNCHANGED <<env, net, mac>>

\* The iPad reads a queued handshake: streaming, and it sends its viewport
\* report on its own route (SessionManager.swift:986-1045, :474).
IpadRecvHs(ch) ==
    /\ net.hs[ch] /\ Delivered(ch)
    /\ ipad' = [ipad EXCEPT !.sess = "streaming", !.hsOK = TRUE]
    /\ net' = Queue([net EXCEPT !.hs[ch] = FALSE], "vp", Route(ipad.sees), TRUE)
    /\ UNCHANGED <<env, mac>>

\* The Mac reads a viewport report: it starts HEVC unless the encoder is off
\* and USB is connected.
MacRecvVp(ch) ==
    /\ net.vp[ch] /\ Open(ch) /\ mac.sees[ch]
    /\ MacCommit([mac EXCEPT !.vpKnown = TRUE,
                             !.mode = IF mac.mode = "lz4" /\ mac.sees["usb"] THEN "lz4" ELSE "hevc"],
                  [net EXCEPT !.vp[ch] = FALSE])
    /\ UNCHANGED <<env, ipad>>

-----------------------------------------------------------------------------
(* iPad event sources.                                                       *)

\* The poll sees the interface appear.  As built it connects only if it holds
\* a link-local address and fires wiredAppeared then.  With AddrOnLink it
\* finds the Mac's current address on the link and always tries.
IpadIfaceUp ==
    /\ env.phys["usb"] /\ ~ipad.iface
    /\ LET known == AddrOnLink \/ ipad.peerGen # 0
           p0 == [ipad EXCEPT !.iface = TRUE, !.usbPending = known,
                              !.peerGen = IF AddrOnLink THEN env.addrGen ELSE @]
       IN IpadSet(IF known THEN IpadStep(p0, "wiredAppeared") ELSE p0, net)
    /\ UNCHANGED <<env, mac>>

\* The poll sees the interface gone (only if it polls while unplugged):
\* tear down USB, wiredDisappeared.
IpadIfaceDown ==
    /\ ~env.phys["usb"] /\ ipad.iface
    /\ IpadSet(IpadStep([ipad EXCEPT !.iface = FALSE, !.sees["usb"] = FALSE,
                                      !.usbPending = FALSE], "wiredDisappeared"),
               LET n == Drain(net, "usb") IN
               IF ~mac.sees["usb"] THEN [n EXCEPT !.conn["usb"] = "none"] ELSE n)
    /\ UNCHANGED <<env, mac>>

\* The peer-address update arrives (SessionManager.swift:431).
IpadAddr(ch) ==
    /\ net.addr[ch] # 0 /\ Delivered(ch)
    /\ LET p0 == [ipad EXCEPT !.peerGen = net.addr[ch]]
           go == p0.iface /\ ~p0.sees["usb"]
       IN IpadSet(IF go THEN IpadStep([p0 EXCEPT !.usbPending = TRUE], "wiredAppeared") ELSE p0,
                  [net EXCEPT !.addr[ch] = 0])
    /\ UNCHANGED <<env, mac>>

\* A USB connect attempt.  Generous to the code [U]: an attempt made before
\* the Mac's listener is bound waits for it (NWConnection .waiting) rather
\* than failing.  An attempt to a stale address never succeeds; as built
\* that is final, with AddrOnLink the iPad re-learns the address and retries.
IpadUsbConnect ==
    /\ ipad.usbPending /\ ipad.iface /\ env.phys["usb"] /\ net.conn["usb"] = "none"
    /\ mac.iface
    /\ IF ipad.peerGen = env.addrGen
       THEN /\ net' = [net EXCEPT !.conn["usb"] = "open"]
            /\ ipad' = [ipad EXCEPT !.usbPending = FALSE]
       ELSE /\ ipad' = [ipad EXCEPT !.usbPending = AddrOnLink,
                                    !.peerGen = IF AddrOnLink THEN env.addrGen ELSE @]
            /\ UNCHANGED net
    /\ UNCHANGED <<env, mac>>

\* With AddrOnLink, a cable that is in but has no USB connection is retried.
IpadUsbRetry ==
    /\ AddrOnLink /\ ipad.iface /\ env.phys["usb"] /\ ~ipad.usbPending
    /\ net.conn["usb"] = "none" /\ ~ipad.sees["usb"]
    /\ ipad' = [ipad EXCEPT !.usbPending = TRUE, !.peerGen = env.addrGen]
    /\ UNCHANGED <<env, net, mac>>

IpadUsbReady ==
    /\ net.conn["usb"] = "open" /\ ~ipad.sees["usb"] /\ ipad.iface
    /\ IpadSet([ipad EXCEPT !.sees["usb"] = TRUE], net)
    /\ UNCHANGED <<env, mac>>

\* USB TCP loss on the iPad fires no FSM event (as built).
IpadUsbLost ==
    /\ net.conn["usb"] = "dead" /\ ipad.sees["usb"]
    /\ IpadSet([ipad EXCEPT !.sees["usb"] = FALSE], net)
    /\ UNCHANGED <<env, mac>>

\* The iPad browses continuously; the Mac listens while it has no wireless
\* connection.  The system picks Wi-Fi or AWDL among links that are up (T4).
IpadWlConnect ==
    /\ net.conn["wl"] = "none" /\ ~mac.sees["wl"] /\ ~ipad.sees["wl"]
    /\ \E l \in WLinks : env.phys[l] /\ net' = [net EXCEPT !.conn["wl"] = "open", !.wlKind = l]
    /\ UNCHANGED <<env, mac, ipad>>

IpadWlReady ==
    /\ net.conn["wl"] = "open" /\ ~ipad.sees["wl"]
    /\ IpadSet(IpadStep([ipad EXCEPT !.sees["wl"] = TRUE],
                         IF net.wlKind = "wifi" THEN "wifiAvail" ELSE "awdlAvail"), net)
    /\ UNCHANGED <<env, mac>>

IpadWlLost ==
    /\ net.conn["wl"] = "dead" /\ ipad.sees["wl"]
    /\ IpadSet(IpadStep([ipad EXCEPT !.sees["wl"] = FALSE],
                         IF net.wlKind = "wifi" THEN "wifiUnavail" ELSE "awdlUnavail"), net)
    /\ UNCHANGED <<env, mac>>

\* A dead connection that neither side sees any more is gone.
Reap(ch) ==
    /\ net.conn[ch] = "dead" /\ ~mac.sees[ch] /\ ~ipad.sees[ch]
    /\ net' = [net EXCEPT !.conn[ch] = "none"]
    /\ UNCHANGED <<env, mac, ipad>>

SysNext ==
    \/ MacIfaceUp \/ MacIfaceDown \/ MacUsbReady \/ MacUsbLost \/ MacWlReady \/ MacWlLost
    \/ MacReconnectTimer \/ MacFrame
    \/ IpadIfaceUp \/ IpadIfaceDown \/ IpadUsbConnect \/ IpadUsbRetry
    \/ IpadUsbReady \/ IpadUsbLost \/ IpadWlConnect \/ IpadWlReady \/ IpadWlLost
    \/ \E ch \in Chans : Reap(ch) \/ IpadRecvHs(ch) \/ MacRecvVp(ch) \/ IpadAddr(ch)


-----------------------------------------------------------------------------
(* Properties.  Each has a control in cfg/ that must report it violated.   *)

MacRoute == Route(mac.sees)

\* Nothing left for the system to do (T5): the environment is still or spent.
Rest == ~ENABLED SysNext
AnyUp == \E l \in Links : env.phys[l]

\* At rest with some link up, both sides stream over a live connection the
\* iPad also sees, the iPad has the handshake (display geometry) sent since
\* it last lost its route, and the Mac has the iPad's viewport.
RestStreams ==
    (Rest /\ AnyUp) =>
        /\ mac.sess = "streaming" /\ ipad.sess = "streaming" /\ ipad.hsOK /\ mac.vpKnown
        /\ MacRoute # "none" /\ Delivered(MacRoute)
\* At rest, USB carries the session whenever the cable is in.
RestUsesUsb == (Rest /\ env.phys["usb"]) => MacRoute = "usb"
\* At rest, the codec suits the route: LZ4 (full-frame bandwidth) only on
\* USB, HEVC on wireless.
RestCodec == (Rest /\ MacRoute # "none") => mac.mode = Codec(MacRoute)

\* At rest, each side's FSM state (shown on the HUD and the Mac's menu bar)
\* names the exact link that side actually sends on (AWDL is not Wi-Fi).
RestLabels ==
    Rest => /\ Label(mac.fsm) = LinkOn(MacRoute)
            /\ Label(ipad.fsm) = LinkOn(Route(ipad.sees))

\* At rest with no route, the Mac is not streaming (capture and encoder off).
RestIdleAlone == (Rest /\ MacRoute = "none") => mac.sess # "streaming"

Good == RestStreams /\ RestUsesUsb /\ RestCodec

\* The design keeps these at every step, not only at rest (TLAPS proves them
\* in TransportAgreementProofs.tla).  Each side's label names the channel it
\* sends on (DerivedState); the Mac streams only with a route (DerivedState);
\* the codec suits the route (RouteResync).
LabelsMatch ==
    /\ Label(mac.fsm) = LinkOn(MacRoute)
    /\ Label(ipad.fsm) = LinkOn(Route(ipad.sees))
StreamOnlyWithRoute == mac.sess = "streaming" => MacRoute # "none"
CodecMatches == MacRoute # "none" => mac.mode = Codec(MacRoute)

-----------------------------------------------------------------------------
(* The environment's moves.  For the witnesses each move records the link   *)
(* the session last rested on in good order with a link up (env.last), the  *)
(* USB address then (env.lastGen), and whether the cable has been pulled     *)
(* since (env.cut).  A rest with no link up keeps the record.               *)

\* Links come and go, at most MaxFlaps times (T5).
Settle == Rest /\ AnyUp
Mark(e, unplug) ==
    [e EXCEPT !.flaps = @ + 1,
              !.last = IF Settle THEN (IF Good THEN LinkOf(MacRoute) ELSE "none") ELSE @,
              !.lastGen = IF Settle THEN env.addrGen ELSE @,
              !.cut = IF Settle THEN unplug ELSE @ \/ unplug]

Flap == env.flaps < MaxFlaps

PlugUSB ==
    /\ Flap /\ ~env.phys["usb"]
    /\ \E g \in {env.addrGen, env.addrGen + 1} \cap 1..MaxGen :
         env' = [Mark(env, FALSE) EXCEPT !.phys["usb"] = TRUE, !.addrGen = g]
    /\ UNCHANGED <<net, mac, ipad>>

UnplugUSB ==
    /\ Flap /\ env.phys["usb"]
    /\ env' = [Mark(env, TRUE) EXCEPT !.phys["usb"] = FALSE]
    /\ net' = Drain(net, "usb")
    /\ UNCHANGED <<mac, ipad>>

WirelessUp(l) ==
    /\ Flap /\ ~env.phys[l]
    /\ env' = [Mark(env, FALSE) EXCEPT !.phys[l] = TRUE]
    /\ UNCHANGED <<net, mac, ipad>>

WirelessDown(l) ==
    /\ Flap /\ env.phys[l]
    /\ env' = [Mark(env, FALSE) EXCEPT !.phys[l] = FALSE]
    /\ net' = IF net.wlKind = l THEN Drain(net, "wl") ELSE net
    /\ UNCHANGED <<mac, ipad>>


EnvNext == PlugUSB \/ UnplugUSB \/ \E l \in WLinks : WirelessUp(l) \/ WirelessDown(l)

Next == EnvNext \/ SysNext
Spec == Init /\ [][Next]_vars

\* The Rest properties mean something only if the system always comes to
\* rest once the environment stops: no cycle of system steps.  Checked as
\* <>[]Rest under weak fairness of the system (the environment may stop).
LiveSpec == Spec /\ WF_vars(SysNext)
Settles  == <>[]Rest

\* Witnesses (must be violated): the session settles in good order on one
\* link, the links change, and it settles in good order on the next.
Switched(a, b) == Rest /\ AnyUp /\ Good /\ env.last = a /\ LinkOf(MacRoute) = b
NeverWiredToWifi  == ~Switched("usb", "wifi")
NeverWifiToWired  == ~Switched("wifi", "usb")
NeverWifiToAwdl   == ~Switched("wifi", "awdl")
NeverAwdlToWifi   == ~Switched("awdl", "wifi")
\* Wired to wired: the cable was pulled and plugged back in, and in the
\* second witness the Mac's link-local address changed meanwhile.
NeverWiredToWired == ~(Switched("usb", "usb") /\ env.cut)
NeverReplugNewAddr == ~(Switched("usb", "usb") /\ env.cut /\ env.lastGen # env.addrGen)

Design == RouteResync /\ AddrOnLink /\ DerivedState /\ IpadResync
=============================================================================
