--------------------------- MODULE FrameLoopProofs ---------------------------
(* TLAPS: under Design the iPad never shows garbage (Spec => []Inv, Inv => NoGarbage), *)
(* for any bounds, with route returns, Mac relaunches and decode failures.  RestGood   *)
(* and Settles are liveness, TLC only (FrameLoop.cfg).                                 *)
EXTENDS FrameLoop, SequenceTheorems, TLAPS

LEMMA AppendFacts == ASSUME NEW S, NEW s \in Seq(S), NEW e \in S
  PROVE /\ Append(s, e) \in Seq(S) /\ Len(Append(s, e)) = Len(s) + 1
        /\ \A i \in 1..Len(s) : Append(s, e)[i] = s[i]
        /\ Append(s, e)[Len(s) + 1] = e
  BY AppendProperties

LEMMA TailFacts == ASSUME NEW S, NEW s \in Seq(S), s # <<>>
  PROVE /\ Tail(s) \in Seq(S) /\ Len(Tail(s)) = Len(s) - 1 /\ Head(s) = s[1]
        /\ \A i \in 1..Len(Tail(s)) : Tail(s)[i] = s[i + 1]
        /\ Len(s) >= 1 /\ Head(s) \in S /\ Len(s) \in Nat
  BY HeadTailProperties

THEOREM InitInv == Init => Inv
  <1> SUFFICES ASSUME Init PROVE Inv OBVIOUS
  <1>1. TypeOK BY Bounds DEF Init, TypeOK, Codecs, Garbage, Zero
  <1>2. ChainInv BY DEF Init, ChainInv
  <1>3. EInv BY DEF Init, EInv, Last, Before
  <1>4. MacInv BY DEF Init, MacInv
  <1>5. IpInv BY DEF Init, IpInv
  <1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5 DEF Inv, Init, NoGarbage, Garbage, Zero

