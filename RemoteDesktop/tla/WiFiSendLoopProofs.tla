------------------------- MODULE WiFiSendLoopProofs -------------------------
(* TLAPS proof that, with the design, the queue in front of a new frame     *)
(* stays within L - 1 + P, no encoded frame is dropped (the iPad never sees *)
(* a seq gap), and at most one keyframe is queued or pending, for any       *)
(* bounds.  The keyframe bound is proved on the ghost kq; TLC checks        *)
(* KqExact (kq is the real count) on every row.  Flows is liveness: TLC.    *)
(* Controls (Makefile): dropping one switch from Design must fail at        *)
(* exactly that mechanism's steps: AckGate at Capture (the gate counts the  *)
(* wrong thing) and at EncodeOut/Deliver (no acks to count), NoPostDrop at  *)
(* EncodeOut, NoBlindReset at StallReset.                                   *)
EXTENDS WiFiSendLoop, SequenceTheorems, TLAPS

ASSUME Bounds == L \in Nat \ {0} /\ P \in Nat /\ SockCap \in Nat
                 /\ MaxStalls \in Nat /\ MaxResets \in Nat
ASSUME Switches == AckGate \in BOOLEAN /\ NoPostDrop \in BOOLEAN /\ NoBlindReset \in BOOLEAN

\* A frame sent after no drop.
Good == [k : Kinds, gap : {FALSE}, g : 0..MaxResets]

KqBound == kq + (IF force THEN 1 ELSE 0) <= 1

SafeInv == TypeOK /\ QueueBounded /\ NoGap /\ KqBound

IInv ==
    /\ force \in BOOLEAN /\ enc \in Seq(Kinds)
    /\ nwq \in Seq(Good) /\ wire \in Seq(Good)
    /\ inFlight \in Nat /\ gen \in 0..MaxResets /\ pendingGap = FALSE
    /\ unacked \in Nat /\ ackq \in Nat /\ kq \in Nat
    /\ macCool \in BOOLEAN /\ ipadCool \in BOOLEAN /\ req = FALSE
    /\ ipad = "ok" /\ shown \in {0, 1}
    /\ linkUp \in BOOLEAN /\ stalls \in 0..MaxStalls /\ resets \in 0..MaxResets
    /\ unacked = Len(nwq) + Len(wire) + ackq
    /\ unacked + Len(enc) <= L - 1 + P
    /\ KqBound

LEMMA GoodFrame == Good \subseteq Frame(0..MaxResets)
  BY DEF Good, Frame

LEMMA InitIInv == Init => IInv
  <1> SUFFICES ASSUME Init PROVE IInv OBVIOUS
  <1>1. /\ << >> \in Seq(Kinds) /\ << >> \in Seq(Good) /\ Len(<< >>) = 0
    BY EmptySeq
  <1> QED BY <1>1, Bounds DEF Init, IInv, KqBound

THEOREM SpecSafe == ASSUME Design PROVE Spec => []SafeInv
  <1>1. Init => IInv BY InitIInv
  <1>2. IInv /\ [Next]_vars => IInv'
    <2> SUFFICES ASSUME IInv, [Next]_vars PROVE IInv' OBVIOUS
    <2> USE Bounds, Switches DEF IInv, KqBound
    <2>a. /\ Len(enc) \in Nat /\ Len(nwq) \in Nat /\ Len(wire) \in Nat
      BY LenProperties
    <2>1. CASE Capture
      <3> DEFINE x == IF force THEN "K" ELSE "P"
      <3>1. x \in Kinds BY DEF Kinds
      <3>2. Append(enc, x) \in Seq(Kinds) /\ Len(Append(enc, x)) = Len(enc) + 1
        BY <3>1, AppendProperties
      <3>3. unacked < L /\ Len(enc) < P BY <2>1 DEF Capture, GateOpen, Design
      <3>4. /\ enc' = Append(enc, x) /\ force' = FALSE
            /\ kq' = IF force THEN kq + 1 ELSE kq
            /\ UNCHANGED <<nwq, wire, inFlight, gen, pendingGap, unacked, ackq, macCool,
                           ipadCool, req, ipad, shown, linkUp, stalls, resets>>
        BY <2>1 DEF Capture
      <3> QED BY <2>a, <3>2, <3>3, <3>4
    <2>2. CASE EncodeOut
      <3>1. enc # << >> BY <2>2 DEF EncodeOut
      <3>2. /\ Head(enc) \in Kinds /\ Tail(enc) \in Seq(Kinds)
            /\ Len(Tail(enc)) = Len(enc) - 1
        BY <3>1, HeadTailProperties
      <3> DEFINE f == [k |-> Head(enc), gap |-> pendingGap, g |-> gen]
      <3>3. f \in Good BY <3>2 DEF Good
      <3>4. Append(nwq, f) \in Seq(Good) /\ Len(Append(nwq, f)) = Len(nwq) + 1
        BY <3>3, AppendProperties
      <3>5. ~PostDrop BY DEF PostDrop, Design
      <3> QED BY <2>2, <2>a, <3>2, <3>4, <3>5 DEF EncodeOut, Design
    <2>3. CASE Complete
      <3>1. nwq # << >> BY <2>3 DEF Complete
      <3>2. /\ Head(nwq) \in Good /\ Tail(nwq) \in Seq(Good)
            /\ Len(Tail(nwq)) = Len(nwq) - 1
        BY <3>1, HeadTailProperties
      <3>3. Append(wire, Head(nwq)) \in Seq(Good)
            /\ Len(Append(wire, Head(nwq))) = Len(wire) + 1
        BY <3>2, AppendProperties
      <3> QED BY <2>3, <2>a, <3>2, <3>3 DEF Complete
    <2>4. CASE MacAck BY <2>4, <2>a DEF MacAck
    <2>5. CASE MacKeyReq BY <2>5 DEF MacKeyReq
    <2>6. CASE StallReset BY <2>6 DEF StallReset, Design
    <2>7. CASE Tick BY <2>7 DEF Tick
    <2>8. CASE Deliver
      <3>1. wire # << >> BY <2>8 DEF Deliver
      <3>2. /\ Head(wire) \in Good /\ Tail(wire) \in Seq(Good)
            /\ Len(Tail(wire)) = Len(wire) - 1
        BY <3>1, HeadTailProperties
      <3>3. Head(wire).gap = FALSE BY <3>2 DEF Good
      <3> QED BY <2>8, <2>a, <3>2, <3>3 DEF Deliver, Design
    <2>9. CASE Stall BY <2>9 DEF Stall
    <2>10. CASE Resume BY <2>10 DEF Resume
    <2>11. CASE UNCHANGED vars BY <2>11 DEF vars
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11
            DEF Next, System, Env
  <1>3. IInv => SafeInv
    <2> SUFFICES ASSUME IInv PROVE SafeInv OBVIOUS
    <2> USE Bounds DEF IInv
    <2>1. nwq \in Seq(Frame(0..MaxResets)) /\ wire \in Seq(Frame(0..MaxResets))
      BY GoodFrame, SeqMonotonic
    <2>2. \A i \in 1..Len(nwq) : nwq[i] \in Good BY ElementOfSeq
    <2>3. \A i \in 1..Len(wire) : wire[i] \in Good BY ElementOfSeq
    <2>4. Len(enc) \in Nat /\ Len(nwq) \in Nat /\ Len(wire) \in Nat BY LenProperties
    <2> QED BY <2>1, <2>2, <2>3, <2>4 DEF SafeInv, TypeOK, QueueBounded, NoGap, KqBound, Good
  <1> QED BY <1>1, <1>2, <1>3, PTL DEF Spec
=============================================================================
