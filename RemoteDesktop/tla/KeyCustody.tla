----------------------------- MODULE KeyCustody -------------------------------
(***************************************************************************)
(* Who can sign with the Mac identity the iPad pins.  Discharges the       *)
(* precondition of SecureSession A5 (symbolic TLS: only a session's two    *)
(* ends can read or forge its records), which assumes the Mac's private    *)
(* key is known to the Mac agent alone.                                    *)
(*                                                                         *)
(* As built [C] (read 2026-11-15):                                          *)
(*   scripts/run-apps.sh, run-e2e-tests.sh, mac-debug.sh: if               *)
(*   /tmp/keydrd-tls/identity.p12 is missing, generate it with openssl,    *)
(*   else reuse whatever file is there.  PairingManager.m loads it with    *)
(*   the passphrase "keydrd" (in the source).  /tmp is shared by every     *)
(*   local account; the file is mode 0600, owned by whoever created it.    *)
(* Design: a P-256 key generated in the Secure Enclave, a permanent item   *)
(*   in the data-protection keychain under the agent's access group; no    *)
(*   export, no file, no fallback.  If the Secure Enclave is unavailable   *)
(*   the agent has no identity and does not pair or serve (fail closed).   *)
(*                                                                         *)
(* Actors: Agent (the signed agent), P (another process running as the     *)
(* owner's user, e.g. a compromised tool), U (another local account).      *)
(* Assumptions:                                                             *)
(*  K1 [I] File modes and uids are enforced: a 0600 file is readable by    *)
(*         its owner's processes (Agent, P) and root, no one else.         *)
(*  K2 [I] Any account can create a path under /tmp that does not exist.   *)
(*  K3 [I] A Secure Enclave key cannot be exported; only processes holding *)
(*         the keychain access group (the agent's signature + profile) can *)
(*         ask the Secure Enclave to sign with it.                         *)
(*  K4     A passphrase written in the source protects nothing (omitted).  *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS
    Storage,       \* "tmp" (as built), "appsupport" (0600 file in ~/Library), "se" (design)
    SEAvailable,   \* environment: the Secure Enclave key can be created
    Fallback       \* on SE failure, fall back to a 0600 file in ~/Library

Actors == {"Agent", "P", "U"}

VARIABLES
    keyExists,   \* the identity the agent will present exists
    inFile,      \* that key is stored in a file
    holders,     \* actors able to sign with it
    pinned       \* the owner's iPad has pinned it (pairing completed)

vars == <<keyExists, inFile, holders, pinned>>

Init == keyExists = FALSE /\ inFile = FALSE /\ holders = {} /\ pinned = FALSE

\* K2: another account creates /tmp/keydrd-tls/identity.p12 first and leaves it
\* readable; the scripts then reuse it.
PreCreate ==
    /\ Storage = "tmp" /\ ~keyExists
    /\ keyExists' = TRUE /\ inFile' = TRUE
    /\ holders' = {"U", "Agent", "P"}
    /\ UNCHANGED pinned

AgentCreate ==
    /\ ~keyExists
    /\ IF Storage = "se" /\ ~SEAvailable /\ ~Fallback
       THEN UNCHANGED <<keyExists, inFile, holders>>          \* fail closed
       ELSE /\ keyExists' = TRUE
            /\ inFile' = (Storage # "se" \/ ~SEAvailable)
            /\ holders' = {"Agent"}
    /\ UNCHANGED pinned

\* K1: a process of the owner's user reads a file the owner can read.
Steal ==
    /\ keyExists /\ inFile /\ "P" \notin holders
    /\ holders' = holders \cup {"P"}
    /\ UNCHANGED <<keyExists, inFile, pinned>>

\* The iPad pins the key the agent presents.
Pair ==
    /\ keyExists /\ "Agent" \in holders /\ ~pinned
    /\ pinned' = TRUE
    /\ UNCHANGED <<keyExists, inFile, holders>>

Next == PreCreate \/ AgentCreate \/ Steal \/ Pair
Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK == keyExists \in BOOLEAN /\ inFile \in BOOLEAN /\ holders \subseteq Actors /\ pinned \in BOOLEAN

\* Only the agent can sign as the Mac the iPad trusts (SecureSession A5).
OnlyAgentSigns == pinned => holders = {"Agent"}

\* Witness: pairing happens.
NeverPinned == ~pinned
=============================================================================
