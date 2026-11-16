--------------------------- MODULE LifecycleProofs ---------------------------
(* TLAPS proof that, with the design, for any bounds:                         *)
(*   the gate counts only queued frames (CountsOnlySent), a streaming session *)
(*   on a ready connection was (re)started on it (SessionOnCurrent), no frame *)
(*   precedes the handshake on its connection (HandshakeBeforeFrames), Outside *)
(*   never displaces the owner (OnlyOwnerDisplaces);                          *)
(*   and every quiet state with a link up and an id left is Good (QuietGood). *)
(* TLC checks Rest <=> Quiet (RestIsQuiet), so QuietGood is RestGood; that    *)
(* every behaviour reaches rest (Settles) is liveness: TLC only.              *)
(* Controls (Makefile): Design without one switch must fail at exactly its    *)
(* step: RestartOnNewConn at MacReady, CountOnSend at MacEncode,              *)
(* AuthBeforeDisplace at MacAccept.                                           *)
EXTENDS Lifecycle, TLAPS

\* MacReady under the design, written out: Handle always restarts there.
ReadyMac(c) ==
    [mac EXCEPT !.in = c, !.isConn = TRUE, !.isAWDL = (cn[c].link = "awdl"),
                !.recov = FALSE, !.med = TRUE, !.lis = FALSE,
                !.fsm = FsmStep(mac.fsm, IF cn[c].link = "awdl" THEN "awdlAvail" ELSE "wifiAvail"),
                !.sess = "streaming", !.sc = c, !.u = 0, !.q = 0, !.gc = c]
ReadyCn(c) ==
    LET old == IF mac.in # c THEN mac.in ELSE 0
        f1  == [Kill(cn, old) EXCEPT ![c].m = "ready"]
    IN [f1 EXCEPT ![c].hs = TRUE, ![c].hsSent = TRUE]
ReadyPost(c) == cn' = ReadyCn(c) /\ mac' = ReadyMac(c)

LEMMA FsmType == \A s \in Fsm0, ev \in {"wifiAvail", "awdlAvail", "wifiUnavail", "awdlUnavail"} :
                   FsmStep(s, ev) \in Fsm0
  BY DEF FsmStep, Fsm0

LEMMA FsmAvail == \A s \in Fsm0, ev \in {"wifiAvail", "awdlAvail"} :
                    FsmStep(s, ev) \notin {"idle", "disc"}
  BY DEF FsmStep, Fsm0

LEMMA ReadyIsRestart ==
  ASSUME Design, Inv, NEW c \in CIds, MacReady(c)
  PROVE  ReadyPost(c)
  <1> USE Bounds DEF Inv, TypeOK, Design, InvFresh, CIds, Sess, Fsm0
  <1> DEFINE old == IF AuthBeforeDisplace /\ mac.in # c THEN mac.in ELSE 0
             f1  == [Kill(cn, old) EXCEPT ![c].m = "ready"]
             ev  == IF cn[c].link = "awdl" THEN "awdlAvail" ELSE "wifiAvail"
             m1  == [mac EXCEPT !.in = c, !.isConn = TRUE, !.isAWDL = (cn[c].link = "awdl"),
                                !.recov = FALSE, !.med = TRUE, !.lis = FALSE]
             s1  == FsmStep(m1.fsm, ev)
             mx  == [m1 EXCEPT !.fsm = s1]
  <1>1. cn[c].m = "accepted" /\ Live(c) /\ Owner(c) /\ cn' = Handle(m1, f1, ev).ff
        /\ mac' = Handle(m1, f1, ev).mm
    BY DEF MacReady
  <1>2. mac.sc # c /\ c # 0 BY <1>1
  <1>3. s1 \in Fsm0 /\ s1 \notin {"idle", "disc"} BY FsmType, FsmAvail
  <1>4. mx.in = c /\ mx.isConn /\ mx.sc # c /\ mx.sess \in Sess /\ mx.fsm = s1 BY <1>2
  <1>5. Handle(m1, f1, ev) = Restart(mx, f1) BY <1>3, <1>4 DEF Handle
  <1>6. old # c /\ f1[c].net = "open" BY <1>1 DEF Live, Kill
  <1>7. Restart(mx, f1) = [mm |-> [mx EXCEPT !.sess = "streaming", !.sc = c, !.u = 0, !.q = 0, !.gc = c],
                           ff |-> [f1 EXCEPT ![c].hs = TRUE, ![c].hsSent = TRUE]]
    BY <1>1, <1>4, <1>6 DEF Restart, Live
  <1> QED BY <1>1, <1>5, <1>7 DEF ReadyPost, ReadyMac, ReadyCn

