---------------------------- MODULE PairingProofs ----------------------------
(* TLAPS proof that the pairing design (USB only, listener bound to the     *)
(* pairing window, iPad-generated key, one attempt at a time, confirmation  *)
(* on the Mac) keeps Inv in every reachable state, whatever the attacker    *)
(* sees.  Checked by tlapm, not TLC.  Control (Makefile): with USBPairing   *)
(* and ConfirmOnMac dropped from Design, at least one obligation must fail. *)
EXTENDS Pairing, TLAPS

USE Distinct, Switches DEF Dev

LEMMA InitInv == Init => Inv
  BY DEF Init, Inv, TypeOK, Safe, OnlyOwnerPaired, ListenerOnlyWhileWindow,
         NoPrivateKeyOnWire, OwnerNotDisplaced

\* Design is a constant hypothesis: assumed, not conjoined to Spec (PTL, METHOD.md).
THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY InitInv
  <1>2. Inv /\ [Next]_vars => Inv'
    <2> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
    <2> USE DEF Inv, TypeOK, Safe, OnlyOwnerPaired, ListenerOnlyWhileWindow,
               NoPrivateKeyOnWire, OwnerNotDisplaced, Design
    <2>1. CASE OpenPairWindow BY <2>1 DEF OpenPairWindow
    <2>2. CASE ClosePairWindow BY <2>2 DEF ClosePairWindow
    <2>3. CASE Scan BY <2>3 DEF Scan
    <2>4. CASE Peek BY <2>4 DEF Peek
    <2>5. CASE Drop BY <2>5 DEF Drop
    <2>6. CASE ResetPairing BY <2>6 DEF ResetPairing
    <2>7. ASSUME NEW d \in Dev, Connect(d) PROVE Inv'
          BY <2>7 DEF Connect, Reach
    <2>8. ASSUME NEW d \in Dev, Accept(d) PROVE Inv'
          BY <2>8 DEF Accept, ProofOK, ConfirmOK
    <2>9. ASSUME NEW d \in Dev, Refuse(d) PROVE Inv'
          BY <2>9 DEF Refuse
    <2>10. CASE UNCHANGED vars BY <2>10 DEF vars
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10 DEF Next
  <1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
