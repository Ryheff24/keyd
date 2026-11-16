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
(*   CauseAware:    only evidence that AWDL is broken (silence, TCP       *)
(*                  timeout, a dial that missed its watchdog) sets         *)
(*                  avoidAwdl; the OS aborting the sockets of a suspended  *)
(*                  app does not.                                          *)
(*                                                                         *)
(* OPEN (not in Design): ClimbsBack.  Nothing moves a session that is on   *)
(*   infrastructure back to AWDL; Design fails ClimbsBack (TC-design-climb).*)
(*   A make-before-break probe needs the Mac's listener up during a session *)
(*   (Lifecycle cancels it at Ready), must cost a healthy infrastructure   *)
(*   stream nothing when AWDL does not come up, and must not loop on an    *)
(*   AWDL that completes TLS then goes silent (2026-11-15).                *)
(*                                                                         *)
(* As built 2026-11-16 (OneLink, AwdlFirst, ExactLabel, SilenceDetect,     *)
(*   RedialOnLoss; ~CauseAware, no climb back): live session (scratchpad *)
(*   live/keyd-run-ipad.log), E2E 68e521e and 6222ff7 (background-recovery *)
(*   phase).  Backgrounding: iPadOS resets the connection (Mac: "Connection *)
(*   reset by peer" within 1 s of Home); on resume the iPad sees the loss  *)
(*   either as TCP FAILED "Software caused connection abort" (live) or as  *)
(*   its silence deadline, whose clock ran while suspended (6222ff7:       *)
(*   silentMs=15110), and both exits set avoidAWDL: "loss on awdl -> next  *)
(*   dial infra".  Nothing ever dials AWDL again: the rest of the session  *)
(*   runs on infrastructure (the 512 TU holds).  68e521e: the first AWDL   *)
(*   dial missed the 3 s connect watchdog (dial=awdl -> next=infra) and    *)
(*   182 of 230 s ran on en0.                                              *)
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
(*  W6 [O] Backgrounded, the app is suspended: it runs no step until it is *)
(*         foregrounded, and iPadOS may abort its sockets meanwhile (the  *)
(*         error shows on resume).  Whether the Mac sees the abort is [U]: *)
(*         modelled as the Mac's side going silent.                       *)
(*  W7 [O] A dial on a usable AWDL link can still miss the connect         *)
(*         watchdog (68e521e), at most MaxStalls times (probes included).  *)
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
    MaxBackgrounds, \* times the app is sent to the background
    MaxStalls,      \* AWDL dials or probes that miss the connect watchdog
    OneLink, AwdlFirst, ExactLabel, SilenceDetect, CauseAware, RedialOnLoss,
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
    avoidWhy,    \* history: what set avoidAwdl ("none", "fault", "suspend")
    suspended,   \* the app is in the background (W6)
    silences, flaps, backgrounds, stalls

vars == <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
          age, badPick, avoidAwdl, avoidWhy, suspended, silences, flaps, backgrounds, stalls>>

Design == OneLink /\ AwdlFirst /\ ExactLabel /\ SilenceDetect /\ CauseAware /\ RedialOnLoss

TypeOK ==
    /\ up \in [Links -> BOOLEAN]
    /\ ipad \in {"discovering", "dialing", "streaming", "stuck"}
    /\ pending \in SUBSET Links
    /\ link \in Links \cup {None}
    /\ live \in BOOLEAN /\ ipadHolds \in BOOLEAN /\ macHolds \in BOOLEAN
    /\ ipadLabel \in Links \cup {None} /\ macLabel \in Links \cup {None}
    /\ age \in 0..MaxAge
    /\ badPick \in BOOLEAN /\ avoidAwdl \in BOOLEAN
    /\ avoidWhy \in {"none", "fault", "suspend"}
    /\ suspended \in BOOLEAN
    /\ silences \in 0..MaxSilence /\ flaps \in 0..MaxFlaps
    /\ backgrounds \in 0..MaxBackgrounds /\ stalls \in 0..MaxStalls

Init ==
    /\ up \in [Links -> BOOLEAN]
    /\ ipad = "discovering" /\ pending = {}
    /\ link = None /\ live = FALSE /\ ipadHolds = FALSE /\ macHolds = FALSE
    /\ ipadLabel = None /\ macLabel = None
    /\ age = 0 /\ badPick = FALSE /\ avoidAwdl = FALSE /\ avoidWhy = "none"
    /\ suspended = FALSE
    /\ silences = 0 /\ flaps = 0 /\ backgrounds = 0 /\ stalls = 0

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

Env6 == <<avoidWhy, suspended, backgrounds, stalls>>

Dial ==
    /\ ~suspended /\ ipad = "discovering" /\ Candidates # {}
    /\ ipad' = "dialing" /\ pending' = Candidates
    /\ badPick' = (badPick \/ ("wifi" \in Candidates /\ up["awdl"] /\ ~avoidAwdl))
    /\ UNCHANGED <<up, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, avoidAwdl, silences, flaps>> /\ UNCHANGED Env6

\* Both sides settle on candidate l (W1); the Mac takes over any old connection (W5).
Establish(l) ==
    /\ ~suspended /\ ipad = "dialing" /\ l \in pending /\ up[l]
    /\ ipad' = "streaming" /\ pending' = {}
    /\ link' = l /\ live' = TRUE /\ ipadHolds' = TRUE /\ macHolds' = TRUE
    /\ ipadLabel' = LabelOf(l) /\ macLabel' = LabelOf(l)
    /\ age' = 0 /\ avoidAwdl' = FALSE
    /\ UNCHANGED <<up, badPick, silences, flaps>> /\ UNCHANGED Env6

\* The connect watchdog gives up on a dial whose links all went down.
DialFail ==
    /\ ~suspended /\ ipad = "dialing" /\ \A l \in pending : ~up[l]
    /\ ipad' = "discovering" /\ pending' = {}
    /\ UNCHANGED <<up, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, silences, flaps>> /\ UNCHANGED Env6

IpadDetect ==
    /\ ~suspended /\ SilenceDetect /\ ipadHolds /\ ~live /\ age >= D
    /\ ipadHolds' = FALSE /\ ipadLabel' = None /\ ipad' = AfterLoss
    /\ avoidAwdl' = (link = "awdl")
    /\ avoidWhy' = IF link = "awdl" THEN "fault" ELSE avoidWhy
    /\ UNCHANGED <<up, pending, link, live, macHolds, macLabel, age, badPick, silences, flaps>>
    /\ UNCHANGED <<suspended, backgrounds, stalls>>

MacDetect ==
    /\ SilenceDetect /\ macHolds /\ ~live /\ age >= D
    /\ macHolds' = FALSE /\ macLabel' = None
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, ipadLabel, age, badPick, avoidAwdl,
                   silences, flaps>> /\ UNCHANGED Env6

\* One heartbeat period passes on a silent, held connection.  An expired
\* detector fires before time moves on (W4).
Tick ==
    /\ Held /\ ~live /\ age < MaxAge
    /\ ~(SilenceDetect /\ age >= D)
    /\ age' = age + 1
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   badPick, avoidAwdl, silences, flaps>> /\ UNCHANGED Env6

System == Dial \/ (\E l \in Links : Establish(l)) \/ DialFail \/ IpadDetect \/ MacDetect \/ Tick

------------------------------------------------------------------------------
(* Environment *)

GoSilent ==
    /\ Held /\ live /\ silences < MaxSilence
    /\ live' = FALSE /\ age' = 0 /\ silences' = silences + 1
    /\ UNCHANGED <<up, ipad, pending, link, ipadHolds, macHolds, ipadLabel, macLabel, badPick,
                   avoidAwdl, flaps>> /\ UNCHANGED Env6

\* A link goes down: a connection on it stops carrying bytes, with no error.
LinkDown(l) ==
    /\ up[l] /\ flaps < MaxFlaps
    /\ up' = [up EXCEPT ![l] = FALSE] /\ flaps' = flaps + 1
    /\ live' = (live /\ link # l)
    /\ age' = IF live /\ link = l THEN 0 ELSE age
    /\ UNCHANGED <<ipad, pending, link, ipadHolds, macHolds, ipadLabel, macLabel, badPick,
                   avoidAwdl, silences>> /\ UNCHANGED Env6

LinkUp(l) ==
    /\ ~up[l] /\ flaps < MaxFlaps
    /\ up' = [up EXCEPT ![l] = TRUE] /\ flaps' = flaps + 1
    /\ UNCHANGED <<ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, silences>> /\ UNCHANGED Env6

\* TCP's retransmission timeout ends the silent connection on both sides (W3).
TcpTimeout ==
    /\ Held /\ ~live
    /\ ipadHolds' = FALSE /\ macHolds' = FALSE /\ ipadLabel' = None /\ macLabel' = None
    /\ ipad' = IF ipadHolds THEN AfterLoss ELSE ipad
    /\ avoidAwdl' = IF ipadHolds THEN link = "awdl" ELSE avoidAwdl
    /\ avoidWhy' = IF ipadHolds /\ link = "awdl" THEN "fault" ELSE avoidWhy
    /\ UNCHANGED <<up, pending, link, live, age, badPick, silences, flaps>>
    /\ UNCHANGED <<suspended, backgrounds, stalls>>

\* W6: the app goes to the background / comes back.
Background ==
    /\ ~suspended /\ backgrounds < MaxBackgrounds
    /\ suspended' = TRUE /\ backgrounds' = backgrounds + 1
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, avoidWhy, silences, flaps, stalls>>

Foreground ==
    /\ suspended /\ suspended' = FALSE
    /\ UNCHANGED <<up, ipad, pending, link, live, ipadHolds, macHolds, ipadLabel, macLabel,
                   age, badPick, avoidAwdl, avoidWhy, silences, flaps, backgrounds, stalls>>

\* W6: iPadOS resets the suspended app's connection; on resume the iPad takes it as a loss.  One
\* step stands for both observed exits: TCP FAILED (connection abort) and the silence deadline,
\* whose clock counted the suspended time.  As built the teardown sets avoidAwdl when the connection was on AWDL
\* ("wasAWDL=true -> next dial infra"); CauseAware: an abort is not evidence about the link.
SuspendAbort ==
    /\ suspended /\ ipadHolds
    /\ ipadHolds' = FALSE /\ ipadLabel' = None /\ ipad' = AfterLoss
    /\ live' = FALSE /\ age' = 0
    /\ avoidAwdl' = IF CauseAware THEN avoidAwdl ELSE link = "awdl"
    /\ avoidWhy' = IF ~CauseAware /\ link = "awdl" THEN "suspend" ELSE avoidWhy
    /\ UNCHANGED <<up, pending, link, macHolds, macLabel, badPick, silences, flaps>>
    /\ UNCHANGED <<suspended, backgrounds, stalls>>

\* W7: an AWDL dial on a usable link misses the connect watchdog: the next dial avoids AWDL.
DialStall ==
    /\ ~suspended /\ stalls < MaxStalls /\ up["awdl"]
    /\ ipad = "dialing" /\ pending = {"awdl"}
    /\ ipad' = "discovering" /\ pending' = {}
    /\ avoidAwdl' = TRUE /\ avoidWhy' = "fault"
    /\ stalls' = stalls + 1
    /\ UNCHANGED <<up, link, live, ipadHolds, macHolds, ipadLabel, macLabel, age, badPick,
                   silences, flaps, suspended, backgrounds>>

Env == GoSilent \/ TcpTimeout \/ \E l \in Links : LinkDown(l) \/ LinkUp(l)
       \/ Background \/ Foreground \/ SuspendAbort \/ DialStall

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

\* CauseAware: the iPad avoids AWDL only after evidence the AWDL link is broken.
AvoidOnFault == avoidAwdl => avoidWhy = "fault"

Inv == TypeOK /\ PreferAwdl /\ LabelExact /\ DetectDeadline /\ AvoidOnFault

\* Once the environment settles with some link usable and the app in the
\* foreground, both sides stream on a live connection.
Recovers ==
    (<>[](up["wifi"] \/ up["awdl"]) /\ <>[]~suspended) => <>[](ipadHolds /\ macHolds /\ live)

\* Under the AwdlPin test mode: once AWDL stays usable, both sides stream.
RecoversPinned ==
    (<>[]up["awdl"] /\ <>[]~suspended) => <>[](ipadHolds /\ macHolds /\ live)

\* Cascade AWDL > infrastructure as an outcome: once AWDL stays usable and the
\* app stays in the foreground, the session ends up streaming on AWDL, whatever
\* sent it to infrastructure (an AWDL loss, a missed watchdog, a background).
ClimbsBack ==
    (<>[]up["awdl"] /\ <>[]~suspended) => <>[](ipadHolds /\ macHolds /\ live /\ link = "awdl")

\* Witness: after losing an AWDL connection the iPad dials infrastructure
\* although AWDL is still usable (the avoidAwdl fallback is reachable).
NeverFallsBackFromAwdl == ~(avoidAwdl /\ ipad = "dialing" /\ pending = {"wifi"} /\ up["awdl"])

\* Witness: the app is suspended and no longer holds its connection (SuspendAbort).
NeverAbortedSuspended == ~(suspended /\ ~ipadHolds /\ macHolds)

\* Witness: a connection does stream.
NeverStreams == ~(ipadHolds /\ macHolds /\ live)
=============================================================================
