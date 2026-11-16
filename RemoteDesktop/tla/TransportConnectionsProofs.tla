----------------------- MODULE TransportConnectionsProofs -----------------------
(* TLAPS proof that, with the design, no dial offers infrastructure while    *)
(* AWDL is usable and not avoided, labels are exact, and no side keeps a silent connection    *)
(* past D, for any bounds.  Recovery (Recovers) is liveness: TLC only.       *)
(* Controls (Makefile): dropping one switch from Design must fail at exactly *)
(* that mechanism's step: OneLink and AwdlFirst at Dial, ExactLabel at      *)
(* Establish,                                                                *)
(* SilenceDetect at Tick.                                                    *)
EXTENDS TransportConnections, TLAPS

ASSUME Bounds == MaxSilence \in Nat /\ MaxFlaps \in Nat /\ D \in Nat /\ MaxAge \in Nat
ASSUME Switches == AwdlPin \in BOOLEAN /\ OneLink \in BOOLEAN /\ AwdlFirst \in BOOLEAN /\ ExactLabel \in BOOLEAN
                   /\ SilenceDetect \in BOOLEAN /\ RedialOnLoss \in BOOLEAN

IInv == Inv

LEMMA InitIInv == Init => IInv
  BY Bounds DEF Init, IInv, Inv, TypeOK, PreferAwdl, LabelExact, DetectDeadline,
                Held, Links, None

THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => IInv BY InitIInv
  <1>2. IInv /\ [Next]_vars => IInv'
    <2> SUFFICES ASSUME IInv, [Next]_vars PROVE IInv' OBVIOUS
    <2> USE Bounds, Switches DEF IInv, Inv, TypeOK, PreferAwdl, LabelExact, DetectDeadline,
                                 Held, Links, None
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
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11
            DEF Next, System, Env
  <1>3. IInv => Inv BY DEF IInv
  <1> QED BY <1>1, <1>2, <1>3, PTL DEF Spec
=============================================================================
