------------------------------ MODULE InputPath -------------------------------
(***************************************************************************)
(* iPad keyboard / pointer input reaching the Mac as CGEvents, across      *)
(* transport switches, link drops, iPad relaunches and agent shutdown.     *)
(* PLAN.md H5/B4 (input) and EndToEnd's StopReleasesAll.  Held keys and    *)
(* held mouse buttons are the same problem; Keys stands for both.          *)
(*                                                                         *)
(* As built [C] (2026-11-15): no input injection exists (H5); the handler  *)
(* covers control types only.  The model's design is the requirement.     *)
(*                                                                         *)
(* Design:                                                                  *)
(*   Every input message carries <<session, seq>>: session is new per iPad *)
(*   app launch, seq counts messages within it.  The Mac applies a message *)
(*   of its current session only if seq is above the last one it applied   *)
(*   (SeqGuard); a message from another session starts a fresh count.      *)
(*   When the Mac sees any input connection end it releases everything     *)
(*   (ReleaseOnLoss).  On every new connection and every switch of link   *)
(*   the iPad first sends HELD = the set it holds now; the Mac releases    *)
(*   what is not in it and never presses from it (Resync, release-only).   *)
(*   Agent stop releases everything (StopRelease).                         *)
(*   Accepted costs: a press racing a HELD may be lost (release-only), and *)
(*   any link loss on the Mac releases keys held through the other link.   *)
(*                                                                         *)
(* Assumptions:                                                             *)
(*  I1 [I] Each link is a TCP connection: FIFO, framed (Framing.tla).  An  *)
(*         abrupt loss drops what is in flight; a closing process's       *)
(*         sockets end gracefully (data first, then end of stream).        *)
(*  I2 [I] Each side sees a link end on its own schedule, possibly much   *)
(*         later (half-open TCP; SecureSession A9).  The iPad sends only   *)
(*         on the link it believes current.                               *)
(*  I3 [I] Authorization (pin, epoch, streaming) is SecureSession's        *)
(*         Deliver guard; here every delivered message is the owner's.     *)
(*  I4 [I] Posting a CGEvent changes the Mac's held state immediately.     *)
(*  I5 [T] An iPad relaunch (process start + TLS handshake, >= 1 s) takes  *)
(*         longer than the Mac reading bytes a closed socket already sent: *)
(*         sessions do not interleave on the Mac.                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Keys, Links, MaxSeq, MaxSession,
    SeqGuard, ReleaseOnLoss, Resync, StopRelease

Msg == [ses : 1..MaxSession, seq : 1..MaxSeq, kind : {"down", "up", "held"},
        key : Keys \cup {"none"}, held : SUBSET Keys]

VARIABLES
    iHeld, iSes, iSeq, cur,        \* iPad: keys held, session, last seq, current link
    up, ipadSees, macSees, chan,   \* links: alive, seen alive per side, in-flight messages
    mHeld, mSes, mLast,            \* Mac: posted-and-held keys, session, last applied seq
    stopped, outOfOrder

vars == <<iHeld, iSes, iSeq, cur, up, ipadSees, macSees, chan, mHeld, mSes, mLast, stopped, outOfOrder>>

Init ==
    /\ iHeld = {} /\ iSes = 1 /\ iSeq = 0 /\ cur = CHOOSE l \in Links : TRUE
    /\ up = [l \in Links |-> TRUE] /\ ipadSees = up /\ macSees = up
    /\ chan = [l \in Links |-> <<>>]
    /\ mHeld = {} /\ mSes = 0 /\ mLast = 0
    /\ stopped = FALSE /\ outOfOrder = FALSE

Send(m) == chan' = [chan EXCEPT ![cur] = Append(@, m)]
NewMsg(kind, k, h) == [ses |-> iSes, seq |-> iSeq + 1, kind |-> kind, key |-> k, held |-> h]
\* MaxSeq bounds the run (real seq is 64-bit): an action that would need seq MaxSeq + 1
\* is disabled, never treated as an unusable link.
Room == iSeq < MaxSeq
CanSend == ~stopped /\ up[cur] /\ ipadSees[cur]

Press(k) ==
    /\ CanSend /\ Room /\ k \notin iHeld
    /\ iHeld' = iHeld \cup {k} /\ iSeq' = iSeq + 1 /\ Send(NewMsg("down", k, {}))
    /\ UNCHANGED <<iSes, cur, up, ipadSees, macSees, mHeld, mSes, mLast, stopped, outOfOrder>>

\* The user lets go; if the iPad has no usable link the key-up is never sent.
Release(k) ==
    /\ ~stopped /\ Room /\ k \in iHeld
    /\ iHeld' = iHeld \ {k}
    /\ IF CanSend
       THEN iSeq' = iSeq + 1 /\ Send(NewMsg("up", k, {}))
       ELSE UNCHANGED <<iSeq, chan>>
    /\ UNCHANGED <<iSes, cur, up, ipadSees, macSees, mHeld, mSes, mLast, stopped, outOfOrder>>

\* Link l dies; its in-flight messages are lost (I1).
Drop(l) ==
    /\ up[l]
    /\ up' = [up EXCEPT ![l] = FALSE] /\ chan' = [chan EXCEPT ![l] = <<>>]
    /\ UNCHANGED <<iHeld, iSes, iSeq, cur, ipadSees, macSees, mHeld, mSes, mLast, stopped, outOfOrder>>

IpadSeeDrop(l) ==
    /\ ~up[l] /\ ipadSees[l]
    /\ ipadSees' = [ipadSees EXCEPT ![l] = FALSE]
    /\ UNCHANGED <<iHeld, iSes, iSeq, cur, up, macSees, chan, mHeld, mSes, mLast, stopped, outOfOrder>>

\* The Mac sees the end of stream after any data still buffered (I1).
MacSeeDrop(l) ==
    /\ ~up[l] /\ macSees[l] /\ chan[l] = <<>>
    /\ macSees' = [macSees EXCEPT ![l] = FALSE]
    /\ mHeld' = IF ReleaseOnLoss THEN {} ELSE mHeld
    /\ UNCHANGED <<iHeld, iSes, iSeq, cur, up, ipadSees, chan, mSes, mLast, stopped, outOfOrder>>

\* A new connection on l (both sides see it), and the iPad switches to it.
Connect(l) ==
    /\ ~stopped /\ ~up[l] /\ ~ipadSees[l] /\ ~macSees[l] /\ iSeq < MaxSeq
    /\ up' = [up EXCEPT ![l] = TRUE]
    /\ ipadSees' = [ipadSees EXCEPT ![l] = TRUE]
    /\ macSees' = [macSees EXCEPT ![l] = TRUE]
    /\ cur' = l
    /\ IF Resync
       THEN /\ iSeq' = iSeq + 1
            /\ chan' = [chan EXCEPT ![l] = <<[ses |-> iSes, seq |-> iSeq + 1, kind |-> "held",
                                              key |-> "none", held |-> iHeld]>>]
       ELSE UNCHANGED <<iSeq, chan>>
    /\ UNCHANGED <<iHeld, iSes, mHeld, mSes, mLast, stopped, outOfOrder>>

\* The iPad switches to another link it believes alive (no new connection).
Switch(l) ==
    /\ l # cur /\ up[l] /\ ipadSees[l] /\ iSeq < MaxSeq
    /\ cur' = l
    /\ IF Resync
       THEN iSeq' = iSeq + 1 /\ chan' = [chan EXCEPT ![l] = Append(@, NewMsg("held", "none", iHeld))]
       ELSE UNCHANGED <<iSeq, chan>>
    /\ UNCHANGED <<iHeld, iSes, up, ipadSees, macSees, mHeld, mSes, mLast, stopped, outOfOrder>>

\* iPad app relaunch: its sockets close gracefully (I1), after the Mac has read what
\* they carried (I5); new session, nothing held, sequence restarts.
Relaunch ==
    /\ ~stopped /\ iSes < MaxSession /\ \A l \in Links : chan[l] = <<>>
    /\ iSes' = iSes + 1 /\ iSeq' = 0 /\ iHeld' = {}
    /\ up' = [l \in Links |-> FALSE] /\ ipadSees' = [l \in Links |-> FALSE]
    /\ UNCHANGED <<cur, macSees, chan, mHeld, mSes, mLast, stopped, outOfOrder>>

\* The Mac applies the next message on l (bytes it already holds even if l has ended).
Deliver(l) ==
    /\ ~stopped /\ chan[l] # <<>> /\ macSees[l]
    /\ LET m == Head(chan[l])
           sameSes == m.ses = mSes
           fresh == ~SeqGuard \/ ~sameSes \/ m.seq > mLast
       IN /\ chan' = [chan EXCEPT ![l] = Tail(@)]
          /\ IF fresh
             THEN /\ mSes' = m.ses /\ mLast' = m.seq
                  /\ outOfOrder' = (outOfOrder \/ (sameSes /\ m.seq <= mLast))
                  /\ mHeld' = CASE m.kind = "down" -> mHeld \cup {m.key}
                                [] m.kind = "up"   -> mHeld \ {m.key}
                                [] OTHER           -> mHeld \cap m.held   \* release-only
             ELSE UNCHANGED <<mSes, mLast, mHeld, outOfOrder>>
    /\ UNCHANGED <<iHeld, iSes, iSeq, cur, up, ipadSees, macSees, stopped>>

Stop ==
    /\ ~stopped
    /\ stopped' = TRUE
    /\ mHeld' = IF StopRelease THEN {} ELSE mHeld
    /\ UNCHANGED <<iHeld, iSes, iSeq, cur, up, ipadSees, macSees, chan, mSes, mLast, outOfOrder>>

Next ==
    \/ \E k \in Keys : Press(k) \/ Release(k)
    \/ \E l \in Links : Drop(l) \/ IpadSeeDrop(l) \/ MacSeeDrop(l) \/ Connect(l) \/ Switch(l) \/ Deliver(l)
    \/ Relaunch \/ Stop

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ iHeld \subseteq Keys /\ mHeld \subseteq Keys
    /\ iSeq \in 0..MaxSeq /\ mLast \in 0..MaxSeq
    /\ \A l \in Links : \A i \in 1..Len(chan[l]) : chan[l][i] \in Msg

\* Quiet: nothing in flight and both sides agree the iPad's current link is alive.
\* The Mac may still believe a dead link alive (I2).
Quiet == /\ \A l \in Links : chan[l] = <<>>
         /\ up[cur] /\ ipadSees[cur] /\ macSees[cur]

\* Once things are quiet the Mac holds nothing the iPad does not hold: no stuck key,
\* no runaway auto-repeat, no phantom press.
NoStuckKey == Quiet => mHeld \subseteq iHeld

\* Once the Mac knows every input link has ended it holds nothing: unplugging
\* cannot leave a key down or auto-repeating.
HeldNeedsLink == mHeld # {} => \E l \in Links : macSees[l]

\* Within one session the Mac applies messages in the order the iPad sent them.
InOrder == ~outOfOrder

\* Agent stop leaves nothing pressed (EndToEnd StopReleasesAll).
StopReleasesAll == stopped => mHeld = {}

\* Witness: a key is held on the Mac.
NeverHeld == mHeld = {}
=============================================================================
