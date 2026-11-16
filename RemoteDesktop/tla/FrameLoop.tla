------------------------------ MODULE FrameLoop ------------------------------
(***************************************************************************)
(* The frame loop end to end, across reconnects and codec switches: what   *)
(* picture the iPad shows, and whether it is the Mac's screen.  Composes   *)
(* the per-stage models (DeltaSync, StripeSync, WiFiSendLoop, FrameRing)   *)
(* across the transitions none of them covers.  Facts: .planning/research/ *)
(* frameloop-inventory-2026-11-16.md and frameloop-recheck-2026-11-16.md   *)
(* (after the Lifecycle fix).  Ack gate: WiFiSendLoop + Lifecycle.          *)
(*                                                                         *)
(* As built [C] (2026-11-16, today's tree):                                *)
(*  - Both codecs are delta chains: LZ4 XOR deltas (FrameCompressor.c) and *)
(*    HEVC P-frames.  A delta decodes right iff the iPad's picture is the  *)
(*    delta's base (content semantics, DeltaSync T3); else garbage.        *)
(*  - Frames lost after encode, seq consumed, no keyframe forced: FF1      *)
(*    onFrame guard (mS:1409-1416), FF2 no transport (mS:1632/1673, no     *)
(*    else), FF3 USB nil/send error.  Action Lost.                          *)
(*  - A new route sends the handshake and forces a keyframe only on the     *)
(*    session (re)start paths (onTransportConnected; FE1 else-branch        *)
(*    mS:834-847; LC Restart).  FF29 (FE1 first branch, USB_NCM label) and *)
(*    the immediate fallback (mS:1041-1050) switch the route with neither.  *)
(*    Action Connect(c, w): w = the restart path.                           *)
(*  - The handshake goes out on S, frames on KQ/VT: nothing orders them on *)
(*    one connection (recheck section 2, windows A-C).  Action SendHs is    *)
(*    separate from Send.                                                   *)
(*  - iPad, handshake: new zero-reference LZ4 decompressor (iS:1022, FF10), *)
(*    sized to display dims so LZ4 frames fail until the geometry update   *)
(*    (rc=-6); then the viewport report.  Zero is not a picture: a delta    *)
(*    on it is garbage.                                                     *)
(*  - iPad accepts media from every connection (HEVC from any; LZ4 over    *)
(*    wireless dropped, iS:1123: a link detail not modelled, F4).  LZ4 has  *)
(*    no gap detection (crc and seq never checked).  HEVC: the reassembler  *)
(*    detects a seq gap, drops until a keyframe and asks for one ONCE      *)
(*    (UR:469); the ask is silently dropped while usbTransport.isConnected *)
(*    (iS:1410).  Decoder errors ask nothing (FF15).                       *)
(*  - Viewport report: one per handshake, sent by the global USB flag, no  *)
(*    retry (iS:1043, 1436-1446, iU:550): lost when that link is dead       *)
(*    (FF20/K3).  The Mac defers capture/encoder until the first viewport   *)
(*    (mS:1227/1256); _viewportReceived is never reset.                    *)
(*  - Static screen: SCStream delivers only complete frames; idle sends     *)
(*    nothing, so a forced keyframe waits for the next change (recheck §3). *)
(*    The E2E synthetic source ticks always (IdleTicks).                    *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  F1 Each connection is FIFO and reliable until it dies; a dead          *)
(*     connection's queue is lost (TCP; Lifecycle L-rows).                  *)
(*  F2 The Mac encodes serially per instance (KQ serial; VT in order,      *)
(*     U-Q1 non-blocking) and sends each frame on the route at encode time. *)
(*  F3 A keyframe request is honoured (encoder active: HE:211) and a retry  *)
(*     waits for the previous keyframe to arrive or be lost (cooldown >     *)
(*     delivery time).                                                      *)
(*  F4 Codec, link and stripe details are abstracted: an encoder restart or *)
(*     codec switch is a new instance whose first frame is a keyframe.      *)
(*  F5 Bounded environment: connections, route changes, screen changes,    *)
(*     losses, restarts, Mac agent relaunches, decode failures.            *)
(*  F6 The route can return to a connection used before (USB unplugged     *)
(*     while the wireless connection stayed up), so a connection carries   *)
(*     any number of handshakes.  A Mac relaunch kills every connection of *)
(*     the old instance (its sockets close) and starts with nothing.       *)
(*  F7 A frame can fail to decode on the iPad (LZ4 size mismatch rc=-6,    *)
(*     HEVC session error); the shown picture stays, the reference is not  *)
(*     trusted.                                                            *)
(*                                                                         *)
(* Mechanisms (CONSTANT switches):                                         *)
(*  KeyOnBreak  Mac: after a lost frame or a route change the next frame   *)
(*              is a keyframe (as built: restart paths only).              *)
(*  HsConn      every route change sends a handshake carrying the Mac's    *)
(*              route epoch; the iPad ignores an older one (handshakes on  *)
(*              two connections race), takes media only from the latest   *)
(*              handshake's connection, the                                *)
(*              handshake does not touch the decoder, and a delta needs an *)
(*              unbroken chain since a keyframe on that connection.        *)
(*  KeyRetry    iPad: while waiting for a keyframe it asks (again after a  *)
(*              lost one), on its handshake connection, for both codecs.   *)
(*  VpOnHsConn  iPad: the viewport report goes on the handshake's          *)
(*              connection (lost only if that connection dies).            *)
(*  IdleKey     Mac: a forced keyframe is encoded from the last captured   *)
(*              surface without waiting for a screen change.               *)
(*  EpochMonotone  the Mac's route epoch keeps rising across relaunches    *)
(*              (taken from the wall clock); off: it restarts at 0 and the *)
(*              iPad ignores the new instance's handshakes.  Code: the max *)
(*              of last+1, the persisted last epoch+1 and 16/s of wall     *)
(*              clock; assumed: the clock does not step back past what the *)
(*              persisted value covers (both lost at once).                *)
(*  AwaitOnFail iPad: a frame that fails to decode makes it wait for a     *)
(*              keyframe (as built: the next delta applies to a stale      *)
(*              reference; FF15 asks for nothing).                         *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS MaxConn, MaxRoute, MaxScr, MaxLost, MaxRestart, MaxRelaunch, MaxFail, IdleTicks,
          KeyOnBreak, HsConn, KeyRetry, VpOnHsConn, IdleKey, EpochMonotone, AwaitOnFail

ASSUME Bounds == /\ {MaxConn, MaxRoute, MaxScr, MaxLost, MaxRestart, MaxRelaunch, MaxFail} \subseteq Nat
ASSUME Switches == {IdleTicks, KeyOnBreak, HsConn, KeyRetry, VpOnHsConn, IdleKey,
                    EpochMonotone, AwaitOnFail} \subseteq BOOLEAN

CIds    == 1..MaxConn
Garbage == -1
Zero    == -2           \* the zero reference after an as-built handshake
Codecs  == {"lz4", "hevc"}
\* scr: a frame's content; on a handshake a ghost, the content of the frame enqueued before it
\* (the picture "so far" on that connection), so the chain runs through handshakes.
Msg     == [k : {"hs", "f"}, key : BOOLEAN, cd : Codecs, inst : Nat, seq : Nat,
            scr : 0..MaxScr \cup {Garbage}, base : 0..MaxScr \cup {Garbage}, ep : Nat]
HsMsg(e, s) == [k |-> "hs", key |-> FALSE, cd |-> "lz4", inst |-> 0, seq |-> 0, scr |-> s, base |-> 0, ep |-> e]
Id(m)   == <<m.inst, m.seq>>
Pred(m) == <<m.inst, m.seq - 1>>

VARIABLES
  \* environment
  scr, losts, restarts, relaunches, fails,
  \* Mac
  cd, inst, n, mlast, cap, fk, rt, used, dead, hsOwed, vp, ep, ses,
  \* connections
  q,
  \* iPad
  hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, vpOwed,
  \* ghosts (proof): content of the frame last enqueued on / dequeued from each
  \* connection (Garbage = none yet)
  lastE, lastD

env  == <<scr, losts, restarts, relaunches, fails>>
mac  == <<cd, inst, n, mlast, cap, fk, rt, used, dead, hsOwed, vp, ep, ses>>
ipad == <<hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, vpOwed>>
gh   == <<lastE, lastD>>
vars == <<env, mac, q, ipad, gh>>

Init ==
  /\ scr = 0 /\ losts = 0 /\ restarts = 0 /\ relaunches = 0 /\ fails = 0
  /\ cd \in Codecs /\ inst = 0 /\ n = 0 /\ mlast = Garbage /\ cap = Garbage /\ fk = TRUE
  /\ rt = 0 /\ used = [c \in CIds |-> FALSE] /\ dead = [c \in CIds |-> FALSE]
  /\ hsOwed = FALSE /\ vp = FALSE /\ ep = 0 /\ ses = FALSE
  /\ q = [c \in CIds |-> <<>>]
  /\ hsC = 0 /\ hsE = 0 /\ ipRef = Zero /\ aw = TRUE /\ ipS = 0 /\ ipInst = 0
  /\ reqOwed = FALSE /\ vpOwed = FALSE
  /\ lastE = [c \in CIds |-> Garbage] /\ lastD = [c \in CIds |-> Garbage]

Live(c) == c \in CIds /\ used[c] /\ ~dead[c]

(* ---------------- environment ---------------- *)

Change == /\ scr < MaxScr /\ scr' = scr + 1
          /\ UNCHANGED <<losts, restarts, relaunches, fails, mac, q, ipad, gh>>

\* A route change: a connection carries the media from now on, a new one or a live one used
\* before (F6).  w: the session (re)start path (handshake + forced keyframe); ~w: FF29 /
\* immediate fallback, only once this instance has a session (ses).  ep: the route epoch.
Connect(c, w) ==
  /\ ep < MaxRoute
  /\ ~used[c] \/ (Live(c) /\ c # rt)
  /\ ~w => ses /\ ~hsOwed     \* both on S: never between start and its handshake
  /\ used' = [used EXCEPT ![c] = TRUE] /\ rt' = c /\ ep' = ep + 1 /\ ses' = TRUE
  /\ hsOwed' = (w \/ HsConn)
  /\ fk' = (fk \/ w \/ KeyOnBreak)
  /\ UNCHANGED <<env, cd, inst, n, mlast, cap, dead, vp, q, ipad, gh>>

\* A connection dies with its queue (F1).
Loss(c) ==
  /\ Live(c)
  /\ dead' = [dead EXCEPT ![c] = TRUE] /\ q' = [q EXCEPT ![c] = <<>>]
  /\ lastE' = [lastE EXCEPT ![c] = lastD[c]]
  /\ rt' = IF rt = c THEN 0 ELSE rt
  /\ UNCHANGED <<env, cd, inst, n, mlast, cap, fk, used, hsOwed, vp, ep, ses, ipad, lastD>>

\* Encoder restart or codec switch (F4): new instance, first frame a keyframe.
Restart(k) ==
  /\ restarts < MaxRestart /\ restarts' = restarts + 1
  /\ cd' = k /\ inst' = inst + 1 /\ n' = 0 /\ mlast' = Garbage /\ fk' = TRUE
  /\ UNCHANGED <<scr, losts, relaunches, fails, cap, rt, used, dead, hsOwed, vp, ep, ses, q, ipad, gh>>

\* The Mac agent relaunches (F6): every connection it had dies with its queue; the new
\* instance has no route, no session, no viewport, no capture and a new encoder.  Its route
\* epoch continues (EpochMonotone, wall clock) or restarts at 0.
MacRelaunch ==
  /\ relaunches < MaxRelaunch /\ relaunches' = relaunches + 1
  /\ dead' = [c \in CIds |-> dead[c] \/ used[c]] /\ q' = [c \in CIds |-> <<>>]
  /\ lastE' = lastD
  /\ inst' = inst + 1 /\ n' = 0 /\ mlast' = Garbage /\ cap' = Garbage /\ fk' = TRUE
  /\ rt' = 0 /\ hsOwed' = FALSE /\ vp' = FALSE /\ ses' = FALSE
  /\ ep' = IF EpochMonotone THEN ep ELSE 0
  /\ UNCHANGED <<scr, losts, restarts, fails, cd, used, ipad, lastD>>

(* ---------------- Mac ---------------- *)

\* A capture is available: the screen changed since the last one, or a forced keyframe
\* is owed and the source ticks regardless (synthetic, IdleTicks) or the Mac re-encodes
\* the last surface (IdleKey).  Identical idle captures are not modelled (no new picture).
CanCapture == scr # cap \/ ((IdleTicks \/ IdleKey) /\ fk)

\* Encode and send on the route.
Send(k) ==
  /\ rt # 0 /\ vp /\ CanCapture
  /\ (fk \/ n = 0) => k
  /\ q' = [q EXCEPT ![rt] = Append(q[rt], [k |-> "f", key |-> k, cd |-> cd, inst |-> inst,
                                            seq |-> n, scr |-> scr, base |-> mlast, ep |-> 0])]
  /\ lastE' = [lastE EXCEPT ![rt] = scr]
  /\ n' = n + 1 /\ mlast' = scr /\ cap' = scr /\ fk' = FALSE
  /\ UNCHANGED <<env, cd, inst, rt, used, dead, hsOwed, vp, ep, ses, ipad, lastD>>

\* Encoded but never sent (FF1, FF2, FF3): the seq and the reference advance.
Lost ==
  /\ losts < MaxLost /\ losts' = losts + 1 /\ vp /\ CanCapture
  /\ n' = n + 1 /\ mlast' = scr /\ cap' = scr
  /\ fk' = (fk \/ KeyOnBreak)
  /\ UNCHANGED <<scr, restarts, relaunches, fails, cd, inst, rt, used, dead, hsOwed, vp, ep, ses, q, ipad, gh>>

SendHs ==
  /\ hsOwed /\ rt # 0
  /\ q' = [q EXCEPT ![rt] = Append(q[rt], HsMsg(ep, lastE[rt]))] /\ hsOwed' = FALSE
  /\ UNCHANGED <<env, cd, inst, n, mlast, cap, fk, rt, used, dead, vp, ep, ses, ipad, gh>>

(* ---------------- iPad ---------------- *)

Apply(m) == IF ipRef = m.base /\ m.base # Garbage THEN m.scr ELSE Garbage

Recv(c) ==
  /\ q[c] # <<>>
  /\ LET m == Head(q[c]) IN
     /\ q' = [q EXCEPT ![c] = Tail(q[c])]
     /\ lastD' = [lastD EXCEPT ![c] = m.scr]
     /\ IF m.k = "hs" THEN
          \* HsConn: a handshake older than the iPad's latest is ignored (route epoch)
          IF HsConn /\ m.ep <= hsE THEN UNCHANGED <<hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, vpOwed>>
          ELSE /\ vpOwed' = TRUE /\ hsC' = c /\ hsE' = m.ep
               /\ IF HsConn THEN aw' = TRUE /\ UNCHANGED <<ipRef, ipS, ipInst, reqOwed>>
                            ELSE ipRef' = Zero /\ UNCHANGED <<aw, ipS, ipInst, reqOwed>>
        ELSE IF HsConn THEN
          \* media only from the handshake connection; a delta needs an unbroken chain
          IF c # hsC THEN UNCHANGED <<hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, vpOwed>>
          ELSE IF m.key THEN /\ ipRef' = m.scr /\ aw' = FALSE /\ ipS' = m.seq /\ ipInst' = m.inst
                             /\ UNCHANGED <<hsC, hsE, reqOwed, vpOwed>>
          ELSE IF aw THEN UNCHANGED <<hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, vpOwed>>
          ELSE /\ ipRef' = Apply(m) /\ ipS' = m.seq /\ ipInst' = m.inst
               /\ UNCHANGED <<hsC, hsE, aw, reqOwed, vpOwed>>
        ELSE \* as built: every connection; HEVC gap detection, LZ4 none
          IF m.key THEN /\ ipRef' = m.scr /\ aw' = FALSE /\ ipS' = m.seq /\ ipInst' = m.inst
                        /\ UNCHANGED <<hsC, hsE, reqOwed, vpOwed>>
          ELSE IF m.cd = "hevc" /\ (aw \/ m.seq # ipS + 1) THEN
               /\ aw' = TRUE /\ reqOwed' = (reqOwed \/ ~aw)
               /\ UNCHANGED <<hsC, hsE, ipRef, ipS, ipInst, vpOwed>>
          ELSE /\ ipRef' = Apply(m) /\ ipS' = m.seq /\ ipInst' = m.inst
               /\ UNCHANGED <<hsC, hsE, aw, reqOwed, vpOwed>>
  /\ UNCHANGED <<env, mac, lastE>>

\* A frame the iPad decodes fails (F7): the shown picture stays.  AwaitOnFail: wait for a
\* keyframe.  As built nothing changes, so the next delta applies to a reference the Mac's
\* chain has moved past.  Under HsConn only frames from the handshake connection are decoded.
DecodeFail(c) ==
  /\ fails < MaxFail /\ fails' = fails + 1
  /\ q[c] # <<>> /\ Head(q[c]).k = "f" /\ (HsConn => c = hsC)
  /\ q' = [q EXCEPT ![c] = Tail(q[c])] /\ lastD' = [lastD EXCEPT ![c] = Head(q[c]).scr]
  /\ aw' = (aw \/ AwaitOnFail)
  /\ UNCHANGED <<scr, losts, restarts, relaunches, mac, hsC, hsE, ipRef, ipS, ipInst, reqOwed, vpOwed, lastE>>

NoKeyInFlight(c) == \A i \in 1..Len(q[c]) : ~(q[c][i].k = "f" /\ q[c][i].key)

\* Keyframe request.  KeyRetry: whenever waiting, on the handshake connection, after the
\* previous keyframe arrived or was lost (F3).  As built: once per gap (reqOwed), and
\* silently dropped when the USB flag is up (ok = FALSE).
Request(ok) ==
  /\ IF KeyRetry THEN /\ aw /\ Live(hsC) /\ rt = hsC /\ ~fk /\ NoKeyInFlight(hsC) /\ ok
                      /\ fk' = TRUE
                      /\ UNCHANGED reqOwed
                 ELSE /\ reqOwed /\ reqOwed' = FALSE
                      /\ fk' = (fk \/ (ok /\ rt # 0))
  /\ UNCHANGED <<env, cd, inst, n, mlast, cap, rt, used, dead, hsOwed, vp, ep, ses, q,
                 hsC, hsE, ipRef, aw, ipS, ipInst, vpOwed, gh>>

\* Viewport report after a handshake.  VpOnHsConn: delivered iff the handshake's
\* connection lives.  As built: by the USB flag, lost if that link is dead (ok = FALSE).
SendVp(ok) ==
  /\ vpOwed /\ vpOwed' = FALSE
  /\ vp' = (vp \/ IF VpOnHsConn THEN Live(hsC) ELSE ok)
  /\ UNCHANGED <<env, cd, inst, n, mlast, cap, fk, rt, used, dead, hsOwed, ep, ses, q,
                 hsC, hsE, ipRef, aw, ipS, ipInst, reqOwed, gh>>

(* ---------------- spec ---------------- *)

EnvNext == Change \/ Lost \/ (\E k \in Codecs : Restart(k)) \/ MacRelaunch
           \/ (\E c \in CIds, w \in BOOLEAN : Connect(c, w)) \/ (\E c \in CIds : Loss(c))
           \/ (\E c \in CIds : DecodeFail(c))
SysNext == (\E k \in BOOLEAN : Send(k)) \/ SendHs \/ (\E c \in CIds : Recv(c))
           \/ (\E ok \in BOOLEAN : Request(ok)) \/ (\E ok \in BOOLEAN : SendVp(ok))
Next == EnvNext \/ SysNext
Spec == Init /\ [][Next]_vars
\* Fair delivery: the true branches (a request or report that gets through) are fair.
FairSpec == Spec /\ WF_vars(\E k \in BOOLEAN : Send(k)) /\ WF_vars(SendHs)
            /\ \A c \in CIds : WF_vars(Recv(c))
            /\ WF_vars(Request(TRUE)) /\ WF_vars(SendVp(TRUE))

(* ---------------- properties ---------------- *)

NoGarbage == ipRef # Garbage

\* At rest (no system step enabled) with a live route, the iPad shows the screen.
Rest == ~ENABLED SysNext
RestGood == Rest => (Live(rt) => ipRef = scr)
Settles == <>[]Rest

\* Witness rows: negate a good outcome.
NeverShowsLast == ~(ipRef = MaxScr /\ scr = MaxScr)

(* ---------------- inductive invariant (TLAPS: FrameLoopProofs) ---------------- *)

TypeOK ==
  /\ scr \in 0..MaxScr /\ losts \in Nat /\ restarts \in Nat
  /\ cd \in Codecs /\ inst \in Nat /\ n \in Nat
  /\ mlast \in 0..MaxScr \cup {Garbage} /\ cap \in 0..MaxScr \cup {Garbage} /\ fk \in BOOLEAN
  /\ rt \in CIds \cup {0} /\ used \in [CIds -> BOOLEAN] /\ dead \in [CIds -> BOOLEAN]
  /\ hsOwed \in BOOLEAN /\ vp \in BOOLEAN /\ ep \in Nat
  /\ q \in [CIds -> Seq(Msg)]
  /\ hsC \in CIds \cup {0} /\ hsE \in Nat /\ ipRef \in 0..MaxScr \cup {Garbage, Zero}
  /\ aw \in BOOLEAN /\ ipS \in Nat /\ ipInst \in Nat /\ reqOwed \in BOOLEAN /\ vpOwed \in BOOLEAN
  /\ relaunches \in Nat /\ fails \in Nat /\ ses \in BOOLEAN
  /\ lastE \in [CIds -> 0..MaxScr \cup {Garbage}] /\ lastD \in [CIds -> 0..MaxScr \cup {Garbage}]

IsF(c, i) == q[c][i].k = "f"
\* Content of the message before position i on c (handshakes pass the content through).
Before(c, i) == IF i = 1 THEN lastD[c] ELSE q[c][i - 1].scr
Last(c) == Before(c, Len(q[c]) + 1)

\* Chain: a delta's base is the content before it on its connection; a handshake passes it on.
ChainInv == \A c \in CIds : \A i \in 1..Len(q[c]) :
              /\ ~IsF(c, i) => q[c][i].scr = Before(c, i)
              /\ IsF(c, i) => /\ q[c][i].scr \in 0..MaxScr
                              /\ ~q[c][i].key => q[c][i].base = Before(c, i)
EInv == \A c \in CIds : /\ lastE[c] = Last(c)
                        /\ ~used[c] => q[c] = <<>> /\ lastE[c] = Garbage /\ lastD[c] = Garbage
\* Mac: nothing lost since the last frame enqueued on the route.
MacInv == /\ rt # 0 => used[rt]
          /\ (rt # 0 /\ ~fk) => lastE[rt] = mlast /\ mlast \in 0..MaxScr
\* iPad: in step with its handshake connection.
IpInv == ~aw => hsC \in CIds /\ ipRef = lastD[hsC] /\ ipRef \in 0..MaxScr

Inv == TypeOK /\ ChainInv /\ EInv /\ MacInv /\ IpInv /\ NoGarbage

Design == KeyOnBreak /\ HsConn /\ KeyRetry /\ VpOnHsConn /\ IdleKey /\ EpochMonotone /\ AwaitOnFail
=============================================================================
