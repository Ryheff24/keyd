----------------------------- MODULE WiFiSendLoop -----------------------------
(***************************************************************************)
(* The Mac's Wi-Fi HEVC send loop over the TLS/TCP control connection, and *)
(* the iPad's reaction to a missing frame.  What gates encoding, what the  *)
(* gate counts, where frames queue, and who asks for keyframes.            *)
(*                                                                         *)
(* As built [C] (2026-11-15):                                              *)
(*   capture -> pre-encode gate (macOS SessionManager.m:1402-1417):        *)
(*     if inFlight >= L: maybe stall-reset (below), else skip the capture. *)
(*     A skipped capture is never encoded, so it leaves no seq gap: the    *)
(*     encoder numbers its outputs (HEVCEncoder.m:665).                    *)
(*   encoder output -> post-encode check (SessionManager.m:1795-1832):     *)
(*     inFlight += 1; if inFlight > L: drop the encoded frame (a seq gap   *)
(*     the iPad sees) and requestKeyframe unless one was asked < 120 ms    *)
(*     ago.  Otherwise nw_connection_send(frame), completion -> inFlight-1 *)
(*     if the frame's generation is current (:1843-1870).                  *)
(*   stall reset (maybeRecoverWiFiTCPInFlightStall, :2448-2523): after     *)
(*     inFlight stays >= L for 320 ms with no completion for 260 ms (and   *)
(*     not within 1.2 s of the last): inFlight := 0, generation += 1,      *)
(*     requestKeyframe (same 120 ms cooldown).  The frames already handed  *)
(*     to TCP stay queued; their completions are ignored.                  *)
(*   requestKeyframe sets a flag; the next encoded frame is an IDR         *)
(*     (HEVCEncoder.m:209).  Periodic IDR every 300 s only (:169).         *)
(*   iPad (UDPReassembler.swift:407-423, 343-361, 469-484): a P frame      *)
(*     after a seq gap -> await a keyframe, drop every frame until one     *)
(*     arrives; on entering (only then) ask the Mac for a keyframe         *)
(*     (SessionManager.swift:1373-1389), suppressed if one was asked       *)
(*     < 500 ms ago, never retried.  A keyframe after a gap is shown.      *)
(*   Mac on the iPad's request (SessionManager.m:3154): requestKeyframe.   *)
(*                                                                         *)
(* What the gate counts [O] (run 8148018, 11,286 frames, scratch ftq.py):  *)
(*   nw send completion - submit: p50 1.0 ms, p90 6.7 ms, p99 199 ms.      *)
(*   iPad last byte - completion (min-normalised): p50 34 ms, p90 161 ms,  *)
(*   p99 388 ms, max 794 ms.  A completion means the kernel took the       *)
(*   bytes, not that the iPad has them: the queue the user sees lives in   *)
(*   the socket buffer and the air, which inFlight never counts.  Run      *)
(*   4540d26 (docs/research/wifi-frame-timeline-4540d26.md): queue delay   *)
(*   p90 803 ms, max 2.9 s, 2-4 keyframes/s, 126 ignored completions.      *)
(*                                                                         *)
(* Model: frames are "K" or "P".  enc = encoder pipeline (at most P        *)
(* frames); nwq = handed to nw_connection_send, completion pending (this   *)
(* is what inFlight counts); wire = completed (socket buffer and air), at  *)
(* most SockCap; the iPad takes wire's head when the link is up.  Each     *)
(* sent frame carries `gap` (a drop came just before it) and its           *)
(* generation.  unacked = frames sent and not yet acknowledged by the iPad *)
(* (AckGate only; as built nothing acks).  Time: Tick ends both cooldowns. *)
(*                                                                         *)
(* Design switches:                                                        *)
(*   AckGate:      the iPad acknowledges each media frame it receives      *)
(*                 (cumulative seq, on the input connection); the Mac      *)
(*                 encodes a capture only while unacked < L.  The gate     *)
(*                 counts the real queue: nw, socket, air.                 *)
(*   NoPostDrop:   an encoded frame is always sent: no seq gaps, so no     *)
(*                 iPad recovery and no drop-driven keyframes.             *)
(*   NoBlindReset: no stall reset.  The count only falls when frames       *)
(*                 leave (acks, or a new connection: TransportConnections).*)
(* Not modelled: the scheduler's usleep spacing (SessionManager.m:1606-    *)
(* 1790) changes timing, not state; the design removes it from the         *)
(* ack-gated path because the gate paces.                                  *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  S1 [C] TCP is reliable and ordered: nwq -> wire -> iPad is FIFO, and   *)
(*         acks on the input connection are not lost.                      *)
(*  S2 [O] The kernel takes a frame when its buffer has room: completion   *)
(*         needs Len(wire) < SockCap; SockCap is far above L (above).      *)
(*  S3 [O] The link can hold bytes (no delivery) at most MaxStalls times;  *)
(*         a hold ends (WF Resume).                                        *)
(*  S4 [I] The encoder holds at most P frames (VideoToolbox realtime).     *)
(*  S5 [I] The stall reset's timing thresholds can be met whenever         *)
(*         inFlight >= L: modelled as an unfair action, at most MaxResets. *)
(*  S6 [I] Captures never stop (WF Capture while the gate is open).        *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    L,          \* gate limit (kMaxMediaSendsInFlightWiFi = 3)
    P,          \* encoder pipeline depth
    SockCap,    \* frames the socket buffer and air can hold
    MaxStalls, MaxResets,
    AckGate, NoPostDrop, NoBlindReset

Kinds == {"K", "P"}
Frame(gs) == [k : Kinds, gap : BOOLEAN, g : gs]

VARIABLES
    force,      \* the encoder makes the next frame an IDR
    enc,        \* Seq(Kinds): in the encoder
    nwq,        \* Seq(Frame): submitted, completion pending
    wire,       \* Seq(Frame): kernel buffer and air
    inFlight,   \* the as-built gate's count
    gen,        \* send generation
    pendingGap, \* a frame was dropped after encode; the next one sent follows a gap
    unacked,    \* frames sent, not yet acknowledged
    ackq,       \* acks in transit to the Mac
    kq,         \* ghost: keyframes in enc, nwq, wire (checked against KCount by TLC)
    macCool,    \* the Mac asked for a keyframe < 120 ms ago
    ipadCool,   \* the iPad asked < 500 ms ago
    req,        \* the iPad's keyframe request in transit
    ipad,       \* "ok" | "await" (dropping until a keyframe)
    shown,      \* toggles on each frame the iPad shows
    linkUp, stalls, resets

vars == <<force, enc, nwq, wire, inFlight, gen, pendingGap, unacked, ackq, kq,
          macCool, ipadCool, req, ipad, shown, linkUp, stalls, resets>>

Design == AckGate /\ NoPostDrop /\ NoBlindReset /\ TRUE

TypeOK ==
    /\ force \in BOOLEAN
    /\ enc \in Seq(Kinds)
    /\ nwq \in Seq(Frame(0..MaxResets))
    /\ wire \in Seq(Frame(0..MaxResets))
    /\ inFlight \in Nat /\ gen \in 0..MaxResets
    /\ pendingGap \in BOOLEAN
    /\ unacked \in Nat /\ ackq \in Nat /\ kq \in Nat
    /\ macCool \in BOOLEAN /\ ipadCool \in BOOLEAN /\ req \in BOOLEAN
    /\ ipad \in {"ok", "await"} /\ shown \in {0, 1}
    /\ linkUp \in BOOLEAN /\ stalls \in 0..MaxStalls /\ resets \in 0..MaxResets

Init ==
    /\ force = TRUE                \* a session starts with an IDR
    /\ enc = <<>> /\ nwq = <<>> /\ wire = <<>>
    /\ inFlight = 0 /\ gen = 0 /\ pendingGap = FALSE
    /\ unacked = 0 /\ ackq = 0 /\ kq = 0
    /\ macCool = FALSE /\ ipadCool = FALSE /\ req = FALSE
    /\ ipad = "ok" /\ shown = 0
    /\ linkUp = TRUE /\ stalls = 0 /\ resets = 0

GateOpen == IF AckGate THEN unacked < L ELSE inFlight < L

\* Mac asks the encoder for an IDR, subject to its 120 ms cooldown.
MacAsk ==
    IF macCool THEN UNCHANGED <<force, macCool>>
    ELSE force' = TRUE /\ macCool' = TRUE

------------------------------------------------------------------------------
(* Mac *)

Capture ==
    /\ GateOpen /\ Len(enc) < P
    /\ enc' = Append(enc, IF force THEN "K" ELSE "P")
    /\ kq' = IF force THEN kq + 1 ELSE kq
    /\ force' = FALSE
    /\ UNCHANGED <<nwq, wire, inFlight, gen, pendingGap, unacked, ackq, macCool, ipadCool,
                   req, ipad, shown, linkUp, stalls, resets>>

PostDrop == ~NoPostDrop /\ inFlight + 1 > L

EncodeOut ==
    /\ enc # <<>>
    /\ enc' = Tail(enc)
    /\ IF PostDrop
         THEN /\ pendingGap' = TRUE
              /\ kq' = IF Head(enc) = "K" /\ kq > 0 THEN kq - 1 ELSE kq
              /\ MacAsk
              /\ UNCHANGED <<nwq, inFlight, unacked>>
         ELSE /\ nwq' = Append(nwq, [k |-> Head(enc), gap |-> pendingGap, g |-> gen])
              /\ pendingGap' = FALSE
              /\ inFlight' = inFlight + 1
              /\ unacked' = IF AckGate THEN unacked + 1 ELSE unacked
              /\ UNCHANGED <<kq, force, macCool>>
    /\ UNCHANGED <<wire, gen, ackq, ipadCool, req, ipad, shown, linkUp, stalls, resets>>

\* The kernel takes the head of nwq; its completion runs.
Complete ==
    /\ nwq # <<>> /\ Len(wire) < SockCap
    /\ wire' = Append(wire, Head(nwq))
    /\ nwq' = Tail(nwq)
    /\ inFlight' = IF Head(nwq).g = gen /\ inFlight > 0 THEN inFlight - 1 ELSE inFlight
    /\ UNCHANGED <<force, enc, gen, pendingGap, unacked, ackq, kq, macCool, ipadCool, req,
                   ipad, shown, linkUp, stalls, resets>>

MacAck ==
    /\ ackq > 0
    /\ unacked' = IF unacked >= ackq THEN unacked - ackq ELSE 0
    /\ ackq' = 0
    /\ UNCHANGED <<force, enc, nwq, wire, inFlight, gen, pendingGap, kq, macCool, ipadCool,
                   req, ipad, shown, linkUp, stalls, resets>>

MacKeyReq ==
    /\ req
    /\ req' = FALSE /\ force' = TRUE
    /\ UNCHANGED <<enc, nwq, wire, inFlight, gen, pendingGap, unacked, ackq, kq, macCool,
                   ipadCool, ipad, shown, linkUp, stalls, resets>>

StallReset ==
    /\ ~NoBlindReset /\ inFlight >= L /\ resets < MaxResets
    /\ inFlight' = 0 /\ gen' = gen + 1 /\ resets' = resets + 1
    /\ MacAsk
    /\ UNCHANGED <<enc, nwq, wire, pendingGap, unacked, ackq, kq, ipadCool, req, ipad, shown,
                   linkUp, stalls>>

Tick ==
    /\ macCool \/ ipadCool
    /\ macCool' = FALSE /\ ipadCool' = FALSE
    /\ UNCHANGED <<force, enc, nwq, wire, inFlight, gen, pendingGap, unacked, ackq, kq, req,
                   ipad, shown, linkUp, stalls, resets>>

------------------------------------------------------------------------------
(* iPad *)

\* The iPad receives wire's head and, with AckGate, acknowledges it.
Deliver ==
    /\ linkUp /\ wire # <<>>
    /\ wire' = Tail(wire)
    /\ ackq' = IF AckGate THEN ackq + 1 ELSE ackq
    /\ kq' = IF Head(wire).k = "K" /\ kq > 0 THEN kq - 1 ELSE kq
    /\ LET f == Head(wire) IN
       IF ipad = "await"
         THEN /\ ipad' = IF f.k = "K" THEN "ok" ELSE "await"
              /\ shown' = IF f.k = "K" THEN 1 - shown ELSE shown
              /\ UNCHANGED <<ipadCool, req>>
         ELSE IF f.gap /\ f.k = "P"
           THEN /\ ipad' = "await" /\ shown' = shown
                /\ IF ipadCool THEN UNCHANGED <<ipadCool, req>>
                   ELSE req' = TRUE /\ ipadCool' = TRUE
           ELSE /\ shown' = 1 - shown
                /\ UNCHANGED <<ipad, ipadCool, req>>
    /\ UNCHANGED <<force, enc, nwq, inFlight, gen, pendingGap, unacked, macCool, linkUp,
                   stalls, resets>>

System == Capture \/ EncodeOut \/ Complete \/ MacAck \/ MacKeyReq \/ StallReset \/ Tick
          \/ Deliver

------------------------------------------------------------------------------
(* Environment *)

Stall ==
    /\ linkUp /\ stalls < MaxStalls
    /\ linkUp' = FALSE /\ stalls' = stalls + 1
    /\ UNCHANGED <<force, enc, nwq, wire, inFlight, gen, pendingGap, unacked, ackq, kq,
                   macCool, ipadCool, req, ipad, shown, resets>>

Resume ==
    /\ ~linkUp /\ linkUp' = TRUE
    /\ UNCHANGED <<force, enc, nwq, wire, inFlight, gen, pendingGap, unacked, ackq, kq,
                   macCool, ipadCool, req, ipad, shown, stalls, resets>>

Env == Stall \/ Resume

Next == System \/ Env

Spec == Init /\ [][Next]_vars

\* StallReset (S5) and Stall owe nothing; everything else is fair.
FairSpec == Spec /\ WF_vars(Capture) /\ WF_vars(EncodeOut) /\ WF_vars(Complete)
                 /\ WF_vars(MacAck) /\ WF_vars(MacKeyReq) /\ WF_vars(Tick)
                 /\ WF_vars(Deliver) /\ WF_vars(Resume)

------------------------------------------------------------------------------
(* Properties *)

\* The queue in front of a new frame (nw, socket, air) stays within what
\* the gate admits plus the encoder pipeline.
QueueBounded == Len(nwq) + Len(wire) <= L - 1 + P

\* No encoded frame is dropped: the iPad never sees a seq gap.
NoGap ==
    /\ ~pendingGap
    /\ \A i \in 1..Len(nwq) : ~nwq[i].gap
    /\ \A i \in 1..Len(wire) : ~wire[i].gap

KCount(s) == Len(SelectSeq(s, LAMBDA x : x = "K"))
KFCount(s) == Len(SelectSeq(s, LAMBDA f : f.k = "K"))
KInFlight == KCount(enc) + KFCount(nwq) + KFCount(wire)

\* At most one IDR is queued or about to be made: no keyframe spiral.
OneKeyframe == KInFlight + (IF force THEN 1 ELSE 0) <= 1

\* The ghost kq the proofs use is the real count (TLC only).
KqExact == kq = KInFlight

\* With acks, unacked is exactly the queue plus acks in transit (TLC only).
UnackedExact == AckGate => unacked = Len(nwq) + Len(wire) + ackq

Inv == TypeOK /\ QueueBounded /\ NoGap /\ OneKeyframe

\* Pictures keep coming: the iPad shows frames forever.
Flows == []<>(shown = 0) /\ []<>(shown = 1)

\* Witness: the iPad shows a frame at all.
NeverShows == shown = 0
=============================================================================
