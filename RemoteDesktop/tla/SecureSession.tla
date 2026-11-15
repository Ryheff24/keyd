---------------------------- MODULE SecureSession ----------------------------
(***************************************************************************)
(* End-to-end security lifecycle of RemoteDesktop: pairing result, mutual  *)
(* TLS on every link (USB NCM, Wi-Fi, AWDL), transport switching in every  *)
(* order with stale messages in flight, revocation and re-pairing, input   *)
(* (iPad -> Mac), frames (Mac -> iPad), control traffic both ways, and an  *)
(* attacker A on the wireless links.  B1-B5 in PLAN.md.  Method: METHOD.md *)
(*                                                                         *)
(* As built [C] (read 2026-10-29):                                         *)
(*   Mac listeners: TLS 1.3, peer_authentication_required, verify block    *)
(*     compares the client cert SHA-256 to the stored pin, re-read on      *)
(*     every handshake, fails closed when no pin is stored:                *)
(*     macOS/Transport/USBNetworkTransport.m:229-262,                      *)
(*     macOS/Transport/WirelessTransport.m:188-250.          (PinnedMTLS)  *)
(*   iPad connections: TLS 1.3 / DTLS, verify block pins the Mac cert,     *)
(*     fails closed: iPadOS/Transport/WirelessTransport.swift:98-106,      *)
(*     219-259; USBNetworkTransport.swift:101-106, 220-261, 603-718.       *)
(*                                                          (ClientPinsMac) *)
(*   Revocation is not atomic.  "Reset pairing" (SessionManager.m:622-627) *)
(*     calls stop, then deletes the pin, but callbacks already queued on   *)
(*     transport queues still run.  "Pair iPad" (showPairingQR,            *)
(*     SessionManager.m:510-512) deletes the pin and leaves every open     *)
(*     session running.  So Revoke only clears the pin; sessions die later *)
(*     (CloseMac, MacLinkDown).  Nothing checks a session against the pin  *)
(*     after its handshake.                                                *)
(*   Design: each Mac session carries the pairing epoch it was opened in;  *)
(*     revocation bumps the epoch and the Mac sends and injects only on    *)
(*     sessions of the current epoch.                         (EpochGuard)  *)
(*   One connection per transport; a new one replaces the old              *)
(*     (USBNetworkTransport.m:962-1030, WirelessTransport.m:810-817).      *)
(*     USB and wireless connections can be open at the same time.          *)
(*   Pairing: insecure as built, see Pairing.tla.         (PairingSecure)  *)
(*   Pairing over QR/Wi-Fi as built; owner design is USB only. (USBPairing)*)
(*   Test pairing accepts any server cert: QRPairing.swift:448-470.        *)
(*                                                          (NoTestBypass)  *)
(*   Plaintext NWParameters.tcp/.udp in DeviceTestRunner.swift:2425-3028,  *)
(*     compiled into the iPad app.                       (NoTestPlaintext)  *)
(*                                                                         *)
(* Assumptions (inputs, not results):                                       *)
(*   A2 [I] A cannot reach the USB NCM link (it needs the cable).           *)
(*   A5 [I] Symbolic TLS 1.3/DTLS 1.3: a record on a session is readable    *)
(*          and forgeable only by the session's two ends; records are bound *)
(*          to their session, so replay into another session fails.        *)
(*   A6 [I] Scope: "message" means an application message (input, frames, *)
(*          control, test traffic).  Some bytes are cleartext by protocol   *)
(*          and are not modelled: TLS ClientHello/ServerHello (TLS 1.3      *)
(*          encrypts everything after ServerHello, certificates included),  *)
(*          Bonjour/mDNS adverts and queries, and TCP/UDP/IP headers.  They *)
(*          reveal that a keyd Mac is present, not content.  Bonjour can be *)
(*          spoofed; the pin check on connect (ClientPinsMac) turns that    *)
(*          into denial of service, which is out of scope here.             *)
(*   A9 [I] Delivery: a link drop is seen by each side separately          *)
(*          (MacLinkDown, IpadLinkDown).  Ordering, exactly-once delivery   *)
(*          and TCP message framing are not claimed here (PLAN.md).         *)
(*   A7 [C] PairingSecure is the consequence proved in PairingProofs.tla:   *)
(*          under Pairing's Design only the owner's iPad is ever pinned.    *)
(*   A8 [I] The iPad pins the Mac's certificate during (USB) pairing.       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    I, A, M, None,       \* owner's iPad, attacker, the Mac, nobody
    MaxConn,             \* bound on connection ids (TLC); any Nat for TLAPS
    MaxEpoch,            \* bound on revocations (TLC); any Nat for TLAPS
    \* mechanisms (all TRUE in Design)
    PairingSecure, USBPairing, PinnedMTLS, ClientPinsMac, EpochGuard,
    NoTestBypass, NoTestPlaintext

ASSUME Distinct == /\ I # A /\ I # M /\ A # M
                   /\ None \notin {I, A, M}
ASSUME Bound == MaxConn \in Nat /\ MaxEpoch \in Nat
ASSUME Switches == {PairingSecure, USBPairing, PinnedMTLS, ClientPinsMac,
                    EpochGuard, NoTestBypass, NoTestPlaintext} \subseteq BOOLEAN

Links    == {"usb", "wifi", "awdl"}
Wireless == {"wifi", "awdl"}
Ids      == 1..MaxConn
Prots    == {"pinned", "unauth"}
Secrets  == {"input", "frame", "control", "test"}

MacRec  == [id : Ids, peer : {I, A}, link : Links, prot : Prots, epoch : Nat]
IpadRec == [id : Ids, peer : {M, A}, link : Links, prot : Prots]
Msg     == [sid : Ids, author : {I, A}, kind : {"input", "control"}]
Drop    == [link : Links, after : Nat]

VARIABLES
    macPin,        \* client the Mac trusts, or None
    macEpoch,      \* pairing epoch at the Mac, bumped on every revocation
    ipadPin,       \* server the owner's iPad trusts, or None
    macPending,    \* Mac connections whose pin check passed but which are not ready yet
    macSess,       \* open sessions at the Mac
    ipadSess,      \* open sessions at the owner's iPad
    nextId,        \* next connection id (ids are never reused)
    inflight,      \* input and control records on the wire, bound to their session
    leaked,        \* secret kinds the attacker has read
    plainSent,     \* some message crossed a link unencrypted
    unauthSent,    \* some message crossed a channel that is not mutually pinned
    pairOffUSB,    \* a pairing exchange ran on a wireless link
    badInject,     \* the Mac acted on input or control from someone other than its pin
    badSend,       \* the Mac sent a frame or control to someone other than its pin
    foreignInject, \* the Mac acted on input or control not from the owner's iPad
    injectedLinks, \* links over which owner input was injected (witness)
    usedIds,       \* sessions on which the Mac acted on owner input (witness)
    deadUsed,      \* drops at the Mac that removed a used session, with nextId then
    switches       \* <<from, to>>: owner input acted on over `to`, on a session
                   \* opened after a used session on `from` was dropped

vars == <<macPin, macEpoch, ipadPin, macPending, macSess, ipadSess, nextId, inflight, leaked,
          plainSent, unauthSent, pairOffUSB, badInject, badSend, foreignInject,
          injectedLinks, usedIds, usedIds, deadUsed, switches>>

TypeOK ==
    /\ macPin \in {I, A, None} /\ macEpoch \in Nat /\ ipadPin \in {M, A, None}
    /\ macPending \subseteq MacRec /\ macSess \subseteq MacRec /\ ipadSess \subseteq IpadRec
    /\ nextId \in Nat /\ nextId >= 1
    /\ inflight \subseteq Msg
    /\ leaked \subseteq Secrets
    /\ {plainSent, unauthSent, pairOffUSB, badInject, badSend, foreignInject} \subseteq BOOLEAN
    /\ injectedLinks \subseteq Links /\ usedIds \subseteq Ids /\ deadUsed \subseteq Drop
    /\ switches \subseteq Links \X Links

Init ==
    /\ macPin = None /\ macEpoch = 0 /\ ipadPin = None
    /\ macPending = {} /\ macSess = {} /\ ipadSess = {} /\ nextId = 1 /\ inflight = {}
    /\ leaked = {}
    /\ plainSent = FALSE /\ unauthSent = FALSE /\ pairOffUSB = FALSE
    /\ badInject = FALSE /\ badSend = FALSE /\ foreignInject = FALSE
    /\ injectedLinks = {} /\ usedIds = {} /\ deadUsed = {} /\ switches = {}

-----------------------------------------------------------------------------
(* Pairing (the result of Pairing.tla, A7) *)

PairLinks == IF USBPairing THEN {"usb"} ELSE Links

\* The Mac stores a client pin after a pairing exchange on link l.
PairMac(d, l) ==
    /\ macPin = None /\ l \in PairLinks
    /\ d = A => (~PairingSecure /\ l \in Wireless)           \* A2
    /\ macPin' = d
    /\ pairOffUSB' = (pairOffUSB \/ l \in Wireless)
    /\ UNCHANGED <<ipadPin, macPending, macSess, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* The owner's iPad stores a server pin (A8); the test path accepts anyone.
PairIpad(s) ==
    /\ ipadPin = None
    /\ s \in (IF NoTestBypass THEN {M} ELSE {M, A})
    /\ ipadPin' = s
    /\ UNCHANGED <<macPin, macPending, macSess, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* "Reset pairing" or "Pair iPad" on the Mac.  Open sessions survive (as built);
\* they close later through CloseMac or MacLinkDown.
Revoke ==
    /\ macPin # None /\ macEpoch < MaxEpoch
    /\ macPin' = None /\ macEpoch' = macEpoch + 1
    /\ UNCHANGED <<macPending, macSess>>
    /\ UNCHANGED <<ipadPin, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   badSend, usedIds, deadUsed, switches>>

\* "Forget this Mac" on the iPad.
ForgetMac ==
    /\ ipadPin # None
    /\ ipadPin' = None /\ ipadSess' = {}
    /\ UNCHANGED <<macPin, macPending, macSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

-----------------------------------------------------------------------------
(* Connections: mutual TLS handshakes *)

MacAccepts(c)  == IF PinnedMTLS THEN macPin = c ELSE TRUE
IpadAccepts(s) == IF ClientPinsMac THEN ipadPin = s ELSE ipadPin # None
ProtOf         == IF PinnedMTLS /\ ClientPinsMac THEN "pinned" ELSE "unauth"

Live(r) == EpochGuard => r.epoch = macEpoch

\* The Mac's verify block checks the client pin and records the epoch it checked
\* against; the connection becomes ready later (USBNetworkTransport.m:251 verify,
\* :1027 ready).  A revocation can land in between, so the record keeps the
\* epoch of the check, not of readiness.
\* Owner's iPad <-> Mac on link l: both pin checks pass.
ConnectIM(l) ==
    /\ nextId \in Ids /\ MacAccepts(I) /\ IpadAccepts(M)
    /\ macPending' = macPending \cup {[id |-> nextId, peer |-> I, link |-> l, prot |-> ProtOf,
                                       epoch |-> macEpoch]}
    /\ ipadSess' = ipadSess \cup {[id |-> nextId, peer |-> M, link |-> l, prot |-> ProtOf]}
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<macPin, ipadPin, macSess, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* The attacker connects to the Mac's wireless listener as a client.
ConnectAM(l) ==
    /\ l \in Wireless /\ nextId \in Ids /\ MacAccepts(A)
    /\ macPending' = macPending \cup {[id |-> nextId, peer |-> A, link |-> l,
                                       prot |-> IF PinnedMTLS THEN "pinned" ELSE "unauth",
                                       epoch |-> macEpoch]}
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<macPin, ipadPin, macSess, ipadSess, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* A checked connection at the Mac becomes ready (its state handler runs).
MacReady(r) ==
    /\ r \in macPending
    /\ macPending' = macPending \ {r} /\ macSess' = macSess \cup {r}
    /\ UNCHANGED <<macPin, ipadPin, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* The attacker poses as the Mac to the owner's iPad (spoofed Bonjour, rogue AP).
