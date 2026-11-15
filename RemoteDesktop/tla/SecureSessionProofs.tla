------------------------- MODULE SecureSessionProofs -------------------------
(* TLAPS proof that, under Design, every reachable state of the abstract    *)
(* end-to-end lifecycle is Safe: no plaintext, every application message on *)
(* a mutually pinned channel, pairing only over USB, nothing leaked to the  *)
(* attacker, and the Mac acts on input or control from, and sends to, only  *)
(* the device it currently trusts (the owner's iPad).  This holds through    *)
(* every pairing, pin check, late readiness, link drop, non-atomic          *)
(* revocation and re-pairing, for any MaxConn and MaxEpoch.  It is safety   *)
(* of the modelled actions only; progress is not claimed (PLAN.md).         *)
(* Controls (Makefile): dropping one mechanism must fail at its own steps.  *)
EXTENDS SecureSession, TLAPS

USE Distinct, Bound, Switches DEF Links, Wireless, Ids, Prots, Secrets, MacRec, IpadRec, Msg, Drop

\* The inductive invariant: Safe plus what makes it inductive.
IInv ==
    /\ TypeOK
    /\ macPin \in {I, None}
    /\ ipadPin \in {M, None}
    /\ \A r \in macPending \cup macSess :
           /\ r.peer = I /\ r.prot = "pinned" /\ r.epoch <= macEpoch
           /\ (r.epoch = macEpoch => macPin = I)
    /\ \A r \in ipadSess : r.peer = M /\ r.prot = "pinned"
    /\ \A m \in inflight : m.author = I
    /\ leaked = {}
    /\ ~plainSent /\ ~unauthSent /\ ~pairOffUSB /\ ~badInject /\ ~badSend /\ ~foreignInject

LEMMA InitIInv == Init => IInv
  BY DEF Init, IInv, TypeOK

LEMMA IInvSafe == IInv => Safe
  BY DEF IInv, Safe, NoPlaintext, AllMutuallyPinned, PairingOnlyOverUSB, NoLeak,
         InjectAuthorized, InjectFromOwner, SendOnlyToTrusted

LEMMA NextIInv == ASSUME Design, IInv, [Next]_vars PROVE IInv'
  <1> USE DEF Design, IInv, TypeOK
  <1>1. ASSUME NEW d \in {I, A}, NEW l \in Links, PairMac(d, l) PROVE IInv'
    <2>1. d = I /\ l = "usb" BY <1>1 DEF PairMac, PairLinks
    <2> QED BY <1>1, <2>1 DEF PairMac
  <1>2. ASSUME NEW s \in {M, A}, PairIpad(s) PROVE IInv'
    BY <1>2 DEF PairIpad
  <1>3. CASE Revoke BY <1>3 DEF Revoke
  <1>4. CASE ForgetMac BY <1>4 DEF ForgetMac
  <1>5. ASSUME NEW l \in Links, ConnectIM(l) PROVE IInv'
    BY <1>5 DEF ConnectIM, MacAccepts, IpadAccepts, ProtOf
  <1>6. ASSUME NEW l \in Links, ConnectAM(l) PROVE IInv'
    BY <1>6 DEF ConnectAM, MacAccepts
  <1>7. ASSUME NEW l \in Links, ConnectIA(l) PROVE IInv'
    BY <1>7 DEF ConnectIA, IpadAccepts
  <1>8. ASSUME NEW l \in Links, MacLinkDown(l) PROVE IInv'
    BY <1>8 DEF MacLinkDown
  <1>17. ASSUME NEW l \in Links, IpadLinkDown(l) PROVE IInv'
    BY <1>17 DEF IpadLinkDown
  <1>9. ASSUME NEW l \in Links, PlainSend(l) PROVE IInv'
    BY <1>9 DEF PlainSend
  <1>10. ASSUME NEW r \in macSess, CloseMac(r) PROVE IInv'
    BY <1>10 DEF CloseMac
  <1>11. ASSUME NEW r \in macSess, NEW k \in {"input", "control"}, AttackerSend(r, k) PROVE IInv'
    BY <1>11 DEF AttackerSend
  <1>12. ASSUME NEW r \in macSess, NEW k \in {"frame", "control"}, MacSend(r, k) PROVE IInv'
    BY <1>12 DEF MacSend, Live
  <1>13. ASSUME NEW r \in ipadSess, CloseIpad(r) PROVE IInv'
    BY <1>13 DEF CloseIpad
  <1>14. ASSUME NEW r \in ipadSess, NEW k \in {"input", "control"}, IpadSend(r, k) PROVE IInv'
    BY <1>14 DEF IpadSend
  <1>15. ASSUME NEW m \in inflight, NEW r \in macSess, Deliver(m, r) PROVE IInv'
    <2>1. r.epoch = macEpoch /\ m.author = I /\ macPin = I BY <1>15 DEF Deliver, Live
    <2>2. switches' \subseteq Links \X Links BY <1>15 DEF Deliver
    <2>3. usedIds' \subseteq Ids BY <1>15 DEF Deliver
    <2> QED BY <1>15, <2>1, <2>2, <2>3 DEF Deliver
  <1>18. ASSUME NEW r \in macPending, MacReady(r) PROVE IInv'
    BY <1>18 DEF MacReady
  <1>16. CASE UNCHANGED vars BY <1>16 DEF vars
  <1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11,
             <1>12, <1>13, <1>14, <1>15, <1>16, <1>17, <1>18 DEF Next

\* Design is a constant hypothesis: assumed, not conjoined to Spec (PTL, METHOD.md).
THEOREM EndToEndSafe == ASSUME Design PROVE Spec => []Safe
  <1>1. Spec => []IInv BY InitIInv, NextIInv, PTL DEF Spec
  <1> QED BY <1>1, IInvSafe, PTL
=============================================================================
