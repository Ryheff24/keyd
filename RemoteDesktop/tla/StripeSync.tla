------------------------------ MODULE StripeSync ------------------------------
(***************************************************************************)
(* Striped parallel LZ4 for the lossless USB media path (H4 x C5, across   *)
(* the boundary). Extends DeltaSync: a frame is split into K horizontal    *)
(* stripes, each with its own XOR delta against its own slice of the       *)
(* reference, compressed and decompressed on parallel workers.             *)
(*                                                                         *)
(* As built [C] (2026-11-15, 52cd800): K = 1. FrameCompressor.c            *)
(* compress_frame XORs the whole frame (compute_delta_and_update writes    *)
(* the pending reference buffer, then flips `active`) and runs one LZ4     *)
(* stream on the serial compress queue. LZ4Decompressor.swift decompresses *)
(* one stream, XORs against keyframeReference and copies the result back.  *)
(* Measured: up to 49 ms per heavy frame on the Mac, 6.5 ms on the iPad.   *)
(*                                                                         *)
(* Design: K stripes. Mac: dispatch_apply over stripes; each worker reads  *)
(* buf[active][k], writes the delta for k and buf[pending][k]; only after  *)
(* all workers return does the queue flip `active` and emit one payload    *)
(* holding all K stripes. iPad: concurrentPerform over stripes; each       *)
(* worker applies stripe k to ref[k]; only after all return is the frame   *)
(* handed to the renderer.                                                 *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  S1 Frames are produced one at a time on the serial compress queue      *)
(*     (DeltaSync T1); the iPad decodes one frame at a time (one receive   *)
(*     path calls decompress).                                             *)
(*  S2 All K stripes of a frame travel in one payload over reliable,       *)
(*     in-order USB TCP (DeltaSync T2); no stripe is lost or reordered     *)
(*     relative to another frame's stripes. Gating/dropping is DeltaSync's.*)
(*  S3 Stripes are disjoint byte ranges: a worker for stripe k touches     *)
(*     only slice k of every buffer.                                       *)
(*  S4 Content is abstracted to the capture index per stripe; applying a   *)
(*     delta to the wrong base, or a stripe missing from the payload,      *)
(*     yields garbage (-1).                                                *)
(*                                                                         *)
(* Mechanisms (CONSTANT switches):                                         *)
(*  MacJoin   emit and flip `active` only after every stripe is compressed.*)
(*  IpadJoin  publish to the renderer only after every stripe is applied.  *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    K,           \* stripes per frame
    MaxFrames,   \* captured frames 1..MaxFrames (frame 0 = shared initial keyframe)
    MacJoin,
    IpadJoin

Stripes == 1..K
Garbage == -1
Vals == 0..MaxFrames \cup {Garbage}

VARIABLES
    next,       \* frame the Mac is compressing (MaxFrames+1 = done)
    active,     \* Mac reference buffer index (0 or 1)
    buf,        \* buf[b][k]: frame held in slice k of Mac reference buffer b
    mdone,      \* stripes of frame `next` compressed so far
    mbase,      \* mbase[k]: base used by stripe k of frame `next` (Garbage = not compressed)
    queue,      \* payloads in flight: [target |-> n, base |-> [Stripes -> Vals]]
    slot,       \* payload the iPad is decoding, or <<>>
    idone,      \* stripes of `slot` applied so far
    ref,        \* ref[k]: frame the iPad's reference slice k holds
    shown,      \* last frame published to the renderer, per stripe (<<>> = none)
    corrupt,    \* the iPad decoded garbage
    torn        \* the renderer was handed a mix of frames

vars == <<next, active, buf, mdone, mbase, queue, slot, idone, ref, shown, corrupt, torn>>

TypeOK ==
    /\ next \in 1..(MaxFrames + 1)
    /\ active \in {0, 1}
    /\ buf \in [{0, 1} -> [Stripes -> 0..MaxFrames]]
    /\ mdone \subseteq Stripes
    /\ mbase \in [Stripes -> Vals]
    /\ idone \subseteq Stripes
    /\ ref \in [Stripes -> Vals]
    /\ corrupt \in BOOLEAN
    /\ torn \in BOOLEAN

Init ==
    /\ next = 1
    /\ active = 0
    /\ buf = [b \in {0, 1} |-> [k \in Stripes |-> 0]]
    /\ mdone = {}
    /\ mbase = [k \in Stripes |-> Garbage]
    /\ queue = <<>>
    /\ slot = <<>>
    /\ idone = {}
    /\ ref = [k \in Stripes |-> 0]
    /\ shown = <<>>
    /\ corrupt = FALSE
    /\ torn = FALSE

Pending == 1 - active

\* One Mac worker compresses stripe k of frame `next` (any interleaving).
MacStripe(k) ==
    /\ next <= MaxFrames
    /\ k \notin mdone
    /\ mbase' = [mbase EXCEPT ![k] = buf[active][k]]
    /\ buf' = [buf EXCEPT ![Pending][k] = next]
    /\ mdone' = mdone \cup {k}
    /\ UNCHANGED <<next, active, queue, slot, idone, ref, shown, corrupt, torn>>

\* The compress queue flips the reference and emits the payload.
\* With MacJoin it waits for every worker; without it, it may go early and the
\* payload carries whatever stripes are done (missing ones are garbage, S4).
MacEmit ==
    /\ next <= MaxFrames
    /\ mdone # {}
    /\ MacJoin => mdone = Stripes
    /\ queue' = Append(queue, [target |-> next,
                               base |-> [k \in Stripes |-> IF k \in mdone THEN mbase[k] ELSE Garbage]])
    /\ active' = Pending
    /\ next' = next + 1
    /\ mdone' = {}
    /\ mbase' = [k \in Stripes |-> Garbage]
    /\ UNCHANGED <<buf, slot, idone, ref, shown, corrupt, torn>>

