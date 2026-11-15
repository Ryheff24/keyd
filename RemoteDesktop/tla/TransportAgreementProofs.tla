---------------------- MODULE TransportAgreementProofs ----------------------
(* TLAPS proof that, under Design, every reachable state of the switching  *)
(* model keeps three properties at every step, through any sequence of     *)
(* plugs, unplugs, Wi-Fi and AWDL changes, address changes and late        *)
(* callbacks, for any bounds:                                               *)
(*   LabelsMatch          each side's transport state names the exact link *)
(*                        it sends on, AWDL apart from Wi-Fi (DerivedState);*)
(*   StreamOnlyWithRoute  the Mac streams only while it has a route        *)
(*                        (DerivedState);                                   *)
(*   CodecMatches         LZ4 only on USB, HEVC on wireless (RouteResync). *)
(* Convergence (both sides streaming on USB whenever the cable is in, and   *)
(* so on) is progress, not safety: TLC checks it at rest under bounded     *)
(* flapping, with <>[]Rest under fairness.  It is not proved here.          *)
(* Controls (Makefile): replacing one switch in Design by TRUE must fail at *)
(* exactly that switch's steps.                                             *)
EXTENDS TransportAgreement, TLAPS

USE Bounds, Switches DEF Links, WLinks, Chans, States, Events, Sess

EnvT  == [phys : [Links -> BOOLEAN], flaps : 0..MaxFlaps, addrGen : 1..MaxGen,
          last : Links \cup {"none"}, lastGen : 1..MaxGen, cut : BOOLEAN]
NetT  == [conn : [Chans -> {"none", "open", "dead"}], wlKind : WLinks,
          hs : [Chans -> BOOLEAN], addr : [Chans -> 0..MaxGen], vp : [Chans -> BOOLEAN]]
MacT  == [fsm : States, sess : Sess, mode : {"lz4", "hevc"}, vpKnown : BOOLEAN,
          iface : BOOLEAN, sees : [Chans -> BOOLEAN], attempts : 0..MaxAttempts]
IpadT == [fsm : States, sess : Sess, iface : BOOLEAN, sees : [Chans -> BOOLEAN],
          peerGen : 0..MaxGen, usbPending : BOOLEAN, hsOK : BOOLEAN]
RouteT == {"usb", "wl", "none"}
\* The link a route runs over when the wireless connection is of kind w.
LinkW(r, w) == CASE r = "usb" -> "usb" [] r = "wl" -> w [] OTHER -> "none"

LEMMA TypeDef == TypeOK <=> env \in EnvT /\ net \in NetT /\ mac \in MacT /\ ipad \in IpadT
  BY DEF TypeOK, EnvT, NetT, MacT, IpadT

Inv == TypeOK /\ LabelsMatch /\ StreamOnlyWithRoute /\ CodecMatches

-----------------------------------------------------------------------------
(* Building blocks.                                                          *)

LEMMA RouteType == ASSUME NEW s \in [Chans -> BOOLEAN] PROVE Route(s) \in RouteT
  BY DEF Route, RouteT

LEMMA FsmType == ASSUME NEW c \in States, NEW e \in Events
                 PROVE /\ Fsm(c, e).s \in States
                       /\ Fsm(c, e).codec \in {"lz4", "hevc", "none"}
                       /\ Fsm(c, e).eff \in BOOLEAN
  BY DEF Fsm, T

LEMMA FsmFallback == /\ Fsm("disc", "wifiAvail").s = "wifi"
                     /\ Fsm("disc", "wifiAvail").codec = "hevc"
                     /\ Fsm("disc", "wiredAppeared").s = "usb"
                     /\ Fsm("disc", "wiredAppeared").codec = "lz4"
  BY DEF Fsm, T

LEMMA StateOfLink == ASSUME net.wlKind \in WLinks, NEW r \in RouteT, NEW c \in States
                     PROVE StateOf(r, c) \in States /\ Label(StateOf(r, c)) = LinkW(r, net.wlKind)
  BY DEF StateOf, Label, LinkW, RouteT

LEMMA MacModeType == ASSUME NEW m \in MacT, NEW c \in {"lz4", "hevc", "none"}
                     PROVE MacMode(m, c) \in {"lz4", "hevc"}
  BY DEF MacMode, MacT

LEMMA ConnectedType == ASSUME NEW m \in MacT
                       PROVE Connected(m) \in MacT /\ Connected(m).sees = m.sees
                             /\ Connected(m).sess = "streaming" /\ Connected(m).fsm = m.fsm
  BY DEF Connected, MacT

LEMMA QueueType == ASSUME NEW n \in NetT, NEW ch \in RouteT, NEW v \in BOOLEAN
                   PROVE /\ Queue(n, "hs", ch, v) \in NetT /\ Queue(n, "vp", ch, v) \in NetT
                         /\ Queue(n, "hs", ch, v).wlKind = n.wlKind
                         /\ Queue(n, "vp", ch, v).wlKind = n.wlKind
  BY DEF Queue, Open, NetT, RouteT

LEMMA QueueAddrType == ASSUME NEW n \in NetT, NEW ch \in RouteT, NEW v \in 0..MaxGen
                       PROVE Queue(n, "addr", ch, v) \in NetT /\ Queue(n, "addr", ch, v).wlKind = n.wlKind
  BY DEF Queue, Open, NetT, RouteT

LEMMA DrainType == ASSUME NEW n \in NetT, NEW ch \in Chans PROVE Drain(n, ch) \in NetT /\ Drain(n, ch).wlKind = n.wlKind
  BY DEF Drain, Kill, NetT

LEMMA MacStepType == ASSUME NEW m \in MacT, NEW ev \in Events
                     PROVE MacStep(m, ev) \in MacT /\ MacStep(m, ev).sees = m.sees
  <1>1. Fsm(m.fsm, ev).s \in States /\ Fsm(m.fsm, ev).codec \in {"lz4", "hevc", "none"}
    BY FsmType DEF MacT
  <1>2. [m EXCEPT !.fsm = Fsm(m.fsm, ev).s, !.mode = MacMode(m, Fsm(m.fsm, ev).codec)] \in MacT
    BY <1>1, MacModeType DEF MacT
  <1> QED BY <1>2, FsmFallback, MacModeType, ConnectedType DEF MacStep, MacT

LEMMA IpadStepType == ASSUME NEW p \in IpadT, NEW ev \in Events
                      PROVE IpadStep(p, ev) \in IpadT /\ IpadStep(p, ev).sees = p.sees
  <1>1. Fsm(p.fsm, ev).s \in States BY FsmType DEF IpadT
  <1>2. [p EXCEPT !.fsm = Fsm(p.fsm, ev).s] \in IpadT BY <1>1 DEF IpadT
  <1>3. /\ [p EXCEPT !.fsm = Fsm(p.fsm, ev).s, !.fsm = Fsm("disc", "wifiAvail").s] \in IpadT
        /\ [p EXCEPT !.fsm = Fsm(p.fsm, ev).s, !.fsm = "usb"] \in IpadT
        /\ [p EXCEPT !.fsm = Fsm(p.fsm, ev).s, !.sess = "reconnecting"] \in IpadT
    BY <1>2, FsmFallback DEF IpadT
  <1> QED BY <1>2, <1>3 DEF IpadStep, IpadT

-----------------------------------------------------------------------------
(* Every Mac action ends in MacCommit, every iPad sees change in IpadSet.   *)
(* Each property is one step here, so a control fails exactly there.       *)

MacGood(m, w) ==
    /\ Label(m.fsm) = LinkW(Route(m.sees), w)
    /\ m.sess = "streaming" => Route(m.sees) # "none"
    /\ Route(m.sees) # "none" => m.mode = Codec(Route(m.sees))
IpadGood(p, w) == Label(p.fsm) = LinkW(Route(p.sees), w)

LEMMA MacCommitOK ==
    ASSUME Design, TypeOK, NEW m \in MacT, NEW n \in NetT, n.wlKind = net.wlKind, MacCommit(m, n)
    PROVE /\ mac' \in MacT /\ net' \in NetT /\ net'.wlKind = net.wlKind /\ mac'.sees = m.sees
          /\ MacGood(mac', net.wlKind)
  <1> USE DEF Design
  <1>0. Route(m.sees) \in RouteT /\ Route(mac.sees) \in RouteT /\ net.wlKind \in WLinks
    BY RouteType, TypeDef DEF MacT, NetT
  <1>1. mac' \in MacT /\ mac'.sees = m.sees
    BY <1>0, StateOfLink, ConnectedType DEF MacCommit, MacT, Codec
  <1>2. net' \in NetT /\ net'.wlKind = net.wlKind
    BY <1>0, QueueType DEF MacCommit
  <1>3. Label(mac'.fsm) = LinkW(Route(mac'.sees), net.wlKind)
    BY <1>0, <1>1, StateOfLink, ConnectedType DEF MacCommit, MacT
  <1>4. mac'.sess = "streaming" => Route(mac'.sees) # "none"
    BY <1>0, <1>1, ConnectedType DEF MacCommit, MacT
  <1>5. Route(mac'.sees) # "none" => mac'.mode = Codec(Route(mac'.sees))
    BY <1>0, <1>1, ConnectedType DEF MacCommit, MacT
  <1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5 DEF MacGood

LEMMA MacHandleOK ==
    ASSUME Design, TypeOK, NEW ev \in Events, NEW ch, NEW m \in MacT, MacHandle(ev, ch, m)
    PROVE /\ mac' \in MacT /\ net' \in NetT /\ net'.wlKind = net.wlKind
          /\ MacGood(mac', net.wlKind) /\ UNCHANGED ipad
  <1>1. MacStep(m, ev) \in MacT /\ MacStep(m, ev).sees = m.sees BY MacStepType
  <1>2. Route(m.sees) \in RouteT /\ Route(MacStep(m, ev).sees) \in RouteT
    BY <1>1, RouteType DEF MacT
  <1>3. env.addrGen \in 0..MaxGen BY TypeDef DEF EnvT
  <1> DEFINE m2 == MacStep(m, ev)
             n1 == IF ev = "wiredAppeared" THEN Queue(net, "addr", Route(m.sees), env.addrGen) ELSE net
             n2 == IF m2.sess = "streaming" /\ m.sess # "streaming"
                   THEN Queue(n1, "hs", Route(m2.sees), TRUE) ELSE n1
  <1>4. n1 \in NetT /\ n1.wlKind = net.wlKind BY <1>2, <1>3, QueueAddrType, TypeDef
  <1>5. n2 \in NetT /\ n2.wlKind = net.wlKind BY <1>2, <1>4, QueueType
  <1>6. MacCommit(m2, n2) /\ UNCHANGED ipad BY DEF MacHandle
  <1> QED BY <1>1, <1>5, <1>6, MacCommitOK

LEMMA IpadSetOK ==
    ASSUME Design, TypeOK, NEW p \in IpadT, NEW n \in NetT, n.wlKind = net.wlKind, IpadSet(p, n)
    PROVE /\ ipad' \in IpadT /\ ipad'.sees = p.sees /\ net' \in NetT /\ net'.wlKind = net.wlKind
          /\ IpadGood(ipad', net.wlKind)
  <1> USE DEF Design
  <1>0. Route(p.sees) \in RouteT /\ Route(ipad.sees) \in RouteT /\ net.wlKind \in WLinks
    BY RouteType, TypeDef DEF IpadT, NetT
  <1>1. ipad' \in IpadT /\ ipad'.sees = p.sees
    BY <1>0, StateOfLink DEF IpadSet, IpadT
  <1>2. net' \in NetT /\ net'.wlKind = net.wlKind
    BY <1>0, QueueType DEF IpadSet
  <1>3. Label(ipad'.fsm) = LinkW(Route(ipad'.sees), net.wlKind)
    BY <1>0, <1>1, StateOfLink DEF IpadSet, IpadT
  <1> QED BY <1>1, <1>2, <1>3 DEF IpadGood

-----------------------------------------------------------------------------

LEMMA InitInv == Init => Inv
  BY DEF Init, Inv, TypeOK, LabelsMatch, StreamOnlyWithRoute, CodecMatches,
         MacRoute, Route, Label, LinkOn

LEMMA MarkType == ASSUME TypeOK, env.flaps < MaxFlaps, NEW b \in BOOLEAN PROVE Mark(env, b) \in EnvT
  BY TypeDef DEF Mark, EnvT, LinkOf, NetT

\* What the properties say about the Mac and the iPad, as record predicates.
LEMMA InvSplit == Inv <=> TypeOK /\ MacGood(mac, net.wlKind) /\ IpadGood(ipad, net.wlKind)
  BY DEF Inv, MacGood, IpadGood, LabelsMatch, StreamOnlyWithRoute, CodecMatches, MacRoute,
         LinkOn, LinkW

LEMMA NextInv == ASSUME Design, Inv, [Next]_vars PROVE Inv'
  <1> DEFINE Post == /\ env' \in EnvT /\ net' \in NetT /\ mac' \in MacT /\ ipad' \in IpadT
                    /\ MacGood(mac', net'.wlKind) /\ IpadGood(ipad', net'.wlKind)
  <1>0. TypeOK /\ MacGood(mac, net.wlKind) /\ IpadGood(ipad, net.wlKind) BY InvSplit
  <1> USE <1>0, TypeDef
  <1> SUFFICES Post
    BY DEF Post, TypeOK, EnvT, NetT, MacT, IpadT, MacGood, IpadGood, Inv, LabelsMatch,
           StreamOnlyWithRoute, CodecMatches, MacRoute, LinkOn, LinkW
  \* Mac event sources
  <1>1. CASE MacIfaceUp
    <2>1. [mac EXCEPT !.iface = TRUE] \in MacT BY DEF MacT
    <2>2. \A e \in Events : UNCHANGED env /\ (MacHandle(e, "usb", [mac EXCEPT !.iface = TRUE]) \/ MacHandle(e, "wl", [mac EXCEPT !.iface = TRUE])) => Post
      BY <2>1, MacHandleOK
    <2> QED BY <1>1, <2>2 DEF MacIfaceUp
  <1>2. CASE MacIfaceDown
    <2>1. [mac EXCEPT !.iface = FALSE] \in MacT BY DEF MacT
    <2>2. \A e \in Events : UNCHANGED env /\ (MacHandle(e, "usb", [mac EXCEPT !.iface = FALSE]) \/ MacHandle(e, "wl", [mac EXCEPT !.iface = FALSE])) => Post
      BY <2>1, MacHandleOK
    <2> QED BY <1>2, <2>2 DEF MacIfaceDown
  <1>3. CASE MacUsbReady
    <2> DEFINE m == [mac EXCEPT !.sees["usb"] = TRUE]
    <2>1. m \in MacT BY DEF MacT
    <2>2. CASE m.fsm # "usb" BY <1>3, <2>1, <2>2, MacHandleOK DEF MacUsbReady
    <2>3. CASE m.fsm = "usb"
      <3>1. Connected(m) \in MacT BY <2>1, ConnectedType
      <3>2. Queue(net, "hs", "usb", TRUE) \in NetT /\ Queue(net, "hs", "usb", TRUE).wlKind = net.wlKind
        BY QueueType DEF RouteT
      <3> QED BY <1>3, <2>3, <3>1, <3>2, MacCommitOK DEF MacUsbReady
    <2> QED BY <2>2, <2>3
  <1>4. CASE MacUsbLost
    <2>1. [mac EXCEPT !.sees["usb"] = FALSE] \in MacT BY DEF MacT
    <2>2. \A e \in Events : UNCHANGED env /\ (MacHandle(e, "usb", [mac EXCEPT !.sees["usb"] = FALSE]) \/ MacHandle(e, "wl", [mac EXCEPT !.sees["usb"] = FALSE])) => Post
      BY <2>1, MacHandleOK
    <2> QED BY <1>4, <2>2 DEF MacUsbLost
  <1>5. CASE MacWlReady
    <2>1. [mac EXCEPT !.sees["wl"] = TRUE] \in MacT BY DEF MacT
    <2>2. \A e \in Events : UNCHANGED env /\ (MacHandle(e, "usb", [mac EXCEPT !.sees["wl"] = TRUE]) \/ MacHandle(e, "wl", [mac EXCEPT !.sees["wl"] = TRUE])) => Post
      BY <2>1, MacHandleOK
    <2> QED BY <1>5, <2>2 DEF MacWlReady
  <1>6. CASE MacWlLost
    <2>1. [mac EXCEPT !.sees["wl"] = FALSE] \in MacT BY DEF MacT
    <2>2. \A e \in Events : UNCHANGED env /\ (MacHandle(e, "usb", [mac EXCEPT !.sees["wl"] = FALSE]) \/ MacHandle(e, "wl", [mac EXCEPT !.sees["wl"] = FALSE])) => Post
      BY <2>1, MacHandleOK
    <2> QED BY <1>6, <2>2 DEF MacWlLost
  <1>7. CASE MacReconnectTimer
    <2> DEFINE m == [mac EXCEPT !.attempts = @ + 1]
    <2>1. m \in MacT BY <1>7 DEF MacReconnectTimer, MacT
    <2>2. Connected(m) \in MacT BY <2>1, ConnectedType
    <2>3. Route(m.sees) \in RouteT BY <2>1, RouteType DEF MacT
    <2>4. Queue(net, "hs", Route(m.sees), TRUE) \in NetT
          /\ Queue(net, "hs", Route(m.sees), TRUE).wlKind = net.wlKind BY <2>3, QueueType
    <2> QED BY <1>7, <2>1, <2>2, <2>4, MacCommitOK DEF MacReconnectTimer
  <1>8. CASE MacFrame
    BY <1>8 DEF MacFrame, IpadT, IpadGood
  \* Messages between the sides
  <1>9. ASSUME NEW ch \in Chans, IpadRecvHs(ch) PROVE Post
    <2>1. [net EXCEPT !.hs[ch] = FALSE] \in NetT BY DEF NetT
    <2>2. Route(ipad.sees) \in RouteT BY RouteType DEF IpadT
    <2> QED BY <1>9, <2>1, <2>2, QueueType DEF IpadRecvHs, IpadT, IpadGood, NetT
  <1>10. ASSUME NEW ch \in Chans, MacRecvVp(ch) PROVE Post
    <2>1. [mac EXCEPT !.vpKnown = TRUE,
                      !.mode = IF mac.mode = "lz4" /\ mac.sees["usb"] THEN "lz4" ELSE "hevc"] \in MacT
      BY DEF MacT
    <2>2. [net EXCEPT !.vp[ch] = FALSE] \in NetT /\ [net EXCEPT !.vp[ch] = FALSE].wlKind = net.wlKind
      BY DEF NetT
    <2> QED BY <1>10, <2>1, <2>2, MacCommitOK DEF MacRecvVp
  <1>11. ASSUME NEW ch \in Chans, IpadAddr(ch) PROVE Post
    <2> DEFINE p0 == [ipad EXCEPT !.peerGen = net.addr[ch]]
    <2>1. p0 \in IpadT /\ [p0 EXCEPT !.usbPending = TRUE] \in IpadT BY DEF IpadT, NetT
    <2>2. IpadStep([p0 EXCEPT !.usbPending = TRUE], "wiredAppeared") \in IpadT
      BY <2>1, IpadStepType
    <2>3. [net EXCEPT !.addr[ch] = 0] \in NetT /\ [net EXCEPT !.addr[ch] = 0].wlKind = net.wlKind
      BY DEF NetT
    <2> QED BY <1>11, <2>1, <2>2, <2>3, IpadSetOK DEF IpadAddr
  \* iPad event sources
  <1>12. CASE IpadIfaceUp
    <2> DEFINE known == AddrOnLink \/ ipad.peerGen # 0
               p0 == [ipad EXCEPT !.iface = TRUE, !.usbPending = known,
                                  !.peerGen = IF AddrOnLink THEN env.addrGen ELSE @]
    <2>1. p0 \in IpadT BY DEF IpadT, EnvT
    <2>2. IpadStep(p0, "wiredAppeared") \in IpadT BY <2>1, IpadStepType
    <2> QED BY <1>12, <2>1, <2>2, IpadSetOK DEF IpadIfaceUp
  <1>13. CASE IpadIfaceDown
    <2> DEFINE p0 == [ipad EXCEPT !.iface = FALSE, !.sees["usb"] = FALSE, !.usbPending = FALSE]
    <2>1. p0 \in IpadT BY DEF IpadT
    <2>2. IpadStep(p0, "wiredDisappeared") \in IpadT BY <2>1, IpadStepType
    <2>3. Drain(net, "usb") \in NetT BY DrainType
    <2>4. /\ [Drain(net, "usb") EXCEPT !.conn["usb"] = "none"] \in NetT
          /\ [Drain(net, "usb") EXCEPT !.conn["usb"] = "none"].wlKind = net.wlKind
      BY <2>3, DrainType DEF NetT
    <2> DEFINE n == IF ~mac.sees["usb"] THEN [Drain(net, "usb") EXCEPT !.conn["usb"] = "none"]
                    ELSE Drain(net, "usb")
    <2>5. n \in NetT /\ n.wlKind = net.wlKind BY <2>3, <2>4, DrainType
    <2>6. IpadSet(IpadStep(p0, "wiredDisappeared"), n) /\ UNCHANGED <<env, mac>>
      BY <1>13 DEF IpadIfaceDown
    <2> QED BY <2>2, <2>5, <2>6, IpadSetOK
  <1>14. CASE IpadUsbConnect
    BY <1>14 DEF IpadUsbConnect, IpadT, NetT, EnvT, IpadGood
  <1>15. CASE IpadUsbRetry
    BY <1>15 DEF IpadUsbRetry, IpadT, EnvT, IpadGood
  <1>16. CASE IpadUsbReady
    BY <1>16, IpadSetOK DEF IpadUsbReady, IpadT
  <1>17. CASE IpadUsbLost
    BY <1>17, IpadSetOK DEF IpadUsbLost, IpadT
  <1>18. CASE IpadWlConnect
    \* The wireless kind changes only while neither side routes over wireless.
    <2>1. Route(mac.sees) # "wl" /\ Route(ipad.sees) # "wl" BY <1>18 DEF IpadWlConnect, Route
    <2> QED BY <1>18, <2>1 DEF IpadWlConnect, NetT, MacGood, IpadGood, LinkW
  <1>19. CASE IpadWlReady
    <2> DEFINE p0 == [ipad EXCEPT !.sees["wl"] = TRUE]
    <2>1. p0 \in IpadT BY DEF IpadT
    <2>2. \A e \in Events : IpadStep(p0, e) \in IpadT BY <2>1, IpadStepType
    <2> QED BY <1>19, <2>2, IpadSetOK DEF IpadWlReady
  <1>20. CASE IpadWlLost
    <2> DEFINE p0 == [ipad EXCEPT !.sees["wl"] = FALSE]
    <2>1. p0 \in IpadT BY DEF IpadT
    <2>2. \A e \in Events : IpadStep(p0, e) \in IpadT BY <2>1, IpadStepType
    <2> QED BY <1>20, <2>2, IpadSetOK DEF IpadWlLost
  <1>21. ASSUME NEW ch \in Chans, Reap(ch) PROVE Post
    BY <1>21 DEF Reap, NetT
  \* The environment
  <1>22. CASE PlugUSB
    <2>1. env.flaps < MaxFlaps BY <1>22 DEF PlugUSB, Flap
    <2>2. Mark(env, FALSE) \in EnvT BY <2>1, MarkType
    <2>3. \A g \in {env.addrGen, env.addrGen + 1} \cap 1..MaxGen :
            [Mark(env, FALSE) EXCEPT !.phys["usb"] = TRUE, !.addrGen = g] \in EnvT
      BY <2>2 DEF EnvT
    <2> QED BY <1>22, <2>3 DEF PlugUSB
  <1>23. CASE UnplugUSB
    BY <1>23, MarkType, DrainType DEF UnplugUSB, Flap, EnvT
  <1>24. ASSUME NEW l \in WLinks, WirelessUp(l) PROVE Post
    BY <1>24, MarkType DEF WirelessUp, Flap, EnvT
  <1>25. ASSUME NEW l \in WLinks, WirelessDown(l) PROVE Post
    BY <1>25, MarkType, DrainType DEF WirelessDown, Flap, EnvT, NetT
  <1>26. CASE UNCHANGED vars
    BY <1>26 DEF vars
  <1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10, <1>11, <1>12,
             <1>13, <1>14, <1>15, <1>16, <1>17, <1>18, <1>19, <1>20, <1>21, <1>22, <1>23,
             <1>24, <1>25, <1>26 DEF Next, SysNext, EnvNext

THEOREM SwitchingSafe == ASSUME Design PROVE Spec => []Inv
  <1>1. Init => Inv BY InitInv
  <1>2. Inv /\ [Next]_vars => Inv' BY NextInv
  <1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