ConnectIA(l) ==
    /\ l \in Wireless /\ nextId \in Ids /\ IpadAccepts(A)
    /\ ipadSess' = ipadSess \cup {[id |-> nextId, peer |-> A, link |-> l,
                                   prot |-> IF ClientPinsMac THEN "pinned" ELSE "unauth"]}
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* Either end closes one session (timeout, replacement by a newer connection).
CloseMac(r) ==
    /\ r \in macSess /\ macSess' = macSess \ {r}
    /\ UNCHANGED <<macPin, ipadPin, macPending, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>
CloseIpad(r) ==
    /\ r \in ipadSess /\ ipadSess' = ipadSess \ {r}
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* A link goes down (cable out, Wi-Fi lost, AWDL gone).  Each side notices on its
\* own schedule (A9); messages already in flight stay on the wire (stale).
\* For the witnesses, a drop counts only if it removes a session the Mac had
\* acted on owner input over.
MacLinkDown(l) ==
    /\ macPending' = {r \in macPending : r.link # l}
    /\ macSess' = {r \in macSess : r.link # l}
    /\ deadUsed' = IF \E r \in macSess : r.link = l /\ r.id \in usedIds
                   THEN deadUsed \cup {[link |-> l, after |-> nextId]} ELSE deadUsed
    /\ UNCHANGED <<macPin, ipadPin, ipadSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, switches>>
