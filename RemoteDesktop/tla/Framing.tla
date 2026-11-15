------------------------------ MODULE Framing --------------------------------
(***************************************************************************)
(* iPad -> Mac messages on one TCP connection (control now, input next):   *)
(* PLAN.md "Input receive passes raw TCP regions to the parser, with no    *)
(* length framing".                                                         *)
(*                                                                         *)
(* As built [C] (read 2026-11-15):                                          *)
(*   iPad sends each message as its raw bytes (InputEventHeader + payload) *)
(*     iPadOS/Transport/USBNetworkTransport.swift:550-557,                 *)
(*     WirelessTransport.swift:406-413.                                    *)
(*   Mac hands every received region to the dispatcher as one message:    *)
(*     macOS/Transport/USBNetworkTransport.m:1114-1138 (receive 1..4096),  *)
(*     WirelessTransport.m:982-1006.                                       *)
(* Design: each message is preceded by a length; the Mac appends every     *)
(* received region to a per-connection buffer and extracts whole messages *)
(* only, keeping a partial tail for the next region.                       *)
(*                                                                         *)
(* Assumptions:                                                             *)
(*  F1 [I] TCP delivers the byte stream in order, without loss or          *)
(*         duplication, cut into regions at arbitrary byte boundaries      *)
(*         (one region may hold parts of several messages).                *)
(*  F2 [I] One connection; a new connection starts with an empty buffer    *)
(*         (cross-connection order is InputPath.tla's job).                *)
(*  F3     A byte is abstracted to <<message index, position>>; position 0 *)
(*         is the length prefix (its value is the payload length).         *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Lens,        \* payload lengths of the messages the iPad sends, e.g. <<1, 2, 1>>
    Framed,      \* the length prefix + reassembly buffer (design)
    KeepPartial  \* the parser keeps an incomplete tail across regions

\* Bound for TLC (cfg: Lens <- Lens3): three messages, one of them longer than one byte.
Lens3 == <<1, 2, 1>>

N == Len(Lens)

\* The bytes of message i on the wire.
MsgBytes(i) == IF Framed THEN [k \in 1..(Lens[i] + 1) |-> <<i, k - 1>>]
                         ELSE [k \in 1..Lens[i] |-> <<i, k>>]
\* The message as the dispatcher must see it (payload only).
Payload(i) == [k \in 1..Lens[i] |-> <<i, k>>]

RECURSIVE Concat(_)
Concat(n) == IF n = 0 THEN <<>> ELSE Concat(n - 1) \o MsgBytes(n)
Wire == Concat(N)

VARIABLES
    sent,      \* bytes TCP has handed to the Mac so far (a prefix of Wire)
    buf,       \* the Mac's reassembly buffer
    parsed     \* payloads the Mac dispatched, in order

vars == <<sent, buf, parsed>>

Init == sent = 0 /\ buf = <<>> /\ parsed = <<>>

\* Pull whole frames off the front of b.  Returns <<frames, rest>>.
RECURSIVE Extract(_, _)
Extract(b, acc) ==
    IF Len(b) = 0 THEN <<acc, b>>
    ELSE LET plen == Lens[b[1][1]]   \* the prefix byte carries the payload length
         IN IF Len(b) >= plen + 1
            THEN Extract(SubSeq(b, plen + 2, Len(b)),
                         Append(acc, SubSeq(b, 2, plen + 1)))
            ELSE <<acc, b>>

\* TCP hands the Mac one region of k bytes (F1).
Receive(k) ==
    /\ k >= 1 /\ sent + k <= Len(Wire)
    /\ LET region == SubSeq(Wire, sent + 1, sent + k) IN
       IF Framed
       THEN LET r == Extract(buf \o region, <<>>) IN
            /\ parsed' = parsed \o r[1]
            /\ buf' = IF KeepPartial THEN r[2] ELSE <<>>
       ELSE /\ parsed' = Append(parsed, region)    \* as built: region = message
            /\ buf' = buf
    /\ sent' = sent + k

Next == \E k \in 1..Len(Wire) : Receive(k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Every dispatched message is exactly the next message the iPad sent.
NoTornMessage ==
    /\ Len(parsed) <= N
    /\ \A j \in 1..Len(parsed) : parsed[j] = Payload(j)

\* Once the whole stream has arrived, every message has been dispatched.
AllDelivered == sent = Len(Wire) => Len(parsed) = N

TypeOK == sent \in 0..Len(Wire)

\* Witness: a message is dispatched.
NeverParsed == parsed = <<>>
=============================================================================
