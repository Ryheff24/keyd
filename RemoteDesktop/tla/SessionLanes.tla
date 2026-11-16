----------------------------- MODULE SessionLanes -----------------------------
(***************************************************************************)
(* Which queue runs what on the Mac, for input latency.  One link's        *)
(* transport queue T, a session queue S, the injector queue J.             *)
(*                                                                         *)
(* As built [C] (2026-11-15):                                              *)
(*   Each transport's nw_connection callbacks run on its own serial        *)
(*   _transportQueue (WirelessTransport.m:632, USBNetworkTransport.m:1048).*)
(*   SessionManager handles everything inline on that queue:               *)
(*     onInputReceived -> handleReceivedInputEvent (SessionManager.m:2433):*)
(*       pointer/key -> InputInjector (dispatch_async to J)                *)
(*       latency probe, clock sync -> reply at once                        *)
(*       viewport report -> start HEVC encoder (~400 ms, run 20:06:12.6)   *)
(*       resolution match / mode change -> display mode change             *)
(*     onConnectionChanged -> transport FSM -> onTransportConnected:       *)
(*       handshake, encoder, registers one-shot onMediaChannelReady        *)
(*       BEFORE the transport starts the media channel (same callback)     *)
(*     onMediaChannelReady -> _beginCapture (synthetic file open blocked   *)
(*       28 s on a Documents consent, run 20:06:14.5-42.8 [O])            *)
(*   So any slow session step delays every pointer and key message queued  *)
(*   behind it on T.                                                       *)
(*                                                                         *)
(* Design:                                                                 *)
(*   T keeps only non-blocking work: realtime messages (pointer, key,      *)
(*   HELD, text, probe, clock sync, keepalive, test control) are handled   *)
(*   inline; pointer/key go on to J (serial).  Every other message and     *)
(*   every transport callback is forwarded, in order, to one serial S.     *)
(*   onMediaChannelReady is set once, for good, and only forwards to S.    *)
(*   The transport keeps an atomic mediaReady flag.  On S, connect sets    *)
(*   awaiting and starts capture at once if mediaReady already holds; the  *)
(*   forwarded media-ready starts capture only if still awaiting; both     *)
(*   clear awaiting (ReadyCheck, Once).                                    *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  L1 [C] dispatch serial queues are FIFO and run one block at a time;    *)
(*         dispatch_async from one queue to another preserves the order of *)
(*         the blocks it submits.                                          *)
(*  L2 [C] An nw_connection delivers its callbacks on the queue set with   *)
(*         nw_connection_set_queue, one at a time.                         *)
(*  L3 [I] Realtime handlers do not block: InputInjector only dispatches,  *)
(*         replies are nw_connection_send (async).  Heavy = any handler    *)
(*         that may block; modelled as Heavy steps of its queue.           *)
(*  L4 [I] The media channel becomes ready only after the transport has    *)
(*         processed the connection's ready event (the iPad opens DTLS     *)
(*         after the TCP handshake).                                       *)
(*  L5 [C] The transport ignores READY from a media connection that is not *)
(*         its current one (WirelessTransport.m:826, "stale DTLS").       *)
(*  L6 [I] A link going down clears mediaReady on T before T handles the   *)
(*         next connection; reconnects arrive through the same T.          *)
(* Reconnect: connections 1..MaxConn on one link.  A forwarded media-ready *)
(* starts capture only while mediaReady holds when S runs it (FreshCheck), *)
(* so a media-ready of a link already down cannot start capture.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxRT,        \* pointer/key messages the iPad sends
    MaxCtl,       \* heavy control messages (viewport, resolution, mode)
    MaxConn,      \* connections (reconnects) on the link
    Heavy,        \* steps a heavy handler occupies its queue
    Split,        \* FALSE = as built: session work inline on T
    ForwardCtl,   \* control messages go to S (else handled inline on T)
    ReadyCheck,   \* permanent forwarding callback + awaiting + mediaReady check on connect
    Once,         \* starting capture clears awaiting
    FreshCheck,   \* a forwarded media-ready needs mediaReady when S runs it
    SerialS,      \* S is a serial FIFO queue
    SerialJ       \* J is a serial FIFO queue

VARIABLES tq, tBusy, sq, sBusy, jq, rtSent, ctlSent,
          conn,         \* the iPad's connection number (environment)
          connUp,       \* that connection is up (environment)
          tConn,        \* the connection T last saw become ready
          mediaStarted, mediaArrived, mediaUp,
          cbRegistered, awaiting, injected, ctlDone,
          captures,     \* captures[c]: capture starts for connection c
          early         \* a capture started while media was not ready

vars == <<tq, tBusy, sq, sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted,
          mediaArrived, mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>

Item(k, n) == [k |-> k, n |-> n]
Conns == 1..MaxConn

Init ==
    /\ tq = <<>> /\ tBusy = 0 /\ sq = <<>> /\ sBusy = 0 /\ jq = <<>>
    /\ rtSent = 0 /\ ctlSent = 0
    /\ conn = 0 /\ connUp = FALSE /\ tConn = 0
    /\ mediaStarted = FALSE /\ mediaArrived = FALSE /\ mediaUp = FALSE
    /\ cbRegistered = FALSE /\ awaiting = FALSE
    /\ injected = <<>> /\ ctlDone = <<>> /\ captures = [c \in Conns |-> 0] /\ early = FALSE

\* Start capture for connection c (records a start while media is not ready).
Capture(c) == captures' = [captures EXCEPT ![c] = @ + 1] /\ early' = (early \/ ~mediaUp)

(* ---- the iPad and the network ---- *)
SendRT == connUp /\ rtSent < MaxRT /\ rtSent' = rtSent + 1 /\ tq' = Append(tq, Item("rt", rtSent + 1))
          /\ UNCHANGED <<tBusy, sq, sBusy, jq, ctlSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                         mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>
SendCtl == connUp /\ ctlSent < MaxCtl /\ ctlSent' = ctlSent + 1 /\ tq' = Append(tq, Item("ctl", ctlSent + 1))
          /\ UNCHANGED <<tBusy, sq, sBusy, jq, rtSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                         mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>
ConnArrive == ~connUp /\ conn < MaxConn /\ conn' = conn + 1 /\ connUp' = TRUE
          /\ tq' = Append(tq, Item("conn", conn + 1))
          /\ UNCHANGED <<tBusy, sq, sBusy, jq, rtSent, ctlSent, tConn, mediaStarted, mediaArrived,
                         mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>
ConnDrop == connUp /\ connUp' = FALSE /\ tq' = Append(tq, Item("down", conn))
          /\ UNCHANGED <<tBusy, sq, sBusy, jq, rtSent, ctlSent, conn, tConn, mediaStarted, mediaArrived,
                         mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>
\* L4: DTLS completes only after T handled the TCP ready event; it may complete for a
\* connection that has since dropped (T ignores it then, L5).
MediaArrive == mediaStarted /\ ~mediaArrived /\ mediaArrived' = TRUE
          /\ tq' = Append(tq, Item("media", tConn))
          /\ UNCHANGED <<tBusy, sq, sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted,
                         mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>

(* ---- T: the transport queue ---- *)
TWork == tBusy > 0 /\ tBusy' = tBusy - 1
         /\ UNCHANGED <<tq, sq, sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted,
                        mediaArrived, mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>

TRT == /\ tBusy = 0 /\ tq # <<>> /\ Head(tq).k = "rt"
       /\ tq' = Tail(tq) /\ jq' = Append(jq, Head(tq).n)
       /\ UNCHANGED <<tBusy, sq, sBusy, rtSent, ctlSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                      mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>

TCtl == /\ tBusy = 0 /\ tq # <<>> /\ Head(tq).k = "ctl" /\ tq' = Tail(tq)
        /\ IF Split /\ ForwardCtl
              THEN sq' = Append(sq, Head(tq)) /\ UNCHANGED <<tBusy, ctlDone>>
              ELSE ctlDone' = Append(ctlDone, Head(tq).n) /\ tBusy' = Heavy /\ UNCHANGED sq
        /\ UNCHANGED <<sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                       mediaUp, cbRegistered, awaiting, injected, captures, early>>

\* Ready event: the session callback, then the transport starts the media channel.
TConn == /\ tBusy = 0 /\ tq # <<>> /\ Head(tq).k = "conn" /\ tq' = Tail(tq)
         /\ tConn' = Head(tq).n /\ mediaStarted' = TRUE /\ mediaArrived' = FALSE
         /\ IF Split
               THEN sq' = Append(sq, Head(tq)) /\ UNCHANGED <<tBusy, cbRegistered>>
               ELSE cbRegistered' = TRUE /\ tBusy' = Heavy /\ UNCHANGED sq   \* inline handshake + encoder
         /\ UNCHANGED <<sBusy, jq, rtSent, ctlSent, conn, connUp, mediaUp, awaiting,
                        injected, ctlDone, captures, early>>

\* Link down: the transport clears mediaReady (L6), then tells the session.
TDown == /\ tBusy = 0 /\ tq # <<>> /\ Head(tq).k = "down" /\ tq' = Tail(tq)
         /\ mediaUp' = FALSE /\ mediaStarted' = FALSE
         /\ IF Split
               THEN sq' = Append(sq, Head(tq)) /\ UNCHANGED <<cbRegistered, awaiting>>
               ELSE cbRegistered' = FALSE /\ UNCHANGED <<sq, awaiting>>
         /\ UNCHANGED <<tBusy, sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaArrived,
                        injected, ctlDone, captures, early>>

TMedia == /\ tBusy = 0 /\ tq # <<>> /\ Head(tq).k = "media" /\ tq' = Tail(tq)
          /\ IF Head(tq).n # tConn \/ ~mediaStarted
                THEN UNCHANGED <<mediaUp, cbRegistered, captures, early, tBusy, sq>>   \* stale (L5)
             ELSE /\ mediaUp' = TRUE
                  /\ IF ~Split
                        THEN IF cbRegistered   \* one-shot callback, inline _beginCapture
                                THEN /\ cbRegistered' = FALSE /\ tBusy' = Heavy /\ UNCHANGED sq
                                     /\ captures' = [captures EXCEPT ![tConn] = @ + 1] /\ UNCHANGED early
                                ELSE UNCHANGED <<cbRegistered, captures, early, tBusy, sq>>
                     ELSE IF ReadyCheck        \* permanent callback: always forward
                        THEN sq' = Append(sq, Item("mediaHop", tConn)) /\ UNCHANGED <<cbRegistered, captures, early, tBusy>>
                     ELSE IF cbRegistered      \* naive port: one-shot registered later, on S
                        THEN cbRegistered' = FALSE /\ sq' = Append(sq, Item("mediaHop", tConn))
                             /\ UNCHANGED <<captures, early, tBusy>>
                        ELSE UNCHANGED <<cbRegistered, captures, early, tBusy, sq>>
          /\ UNCHANGED <<sBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                         awaiting, injected, ctlDone>>

(* ---- S: the session queue (only when Split) ---- *)
SWork == sBusy > 0 /\ sBusy' = sBusy - 1
         /\ UNCHANGED <<tq, tBusy, sq, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted,
                        mediaArrived, mediaUp, cbRegistered, awaiting, injected, ctlDone, captures, early>>

\* SerialS: take the head; otherwise any item (a concurrent queue).
STake(i) ==
    /\ sBusy = 0 /\ i \in 1..Len(sq) /\ (SerialS => i = 1)
    /\ LET h == sq[i] IN
       /\ sq' = SubSeq(sq, 1, i - 1) \o SubSeq(sq, i + 1, Len(sq))
       /\ sBusy' = IF h.k = "down" THEN 0 ELSE Heavy
       /\ CASE h.k = "ctl" ->
                 ctlDone' = Append(ctlDone, h.n) /\ UNCHANGED <<cbRegistered, awaiting, captures, early>>
            [] h.k = "down" ->
                 awaiting' = FALSE /\ UNCHANGED <<ctlDone, cbRegistered, captures, early>>
            [] h.k = "conn" /\ ~ReadyCheck ->
                 cbRegistered' = TRUE /\ UNCHANGED <<ctlDone, awaiting, captures, early>>
            [] h.k = "conn" /\ ReadyCheck ->
                 IF mediaUp
                    THEN Capture(h.n) /\ awaiting' = ~Once /\ UNCHANGED <<ctlDone, cbRegistered>>
                    ELSE awaiting' = TRUE /\ UNCHANGED <<ctlDone, cbRegistered, captures, early>>
            [] h.k = "mediaHop" /\ ~ReadyCheck ->
                 Capture(h.n) /\ UNCHANGED <<ctlDone, cbRegistered, awaiting>>
            [] h.k = "mediaHop" /\ ReadyCheck ->
                 IF awaiting /\ (FreshCheck => mediaUp)
                    THEN Capture(h.n) /\ awaiting' = ~Once /\ UNCHANGED <<ctlDone, cbRegistered>>
                    ELSE UNCHANGED <<ctlDone, cbRegistered, awaiting, captures, early>>
    /\ UNCHANGED <<tq, tBusy, jq, rtSent, ctlSent, conn, connUp, tConn, mediaStarted, mediaArrived,
                   mediaUp, injected>>

(* ---- J: the injector queue ---- *)
JPost(i) ==
    /\ i \in 1..Len(jq) /\ (SerialJ => i = 1)
    /\ injected' = Append(injected, jq[i])
    /\ jq' = SubSeq(jq, 1, i - 1) \o SubSeq(jq, i + 1, Len(jq))
    /\ UNCHANGED <<tq, tBusy, sq, sBusy, rtSent, ctlSent, conn, connUp, tConn, mediaStarted,
                   mediaArrived, mediaUp, cbRegistered, awaiting, ctlDone, captures, early>>

Next == \/ SendRT \/ SendCtl \/ ConnArrive \/ ConnDrop \/ MediaArrive
        \/ TWork \/ TRT \/ TCtl \/ TConn \/ TDown \/ TMedia
        \/ SWork \/ \E i \in 1..Len(sq) : STake(i)
        \/ \E i \in 1..Len(jq) : JPost(i)

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(MediaArrive)
               /\ WF_vars(TWork) /\ WF_vars(TRT) /\ WF_vars(TCtl) /\ WF_vars(TConn)
               /\ WF_vars(TDown) /\ WF_vars(TMedia)
               /\ WF_vars(SWork) /\ WF_vars(\E i \in 1..Len(sq) : STake(i))
               /\ WF_vars(\E i \in 1..Len(jq) : JPost(i))

(* ---- properties ---- *)
\* No pointer/key message waits on T while T runs a blocking handler.
RTNotBehindHeavy == tBusy > 0 => \A i \in 1..Len(tq) : tq[i].k # "rt"
\* Pointer/key messages reach the injector, and post, in the order sent.
RTInOrder == \A i \in 1..Len(injected) : injected[i] = i
\* Control messages run in the order sent.
CtlInOrder == \A i \in 1..Len(ctlDone) : ctlDone[i] = i
\* Capture starts at most once per connection.
CaptureAtMostOnce == \A c \in Conns : captures[c] <= 1
\* Capture never starts while the media channel is down.
CaptureOnlyWhenReady == ~early
\* A connection whose media channel is ready gets capture, unless it drops first.
CaptureStarts == \A c \in Conns :
    (conn = c /\ connUp /\ tConn = c /\ mediaUp) ~> (captures[c] >= 1 \/ conn # c \/ ~connUp)

\* Witness (must be violated): everything can complete, on the last connection too.
NoProgress == ~(captures[MaxConn] = 1 /\ Len(injected) = MaxRT /\ Len(ctlDone) = MaxCtl)
=============================================================================
