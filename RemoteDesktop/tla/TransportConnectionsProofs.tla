----------------------- MODULE TransportConnectionsProofs -----------------------
(* TLAPS proof that, with the design, no dial offers infrastructure while    *)
(* AWDL is usable and not avoided, labels are exact, no side keeps a silent connection    *)
(* past D, and AWDL is avoided only after a fault on it, for any bounds.     *)
(* Recovery (Recovers) is liveness: TLC only; ClimbsBack is open (PLAN).    *)
(* Controls (Makefile): dropping one switch from Design must fail at exactly *)
(* that mechanism's step: OneLink and AwdlFirst at Dial, ExactLabel at      *)
(* Establish, SilenceDetect at Tick, CauseAware at SuspendAbort.            *)
EXTENDS TransportConnections, TLAPS

ASSUME Bounds == MaxSilence \in Nat /\ MaxFlaps \in Nat /\ D \in Nat /\ MaxAge \in Nat
                 /\ MaxBackgrounds \in Nat /\ MaxStalls \in Nat
ASSUME Switches == AwdlPin \in BOOLEAN /\ OneLink \in BOOLEAN /\ AwdlFirst \in BOOLEAN /\ ExactLabel \in BOOLEAN
                   /\ SilenceDetect \in BOOLEAN /\ RedialOnLoss \in BOOLEAN
                   /\ CauseAware \in BOOLEAN

IInv == Inv

LEMMA InitIInv == Init => IInv
  BY Bounds DEF Init, IInv, Inv, TypeOK, PreferAwdl, LabelExact, DetectDeadline, AvoidOnFault,
                Held, Links, None

THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => IInv BY InitIInv
  <1>2. IInv /\ [Next]_vars => IInv'
    <2> SUFFICES ASSUME IInv, [Next]_vars PROVE IInv' OBVIOUS
    <2> USE Bounds, Switches DEF IInv, Inv, TypeOK, PreferAwdl, LabelExact, DetectDeadline,
                                 AvoidOnFault, Held, Links, None, Env6
    <2>1. CASE Dial BY <2>1 DEF Dial, Candidates, Design
    <2>2. CASE \E l \in Links : Establish(l) BY <2>2 DEF Establish, LabelOf, Design
    <2>3. CASE DialFail BY <2>3 DEF DialFail
    <2>4. CASE IpadDetect BY <2>4 DEF IpadDetect, AfterLoss
    <2>5. CASE MacDetect BY <2>5 DEF MacDetect
    <2>6. CASE Tick BY <2>6 DEF Tick, Design
    <2>7. CASE GoSilent BY <2>7 DEF GoSilent
    <2>8. CASE TcpTimeout BY <2>8 DEF TcpTimeout, AfterLoss
    <2>9. CASE \E l \in Links : LinkDown(l) BY <2>9 DEF LinkDown
    <2>10. CASE \E l \in Links : LinkUp(l) BY <2>10 DEF LinkUp
    <2>11. CASE UNCHANGED vars BY <2>11 DEF vars
    <2>12. CASE Background BY <2>12 DEF Background
    <2>13. CASE Foreground BY <2>13 DEF Foreground
    <2>14. CASE SuspendAbort BY <2>14 DEF SuspendAbort, AfterLoss, Design
    <2>15. CASE DialStall BY <2>15 DEF DialStall
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11,
               <2>12, <2>13, <2>14, <2>15
            DEF Next, System, Env
  <1>3. IInv => Inv BY DEF IInv
  <1> QED BY <1>1, <1>2, <1>3, PTL DEF Spec
=============================================================================
