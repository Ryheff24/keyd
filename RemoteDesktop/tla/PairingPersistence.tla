-------------------------- MODULE PairingPersistence --------------------------
(***************************************************************************)
(* Does the iPad keep its pairing while the Mac is unreachable, and does   *)
(* it reconnect on its own once the Mac is back?                           *)
(*                                                                         *)
(* As built [C] (2026-11-15):                                              *)
(*   iPad SessionManager.swift startConnectingTimeout (:346): every entry  *)
(*   to .connecting arms an 8 s one-shot timer.  If still .connecting when *)
(*   it fires: stop USB monitoring, stop Bonjour browsing,                 *)
(*   qrPairing.resetPairing() (QRPairing.swift:1087: deletes the client    *)
(*   identity, certificate, private key, pinned Mac fingerprint, paired    *)
(*   host), state = .awaitingPairing (QR scanner).                         *)
(*   Seen on hardware [O] 2026-11-15 22:38: Mac agent not running for      *)
(*   ~8 s -> "Connecting timeout -- pairing likely stale" -> iPad deleted  *)
(*   its credentials; the Mac still held the pin; the owner had to re-pair.*)
(*   Discovery can stall silently [O] (run 14ab289: Wi-Fi connect hung,    *)
(*   watchdog cancelled, browser restart skipped "already active").        *)
(*                                                                         *)
(* Design:                                                                 *)
(*   KeepCreds:  the timeout never deletes credentials.  Only the owner's  *)
(*               "Reset Pairing" (ContentView, resetPairingAndShowQR)      *)
(*               does, and a new pairing replaces them.                    *)
(*   RestartOnTimeout: the timeout restarts discovery (USB monitoring and  *)
(*               Bonjour browsing) and re-arms itself, staying .connecting.*)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  P1 [C] Only the owner's Reset Pairing, a new pairing, or the timeout   *)
(*         change the iPad's credentials (QRPairing.resetPairing callers:  *)
(*         SessionManager.swift:336 and :353).                             *)
(*  P2 [I] With credentials on both sides, the Mac reachable and discovery *)
(*         running, a connection eventually succeeds (TransportAgreement   *)
(*         proves the link choice; SecureSession the mutual pin check).    *)
(*  P3 [I] Discovery can stop without the iPad noticing (stall), at most   *)
(*         MaxStalls times; the Mac can go away and come back at most      *)
(*         MaxFlaps times; the owner may reset the Mac's pairing           *)
(*         (MacForget) - then only a new pairing helps, by design.         *)
(*  P4 [I] Pairing needs the owner (scan the QR over USB): an environment  *)
(*         action, never assumed to happen.                                *)
(* Security: keeping credentials changes nothing SecureSession relies on:  *)
(* they stay in the iPad keychain (ThisDeviceOnly) and a session still     *)
(* needs both pins.  The Mac's pin of an iPad that deleted its key is      *)
(* unusable by anyone, so the as-built mismatch was not an opening, only a *)
(* forced re-pair.                                                         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxFlaps,          \* Mac agent/link going away and coming back
    MaxStalls,         \* silent discovery stalls
    KeepCreds,         \* FALSE = as built: the timeout deletes credentials
    RestartOnTimeout   \* FALSE = as built: the timeout stops discovery

VARIABLES
    ipad,        \* "connecting" | "streaming" | "qr"
    creds,       \* the iPad holds its client key and the Mac's pin
    macPin,      \* the Mac holds this iPad's pin
    macUp,       \* the Mac agent is running and reachable
    discovering, \* the iPad's USB monitoring / Bonjour browsing is live
    timer,       \* the connecting timer is armed
    ownerReset,  \* history: the owner pressed Reset Pairing on the iPad
    flaps, stalls

vars == <<ipad, creds, macPin, macUp, discovering, timer, ownerReset, flaps, stalls>>

Design == KeepCreds /\ RestartOnTimeout

TypeOK ==
    /\ ipad \in {"connecting", "streaming", "qr"}
    /\ creds \in BOOLEAN /\ macPin \in BOOLEAN /\ macUp \in BOOLEAN
    /\ discovering \in BOOLEAN /\ timer \in BOOLEAN /\ ownerReset \in BOOLEAN
    /\ flaps \in 0..MaxFlaps /\ stalls \in 0..MaxStalls

\* Paired and launching: the app starts in .connecting with the timer armed.
Init ==
    /\ ipad = "connecting" /\ creds = TRUE /\ macPin = TRUE
    /\ macUp \in BOOLEAN /\ discovering = TRUE /\ timer = TRUE
    /\ ownerReset = FALSE /\ flaps = 0 /\ stalls = 0

------------------------------------------------------------------------------
(* System *)

Connect ==
    /\ ipad = "connecting" /\ discovering /\ macUp /\ creds /\ macPin
    /\ ipad' = "streaming" /\ timer' = FALSE
    /\ UNCHANGED <<creds, macPin, macUp, discovering, ownerReset, flaps, stalls>>

\* The session drops after the Mac went away; reconnect path re-arms the timer.
Lose ==
    /\ ipad = "streaming" /\ ~macUp
    /\ ipad' = "connecting" /\ timer' = TRUE
    /\ UNCHANGED <<creds, macPin, macUp, discovering, ownerReset, flaps, stalls>>

Timeout ==
    /\ ipad = "connecting" /\ timer
    /\ IF KeepCreds
          THEN /\ creds' = creds
               /\ ipad' = "connecting"
               /\ discovering' = (discovering \/ RestartOnTimeout)
               /\ timer' = RestartOnTimeout
          ELSE /\ creds' = FALSE          \* resetPairing()
               /\ ipad' = "qr"
               /\ discovering' = FALSE    \* stopMonitoring, stopBrowsing
               /\ timer' = FALSE
    /\ UNCHANGED <<macPin, macUp, ownerReset, flaps, stalls>>

System == Connect \/ Lose \/ Timeout

------------------------------------------------------------------------------
(* Environment and owner *)

MacDown ==
    /\ macUp /\ flaps < MaxFlaps
    /\ macUp' = FALSE /\ flaps' = flaps + 1
    /\ UNCHANGED <<ipad, creds, macPin, discovering, timer, ownerReset, stalls>>

MacUp ==
    /\ ~macUp /\ flaps < MaxFlaps
    /\ macUp' = TRUE /\ flaps' = flaps + 1
    /\ UNCHANGED <<ipad, creds, macPin, discovering, timer, ownerReset, stalls>>

Stall ==
    /\ discovering /\ ipad = "connecting" /\ stalls < MaxStalls
    /\ discovering' = FALSE /\ stalls' = stalls + 1
    /\ UNCHANGED <<ipad, creds, macPin, macUp, timer, ownerReset, flaps>>

\* Owner taps Reset Pairing on the iPad (connecting overlay).
OwnerReset ==
    /\ ipad = "connecting"
    /\ creds' = FALSE /\ ipad' = "qr" /\ discovering' = FALSE /\ timer' = FALSE
    /\ ownerReset' = TRUE
    /\ UNCHANGED <<macPin, macUp, flaps, stalls>>

\* Owner chooses Reset Pairing on the Mac.
MacForget ==
    /\ macPin
    /\ macPin' = FALSE
    /\ UNCHANGED <<ipad, creds, macUp, discovering, timer, ownerReset, flaps, stalls>>

\* Owner scans a new QR over USB (Pairing.tla); replaces both sides' credentials.
Pair ==
    /\ ipad = "qr" /\ macUp
    /\ creds' = TRUE /\ macPin' = TRUE /\ ipad' = "connecting"
    /\ discovering' = TRUE /\ timer' = TRUE
    /\ UNCHANGED <<macUp, ownerReset, flaps, stalls>>

Env == MacDown \/ MacUp \/ Stall \/ OwnerReset \/ MacForget \/ Pair

Next == System \/ Env

Spec == Init /\ [][Next]_vars

\* Fairness on the system's own steps only; the owner and environment owe nothing.
FairSpec == Spec /\ WF_vars(Connect) /\ WF_vars(Lose) /\ WF_vars(Timeout)

------------------------------------------------------------------------------
(* Properties *)

\* Credentials are gone only after the owner asked for it.
CredsOnlyOwnerForgets == ~creds => ownerReset

Inv == TypeOK /\ CredsOnlyOwnerForgets

\* Once the Mac stays reachable with its pin and the owner leaves pairing
\* alone, the iPad streams without a re-pair.
Reconnects ==
    (<>[](macUp /\ macPin /\ ~ownerReset)) => <>[](ipad = "streaming")

\* Witness: the iPad does stream.
NeverStreams == ipad # "streaming"
=============================================================================