LEMMA InitInv == Init => Inv
  BY Bounds, Switches DEF Init, Inv, TypeOK, Free, CIds, Insts, Who, Links, Fsm0, Sess,
         CountsOnlySent, SessionOnCurrent, HandshakeBeforeFrames, OnlyOwnerDisplaces, InvCur, InvFresh, InvFree, InvIpad, InvIReady, InvOneReady, InvEnded, InvHs, InvGate, InvSum,
         InvListen, InvLiveOwner

THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY InitInv
  <1>2. Inv /\ [Next]_vars => Inv'
    <2> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
    <2> USE Bounds, Switches DEF Inv, TypeOK, Design, Free, CIds, Insts, Who, Links, Fsm0, Sess,
                                 CountsOnlySent, SessionOnCurrent, HandshakeBeforeFrames,
                                 OnlyOwnerDisplaces, Live, Owner, FreeId, Kill,
                                 InvCur, InvFresh, InvFree, InvIpad, InvIReady, InvOneReady, InvEnded, InvHs, InvGate, InvSum,
         InvListen, InvLiveOwner
    <2>1. CASE IpadDial BY <2>1 DEF IpadDial
    <2>2. CASE IpadReady BY <2>2 DEF IpadReady
    <2>3. CASE IpadHandshake BY <2>3 DEF IpadHandshake
    <2>4. CASE IpadFrame BY <2>4 DEF IpadFrame
    <2>5. CASE IpadLoss BY <2>5 DEF IpadLoss
    <2>6. CASE \E c \in CIds : MacAccept(c) BY <2>6 DEF MacAccept
    <2>7. CASE \E c \in CIds : MacReady(c)
      <3> PICK c \in CIds : MacReady(c) BY <2>7
      <3>1. ReadyPost(c) BY ReadyIsRestart
      <3>2. FsmStep(mac.fsm, IF cn[c].link = "awdl" THEN "awdlAvail" ELSE "wifiAvail") \in Fsm0
        BY FsmType
      <3>3. cn[c].m = "accepted" /\ cn[c].net = "open" /\ cn[c].who \in Insts
            /\ cn[c].i # "ready" /\ mac.in # c BY DEF MacReady
      <3> DEFINE old == IF mac.in # c THEN mac.in ELSE 0
      <3>4. old # c /\ old \in CIds \cup {0} /\ (old # 0 => old = mac.in) BY <3>3
      <3>5. cn' = [d \in CIds |-> IF d = c THEN [cn[c] EXCEPT !.m = "ready", !.hs = TRUE, !.hsSent = TRUE]
                                 ELSE IF d = old THEN [cn[d] EXCEPT !.net = "dead", !.m = "ended"]
                                 ELSE cn[d]]
        BY <3>1, <3>4 DEF ReadyPost, ReadyCn
      <3>6. mac' = [mac EXCEPT !.in = c, !.isConn = TRUE, !.isAWDL = (cn[c].link = "awdl"),
                               !.recov = FALSE, !.med = TRUE, !.lis = FALSE,
                               !.fsm = FsmStep(mac.fsm, IF cn[c].link = "awdl" THEN "awdlAvail" ELSE "wifiAvail"),
                               !.sess = "streaming", !.sc = c, !.u = 0, !.q = 0, !.gc = c]
        BY ONLY <3>1 DEF ReadyPost, ReadyMac
      <3>6b. UNCHANGED <<env, ipad>> BY DEF MacReady
      <3>7a. cn' \in [CIds -> [st : {"free", "used"}, link : Links, who : Who,
                         net : {"open", "dead"},
                         m : {"none", "accepted", "ready", "ended"},
                         i : {"none", "dialing", "ready", "ended"},
                         hs : BOOLEAN, fr : 0..G, ak : 0..G, hsSent : BOOLEAN]]
        BY <3>3, <3>4, <3>5
      <3>7b. mac' \in [in : CIds \cup {0}, isConn : BOOLEAN, isAWDL : BOOLEAN, recov : BOOLEAN,
                allowTO : BOOLEAN, med : BOOLEAN, fsm : Fsm0, sess : Sess,
                sc : CIds \cup {0}, u : 0..G, q : 0..G, gc : CIds \cup {0},
                pa : BOOLEAN, rto : BOOLEAN, lis : BOOLEAN]
        <4>1. mac \in [in : CIds \cup {0}, isConn : BOOLEAN, isAWDL : BOOLEAN, recov : BOOLEAN,
                allowTO : BOOLEAN, med : BOOLEAN, fsm : Fsm0, sess : Sess,
                sc : CIds \cup {0}, u : 0..G, q : 0..G, gc : CIds \cup {0},
                pa : BOOLEAN, rto : BOOLEAN, lis : BOOLEAN] OBVIOUS
        <4>2. c \in CIds /\ G \in Nat OBVIOUS
        <4> QED BY ONLY <3>2, <3>6, <4>1, <4>2 DEF Sess
      <3>7. TypeOK' BY <3>7a, <3>7b, <3>6, <3>6b
      <3>8. (CountsOnlySent /\ OnlyOwnerDisplaces /\ InvCur /\ InvFree /\ InvFresh)'
        BY <3>3, <3>4, <3>5, <3>6, <3>6b
      <3>9. (InvIpad /\ InvIReady /\ InvEnded /\ InvSum /\ InvOneReady)' BY <3>3, <3>4, <3>5, <3>6, <3>6b
      <3>10. (HandshakeBeforeFrames /\ InvHs /\ InvGate)' BY <3>3, <3>4, <3>5, <3>6, <3>6b
      <3>11. (InvListen /\ InvLiveOwner)' BY <3>3, <3>4, <3>5, <3>6, <3>6b
      <3> QED BY <3>7, <3>8, <3>9, <3>10, <3>11
    <2>8. CASE \E c \in CIds : MacTlsFail(c)
      <3> PICK c \in CIds : MacTlsFail(c) BY <2>8
      <3>1. cn[c].who = 0 /\ cn[c].m = "accepted" /\ c # mac.in /\ c # ipad.in
            /\ cn' = [cn EXCEPT ![c].net = "dead", ![c].m = "ended"] /\ UNCHANGED <<env, mac, ipad>>
        BY DEF MacTlsFail
      <3>2. TypeOK' BY <3>1
      <3>3. (InvCur /\ InvFresh /\ InvFree /\ InvIpad /\ InvIReady)' BY <3>1
      <3>4. (InvOneReady /\ InvEnded /\ InvHs /\ InvGate /\ InvSum)' BY <3>1
      <3>5. (CountsOnlySent /\ OnlyOwnerDisplaces /\ HandshakeBeforeFrames)' BY <3>1
      <3>6. (InvListen /\ InvLiveOwner)' BY <3>1
      <3> QED BY <3>2, <3>3, <3>4, <3>5, <3>6
    <2>9. CASE \E c \in CIds : MacEnd(c)
      <3> PICK c \in CIds : MacEnd(c) BY <2>9
      <3>1. FsmStep(mac.fsm, IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail") \in Fsm0
        BY FsmType
      <3> QED BY <3>1 DEF MacEnd, Handle
    <2>19. CASE MacSilent
      <3>1. FsmStep(mac.fsm, IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail") \in Fsm0
        BY FsmType
      <3> QED BY <2>19, <3>1 DEF MacSilent, Handle
    <2>10. CASE MacRecoveryTimeout
      <3>1. FsmStep(mac.fsm, IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail") \in Fsm0
        BY FsmType
      <3> QED BY <2>10, <3>1 DEF MacRecoveryTimeout, Handle
    <2>11. CASE MacEncode BY <2>11 DEF MacEncode
    <2>12. CASE MacAck BY <2>12 DEF MacAck
    <2>13. CASE Relaunch
      <3>1. /\ env.inst < MaxInst
            /\ cn' = [c \in CIds |-> IF cn[c].who = env.inst /\ cn[c].st = "used"
                                     THEN [cn[c] EXCEPT !.net = "dead"] ELSE cn[c]]
            /\ env' = [env EXCEPT !.inst = @ + 1]
            /\ ipad' = [in |-> 0, isConn |-> FALSE, sess |-> "connecting"]
            /\ UNCHANGED mac
        BY <2>13 DEF Relaunch
      <3>2. \A c \in CIds : (cn[c].st = "used" /\ cn[c].net = "open" /\ cn[c].who \in Insts)
                            => cn[c].who = env.inst
        OBVIOUS
      <3>3a. cn' \in [CIds -> [st : {"free", "used"}, link : Links, who : Who,
                         net : {"open", "dead"},
                         m : {"none", "accepted", "ready", "ended"},
                         i : {"none", "dialing", "ready", "ended"},
                         hs : BOOLEAN, fr : 0..G, ak : 0..G, hsSent : BOOLEAN]]
        BY <3>1
      <3>3b. env' \in [inst : Insts, up : [Links -> BOOLEAN], outs : 0..MaxOutside,
                flaps : 0..MaxFlaps, changes : 0..MaxChanges, dirty : BOOLEAN,
                displaced : BOOLEAN]
        BY <3>1
      <3>3c. ipad' \in [in : CIds \cup {0}, isConn : BOOLEAN, sess : Sess] BY <3>1
      <3>3. TypeOK' BY <3>1, <3>3a, <3>3b, <3>3c
      <3>4. (CountsOnlySent /\ OnlyOwnerDisplaces /\ HandshakeBeforeFrames /\ InvCur)' BY <3>1
      <3>5. (InvFresh /\ InvFree /\ InvIpad /\ InvIReady /\ InvOneReady)' BY <3>1
      <3>6. (InvEnded /\ InvHs /\ InvGate /\ InvSum /\ InvListen)' BY <3>1
      <3>7. InvLiveOwner' BY <3>1, <3>2
      <3> QED BY <3>3, <3>4, <3>5, <3>6, <3>7
    <2>14. CASE MediaEnd
      <3>1. FsmStep(mac.fsm, IF mac.isAWDL THEN "awdlUnavail" ELSE "wifiUnavail") \in Fsm0
        BY FsmType
      <3>2. mac.in # 0 => (mac.isConn /\ cn[mac.in].m = "ready") OBVIOUS
      <3>3. CASE mac.in = 0 /\ mac.isConn BY <2>14, <3>1, <3>3 DEF MediaEnd, Handle
      <3>4. CASE ~(mac.in = 0 /\ mac.isConn) BY <2>14, <3>2, <3>4 DEF MediaEnd
      <3> QED BY <3>3, <3>4
    <2>15. CASE OutsideDial BY <2>15 DEF OutsideDial
    <2>16. CASE \E l \in Links : Flap(l) BY <2>16 DEF Flap
    <2>17. CASE Change BY <2>17 DEF Change
    <2>18. CASE UNCHANGED vars BY <2>18 DEF vars
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12,
               <2>13, <2>14, <2>15, <2>16, <2>17, <2>18, <2>19 DEF Next, SysNext, EnvNext
  <1> QED BY <1>1, <1>2, PTL DEF Spec

