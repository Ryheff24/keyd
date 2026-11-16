------------------------- MODULE TransportConnections -------------------------
(***************************************************************************)
(* The wireless lane of PLAN.md 4a: which link a wireless connection rides, *)
(* whether a connection that went silent is noticed, and whether the iPad  *)
(* dials again after losing it.  USB is out of scope (TransportAgreement). *)
(*                                                                         *)
(* As built [C] (2026-11-15):                                              *)
(*   iPad dial: one NWConnection to the Bonjour service with               *)
(*     includePeerToPeer = true (iPadOS WirelessTransport.swift:20, :37).  *)
(*     Network.framework races every usable interface, so one dial lands   *)
(*     on the Mac as several TCP candidates (infrastructure en0, awdl0).   *)
(*   Mac accept (macOS WirelessTransport.m:612-672): the first candidate   *)
(*     becomes the input connection; later ones are cancelled unless the   *)
(*     current one is stale.  Nothing ranks infrastructure over AWDL.      *)
(*   Labels: both sides call a connection AWDL only if its path has an     *)
(*     interface of type `other` and none of type `wifi` (iPad :685-703,   *)
(*     Mac :700-710).  awdl0 reports type wifi, so AWDL is labelled Wi-Fi. *)
(*   Silence: nothing on either side turns "no bytes arrive" into a lost   *)
(*     link.  The Mac's stall recovery (SessionManager.m                   *)
(*     maybeRecoverWiFiTCPInFlightStall) resets its in-flight count and    *)
(*     asks for a keyframe, forever; the iPad's unanswered latency probes  *)
(*     change nothing.  Only TCP's own retransmission timeout ends it.     *)
(*   Redial: the iPad ignores a Bonjour .added while it still holds a      *)
(*     connection (:366) and never restarts a browser that is already      *)
(*     running (:1012-1025, :291-296).  A re-advertisement seen before the *)
(*     loss is consumed, so after the loss nothing dials.                  *)
(*   Observed [O] 2026-11-15 22:50-22:57 (scratchpad unplug-2251): Mac     *)
(*     accepted awdl0 then en0 41 ms apart, kept awdl0, both sides logged  *)
(*     AWDL=0; the link carried TLS and DTLS handshakes, then no Mac->iPad *)
(*     byte arrived (input events at 22:50:42, frames from 22:51:40).      *)
(*     Both sides stayed streaming 113 s, until TCP timed out at 22:53:33; *)
(*     the iPad then sat in reconnecting with the Mac advertising.  Only   *)
(*     plugging USB back in recovered it.  Why the AWDL link went quiet is *)
(*     [U]; the design must not depend on it.                              *)
(*                                                                         *)
(* As built 2026-11-15 (InfraFirst, now OneLink /\ ~AwdlFirst): one link  *)
(*   per dial, infrastructure first, AWDL only when infrastructure fails.  *)
(* Observed [O] 2026-11-16: on infrastructure (router ch157, 80 MHz) the   *)
(*   iPad's receive holds two ~100 ms windows every 512 TU, 37-45% of the  *)
(*   time, with our peer-to-peer on or off (runs 1247cc4, 251f328), which  *)
(*   caps the stream near 40 fps.  Pinned to AWDL (565c38c): holds 18% of  *)
(*   the time, no 512 TU lock, 50.4 fps, g2g 56/143/67 ms.  So AWDL is the *)
(*   preferred wireless link (user decision 2026-11-16).                  *)
(*                                                                         *)
(* Design switches:                                                        *)
(*   OneLink:       a dial offers one link (one candidate), never a race   *)
(*                  of every usable interface.                             *)
(*   AwdlFirst:     the one link is AWDL when AWDL is usable, else         *)
(*                  infrastructure; after the iPad loses a connection on   *)
(*                  AWDL (silence or TCP timeout) its next dial prefers    *)
(*                  infrastructure (avoidAwdl), so a quietly broken AWDL   *)
(*                  costs one silence deadline, not a loop; any            *)
(*                  established connection clears it.                      *)
(*   ExactLabel:    a connection's label is its real link (interface name *)
(*                  awdl*, or path.usesInterfaceType semantics that tell   *)
(*                  AWDL apart), on both sides.                            *)
(*   SilenceDetect: each side sends a heartbeat each second on the control *)
(*                  connection; a side that receives no byte for D ticks   *)
(*                  drops the connection as lost.                          *)
(*   RedialOnLoss:  after any loss the iPad restarts discovery (new        *)
(*                  browser, fresh results) and dials again.               *)
(*                                                                         *)
(* Test-mode switch (not part of Design):                                  *)
(*   AwdlPin:       E2E diagnostic `--awdl-only`: a dial offers AWDL only. *)
(*                  Run 251f328 showed the iPad's infrastructure receive   *)
(*                  holds two ~100 ms windows every 512 TU even with our   *)
(*                  peer-to-peer off; the pin measures whether the AWDL    *)
(*                  link flows in those windows.  It gives up the Wi-Fi    *)
(*                  fallback, so it recovers only while AWDL is usable     *)
(*                  (RecoversPinned); Recovers fails under it by design.   *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  W1 [O] One dial may yield candidates on every usable link, reaching    *)
(*         the Mac in any order; both sides end up on the same one         *)
(*         (observed; the connection-identity question is                  *)
(*         TransportAgreement T7).                                         *)
(*  W2 [O] A handshaken connection can go silent with no error on either   *)
(*         side, at most MaxSilence times; a link can also go down and up, *)
(*         at most MaxFlaps times.                                         *)
(*  W3 [C] TCP's retransmission timeout eventually ends a silent           *)
(*         connection, but after minutes: modelled as an environment       *)
(*         action without fairness, so recovery may not depend on it.      *)
(*  W4 [I] Time: Tick advances the age of a silence by one heartbeat       *)
(*         period; a side's timer fires no later than D ticks (Tick waits  *)
(*         for an expired timer).                                          *)
(*  W5 [I] A dial to a usable link succeeds (TLS pin checks: SecureSession;*)
(*         the Mac takes over a stale connection: WirelessTransport.m      *)
(*         staleByIdle / allowReconnectTakeover).                          *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxSilence,     \* silent-without-error events
    MaxFlaps,       \* link down/up events
    D,              \* silence deadline, in ticks
    MaxAge,         \* bound on a silence's age (as built it grows past D)
    OneLink, AwdlFirst, ExactLabel, SilenceDetect, RedialOnLoss,
    AwdlPin         \* test mode only, see header

Links == {"wifi", "awdl"}
None == "none"

VARIABLES
    up,          \* up[l]: link l is usable (infrastructure Wi-Fi, AWDL)
    ipad,        \* "discovering" | "dialing" | "streaming" | "stuck"
    pending,     \* candidates of the dial in progress
    link,        \* the connection's link, or None
    live,        \* the connection carries bytes
    ipadHolds,   \* the iPad holds the connection
    macHolds,    \* the Mac holds the connection (its session STREAMING)
    ipadLabel, macLabel,
    age,         \* ticks since the connection went silent
    badPick,     \* history: a dial offered infrastructure while AWDL was usable and not avoided
    avoidAwdl,   \* the iPad's last loss was a connection on AWDL
    silences, flaps

vars == <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
          age, badPick, avoidAwdl, silences, flaps>>

Design == OneLink /\ AwdlFirst /\ ExactLabel /\ SilenceDetect /\ RedialOnLoss

TypeOK ==
    /\ up \in [Links -> BOOLEAN]
    /\ ipad \in {"discovering", "dialing", "streaming", "stuck"}
    /\ pending \in SUBSET Links
    /\ link \in Links \cup {None}
    /\ live \in BOOLEAN /\ ipadHolds \in BOOLEAN /\ macHolds \in BOOLEAN
    /\ ipadLabel \in Links \cup {None} /\ macLabel \in Links \cup {None}
    /\ age \in 0..MaxAge
    /\ badPick \in BOOLEAN /\ avoidAwdl \in BOOLEAN
    /\ silences \in 0..MaxSilence /\ flaps \in 0..MaxFlaps

Init ==
    /\ up \in [Links -> BOOLEAN]
    /\ ipad = "discovering" /\ pending = {}
    /\ link = None /\ live = FALSE /\ ipadHolds = FALSE /\ macHolds = FALSE
    /\ ipadLabel = None /\ macLabel = None
    /\ age = 0 /\ badPick = FALSE /\ avoidAwdl = FALSE /\ silences = 0 /\ flaps = 0

Held == ipadHolds \/ macHolds

\* What one dial offers.
Candidates ==
    IF AwdlPin THEN (IF up["awdl"] THEN {"awdl"} ELSE {})
    ELSE IF ~OneLink THEN {l \in Links : up[l]}
    ELSE IF AwdlFirst
       THEN IF up["awdl"] /\ ~avoidAwdl THEN {"awdl"}
            ELSE IF up["wifi"] THEN {"wifi"} ELSE IF up["awdl"] THEN {"awdl"} ELSE {}
       ELSE IF up["wifi"] THEN {"wifi"} ELSE IF up["awdl"] THEN {"awdl"} ELSE {}

LabelOf(l) == IF ExactLabel THEN l ELSE "wifi"

\* After a loss the iPad dials again only if it restarts discovery.
AfterLoss == IF RedialOnLoss THEN "discovering" ELSE "stuck"

------------------------------------------------------------------------------
(* System *)

Dial ==
    /\ ipad = "discovering" /\ Candidates # {}
    /\ ipad' = "dialing" /\ pending' = Candidates
    /\ badPick' = (badPick \/ ("wifi" \in Candidates /\ up["awdl"] /\ ~avoidAwdl))
    /\ UNCHANGED <<up, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, avoidAwdl, silences, flaps>>

\* Both sides settle on candidate l (W1); the Mac takes over any old connection (W5).
Establish(l) ==
    /\ ipad = "dialing" /\ l \in pending /\ up[l]
    /\ ipad' = "streaming" /\ pending' = {}
    /\ link' = l /\ live' = TRUE /\ ipadHolds' = TRUE /\ macHolds' = TRUE
    /\ ipadLabel' = LabelOf(l) /\ macLabel' = LabelOf(l)
    /\ age' = 0 /\ avoidAwdl' = FALSE
    /\ UNCHANGED <<up, badPick, silences, flaps>>

\* The connect watchdog gives up on a dial whose links all went down.
DialFail ==
    /\ ipad = "dialing" /\ \A l \in pending : ~up[l]
    /\ ipad' = "discovering" /\ pending' = {}
    /\ UNCHANGED <<up, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, silences, flaps>>

IpadDetect ==
    /\ SilenceDetect /\ ipadHolds /\ ~live /\ age >= D
    /\ ipadHolds' = FALSE /\ ipadLabel' = None /\ ipad' = AfterLoss
    /\ avoidAwdl' = (link = "awdl")
    /\ UNCHANGED <<up, pending, link, live, macHolds, macLabel, age, badPick, silences, flaps>>

MacDetect ==
    /\ SilenceDetect /\ macHolds /\ ~live /\ age >= D
    /\ macHolds' = FALSE /\ macLabel' = None
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, ipadLabel, age, badPick, avoidAwdl,
                   silences, flaps>>

\* One heartbeat period passes on a silent, held connection.  An expired
\* detector fires before time moves on (W4).
Tick ==
    /\ Held /\ ~live /\ age < MaxAge
    /\ ~(SilenceDetect /\ age >= D)
    /\ age' = age + 1
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   badPick, avoidAwdl, silences, flaps>>

System == Dial \/ (\E l \in Links : Establish(l)) \/ DialFail \/ IpadDetect \/ MacDetect \/ Tick

------------------------------------------------------------------------------
(* Environment *)

GoSilent ==
    /\ Held /\ live /\ silences < MaxSilence
    /\ live' = FALSE /\ age' = 0 /\ silences' = silences + 1
    /\ UNCHANGED <<up, ipad, pending, link, ipadHolds, macHolds, ipadLabel, macLabel, badPick,
                   avoidAwdl, flaps>>

\* A link goes down: a connection on it stops carrying bytes, with no error.
LinkDown(l) ==
    /\ up[l] /\ flaps < MaxFlaps
    /\ up' = [up EXCEPT ![l] = FALSE] /\ flaps' = flaps + 1
    /\ live' = (live /\ link # l)
    /\ age' = IF live /\ link = l THEN 0 ELSE age
    /\ UNCHANGED <<ipad, pending, link, ipadHolds, macHolds, ipadLabel, macLabel, badPick,
                   avoidAwdl, silences>>

LinkUp(l) ==
    /\ ~up[l] /\ flaps < MaxFlaps
    /\ up' = [up EXCEPT ![l] = TRUE] /\ flaps' = flaps + 1
    /\ UNCHANGED <<ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, silences>>

\* TCP's retransmission timeout ends the silent connection on both sides (W3).
TcpTimeout ==
    /\ Held /\ ~live
    /\ ipadHolds' = FALSE /\ macHolds' = FALSE /\ ipadLabel' = None /\ macLabel' = None
    /\ ipad' = IF ipadHolds THEN AfterLoss ELSE ipad
    /\ avoidAwdl' = IF ipadHolds THEN link = "awdl" ELSE avoidAwdl
    /\ UNCHANGED <<up, pending, link, live, age, badPick, silences, flaps>>

Env == GoSilent \/ TcpTimeout \/ \E l \in Links : LinkDown(l) \/ LinkUp(l)

Next == System \/ Env

Spec == Init /\ [][Next]_vars

\* Fairness on the system's own steps (time included); TcpTimeout and the
\* environment owe nothing.
FairSpec == Spec /\ WF_vars(Dial) /\ WF_vars(\E l \in Links : Establish(l))
                 /\ WF_vars(DialFail) /\ WF_vars(IpadDetect) /\ WF_vars(MacDetect)
                 /\ WF_vars(Tick)

------------------------------------------------------------------------------
(* Properties *)

\* Wireless cascade AWDL > infrastructure: a dial never offers infrastructure
\* while AWDL is usable, unless the last loss was on AWDL.
PreferAwdl == ~badPick

\* Each side's label is the real link of the connection it holds.
LabelExact ==
    /\ ipadHolds => ipadLabel = link
    /\ macHolds => macLabel = link

\* Neither side keeps a silent connection (and its "Connected" label) past D.
DetectDeadline == (Held /\ ~live) => age <= D

Inv == TypeOK /\ PreferAwdl /\ LabelExact /\ DetectDeadline

\* Once the environment settles with some link usable, both sides stream on
\* a live connection.
Recovers ==
    (<>[](up["wifi"] \/ up["awdl"])) => <>[](ipadHolds /\ macHolds /\ live)

\* Under the AwdlPin test mode: once AWDL stays usable, both sides stream.
RecoversPinned ==
    (<>[]up["awdl"]) => <>[](ipadHolds /\ macHolds /\ live)

\* Witness: after losing an AWDL connection the iPad dials infrastructure
\* although AWDL is still usable (the avoidAwdl fallback is reachable).
NeverFallsBackFromAwdl == ~(avoidAwdl /\ ipad = "dialing" /\ pending = {"wifi"} /\ up["awdl"])

\* Witness: a connection does stream.
NeverStreams == ~(ipadHolds /\ macHolds /\ live)
=============================================================================