(* Taking the head off connection c (Recv, DecodeFail): the chain and the ghosts shift. *)
LEMMA PopInv ==
  ASSUME TypeOK, ChainInv, EInv, NEW c \in CIds, q[c] # <<>>,
         q' = [q EXCEPT ![c] = Tail(q[c])],
         lastD' = [lastD EXCEPT ![c] = Head(q[c]).scr],
         lastE' = lastE, used' = used
  PROVE /\ ChainInv' /\ EInv'
        /\ q' \in [CIds -> Seq(Msg)] /\ lastD' \in [CIds -> 0..MaxScr \cup {Garbage}]
        /\ \A d \in CIds \ {c} : q'[d] = q[d] /\ lastD'[d] = lastD[d]
        /\ lastD'[c] = Head(q[c]).scr /\ Head(q[c]) \in Msg
        /\ Head(q[c]).k = "hs" => Head(q[c]).scr = lastD[c]
        /\ Head(q[c]).k = "f" => /\ Head(q[c]).scr \in 0..MaxScr
                                 /\ ~Head(q[c]).key => Head(q[c]).base = lastD[c]
  <1> DEFINE m == Head(q[c])
  <1> DEFINE L == Len(q[c])
  <1>1. q[c] \in Seq(Msg) BY DEF TypeOK
  <1>2. /\ Tail(q[c]) \in Seq(Msg) /\ Len(Tail(q[c])) = L - 1 /\ m = q[c][1]
        /\ \A i \in 1..Len(Tail(q[c])) : Tail(q[c])[i] = q[c][i + 1]
        /\ L >= 1 /\ m \in Msg /\ L \in Nat
    BY <1>1, TailFacts
  <1>3. /\ q'[c] = Tail(q[c]) /\ \A d \in CIds \ {c} : q'[d] = q[d]
        /\ lastD'[c] = m.scr /\ \A d \in CIds \ {c} : lastD'[d] = lastD[d]
        /\ q' \in [CIds -> Seq(Msg)]
    BY <1>2 DEF TypeOK
  <1>4. lastD' \in [CIds -> 0..MaxScr \cup {Garbage}] BY <1>2, <1>3 DEF TypeOK, Msg
  <1>5. /\ m.k = "hs" => m.scr = lastD[c]
        /\ m.k = "f" => m.scr \in 0..MaxScr /\ (~m.key => m.base = lastD[c])
    <2>1. 1 \in 1..L BY <1>2
    <2>2. Before(c, 1) = lastD[c] BY DEF Before
    <2> QED BY <1>2, <2>1, <2>2 DEF ChainInv, IsF
  \* the shift: Before on the tail is Before one place later
  <1>6. \A i \in 1..L : Before(c, i)' = Before(c, i + 1)
    <2> SUFFICES ASSUME NEW i \in 1..L PROVE Before(c, i)' = Before(c, i + 1) OBVIOUS
    <2>1. CASE i = 1 BY <1>2, <1>3, <2>1 DEF Before
    <2>2. CASE i > 1
      <3>1. i - 1 \in 1..Len(Tail(q[c])) /\ q'[c][i - 1] = q[c][i] BY <1>2, <1>3, <2>2
      <3> QED BY <2>2, <3>1, <1>2 DEF Before
    <2> QED BY <1>2, <2>1, <2>2
  <1>7. ChainInv'
    <2> SUFFICES ASSUME NEW d \in CIds, NEW i \in 1..Len(q'[d])
                 PROVE (/\ ~IsF(d, i) => q[d][i].scr = Before(d, i)
                        /\ IsF(d, i) => /\ q[d][i].scr \in 0..MaxScr
                                        /\ ~q[d][i].key => q[d][i].base = Before(d, i))'
      BY DEF ChainInv
    <2>1. CASE d # c
      <3>1. q'[d] = q[d] /\ lastD'[d] = lastD[d] BY <1>3, <2>1
      <3>2. Before(d, i)' = Before(d, i) BY <3>1 DEF Before
      <3> QED BY <3>1, <3>2 DEF ChainInv, IsF
    <2>2. CASE d = c
      <3>1. i \in 1..(L - 1) /\ q'[c][i] = q[c][i + 1] /\ i + 1 \in 1..L /\ i \in 1..L
        BY <1>2, <1>3, <2>2
      <3>2. Before(c, i)' = Before(c, i + 1) BY <1>6, <3>1
      <3>3. /\ ~IsF(c, i + 1) => q[c][i + 1].scr = Before(c, i + 1)
            /\ IsF(c, i + 1) => /\ q[c][i + 1].scr \in 0..MaxScr
                                /\ ~q[c][i + 1].key => q[c][i + 1].base = Before(c, i + 1)
        BY <3>1 DEF ChainInv
      <3> QED BY <2>2, <3>1, <3>2, <3>3 DEF IsF
    <2> QED BY <2>1, <2>2
  <1>8. EInv'
    <2> SUFFICES ASSUME NEW d \in CIds
                 PROVE (/\ lastE[d] = Last(d)
                        /\ ~used[d] => q[d] = <<>> /\ lastE[d] = Garbage /\ lastD[d] = Garbage)'
      BY DEF EInv
    <2>1. CASE d # c
      <3>1. q'[d] = q[d] /\ lastD'[d] = lastD[d] BY <1>3, <2>1
      <3>2. Last(d)' = Last(d) BY <3>1 DEF Last, Before
      <3> QED BY <3>1, <3>2 DEF EInv
    <2>2. CASE d = c
      <3>1. used[c] BY <1>2 DEF EInv
      \* L is DEFINEd over q, so it stays outside primes.
      <3>2. Len(q'[c]) + 1 = L /\ L \in 1..L BY <1>2, <1>3
      <3>3. \A j \in Nat : Len(q'[c]) + 1 = j => Last(c)' = Before(c, j)' BY DEF Last
      <3>4. \A j \in 1..L : Len(q'[c]) + 1 = j => Last(c)' = Before(c, j + 1) BY <1>6, <3>3
      <3>5. Last(c)' = Last(c) BY <1>2, <3>2, <3>4 DEF Last
      <3> QED BY <2>2, <3>1, <3>5 DEF EInv
    <2> QED BY <2>1, <2>2
  <1> QED BY <1>2, <1>3, <1>4, <1>5, <1>7, <1>8

\* Parts of Inv that only read q, lastE, lastD, hsC, aw, ipRef, used.
QFrozen == UNCHANGED <<q, lastE, lastD, hsC, aw, ipRef>>

THEOREM SpecSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY InitInv
  <1>2. Inv /\ [Next]_vars => Inv'
    <2> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv' OBVIOUS
    <2> USE Bounds, Switches DEF Design
    <2>0. TypeOK /\ ChainInv /\ EInv /\ MacInv /\ IpInv /\ NoGarbage BY DEF Inv
    \* Steps that leave the queues, the ghosts and the iPad's picture alone.
    <2>a. ASSUME QFrozen, \A d \in CIds : used[d] => used'[d], TypeOK', MacInv'
          PROVE Inv'
      <3>1. ChainInv' BY <2>0, <2>a DEF QFrozen, ChainInv, Before, IsF
      <3>2. EInv' BY <2>0, <2>a DEF QFrozen, EInv, Last, Before, IsF
      <3>3. IpInv' BY <2>0, <2>a DEF QFrozen, IpInv
      <3> QED BY <2>0, <2>a, <3>1, <3>2, <3>3 DEF Inv, QFrozen, NoGarbage
    <2>1. CASE Change
      <3>1. TypeOK' BY <2>0, <2>1 DEF Change, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0, <2>1 DEF Change, env, mac, ipad, gh, MacInv
      <3> QED BY <2>0, <2>1, <2>a, <3>1, <3>2 DEF Change, env, mac, ipad, gh, QFrozen
    <2>2. CASE Lost
      <3>1. TypeOK' BY <2>0, <2>2 DEF Lost, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0, <2>2 DEF Lost, env, mac, ipad, gh, MacInv
      <3> QED BY <2>0, <2>2, <2>a, <3>1, <3>2 DEF Lost, env, mac, ipad, gh, QFrozen
    <2>3. CASE \E k \in Codecs : Restart(k)
      <3> PICK k \in Codecs : Restart(k) BY <2>3
      <3>1. TypeOK' BY <2>0 DEF Restart, env, mac, ipad, gh, TypeOK, Garbage
      <3>2. MacInv' BY <2>0 DEF Restart, env, mac, ipad, gh, MacInv
      <3> QED BY <2>0, <2>a, <3>1, <3>2 DEF Restart, env, mac, ipad, gh, QFrozen
    <2>4. CASE \E c \in CIds, w \in BOOLEAN : Connect(c, w)
      <3> PICK c \in CIds, w \in BOOLEAN : Connect(c, w) BY <2>4
      <3>1. TypeOK' BY <2>0 DEF Connect, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0 DEF Connect, env, mac, ipad, gh, MacInv, TypeOK
      <3>3. \A d \in CIds : used[d] => used'[d] BY <2>0 DEF Connect, TypeOK
      <3> QED BY <2>0, <2>a, <3>1, <3>2, <3>3 DEF Connect, env, mac, ipad, gh, QFrozen
    <2>5. CASE MacRelaunch
      <3>1. /\ q' = [c \in CIds |-> <<>>] /\ lastE' = lastD
            /\ UNCHANGED <<lastD, used, hsC, aw, ipRef>> /\ rt' = 0
        BY <2>5 DEF MacRelaunch, env, mac, ipad, gh
      <3>2. TypeOK' BY <2>0, <2>5 DEF MacRelaunch, env, mac, ipad, gh, TypeOK, Garbage
      <3>3. ChainInv' BY <3>1 DEF ChainInv
      <3>4. EInv' BY <2>0, <3>1 DEF EInv, Last, Before
      <3>5. MacInv' BY <3>1 DEF MacInv
      <3>6. (IpInv /\ NoGarbage)' BY <2>0, <3>1 DEF IpInv, NoGarbage
      <3> QED BY <3>2, <3>3, <3>4, <3>5, <3>6 DEF Inv
    <2>6. CASE \E c \in CIds : Loss(c)
      <3> PICK c \in CIds : Loss(c) BY <2>6
      \* Bulleted, so the \A ends before UNCHANGED.
      <3>1. /\ q'[c] = <<>> /\ lastE'[c] = lastD[c] /\ used[c]
            /\ \A d \in CIds \ {c} : q'[d] = q[d] /\ lastE'[d] = lastE[d]
            /\ UNCHANGED <<lastD, used, hsC, aw, ipRef>>
        BY <2>0 DEF Loss, env, mac, ipad, gh, TypeOK, Live
      <3>2. TypeOK' BY <2>0 DEF Loss, env, mac, ipad, gh, TypeOK
      <3>3. ChainInv' BY <2>0, <3>1 DEF ChainInv, Before, IsF
      <3>4. EInv'
        <4>1. Last(c)' = lastD[c]
          <5>1. Len(q'[c]) + 1 = 1 BY <3>1
          <5>2. \A j \in Nat : Len(q'[c]) + 1 = j => Last(c)' = Before(c, j)' BY DEF Last
          <5>3. Before(c, 1)' = lastD'[c] BY DEF Before
          <5> QED BY <3>1, <5>1, <5>2, <5>3
        <4>2. \A d \in CIds \ {c} : Last(d)' = Last(d) BY <3>1 DEF Last, Before
        <4> QED BY <2>0, <3>1, <4>1, <4>2 DEF EInv
      <3>5. MacInv' BY <2>0, <3>1 DEF Loss, env, mac, ipad, gh, MacInv, TypeOK
      <3>6. (IpInv /\ NoGarbage)' BY <2>0, <3>1 DEF IpInv, NoGarbage
      <3> QED BY <3>2, <3>3, <3>4, <3>5, <3>6 DEF Inv
    <2>7. CASE \E k \in BOOLEAN : Send(k)
      <3> PICK k \in BOOLEAN : Send(k) BY <2>7
      <3> DEFINE m == [k |-> "f", key |-> k, cd |-> cd, inst |-> inst, seq |-> n, scr |-> scr,
                       base |-> mlast, ep |-> 0]
      <3> DEFINE L == Len(q[rt])
      <3>1. rt \in CIds /\ m \in Msg /\ used[rt] /\ q[rt] \in Seq(Msg) /\ L \in Nat
        BY <2>0 DEF Send, env, mac, ipad, gh, TypeOK, MacInv, Msg, Codecs
      <3>2. q' = [q EXCEPT ![rt] = Append(q[rt], m)] /\ lastE' = [lastE EXCEPT ![rt] = scr]
            /\ UNCHANGED <<lastD, hsC, aw, ipRef, used, rt>> /\ ~fk' /\ mlast' = scr
        BY DEF Send, env, mac, ipad, gh
      <3>3. /\ q'[rt] \in Seq(Msg) /\ Len(q'[rt]) = L + 1
            /\ \A i \in 1..L : q'[rt][i] = q[rt][i]
            /\ q'[rt][L + 1] = m
            /\ \A d \in CIds \ {rt} : q'[d] = q[d]
        BY <2>0, <3>1, <3>2, AppendFacts DEF TypeOK
      <3>4. \A i \in 1..(L + 1) : Before(rt, i)' = Before(rt, i)
        BY <3>1, <3>2, <3>3 DEF Before
      <3>5. ~k => mlast = Before(rt, L + 1) /\ mlast \in 0..MaxScr
        BY <2>0, <3>1 DEF Send, env, mac, ipad, gh, MacInv, EInv, Last
      <3>6. TypeOK' BY <2>0, <3>1, <3>2, <3>3 DEF Send, env, mac, ipad, gh, TypeOK
      <3>7. ChainInv'
        <4> SUFFICES ASSUME NEW c \in CIds, NEW i \in 1..Len(q'[c])
                     PROVE (/\ ~IsF(c, i) => q[c][i].scr = Before(c, i)
                            /\ IsF(c, i) => /\ q[c][i].scr \in 0..MaxScr
                                            /\ ~q[c][i].key => q[c][i].base = Before(c, i))'
          BY DEF ChainInv
        <4>1. CASE c # rt BY <2>0, <3>2, <3>3, <4>1 DEF ChainInv, Before, IsF
        <4>2. CASE c = rt /\ i <= L
          <5>1. i \in 1..L /\ q'[rt][i] = q[rt][i] /\ Before(rt, i)' = Before(rt, i)
            BY <3>1, <3>3, <3>4, <4>2
          <5> QED BY <2>0, <3>2, <4>2, <5>1 DEF ChainInv, IsF
        <4>3. CASE c = rt /\ i = L + 1
          <5>1. q'[rt][L + 1].k = "f" /\ q'[rt][L + 1].scr = scr /\ q'[rt][L + 1].key = k
                /\ q'[rt][L + 1].base = mlast
            BY <3>3
          <5>2. scr \in 0..MaxScr BY <2>0 DEF TypeOK
          <5> QED BY <3>2, <3>4, <3>5, <4>3, <5>1, <5>2 DEF IsF
        <4> QED BY <3>1, <3>3, <4>1, <4>2, <4>3
      <3>8. EInv'
        <4>1. Last(rt)' = scr
          \* L is DEFINEd over q, so it must stay outside primes.
          <5>1. Len(q'[rt]) = L + 1 /\ L + 1 \in Nat BY <3>1, <3>3
          <5>2. q'[rt][L + 1].scr = scr BY <3>3
          <5>3. \A j \in Nat \ {0} : Len(q'[rt]) = j /\ q'[rt][j].scr = scr => Last(rt)' = scr
            BY <3>2 DEF Last, Before
          <5> QED BY <3>1, <5>1, <5>2, <5>3
        <4>2. \A d \in CIds \ {rt} : Last(d)' = Last(d) BY <3>2, <3>3 DEF Last, Before
        <4> QED BY <2>0, <3>1, <3>2, <3>3, <4>1, <4>2 DEF EInv, TypeOK
      <3>9. MacInv' BY <2>0, <3>1, <3>2 DEF Send, env, mac, ipad, gh, MacInv, TypeOK
      <3>10. (IpInv /\ NoGarbage)' BY <2>0, <3>2 DEF IpInv, NoGarbage
      <3> QED BY <3>6, <3>7, <3>8, <3>9, <3>10 DEF Inv
    <2>8. CASE SendHs
      <3> DEFINE m == HsMsg(ep, lastE[rt])
      <3> DEFINE L == Len(q[rt])
      <3>1. rt \in CIds /\ m \in Msg /\ q[rt] \in Seq(Msg) /\ L \in Nat /\ used[rt]
        BY <2>0, <2>8 DEF SendHs, env, mac, ipad, gh, TypeOK, MacInv, HsMsg, Msg, Codecs
      <3>2. /\ q' = [q EXCEPT ![rt] = Append(q[rt], m)]
            /\ UNCHANGED <<lastE, lastD, hsC, aw, ipRef, used, rt, fk, mlast>> /\ hsOwed' = FALSE
        BY <2>8 DEF SendHs, env, mac, ipad, gh
      <3>3. /\ q'[rt] \in Seq(Msg) /\ Len(q'[rt]) = L + 1
            /\ \A i \in 1..L : q'[rt][i] = q[rt][i]
            /\ q'[rt][L + 1] = m
            /\ \A d \in CIds \ {rt} : q'[d] = q[d]
        BY <2>0, <3>1, <3>2, AppendFacts DEF TypeOK
      <3>4. \A i \in 1..(L + 1) : Before(rt, i)' = Before(rt, i)
        BY <3>1, <3>2, <3>3 DEF Before
      <3>5. lastE[rt] = Before(rt, L + 1) BY <2>0, <3>1 DEF EInv, Last
      <3>6. TypeOK'
        <4>1. q' \in [CIds -> Seq(Msg)] BY <2>0, <3>1, <3>2, <3>3 DEF TypeOK
        <4>2. UNCHANGED <<env, cd, inst, n, mlast, cap, fk, rt, used, dead, vp, ep, ses, ipad, lastE, lastD>>
          BY <2>8 DEF SendHs, gh
        <4> QED BY <2>0, <3>2, <4>1, <4>2 DEF TypeOK, env, ipad
      <3>7. ChainInv'
        <4> SUFFICES ASSUME NEW c \in CIds, NEW i \in 1..Len(q'[c])
                     PROVE (/\ ~IsF(c, i) => q[c][i].scr = Before(c, i)
                            /\ IsF(c, i) => /\ q[c][i].scr \in 0..MaxScr
                                            /\ ~q[c][i].key => q[c][i].base = Before(c, i))'
          BY DEF ChainInv
        <4>1. CASE c # rt BY <2>0, <3>2, <3>3, <4>1 DEF ChainInv, Before, IsF
        <4>2. CASE c = rt /\ i <= L
          <5>1. i \in 1..L /\ q'[rt][i] = q[rt][i] /\ Before(rt, i)' = Before(rt, i)
            BY <3>1, <3>3, <3>4, <4>2
          <5> QED BY <2>0, <3>2, <4>2, <5>1 DEF ChainInv, IsF
        <4>3. CASE c = rt /\ i = L + 1
          <5>1. q'[rt][L + 1].k = "hs" /\ q'[rt][L + 1].scr = lastE[rt] BY <3>3 DEF HsMsg
          \* Stated with i, not L (L is DEFINEd over q and would be primed); rt' = rt from <3>2.
          <5>2. q'[rt][i].k = "hs" /\ q'[rt][i].scr = lastE[rt] BY <4>3, <5>1
          <5>3. Before(rt, i)' = lastE[rt] BY <3>1, <3>4, <3>5, <4>3
          <5>4. (~IsF(rt, i) => q[rt][i].scr = Before(rt, i))' BY <3>2, <5>2, <5>3 DEF IsF
          <5>5. (IsF(rt, i) => /\ q[rt][i].scr \in 0..MaxScr
                               /\ ~q[rt][i].key => q[rt][i].base = Before(rt, i))' BY <3>2, <5>2 DEF IsF
          <5> QED BY <3>2, <4>3, <5>4, <5>5
        <4> QED BY <3>1, <3>3, <4>1, <4>2, <4>3
      <3>8. EInv'
        <4>1. Last(rt)' = lastE[rt]
          <5>1. Len(q'[rt]) = L + 1 /\ L + 1 \in Nat BY <3>1, <3>3
          <5>2. q'[rt][L + 1].scr = lastE[rt] BY <3>3 DEF HsMsg
          <5>3. \A j \in Nat \ {0} : Len(q'[rt]) = j /\ q'[rt][j].scr = lastE[rt] => Last(rt)' = lastE[rt]
            BY <3>2 DEF Last, Before
          <5> QED BY <3>1, <5>1, <5>2, <5>3
        <4>2. \A d \in CIds \ {rt} : Last(d)' = Last(d) BY <3>2, <3>3 DEF Last, Before
        <4> QED BY <2>0, <3>1, <3>2, <3>3, <4>1, <4>2 DEF EInv, TypeOK
      <3>9. MacInv' BY <2>0, <3>2 DEF MacInv
      <3>10. (IpInv /\ NoGarbage)' BY <2>0, <3>2 DEF IpInv, NoGarbage
      <3> QED BY <3>6, <3>7, <3>8, <3>9, <3>10 DEF Inv
    <2>9. CASE \E c \in CIds : Recv(c)
      <3> PICK c \in CIds : Recv(c) BY <2>9
      <3> DEFINE m == Head(q[c])
      <3>1. q[c] # <<>> /\ q' = [q EXCEPT ![c] = Tail(q[c])]
            /\ lastD' = [lastD EXCEPT ![c] = m.scr]
            /\ UNCHANGED <<lastE, used, rt, fk, mlast>>
        BY DEF Recv, env, mac, ipad, gh
      <3>2. /\ ChainInv' /\ EInv'
            /\ q' \in [CIds -> Seq(Msg)] /\ lastD' \in [CIds -> 0..MaxScr \cup {Garbage}]
            /\ \A d \in CIds \ {c} : q'[d] = q[d] /\ lastD'[d] = lastD[d]
            /\ lastD'[c] = m.scr /\ m \in Msg
            /\ m.k = "hs" => m.scr = lastD[c]
            /\ m.k = "f" => /\ m.scr \in 0..MaxScr
                            /\ ~m.key => m.base = lastD[c]
        BY <2>0, <3>1, PopInv
      <3>3. TypeOK'
        <4>1. (ipRef \in 0..MaxScr \cup {Garbage, Zero} /\ aw \in BOOLEAN /\ hsC \in CIds \cup {0}
               /\ hsE \in Nat /\ ipS \in Nat /\ ipInst \in Nat /\ reqOwed \in BOOLEAN /\ vpOwed \in BOOLEAN)'
          BY <2>0, <3>2 DEF Recv, env, mac, ipad, gh, TypeOK, Msg, Apply
        <4> QED BY <2>0, <3>1, <3>2, <4>1 DEF Recv, env, mac, ipad, gh, TypeOK
      <3>4. MacInv' BY <2>0, <3>1 DEF MacInv
      <3>5. (IpInv /\ NoGarbage)'
        <4>1. CASE m.k = "hs"
          <5>1. lastD' = lastD BY <2>0, <3>1, <3>2, <4>1 DEF TypeOK
          <5> QED BY <2>0, <4>1, <5>1 DEF Recv, env, mac, ipad, gh, IpInv, NoGarbage
        <4>2. CASE m.k = "f" /\ c # hsC BY <2>0, <3>2, <4>2 DEF Recv, env, mac, ipad, gh, IpInv, NoGarbage
        <4>3. CASE m.k = "f" /\ c = hsC /\ m.key
          BY <2>0, <3>2, <4>3 DEF Recv, env, mac, ipad, gh, IpInv, NoGarbage, Garbage
        <4>4. CASE m.k = "f" /\ c = hsC /\ ~m.key /\ aw BY <2>0, <3>2, <4>4 DEF Recv, env, mac, ipad, gh, IpInv, NoGarbage
        <4>5. CASE m.k = "f" /\ c = hsC /\ ~m.key /\ ~aw
          <5>1. ipRef = m.base /\ m.base # Garbage /\ m.base \in 0..MaxScr
            BY <2>0, <3>2, <4>5 DEF IpInv, Garbage
          <5>2. ipRef' = m.scr BY <5>1, <4>5 DEF Recv, env, mac, ipad, gh, Apply
          <5> QED BY <2>0, <3>2, <4>5, <5>2 DEF Recv, env, mac, ipad, gh, IpInv, NoGarbage, Garbage
        <4> QED BY <3>2, <4>1, <4>2, <4>3, <4>4, <4>5 DEF Msg
      <3> QED BY <3>2, <3>3, <3>4, <3>5 DEF Inv
    <2>10. CASE \E c \in CIds : DecodeFail(c)
      <3> PICK c \in CIds : DecodeFail(c) BY <2>10
      <3>1. q[c] # <<>> /\ q' = [q EXCEPT ![c] = Tail(q[c])]
            /\ lastD' = [lastD EXCEPT ![c] = Head(q[c]).scr]
            /\ UNCHANGED <<lastE, used, rt, fk, mlast, ipRef>>
        BY DEF DecodeFail, mac
      <3>2. /\ ChainInv' /\ EInv'
            /\ q' \in [CIds -> Seq(Msg)] /\ lastD' \in [CIds -> 0..MaxScr \cup {Garbage}]
        BY <2>0, <3>1, PopInv
      <3>3. TypeOK' BY <2>0, <3>1, <3>2 DEF DecodeFail, env, mac, ipad, gh, TypeOK
      <3>4. MacInv' BY <2>0, <3>1 DEF MacInv
      \* AwaitOnFail: the failed key leaves the iPad awaiting, so IpInv holds vacuously.
      <3>5. (IpInv /\ NoGarbage)' BY <2>0, <3>1 DEF DecodeFail, IpInv, NoGarbage
      <3> QED BY <3>2, <3>3, <3>4, <3>5 DEF Inv
    <2>11. CASE \E ok \in BOOLEAN : Request(ok)
      <3> PICK ok \in BOOLEAN : Request(ok) BY <2>11
      <3>1. TypeOK' BY <2>0 DEF Request, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0 DEF Request, env, mac, ipad, gh, MacInv
      <3> QED BY <2>0, <2>a, <3>1, <3>2 DEF Request, env, mac, ipad, gh, QFrozen
    <2>12. CASE \E ok \in BOOLEAN : SendVp(ok)
      <3> PICK ok \in BOOLEAN : SendVp(ok) BY <2>12
      <3>1. TypeOK' BY <2>0 DEF SendVp, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0 DEF SendVp, env, mac, ipad, gh, MacInv
      <3> QED BY <2>0, <2>a, <3>1, <3>2 DEF SendVp, env, mac, ipad, gh, QFrozen
    <2>13. CASE UNCHANGED vars
      <3>1. TypeOK' BY <2>0, <2>13 DEF vars, env, mac, ipad, gh, TypeOK
      <3>2. MacInv' BY <2>0, <2>13 DEF vars, mac, gh, MacInv
      <3> QED BY <2>0, <2>a, <2>13, <3>1, <3>2 DEF vars, QFrozen, mac, ipad, gh
    <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11, <2>12, <2>13
      DEF Next, EnvNext, SysNext
  <1> QED BY <1>1, <1>2, PTL DEF Spec

THEOREM NoGarbageThm == ASSUME Design PROVE Spec => []NoGarbage
  BY SpecSafe, PTL DEF Inv
=============================================================================
