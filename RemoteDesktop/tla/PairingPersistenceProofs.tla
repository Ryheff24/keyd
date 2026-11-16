------------------------ MODULE PairingPersistenceProofs ------------------------
(* TLAPS proof that, with KeepCreds, the iPad's credentials are gone only    *)
(* after the owner pressed Reset Pairing (CredsOnlyOwnerForgets), for any    *)
(* MaxFlaps and MaxStalls.  Reconnection (Reconnects) is liveness: TLC only. *)
(* Control (Makefile): with KeepCreds dropped from Design, the proof must    *)
(* fail at exactly the Timeout step.                                         *)
EXTENDS PairingPersistence, TLAPS

ASSUME Bounds == MaxFlaps \in Nat /\ MaxStalls \in Nat
ASSUME Switches == KeepCreds \in BOOLEAN /\ RestartOnTimeout \in BOOLEAN

LEMMA InitInv == Init => Inv
  BY Bounds DEF Init, Inv, TypeOK, CredsOnlyOwnerForgets

\* Design is a constant hypothesis: assumed, not conjoined to Spec (PTL, METHOD.md).
THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY InitInv
  <1>2. Inv /\ [Next]_vars => Inv'
    <2> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
    <2> USE Bounds, Switches DEF Inv, TypeOK, CredsOnlyOwnerForgets
    <2>1. CASE Connect BY <2>1 DEF Connect
    <2>2. CASE Lose BY <2>2 DEF Lose
    <2>3. CASE Timeout BY <2>3 DEF Timeout, Design
    <2>4. CASE MacDown BY <2>4 DEF MacDown
    <2>5. CASE MacUp BY <2>5 DEF MacUp
    <2>6. CASE Stall BY <2>6 DEF Stall
    <2>7. CASE OwnerReset BY <2>7 DEF OwnerReset
    <2>8. CASE MacForget BY <2>8 DEF MacForget
    <2>9. CASE Pair BY <2>9 DEF Pair
    <2>10. CASE UNCHANGED vars BY <2>10 DEF vars
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10
            DEF Next, System, Env
  <1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