IpadLinkDown(l) ==
    /\ ipadSess' = {r \in ipadSess : r.link # l}
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, nextId, inflight, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

-----------------------------------------------------------------------------
(* Traffic *)

\* The owner's iPad sends input or control (viewport, resolution, mode, clock
\* sync, keyframe request) on one of its sessions.
IpadSend(r, k) ==
    /\ r \in ipadSess /\ k \in {"input", "control"}
    /\ unauthSent' = (unauthSent \/ r.prot # "pinned")
    /\ leaked' = IF r.peer = A THEN leaked \cup {k} ELSE leaked
    /\ inflight' = IF r.peer = M
                   THEN inflight \cup {[sid |-> r.id, author |-> I, kind |-> k]} ELSE inflight
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, ipadSess, nextId,
                   plainSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* The Mac sends a frame or control on one of its sessions.
MacSend(r, k) ==
    /\ r \in macSess /\ k \in {"frame", "control"} /\ Live(r)
    /\ unauthSent' = (unauthSent \/ r.prot # "pinned")
    /\ badSend' = (badSend \/ r.peer # macPin)
    /\ leaked' = IF r.peer = A THEN leaked \cup {k} ELSE leaked
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, ipadSess, nextId, inflight,
                   plainSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, usedIds, deadUsed, switches>>