\* The iPad takes the next payload (S1: only when not already decoding one).
IpadTake ==
    /\ slot = <<>>
    /\ Len(queue) > 0
    /\ slot' = Head(queue)
    /\ queue' = Tail(queue)
    /\ idone' = {}
    /\ UNCHANGED <<next, active, buf, mdone, mbase, ref, shown, corrupt, torn>>

\* One iPad worker applies stripe k of the payload in `slot`.
IpadStripe(k) ==
    /\ slot # <<>>
    /\ k \notin idone
    /\ LET out == IF slot.base[k] # Garbage /\ ref[k] = slot.base[k]
                  THEN slot.target ELSE Garbage
       IN  /\ ref' = [ref EXCEPT ![k] = out]
           /\ corrupt' = (corrupt \/ out = Garbage)
    /\ idone' = idone \cup {k}
    /\ UNCHANGED <<next, active, buf, mdone, mbase, queue, slot, shown, torn>>

\* Hand the frame to the renderer. With IpadJoin it waits for every worker.
\* Without it, the renderer may copy while workers are still writing, and the
\* remaining workers are lost to this publish (they finish into the next one).
IpadPublish ==
    /\ slot # <<>>
    /\ idone # {}
    /\ IpadJoin => idone = Stripes
    /\ shown' = ref
    /\ torn' = (torn \/ \E i, j \in Stripes : ref[i] # ref[j])
    /\ slot' = IF idone = Stripes THEN <<>> ELSE slot
    /\ UNCHANGED <<next, active, buf, mdone, mbase, queue, idone, ref, corrupt>>

Next ==
    \/ \E k \in Stripes : MacStripe(k)
    \/ MacEmit
    \/ IpadTake
    \/ \E k \in Stripes : IpadStripe(k)
    \/ IpadPublish

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties, each with a control (cfg/SS-*.cfg).

\* Every stripe the iPad reconstructs is the stripe the Mac captured.
NoCorruption == ~corrupt

\* The renderer is never handed a mix of two frames.
NoTornPublish == ~torn

\* Structural: the Mac's active reference is uniform across stripes between frames,
\* i.e. the flip happens once per frame, after all slices are written.
MacRefUniform == mdone = {} => \A i, j \in Stripes : buf[active][i] = buf[active][j]

\* Witness: frames reach the renderer (a control config expects this "violated").
NeverPublished == shown = <<>>
=============================================================================
