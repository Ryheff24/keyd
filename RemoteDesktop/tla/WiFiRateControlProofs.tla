------------------------ MODULE WiFiRateControlProofs ------------------------
(* TLAPS proof that, with the design, the frame rate stays at 60 and every   *)
(* level stays in range, for any bounds.  Settles (the bitrate is never      *)
(* latched at the floor by holds) is liveness: TLC only, with its control    *)
(* WRC-ctl-ignoreholds.  Proof control (Makefile): Design without KeepFps    *)
(* must fail at exactly the Window step.                                     *)
EXTENDS WiFiRateControl, TLAPS

ASSUME Bounds == N \in Nat /\ T \in 0..N /\ MaxCapChanges \in Nat
ASSUME Switches == IgnoreHolds \in BOOLEAN /\ KeepFps \in BOOLEAN

Inv == TypeOK /\ FpsKept

THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY Bounds DEF Init, Inv, TypeOK, FpsKept, Levels
  <1>2. Inv /\ [Next]_vars => Inv'
    <2> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
    <2> USE Bounds, Switches DEF Inv, TypeOK, FpsKept, Levels
    <2>1. CASE Window BY <2>1 DEF Window, Toward, Design
    <2>2. CASE CapChange BY <2>2 DEF CapChange
    <2>3. CASE UNCHANGED vars BY <2>3 DEF vars
    <2> QED BY <2>1, <2>2, <2>3 DEF Next
  <1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