\* The attacker sends input or control on a session it holds with the Mac.
AttackerSend(r, k) ==
    /\ r \in macSess /\ r.peer = A /\ k \in {"input", "control"}
    /\ inflight' = inflight \cup {[sid |-> r.id, author |-> A, kind |-> k]}
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, ipadSess, nextId, leaked,
                   plainSent, unauthSent, pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

\* The Mac decrypts a record on an open session and acts on it: input becomes
\* CGEvents; control changes the display mode, starts capture or the encoder,
\* or answers a clock request (SessionManager.m:2376-2409).
\* A record is bound to its session (A5): stale records of closed sessions,
\* and replays into other sessions, are never delivered.
Deliver(m, r) ==
    /\ m \in inflight /\ r \in macSess /\ r.id = m.sid /\ Live(r)
    /\ inflight' = inflight \ {m}
    /\ badInject' = (badInject \/ m.author # macPin)
    /\ foreignInject' = (foreignInject \/ m.author # I)
    /\ LET owner == m.author = I /\ m.kind = "input" IN
       /\ injectedLinks' = IF owner THEN injectedLinks \cup {r.link} ELSE injectedLinks
       /\ usedIds' = IF owner THEN usedIds \cup {r.id} ELSE usedIds
       /\ switches' = IF owner
                      THEN switches \cup {<<f.link, r.link>> : f \in {g \in deadUsed : r.id >= g.after}}
                      ELSE switches
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, ipadSess, nextId, leaked,
                   plainSent, unauthSent, pairOffUSB,
                   macEpoch, badSend, deadUsed>>

