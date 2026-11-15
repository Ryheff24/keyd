------------------------------- MODULE Pairing -------------------------------
(***************************************************************************)
(* First pairing between the Mac agent (host) and an iPad (client): B1, H2  *)
(* and C2 in PLAN.md.  Method: METHOD.md.                                   *)
(*                                                                         *)
(* As built [C] (read 2026-10-29):                                         *)
(*   Mac  showQR():  QR = {macCertFingerprint, ecdhPub, host, port}         *)
(*                   startPairingListener() on "::"  (all interfaces)       *)
(*          RemoteDesktop/macOS/App/SessionManager.m:509-620                *)
(*          RemoteDesktop/macOS/Pairing/PairingManager.m:1015-1070          *)
(*   Mac  closeQR(): window.close()  -- listener keeps running              *)
(*          SessionManager.m:20-24 (QRWindow), no stopPairingListener call  *)
(*   Mac  onConnection(c): if active != c: cancel(active); active := c      *)
(*          PairingManager.m:629-638  (a new connection replaces the old)   *)
(*   Mac  onReceive(c, bytes): completePairing(bytes)  -- no client proof   *)
(*          store peer := provisionedClientFingerprint                      *)
(*          reply {clientCertificateDER, clientPrivateKeyRepresentation}    *)
(*          stopPairingListener(); close QR window                          *)
(*          PairingManager.m:428-515, 650-712, 771-846                      *)
(*   iPad scan(QR): connect(host, port), pin macCertFingerprint, send key   *)
(*          RemoteDesktop/iPadOS/Pairing/QRPairing.swift                    *)
(*                                                                         *)
(* Assumptions (inputs, not results):                                       *)
(*   A1 [I] Outside (A) can reach any listener bound to a Wi-Fi or AWDL     *)
(*          interface, at any time (public network, PLAN.md / METHOD.md).   *)
(*   A2 [I] Outside cannot reach a listener bound only to the USB NCM       *)
(*          interface: that needs the cable in the Mac.                     *)
(*   A3 [I] With ConfirmOnMac the Mac shows a short code derived from both  *)
(*          certificates and the iPad shows the same code; the owner        *)
(*          confirms only when the two match, which only the iPad on the    *)
(*          owner's desk can produce.                                       *)
(*   A4 [I] The iPad pins the Mac fingerprint from the QR, so A cannot pose *)
(*          as the Mac to I (steady-state pinning is out of scope here).    *)
(*   AttackerSeesQR is the environment: TRUE means A photographed or        *)
(*   screen-captured the QR while it was shown.                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    I, A, None,          \* the owner's iPad, Outside, no device
    \* mechanisms (design switches; as built: all FALSE)
    TokenInQR,           \* QR carries a one-time token; the client must prove it
    CloseWithWindow,         \* the pairing listener exists only while the QR is shown
    ClientKeygen,        \* the iPad makes its own key; no private key is sent
    SingleAttempt,       \* one pairing connection at a time; no replacement
    ConfirmOnMac,        \* the owner confirms a matching short code on the Mac (A3)
    USBPairing,          \* the pairing listener binds only the USB NCM interface (A2)
    \* environment
    AttackerSeesQR

ASSUME Distinct == I # A /\ None \notin {I, A}
ASSUME Switches == {TokenInQR, CloseWithWindow, ClientKeygen, SingleAttempt,
                    ConfirmOnMac, USBPairing, AttackerSeesQR} \subseteq BOOLEAN

Dev == {I, A}

VARIABLES
    pairWindow,          \* the pairing window is shown (USB design: "connect your iPad by cable"; as built: the QR window)
    listening,   \* the pairing listener is open
    tokenFresh,  \* the token in the current QR has not been used
    seen,        \* devices that have read the current QR
    pending,     \* the device on the Mac's active pairing connection, or None
    macPeer,     \* the client fingerprint the Mac stores as paired, or None
    keyOnWire,   \* a private key has been sent over the network
    displaced    \* an owner's pairing connection was replaced by another

vars == <<pairWindow, listening, tokenFresh, seen, pending, macPeer, keyOnWire, displaced>>

TypeOK ==
    /\ pairWindow \in BOOLEAN /\ listening \in BOOLEAN /\ tokenFresh \in BOOLEAN
    /\ seen \subseteq Dev
    /\ pending \in Dev \cup {None}
    /\ macPeer \in Dev \cup {None}
    /\ keyOnWire \in BOOLEAN /\ displaced \in BOOLEAN

Init ==
    /\ pairWindow = FALSE /\ listening = FALSE /\ tokenFresh = FALSE
    /\ seen = {} /\ pending = None /\ macPeer = None
    /\ keyOnWire = FALSE /\ displaced = FALSE

\* The owner opens "Pair iPad" on the Mac: QR shown, listener started.
OpenPairWindow ==
    /\ ~pairWindow
    /\ pairWindow' = TRUE /\ listening' = TRUE /\ tokenFresh' = TRUE /\ seen' = {}
    /\ UNCHANGED <<pending, macPeer, keyOnWire, displaced>>

\* The owner closes the QR window (Escape or the close button).
ClosePairWindow ==
    /\ pairWindow
    /\ pairWindow' = FALSE
    /\ listening' = IF CloseWithWindow THEN FALSE ELSE listening
    /\ pending' = IF CloseWithWindow THEN None ELSE pending
    /\ UNCHANGED <<tokenFresh, seen, macPeer, keyOnWire, displaced>>

\* The owner's iPad scans the QR.
Scan ==
    /\ pairWindow
    /\ seen' = seen \cup {I}
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, pending, macPeer, keyOnWire, displaced>>

\* Outside reads the QR (photo, screen capture): environment.
Peek ==
    /\ AttackerSeesQR /\ pairWindow
    /\ seen' = seen \cup {A}
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, pending, macPeer, keyOnWire, displaced>>

\* Who can reach the pairing listener (A1, A2).  The owner's iPad needs the
\* QR's host unless it pairs over the cable.
Reach(d) ==
    IF d = I THEN USBPairing \/ I \in seen
             ELSE ~USBPairing

Connect(d) ==
    /\ listening /\ Reach(d)
    /\ pending # d
    /\ SingleAttempt => pending = None
    /\ pending' = d
    /\ displaced' = (displaced \/ (pending = I /\ d # I))
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, seen, macPeer, keyOnWire>>

\* A pairing connection fails or is dropped.
Drop ==
    /\ pending # None
    /\ pending' = None
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, seen, macPeer, keyOnWire, displaced>>

ProofOK(d)   == ~TokenInQR \/ (d \in seen /\ tokenFresh)
ConfirmOK(d) == ~ConfirmOnMac \/ d = I                    \* A3

\* The Mac completes pairing with the device on the pending connection.
Accept(d) ==
    /\ pending = d /\ d # None
    /\ ProofOK(d) /\ ConfirmOK(d)
    /\ macPeer' = d
    /\ keyOnWire' = (keyOnWire \/ ~ClientKeygen)
    /\ pending' = None /\ listening' = FALSE /\ pairWindow' = FALSE /\ tokenFresh' = FALSE
    /\ UNCHANGED <<seen, displaced>>

\* The Mac refuses a pairing attempt that fails a check.
Refuse(d) ==
    /\ pending = d /\ d # None
    /\ ~(ProofOK(d) /\ ConfirmOK(d))
    /\ pending' = None
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, seen, macPeer, keyOnWire, displaced>>

\* The owner chooses "Reset pairing" on the Mac.
ResetPairing ==
    /\ macPeer # None
    /\ macPeer' = None
    /\ UNCHANGED <<pairWindow, listening, tokenFresh, seen, pending, keyOnWire, displaced>>

Next ==
    \/ OpenPairWindow \/ ClosePairWindow \/ Scan \/ Peek \/ Drop \/ ResetPairing
    \/ \E d \in Dev : Connect(d) \/ Accept(d) \/ Refuse(d)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties.  Each has a control in cfg/ that must report it violated.   *)

\* The security goal: only the owner's iPad is ever stored as paired.
OnlyOwnerPaired == macPeer \in {I, None}

\* The pairing listener is never open without the QR on screen.
ListenerOnlyWhileWindow == listening => pairWindow

\* No private key ever crosses the network.
NoPrivateKeyOnWire == ~keyOnWire

\* Nobody can take over the owner's pairing connection mid-flight.
OwnerNotDisplaced == ~displaced

Safe == OnlyOwnerPaired /\ ListenerOnlyWhileWindow /\ NoPrivateKeyOnWire /\ OwnerNotDisplaced
Inv  == TypeOK /\ Safe

\* Non-vacuity: the owner can pair at all.  Must be violated (a witness).
NeverPaired == macPeer = None

Design == USBPairing /\ CloseWithWindow /\ ClientKeygen /\ SingleAttempt /\ ConfirmOnMac
=============================================================================
