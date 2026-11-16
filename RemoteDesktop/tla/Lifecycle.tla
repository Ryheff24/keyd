------------------------------ MODULE Lifecycle ------------------------------
(***************************************************************************)
(* PLAN.md step 6 (EndToEnd), connection and session layer, wireless first *)
(* (2026-11-16).  Written because the transport models scope out exactly   *)
(* what broke on hardware: TransportAgreement T1 (one connection per       *)
(* channel, no identity), T6 (no iPad relaunch), T7 (control and media     *)
(* fail together).  Here connections are objects with ids, each side has   *)
(* its own view of each one, the iPad can relaunch, and an Outside party   *)
(* can dial the Mac's listener.  Inventory this is built from:             *)
(* .planning/research/lifecycle-inventory-2026-11-16.md (rows M.., P..).        *)
(*                                                                         *)
(* As built [C] (re-read 2026-11-16; mW = macOS WirelessTransport.m,       *)
(* mS = macOS SessionManager.m, mF = TransportFSM.c):                      *)
(*   Accept (mW:621-680): runs at the listener's new-connection handler,  *)
(*     before TLS.  If a current input connection exists it is replaced   *)
(*     when _allowReconnectTakeover or it is stale (no input activity for *)
(*     2 s), else the candidate is cancelled.  Accept also cancels control *)
(*     recovery (M05).                                                     *)
(*   Listener (mW:731-741, 787-795, 1146-1150): the Bonjour listener is    *)
(*     cancelled at Ready and started again when the current connection    *)
(*     ends (either branch); accepts happen only while it runs (lis).       *)
(*   Ready (mW:692-752): TLS done (pin checked by the verify block);       *)
(*     isConnected=YES, isAWDL from the path, recovery cancelled, media    *)
(*     (DTLS) dialled to the iPad, onConnectionChanged(YES, isAWDL), which *)
(*     runs handleTransportEvent(AVAILABLE) on the session queue.          *)
(*   End (mW:754-800): stale connection -> ignored.  Current: input :=    *)
(*     nil; if a media connection exists and isConnected, "degraded":      *)
(*     isConnected stays YES and control recovery starts (6 s, M15);       *)
(*     else isConnected=NO and onConnectionChanged(NO).                    *)
(*   handleTransportEvent (mS:1009-1066): FSM step (mF: WIFI+AWDL_AVAIL   *)
(*     and same-link AVAIL are no-ops).  DISCONNECTED while STREAMING:     *)
(*     wireless still connected -> re-fire AVAILABLE; else                 *)
(*     startReconnection.  Otherwise, only in CONNECTING/RECONNECTING with *)
(*     a connection: onTransportConnected (mS:1178-1200: gate reset,       *)
(*     generation bump, STREAMING, handshake on the route).  mS:1053 is   *)
(*     the line that skips all of this for a new connection while         *)
(*     STREAMING.                                                          *)
(*   startReconnection (mS:3618-3640): NSTimer scheduled from the session  *)
(*     GCD queue (no run loop): never fires.  Not modelled on wireless:    *)
(*     RECONNECTING is entered only with isConnected NO, and the next      *)
(*     Ready restarts from it; USB (version 2) needs it.                   *)
(*   Frame gate (mS:1472-1477, 1888): encode only while unacked < limit;  *)
(*     the frame is counted as sent (mS:1888) before the send, which       *)
(*     fails with no log when there is no input connection (mW:550-553).   *)
(*     Acks (0x32) arrive on the input connection.  No time escape.        *)
(*   iPad (iS = iPadOS SessionManager.swift): .connecting only at start/  *)
(*     resume/pairing; handshake or any frame -> streaming (P16/P17);      *)
(*     loss while streaming -> reconnecting; acks each frame.              *)
(*                                                                         *)
(* Assumptions:                                                             *)
(*   L1 [I] TCP: messages on a connection arrive in order, once, while it *)
(*        is open; all are lost when it dies.  A cancel or a process exit  *)
(*        is seen by the other side (RST/FIN, or the 4 s heartbeat         *)
(*        deadline of TransportConnections, proved there); a silent link   *)
(*        is seen the same way.  Both are weakly fair here.                *)
(*   L2 [I] TLS pin checks are SecureSession's (proved): an Outside       *)
(*        connection never becomes ready; an owner connection does.        *)
(*   L3 [I] The iPad redials while it has no connection and a link is up  *)
(*        (TransportConnections RedialOnLoss, proved); which link is       *)
(*        TransportConnections' policy, so any up link here.               *)
(*   L4 [U] Whether the Mac ever learns that a dead iPad's DTLS media path *)
(*        is gone (U4): environment action MediaEnd, not fair.             *)
(*   L5 [I] "Stale" (2 s with no input activity) holds for a connection   *)
(*        that is dead or on a silent link; a live one sends heartbeats.   *)
(*   L6 [I] A transport callback and its session-queue hop are one step   *)
(*        (SessionLanes: the hop keeps order).                             *)
(*   L7 [I] Screen changes are an environment action (bounded); a capture *)
(*        the gate refuses is dropped, so "changed and not yet shown"      *)
(*        stays true until a frame goes out (dirty).                       *)
(*   Restart also restarts the HEVC encoder at the stored viewport          *)
(*   (mS:1206 -> _startEncoderAtViewportResolution -> startWithWidth), so  *)
(*   the new connection's first frame comes from a fresh encoder session;  *)
(*   viewport and codec state are version 2.                              *)
(*   iPad connecting timeout (iS:350-372, 8 s): with a link up it only    *)
(*   re-arms and logs "link up but not streaming yet" (a stutter here: it  *)
(*   is the log line of a Rest state that is not Good); with no link it    *)
(*   restarts discovery (TransportConnections' scope).                     *)
(*   Scope of this version: wireless only (USB, viewport and codec next);  *)
(*   the iPad's own media/degraded branch (iW:620-626) is not modelled.   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxConn,      \* connection ids 1..MaxConn
    MaxInst,      \* iPad app instances (relaunches = MaxInst - 1)
    MaxOutside,   \* Outside dials
    MaxFlaps,     \* link down/up events
    MaxChanges,   \* screen changes after the first
    G,            \* ack gate limit (kWiFiAckGateFrames)
    \* mechanisms (all TRUE in Design)
    RestartOnNewConn,   \* a new current connection restarts the session on it
                        \* (handshake, gate reset) whatever the session state
    CountOnSend,        \* the gate counts a frame only when it is queued on
                        \* the current, ready connection
    AuthBeforeDisplace  \* a candidate replaces the current connection only
                        \* after its TLS pin check, never at accept

ASSUME Bounds == {MaxConn, MaxInst, MaxOutside, MaxFlaps, MaxChanges, G} \subseteq Nat
                 /\ MaxInst >= 1 /\ G >= 1
ASSUME Switches == {RestartOnNewConn, CountOnSend, AuthBeforeDisplace}
                   \subseteq BOOLEAN

Insts == 1..MaxInst
Who   == 0..MaxInst          \* 0 = Outside
Links == {"wifi", "awdl"}
CIds  == 1..MaxConn
Fsm0  == {"idle", "wifi", "awdl", "disc"}
Sess  == {"connecting", "streaming", "reconnecting"}

VARIABLES
    cn,     \* cn[c]: connection c (see TypeOK); "free" until dialled
    env,    \* environment: current iPad instance, links, budgets, screen
    mac,    \* the Mac's wireless transport and session
    ipad    \* the current iPad instance
vars == <<cn, env, mac, ipad>>

Free == [st |-> "free", link |-> "wifi", who |-> 0, net |-> "dead", m |-> "none",
         i |-> "none", hs |-> FALSE, fr |-> 0, ak |-> 0, hsSent |-> FALSE]

TypeOK ==
    /\ cn \in [CIds -> [st : {"free", "used"}, link : Links, who : Who,
                         net : {"open", "dead"},
                         m : {"none", "accepted", "ready", "ended"},
                         i : {"none", "dialing", "ready", "ended"},
                         hs : BOOLEAN, fr : 0..G, ak : 0..G, hsSent : BOOLEAN]]
    /\ env \in [inst : Insts, up : [Links -> BOOLEAN], outs : 0..MaxOutside,
                flaps : 0..MaxFlaps, changes : 0..MaxChanges, dirty : BOOLEAN,
                displaced : BOOLEAN]
    /\ mac \in [in : CIds \cup {0}, isConn : BOOLEAN, isAWDL : BOOLEAN, recov : BOOLEAN,
                allowTO : BOOLEAN, med : BOOLEAN, fsm : Fsm0, sess : Sess,
                sc : CIds \cup {0}, u : 0..G, q : 0..G, gc : CIds \cup {0},
                pa : BOOLEAN, rto : BOOLEAN, lis : BOOLEAN]
    /\ ipad \in [in : CIds \cup {0}, isConn : BOOLEAN, sess : Sess]

Init ==
    /\ cn = [c \in CIds |-> Free]
    /\ env = [inst |-> 1, up |-> [l \in Links |-> TRUE], outs |-> 0, flaps |-> 0,
              changes |-> 0, dirty |-> TRUE, displaced |-> FALSE]
    /\ mac = [in |-> 0, isConn |-> FALSE, isAWDL |-> FALSE, recov |-> FALSE,
              allowTO |-> FALSE, med |-> FALSE, fsm |-> "idle", sess |-> "connecting",
              sc |-> 0, u |-> 0, q |-> 0, gc |-> 0, pa |-> FALSE, rto |-> FALSE,
              lis |-> TRUE]
    /\ ipad = [in |-> 0, isConn |-> FALSE, sess |-> "connecting"]

-----------------------------------------------------------------------------
(* Helpers *)

FreeId    == {c \in CIds : cn[c].st = "free"}
Owner(c)  == cn[c].who \in Insts
Live(c)   == c # 0 /\ cn[c].net = "open"
\* Mac cancels c: the TCP connection dies (the iPad sees it, L1).
Kill(f, c) == IF c = 0 THEN f ELSE [f EXCEPT ![c].net = "dead", ![c].m = "ended"]

\* The FSM table for wireless events (mF:62-160, identical in Swift).
FsmStep(s, ev) ==
    CASE s \in {"idle", "disc"} /\ ev = "wifiAvail" -> "wifi"
      [] s \in {"idle", "disc"} /\ ev = "awdlAvail" -> "awdl"
      [] s = "awdl" /\ ev = "wifiAvail"               -> "wifi"
      [] s = "wifi" /\ ev = "wifiUnavail"             -> "disc"
      [] s = "awdl" /\ ev = "awdlUnavail"             -> "disc"
      [] OTHER                                         -> s

\* onTransportConnected (mS:1178-1200): gate reset, STREAMING, handshake on
\* the current input connection (lost if there is none).  sc records the
\* connection the session was (re)started on.
Restart(m, f) ==
    LET c == m.in
    IN [mm |-> [m EXCEPT !.sess = "streaming", !.sc = c, !.u = 0, !.q = 0, !.gc = c],
        ff |-> IF Live(c) THEN [f EXCEPT ![c].hs = TRUE, ![c].hsSent = TRUE] ELSE f]

\* handleTransportEvent (mS:1009-1066).  Its re-fire branch (DISCONNECTED while
\* STREAMING and wireless still connected) needs a second link that ended (USB,
\* version 2): every UNAVAILABLE here is raised with isConnected NO, so it is
\* left out.
Handle(m, f, ev) ==
    LET s1 == FsmStep(m.fsm, ev)
        m1 == [m EXCEPT !.fsm = s1]
    IN IF s1 = "disc" /\ m1.sess = "streaming"
       THEN [mm |-> [m1 EXCEPT !.sess = "reconnecting"], ff |-> f]
       ELSE IF s1 \notin {"idle", "disc"} /\ m1.isConn
               /\ (m1.sess \in {"connecting", "reconnecting"}
                   \/ (RestartOnNewConn /\ m1.sess = "streaming" /\ m1.in # m1.sc
                       /\ m1.in # 0))
       THEN Restart(m1, f)
       ELSE [mm |-> m1, ff |-> f]

-----------------------------------------------------------------------------
(* iPad actions *)

\* Dial: no connection and a link up (L3).
IpadDial ==
    /\ ipad.in = 0
    /\ FreeId # {}
    /\ \E c \in FreeId, l \in Links :
         /\ env.up[l]
         /\ cn' = [cn EXCEPT ![c] = [Free EXCEPT !.st = "used", !.link = l, !.who = env.inst,
                                                 !.net = "open", !.i = "dialing"]]
         /\ ipad' = [ipad EXCEPT !.in = c]
    /\ UNCHANGED <<env, mac>>

\* TLS completes on the iPad's side once the Mac has it ready.
IpadReady ==
    /\ ipad.in # 0 /\ Live(ipad.in)
    /\ cn[ipad.in].m = "ready" /\ cn[ipad.in].i = "dialing"
    /\ cn' = [cn EXCEPT ![ipad.in].i = "ready"]
    /\ ipad' = [ipad EXCEPT !.isConn = TRUE]
    /\ UNCHANGED <<env, mac>>

\* Handshake arrives: streaming (P17).
IpadHandshake ==
    /\ ipad.in # 0 /\ Live(ipad.in) /\ cn[ipad.in].i = "ready" /\ cn[ipad.in].hs
    /\ cn' = [cn EXCEPT ![ipad.in].hs = FALSE]
    /\ ipad' = [ipad EXCEPT !.sess = "streaming"]
    /\ UNCHANGED <<env, mac>>

\* A frame arrives: streaming (P16, even with no handshake) and an ack back.
IpadFrame ==
    LET c == ipad.in IN
    /\ c # 0 /\ Live(c) /\ cn[c].i = "ready" /\ cn[c].fr > 0 /\ ~cn[c].hs
    /\ cn' = [cn EXCEPT ![c].fr = @ - 1, ![c].ak = @ + 1]
    /\ ipad' = [ipad EXCEPT !.sess = "streaming"]
    /\ UNCHANGED <<env, mac>>

\* The iPad sees its connection end (cancelled by the Mac, died, silent): L1.
IpadLoss ==
    LET c == ipad.in IN
    /\ c # 0 /\ cn[c].net = "dead"
    /\ cn' = [cn EXCEPT ![c].i = "ended"]
    /\ ipad' = [ipad EXCEPT !.in = 0, !.isConn = FALSE,
                            !.sess = IF @ = "streaming" THEN "reconnecting" ELSE @]
    /\ UNCHANGED <<env, mac>>

-----------------------------------------------------------------------------
(* Mac actions *)

\* Listener new-connection handler (mW:621-680), before TLS.  As built a
\* candidate replaces the current connection when the reconnect window is armed
\* (allowTO: set by control recovery, cleared at Ready or by a replacement),
\* when the current one is stale (L5), or when it has been pending (accepted,
\* not ready, isConnected NO) for 1.5 s, which time-free is "may be".
MacAccept(c) ==
    /\ mac.lis
    /\ cn[c].st = "used" /\ cn[c].m = "none" /\ cn[c].net = "open"
    /\ \E pendingOld \in BOOLEAN :
       LET cur      == mac.in
           stale    == cur # 0 /\ cn[cur].net = "dead"            \* L5
           pending  == pendingOld /\ cur # 0 /\ cn[cur].m = "accepted" /\ ~mac.isConn
           replace  == cur # 0 /\ (mac.allowTO \/ stale \/ pending)
       IN IF AuthBeforeDisplace
          THEN \* Candidate kept beside the current one; replacement at Ready.
               /\ ~pendingOld
               /\ cn' = [cn EXCEPT ![c].m = "accepted"]
               /\ mac' = mac
               /\ UNCHANGED env
          ELSE IF cur = 0 \/ replace
          THEN /\ cn' = [Kill(cn, cur) EXCEPT ![c].m = "accepted"]
               /\ mac' = [mac EXCEPT !.in = c, !.recov = FALSE,
                                     !.allowTO = IF replace THEN FALSE ELSE @,
                                     !.pa = @ \/ (cur = 0 /\ mac.recov)]
               \* ghost: a live owner connection displaced by a connection
               \* whose pin is not yet checked
               /\ env' = [env EXCEPT !.displaced = @ \/ (cur # 0 /\ Live(cur) /\ Owner(cur))]
          ELSE /\ ~pendingOld
               /\ cn' = Kill(cn, c)
               /\ mac' = mac
               /\ UNCHANGED env
    /\ UNCHANGED ipad

\* TLS ready on the Mac (pin checked, L2), then handleTransportEvent(AVAILABLE).
MacReady(c) ==
    /\ cn[c].m = "accepted" /\ Live(c) /\ Owner(c)
    /\ AuthBeforeDisplace \/ c = mac.in
    /\ LET old == IF AuthBeforeDisplace /\ mac.in # c THEN mac.in ELSE 0
           f1  == [Kill(cn, old) EXCEPT ![c].m = "ready"]
           m1  == [mac EXCEPT !.in = c, !.isConn = TRUE, !.isAWDL = (cn[c].link = "awdl"),
                              !.recov = FALSE, !.med = TRUE, !.lis = FALSE]
           r   == Handle(m1, f1, IF cn[c].link = "awdl" THEN "awdlAvail" ELSE "wifiAvail")
       IN /\ cn' = r.ff
          /\ mac' = r.mm
    /\ UNCHANGED <<env, ipad>>

\* An Outside connection fails TLS on the Mac: an end-state for it.
MacTlsFail(c) ==
    /\ cn[c].m = "accepted" /\ ~Owner(c) /\ cn[c].net = "open"
    /\ cn' = Kill(cn, c)
    /\ UNCHANGED <<env, mac, ipad>>

\* The Mac sees connection c end (RST, error, silence deadline: L1), mW:754-800.
MacEnd(c) ==
    /\ cn[c].st = "used" /\ cn[c].m \in {"accepted", "ready"} /\ cn[c].net = "dead"
    /\ IF c # mac.in
       THEN /\ cn' = [cn EXCEPT ![c].m = "ended"]          \* stale: ignored
            /\ mac' = mac
       ELSE IF mac.med /\ mac.isConn
       THEN /\ cn' = [cn EXCEPT ![c].m = "ended"]          \* degraded
            /\ mac' = [mac EXCEPT !.in = 0, !.recov = TRUE, !.allowTO = TRUE, !.lis = TRUE]
       ELSE LET m1 == [mac EXCEPT !.in = 0, !.isConn = FALSE, !.allowTO = FALSE, !.recov = FALSE,
                                  !.med = FALSE, !.lis = TRUE]
                r  == Handle(m1, [cn EXCEPT ![c].m = "ended"],
                             IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail")
            IN /\ cn' = r.ff
               /\ mac' = r.mm
    /\ UNCHANGED <<env, ipad>>

\* An Outside connection the Mac accepted ends while current (its TLS failed):
\* covered by MacEnd once MacTlsFail killed it.

\* The heartbeat deadline (mW handleSilentLinkLossAfterNs, 4 s with no byte)
\* drops a dead current connection: never degraded, media cancelled, listener
\* restarted, UNAVAILABLE.  Log: "LC MacSilent".
MacSilent ==
    LET c == mac.in IN
    /\ c # 0 /\ cn[c].m = "ready" /\ cn[c].net = "dead"
    /\ LET m1 == [mac EXCEPT !.in = 0, !.isConn = FALSE, !.allowTO = FALSE, !.recov = FALSE,
                             !.med = FALSE, !.lis = TRUE]
           r  == Handle(m1, [cn EXCEPT ![c].m = "ended"],
                        IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail")
       IN /\ cn' = r.ff
          /\ mac' = r.mm
    /\ UNCHANGED <<env, ipad>>

\* Control recovery times out (M15, 6 s): isConnected=NO, UNAVAILABLE.
MacRecoveryTimeout ==
    /\ mac.recov /\ mac.in = 0
    /\ LET m1 == [mac EXCEPT !.recov = FALSE, !.isConn = FALSE, !.allowTO = FALSE, !.med = FALSE,
                              !.rto = TRUE]
           r  == Handle(m1, cn, IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail")
       IN /\ cn' = r.ff
          /\ mac' = r.mm
    /\ UNCHANGED <<env, ipad>>

\* Encode and send one frame (mS:1472-1477, 1888; mW:550-553).
MacEncode ==
    LET c == mac.in
        sendable == c # 0 /\ cn[c].m = "ready"
    IN
    /\ mac.sess = "streaming" /\ env.dirty /\ mac.u < G
    /\ CountOnSend => sendable
    /\ env' = [env EXCEPT !.dirty = FALSE]
    /\ IF sendable /\ Live(c)
       THEN /\ cn' = [cn EXCEPT ![c].fr = @ + 1]
            /\ mac' = [mac EXCEPT !.u = @ + 1, !.q = @ + 1]
       ELSE /\ cn' = cn                                  \* nothing on the wire
            /\ mac' = [mac EXCEPT !.u = @ + 1,
                                  !.q = IF sendable THEN @ + 1 ELSE @]  \* sent into a dead conn counts
    /\ UNCHANGED ipad

\* An ack arrives on the current connection.
MacAck ==
    LET c == mac.in IN
    /\ c # 0 /\ Live(c) /\ cn[c].ak > 0
    /\ cn' = [cn EXCEPT ![c].ak = @ - 1]
    /\ mac' = [mac EXCEPT !.u = IF @ > 0 THEN @ - 1 ELSE 0, !.q = IF @ > 0 THEN @ - 1 ELSE 0]
    /\ UNCHANGED <<env, ipad>>

-----------------------------------------------------------------------------
(* Environment *)

\* The iPad app is relaunched: the old instance's connections die (L1).
Relaunch ==
    /\ env.inst < MaxInst
    /\ cn' = [c \in CIds |-> IF cn[c].who = env.inst /\ cn[c].st = "used"
                             THEN [cn[c] EXCEPT !.net = "dead"] ELSE cn[c]]
    /\ env' = [env EXCEPT !.inst = @ + 1]
    /\ ipad' = [in |-> 0, isConn |-> FALSE, sess |-> "connecting"]
    /\ UNCHANGED mac

\* The Mac learns the media path is gone (L4, not fair), and reacts as
\* handleActiveMediaPathLoss does (mW): with a healthy control path (a ready
\* current connection) only media goes; otherwise, if there was a session, the
\* control connection is cancelled too, the listener restarted, UNAVAILABLE.
\* Logs: "LC MediaEnd branch=disconnect" for the second.
MediaEnd ==
    LET c       == mac.in
        healthy == c # 0 /\ mac.isConn /\ cn[c].m = "ready"
        recover == (c # 0 \/ mac.isConn) /\ ~healthy
    IN /\ mac.med
       /\ IF recover
          THEN LET m1 == [mac EXCEPT !.in = 0, !.recov = FALSE, !.isConn = FALSE, !.allowTO = FALSE,
                                     !.med = FALSE, !.lis = TRUE]
                   r  == Handle(m1, Kill(cn, c), IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail")
               IN /\ cn' = r.ff
                  /\ mac' = r.mm
          ELSE /\ cn' = cn
               /\ mac' = [mac EXCEPT !.med = FALSE]
       /\ UNCHANGED <<env, ipad>>

\* Outside dials the Mac's listener.
OutsideDial ==
    /\ env.outs < MaxOutside /\ FreeId # {}
    /\ \E c \in FreeId, l \in Links :
         /\ env.up[l]
         /\ cn' = [cn EXCEPT ![c] = [Free EXCEPT !.st = "used", !.link = l, !.who = 0,
                                                 !.net = "open"]]
    /\ env' = [env EXCEPT !.outs = @ + 1]
    /\ UNCHANGED <<mac, ipad>>

\* A link goes down (its connections go silent and die: L1) or comes back.
Flap(l) ==
    /\ env.flaps < MaxFlaps
    /\ env' = [env EXCEPT !.flaps = @ + 1, !.up[l] = ~@]
    /\ cn' = IF env.up[l]
             THEN [c \in CIds |-> IF cn[c].link = l /\ cn[c].st = "used"
                                  THEN [cn[c] EXCEPT !.net = "dead"] ELSE cn[c]]
             ELSE cn
    /\ UNCHANGED <<mac, ipad>>

\* The screen changes.
Change ==
    /\ env.changes < MaxChanges
    /\ env' = [env EXCEPT !.changes = @ + 1, !.dirty = TRUE]
    /\ UNCHANGED <<cn, mac, ipad>>

-----------------------------------------------------------------------------
SysNext ==
    \/ IpadDial \/ IpadReady \/ IpadHandshake \/ IpadFrame \/ IpadLoss
    \/ \E c \in CIds : MacAccept(c) \/ MacReady(c) \/ MacTlsFail(c) \/ MacEnd(c)
    \/ MacSilent \/ MacRecoveryTimeout \/ MacEncode \/ MacAck

EnvNext == Relaunch \/ MediaEnd \/ OutsideDial \/ (\E l \in Links : Flap(l)) \/ Change

Next == SysNext \/ EnvNext

Spec == Init /\ [][Next]_vars

FairSpec ==
    /\ Spec
    /\ WF_vars(IpadDial) /\ WF_vars(IpadReady) /\ WF_vars(IpadHandshake)
    /\ WF_vars(IpadFrame) /\ WF_vars(IpadLoss)
    /\ \A c \in CIds : WF_vars(MacAccept(c)) /\ WF_vars(MacReady(c))
                       /\ WF_vars(MacTlsFail(c)) /\ WF_vars(MacEnd(c))
    /\ WF_vars(MacSilent) /\ WF_vars(MacRecoveryTimeout) /\ WF_vars(MacEncode)
    /\ WF_vars(MacAck)

-----------------------------------------------------------------------------
(* Properties *)

\* The gate counts only frames that were actually queued (CountOnSend).
CountsOnlySent == mac.u = mac.q

\* While streaming over a ready connection, the session was (re)started on it:
\* handshake and gate belong to the current connection (RestartOnNewConn).
SessionOnCurrent ==
    (mac.sess = "streaming" /\ mac.in # 0 /\ cn[mac.in].m = "ready")
        => (mac.sc = mac.in /\ mac.gc = mac.in)

\* No frame is queued on a connection the handshake was not sent on.
HandshakeBeforeFrames == \A c \in CIds : cn[c].fr > 0 => cn[c].hsSent

\* Outside never displaces a live, ready owner connection (AuthBeforeDisplace).
OnlyOwnerDisplaces == ~env.displaced

\* At rest (no system step enabled), with a link up and connection ids left,
\* both sides stream on one live owner connection and the screen is shown.
Rest == ~ENABLED SysNext

\* Rest written out from the action guards (for TLAPS); RestIsQuiet checks it.
Quiet ==
    /\ ~(ipad.in = 0 /\ FreeId # {} /\ \E l \in Links : env.up[l])
    /\ ipad.in # 0 => /\ cn[ipad.in].net = "open"
                      /\ ~(cn[ipad.in].m = "ready" /\ cn[ipad.in].i = "dialing")
                      /\ ~(cn[ipad.in].i = "ready" /\ cn[ipad.in].hs)
                      /\ ~(cn[ipad.in].i = "ready" /\ cn[ipad.in].fr > 0)
    /\ \A c \in CIds :
         /\ ~(mac.lis /\ cn[c].st = "used" /\ cn[c].m = "none" /\ cn[c].net = "open")
         /\ ~(cn[c].m = "accepted" /\ cn[c].net = "open" /\ Owner(c)
              /\ (AuthBeforeDisplace \/ c = mac.in))
         /\ ~(cn[c].m = "accepted" /\ cn[c].net = "open" /\ ~Owner(c))
         /\ ~(cn[c].st = "used" /\ cn[c].m \in {"accepted", "ready"} /\ cn[c].net = "dead")
    /\ ~(mac.recov /\ mac.in = 0)
    /\ ~(mac.sess = "streaming" /\ env.dirty /\ mac.u < G
         /\ (CountOnSend => (mac.in # 0 /\ cn[mac.in].m = "ready")))
    /\ ~(mac.in # 0 /\ cn[mac.in].net = "open" /\ cn[mac.in].ak > 0)
RestIsQuiet == Rest <=> Quiet
Good ==
    /\ mac.sess = "streaming" /\ ipad.sess = "streaming"
    /\ mac.in # 0 /\ mac.in = ipad.in /\ Live(mac.in) /\ cn[mac.in].who = env.inst
    /\ ~env.dirty
RestGood == (Rest /\ (\E l \in Links : env.up[l]) /\ FreeId # {}) => Good

\* Every behaviour reaches rest (no livelock).
Settles == <>[]Rest

\* Fidelity: the state seen on hardware (pid 98733: degraded takeover, gate
\* full at G, iPad connecting, nothing enabled) is reachable as built.
NotObservedHang == ~(Rest /\ env.inst > 1 /\ ipad.sess = "connecting" /\ ipad.isConn
                     /\ mac.sess = "streaming" /\ mac.u = G /\ mac.q < G /\ mac.pa)

\* Fidelity: pid 99751 (degraded, no replacement inside the window, recovery
\* timeout, RECONNECTING, then a new connection) recovers as built.
NotObservedRecovery == ~(mac.rto /\ ~mac.pa /\ env.inst > 1 /\ Good)

\* Witness: Outside dialled and the relaunched owner still ends Good.
NeverGoodUnderAttack == ~(Rest /\ Good /\ env.outs > 0 /\ env.inst > 1)

\* Witness: some behaviour relaunches and gets back to Good.
NeverRecoversAfterRelaunch == ~(env.inst > 1 /\ Good)
-----------------------------------------------------------------------------
(* Design and the inductive invariant (LifecycleProofs; TLC checks Inv too). *)

Design == RestartOnNewConn /\ CountOnSend /\ AuthBeforeDisplace

\* The session, gate and handshake belong to a ready current connection.
InvCur == (mac.in # 0) => /\ cn[mac.in].m = "ready" /\ mac.isConn /\ mac.sess = "streaming"
                          /\ cn[mac.in].who \in Insts
                          /\ mac.sc = mac.in /\ mac.gc = mac.in /\ cn[mac.in].hsSent
\* A connection not yet ready is not current and carries nothing.
InvFresh == \A c \in CIds : cn[c].m \in {"none", "accepted"} =>
               /\ mac.in # c /\ mac.sc # c
               /\ cn[c].fr = 0 /\ cn[c].ak = 0 /\ ~cn[c].hs /\ ~cn[c].hsSent
InvFree == \A c \in CIds : cn[c].st = "free" => cn[c] = Free
\* The iPad's connection is its current instance's, dialing or ready.
InvIpad == ipad.in # 0 => /\ cn[ipad.in].st = "used" /\ cn[ipad.in].who = env.inst
                          /\ cn[ipad.in].i \in {"dialing", "ready"}
InvIReady == \A c \in CIds : cn[c].i = "ready" => cn[c].m \in {"ready", "ended"}
\* A ready, open connection is the Mac's current one.
InvOneReady == \A c \in CIds : (cn[c].m = "ready" /\ cn[c].net = "open") => mac.in = c
InvEnded == \A c \in CIds : cn[c].m = "ended" => cn[c].net = "dead"
\* A consumed handshake means the iPad streams.
InvHs == (ipad.in # 0 /\ cn[ipad.in].hsSent /\ ~cn[ipad.in].hs) => ipad.sess = "streaming"
\* The gate is exactly the frames and acks in flight on the current connection.
InvGate == (mac.in # 0 /\ cn[mac.in].net = "open") => mac.u = cn[mac.in].fr + cn[mac.in].ak
InvSum == \A c \in CIds : cn[c].fr + cn[c].ak <= G
\* The listener runs whenever the Mac has no current connection.
InvListen == mac.in = 0 => mac.lis
\* Every live owner connection is the iPad's current one.
InvLiveOwner == \A c \in CIds : (cn[c].st = "used" /\ cn[c].net = "open" /\ cn[c].who \in Insts)
                                 => c = ipad.in

Inv == /\ TypeOK /\ CountsOnlySent /\ OnlyOwnerDisplaces /\ HandshakeBeforeFrames
       /\ InvCur /\ InvFresh /\ InvFree /\ InvIpad /\ InvIReady /\ InvOneReady /\ InvEnded
       /\ InvHs /\ InvGate /\ InvSum /\ InvListen /\ InvLiveOwner

=============================================================================