\* Test code compiled into the app opens a plaintext, unauthenticated connection.
PlainSend(l) ==
    /\ ~NoTestPlaintext
    /\ plainSent' = TRUE /\ unauthSent' = TRUE
    /\ leaked' = IF l \in Wireless THEN leaked \cup {"test"} ELSE leaked
    /\ UNCHANGED <<macPin, ipadPin, macPending, macSess, ipadSess, nextId, inflight,
                   pairOffUSB, badInject, foreignInject, injectedLinks,
                   macEpoch, badSend, usedIds, deadUsed, switches>>

Next ==
    \/ \E d \in {I, A}, l \in Links : PairMac(d, l)
    \/ \E s \in {M, A} : PairIpad(s)
    \/ Revoke \/ ForgetMac
    \/ \E l \in Links : ConnectIM(l) \/ ConnectAM(l) \/ ConnectIA(l) \/ PlainSend(l)
                         \/ MacLinkDown(l) \/ IpadLinkDown(l)
    \/ \E r \in macPending : MacReady(r)
    \/ \E r \in macSess : CloseMac(r) \/ \E k \in {"frame", "control"} : MacSend(r, k)
    \/ \E r \in macSess, k \in {"input", "control"} : AttackerSend(r, k)
    \/ \E r \in ipadSess : CloseIpad(r) \/ \E k \in {"input", "control"} : IpadSend(r, k)
    \/ \E m \in inflight, r \in macSess : Deliver(m, r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties.  Each has a control in cfg/ that must report it violated. *)

\* Every application message on every link is encrypted (scope: A6).
NoPlaintext == ~plainSent
\* Every application message on an established session rides a channel where both
\* ends checked the other's pin.  The pairing bootstrap is authenticated by
\* Pairing.tla's mechanisms instead (USB only, confirmation on the Mac).
AllMutuallyPinned == ~unauthSent
\* Pairing exchanges never touch a wireless link.
PairingOnlyOverUSB == ~pairOffUSB
\* The attacker never reads input, frames, control or test traffic.
NoLeak == leaked = {}
\* The Mac only ever acts on input or control from the device it currently trusts.
InjectAuthorized == ~badInject
\* The Mac only ever acts on input or control from the owner's iPad.
InjectFromOwner == ~foreignInject
\* The Mac only ever sends frames and control to the device it currently trusts.
SendOnlyToTrusted == ~badSend

Safe == NoPlaintext /\ AllMutuallyPinned /\ PairingOnlyOverUSB /\ NoLeak
        /\ InjectAuthorized /\ InjectFromOwner /\ SendOnlyToTrusted

\* Witnesses (must be violated): owner input reaches the Mac, and it keeps
\* reaching it after the link it was using goes down, in each switching
\* direction the owner uses (PLAN.md, owner decisions).
NeverInjected       == injectedLinks = {}
NeverWiredToWifi    == <<"usb", "wifi">> \notin switches
NeverWifiToWired    == <<"wifi", "usb">> \notin switches
NeverWifiToAwdl     == <<"wifi", "awdl">> \notin switches
NeverAwdlToWifi     == <<"awdl", "wifi">> \notin switches
NeverWiredToWired   == <<"usb", "usb">> \notin switches

Design == PairingSecure /\ USBPairing /\ PinnedMTLS /\ ClientPinsMac /\ EpochGuard /\ NoTestBypass /\ NoTestPlaintext
=============================================================================