\* The headline: a quiet state with a link up and an id left is Good.
THEOREM QuietGood ==
  ASSUME Design, Inv, Quiet, \E l \in Links : env.up[l], FreeId # {}
  PROVE  Good
  <1> USE Bounds DEF Inv, TypeOK, Design, Quiet, Good, Live, Owner, CIds, Insts, Who, Links,
                   InvCur, InvFresh, InvFree, InvIpad, InvIReady, InvOneReady, InvEnded, InvHs, InvGate, InvSum,
         InvListen, InvLiveOwner
  <1>1. ipad.in # 0 OBVIOUS
  <1> DEFINE c == ipad.in
  <1>2. cn[c].net = "open" /\ cn[c].st = "used" /\ cn[c].who = env.inst
        /\ cn[c].i \in {"dialing", "ready"} BY <1>1
  <1>3. cn[c].m # "none"
    <2> SUFFICES ASSUME cn[c].m = "none" PROVE FALSE OBVIOUS
    <2>1. ~mac.lis BY <1>2
    <2>2. mac.in # 0 /\ cn[mac.in].m = "ready" /\ cn[mac.in].who \in Insts BY <2>1
    <2>3. cn[mac.in].st = "used" BY <2>2 DEF Free
    <2>4. cn[mac.in].net = "open" BY <2>2, <2>3
    <2>5. mac.in = ipad.in BY <2>2, <2>3, <2>4
    <2> QED BY <2>2, <2>5
  <1>4. cn[c].m # "accepted" BY <1>1, <1>2
  <1>5. cn[c].m # "ended" BY <1>2
  <1>6. cn[c].m = "ready" BY <1>3, <1>4, <1>5
  <1>7. mac.in = c /\ mac.sess = "streaming" /\ mac.sc = c /\ cn[c].hsSent BY <1>2, <1>6
  <1>8. cn[c].i = "ready" /\ ~cn[c].hs /\ ipad.sess = "streaming" BY <1>1, <1>2, <1>6, <1>7
  <1>9. ~env.dirty BY <1>1, <1>2, <1>6, <1>7, <1>8
  <1> QED BY <1>1, <1>2, <1>7, <1>8, <1>9
=============================================================================
