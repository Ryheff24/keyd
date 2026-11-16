------------------------------ MODULE DeltaSync ------------------------------
(***************************************************************************)
(* Lossless USB media path: XOR-delta + LZ4 frames from the Mac to the     *)
(* iPad (H4 media pipeline x C5 decode, across the boundary).              *)
(*                                                                         *)
(* As built [C] (2026-11-15):                                              *)
(*  - The Mac compresses each captured frame on one serial queue           *)
(*    (FrameCompressor.c compress_frame, dispatch_assert_queue). A delta   *)
(*    frame XORs against the Mac's reference and then the reference        *)
(*    becomes this frame (compute_delta_and_update).                       *)
(*  - The compressed frame is then offered to the USB TCP sender. If more  *)
(*    than kMaxMediaSendsInFlightUSB sends are in flight, it is DROPPED    *)
(*    (SessionManager.m sendMediaFrameToiPad USB branch and the split-send *)
(*    branch).                                                             *)
(*  - The iPad applies each delta to its own reference (LZ4Decompressor    *)
(*    decompressDelta: output = delta ^ reference; reference = output).    *)
(*  - Observed: 11,000 drops in one run, iPad seq gaps of 3-8, a garbled   *)
(*    picture until the next keyframe.                                     *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  T1 One serial producer: only the compress queue enqueues sends, so the *)
(*     in-flight count can only fall between the gate check and the        *)
(*     enqueue (completions only decrement).                               *)
(*  T2 USB TCP is reliable and in order for one connection: a send that    *)
(*     is enqueued reaches the iPad, in enqueue order.                     *)
(*  T4 [O] 2026-11-16 01:23:20 (AWDL -> USB replug): a (re)connect breaks  *)
(*     the stream.  Frames compressed before the USB connection was ready  *)
(*     never reach the new connection in order: the switch's keyframe      *)
(*     (seq 1803, 1.68 MB) went out on the wireless link and reached the   *)
(*     iPad after USB deltas 1805-1814.  The first USB frame was a delta   *)
(*     with no base (decode FAILED), and the picture stayed wrong until    *)
(*     the periodic keyframe (seq 2400, 5.5 s later).  Modelled: Reconnect *)
(*     moves the in-flight queue to `stale`, which may still reach the     *)
(*     decoder at any later time, interleaved with new frames.             *)
(*  T3 Frame content is abstracted to its capture index. Applying a delta  *)
(*     to the wrong reference yields garbage (0 is never a valid frame     *)
(*     after Init; garbage is -1) and garbage persists until a keyframe.   *)
(*                                                                         *)
(* Mechanisms (CONSTANT switches, METHOD.md "Design switches"):            *)
(*  GateBeforeCompress  skip compressing (and do not advance the Mac       *)
(*                      reference) while the in-flight queue is full.      *)
(*  DropAfterCompress   as built: a compressed frame that finds the queue  *)
(*                      full is dropped. FALSE = it is enqueued anyway.    *)
(*  KeyOnConnect        the first frame compressed after a (re)connect is  *)
(*                      a keyframe (Mac).                                  *)
(*  DropOldLink         the iPad decodes LZ4 frames only from the current  *)
(*                      USB connection; stale ones are discarded.          *)
(* Design: GateBeforeCompress, KeyOnConnect, DropOldLink = TRUE,           *)
(* DropAfterCompress = FALSE.                                              *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    MaxFrames,            \* captured frames 1..MaxFrames (frame 0 = initial keyframe)
    Cap,                  \* kMaxMediaSendsInFlightUSB
    KeyEvery,             \* keyframe when frame index mod KeyEvery = 0 (0 = never)
    GateBeforeCompress,
    DropAfterCompress,
    MaxReconnects,        \* (re)connects in one behaviour
    KeyOnConnect,
    DropOldLink

VARIABLES
    next,       \* next frame index the capture will deliver
    macRef,     \* frame the Mac's delta reference holds
    queue,      \* in-flight sends, FIFO: [key |-> BOOLEAN, base |-> Int, target |-> Int]
    ipadRef,    \* frame the iPad's reference holds (-1 = garbage)
    corrupt,    \* TRUE once the iPad has shown a frame that is not a captured frame
    stale,      \* sends of earlier connections still on their way (any order w.r.t. new ones)
    forceKey,   \* the Mac's next compressed frame is a keyframe
    reconnects

vars == <<next, macRef, queue, ipadRef, corrupt, stale, forceKey, reconnects>>

Garbage == -1

TypeOK ==
    /\ next \in 1..(MaxFrames + 1)
    /\ macRef \in 0..MaxFrames
    /\ ipadRef \in 0..MaxFrames \cup {Garbage}
    /\ corrupt \in BOOLEAN
    /\ forceKey \in BOOLEAN /\ reconnects \in 0..MaxReconnects
    /\ \A i \in 1..Len(stale) :
          /\ stale[i].key \in BOOLEAN
          /\ stale[i].base \in 0..MaxFrames
          /\ stale[i].target \in 1..MaxFrames
    /\ \A i \in 1..Len(queue) :
          /\ queue[i].key \in BOOLEAN
          /\ queue[i].base \in 0..MaxFrames
          /\ queue[i].target \in 1..MaxFrames

Init ==
    /\ next = 1
    /\ macRef = 0          \* session starts from a shared keyframe 0
    /\ queue = <<>>
    /\ ipadRef = 0
    /\ corrupt = FALSE
    /\ stale = <<>> /\ forceKey = FALSE /\ reconnects = 0

IsKey(n) == KeyEvery > 0 /\ n % KeyEvery = 0

\* The capture delivers frame `next`; the gate skips it without touching the reference.
SkipFrame ==
    /\ next <= MaxFrames
    /\ GateBeforeCompress
    /\ Len(queue) >= Cap
    /\ next' = next + 1
    /\ UNCHANGED <<macRef, queue, ipadRef, corrupt, stale, forceKey, reconnects>>

\* Compress frame `next` against macRef (or as a keyframe), advance the reference, offer it.
Compress ==
    /\ next <= MaxFrames
    /\ ~(GateBeforeCompress /\ Len(queue) >= Cap)
    /\ LET msg == [key |-> IsKey(next) \/ forceKey, base |-> macRef, target |-> next]
       IN  IF Len(queue) < Cap \/ ~DropAfterCompress
           THEN queue' = Append(queue, msg)
           ELSE queue' = queue                 \* as built: dropped after compression
    /\ macRef' = next
    /\ next' = next + 1
    /\ forceKey' = FALSE
    /\ UNCHANGED <<ipadRef, corrupt, stale, reconnects>>

Decode(m) == IF m.key THEN m.target
             ELSE IF ipadRef = m.base THEN m.target ELSE Garbage

\* The iPad receives the head send (T2) and decodes it.
Deliver ==
    /\ Len(queue) > 0
    /\ LET out == Decode(Head(queue))
       IN  /\ ipadRef' = out
           /\ corrupt' = (corrupt \/ out = Garbage)
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<next, macRef, stale, forceKey, reconnects>>

\* The link changes (T4): what is in flight becomes stale; the Mac keeps its reference.
Reconnect ==
    /\ reconnects < MaxReconnects
    /\ reconnects' = reconnects + 1
    /\ stale' = stale \o queue /\ queue' = <<>>
    /\ forceKey' = (forceKey \/ KeyOnConnect)
    /\ UNCHANGED <<next, macRef, ipadRef, corrupt>>

\* A send of an earlier connection reaches the iPad late (T4); with DropOldLink it is discarded.
DeliverStale ==
    /\ Len(stale) > 0
    /\ LET out == Decode(Head(stale))
       IN  IF DropOldLink
           THEN UNCHANGED <<ipadRef, corrupt>>
           ELSE /\ ipadRef' = out
                /\ corrupt' = (corrupt \/ out = Garbage)
    /\ stale' = Tail(stale)
    /\ UNCHANGED <<next, macRef, queue, forceKey, reconnects>>

Next == SkipFrame \/ Compress \/ Deliver \/ Reconnect \/ DeliverStale

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties, each with a control (cfg/DS-*.cfg).

\* Every frame the iPad decodes is a frame the Mac captured.
NoCorruption == ~corrupt

\* The in-flight queue stays within the sender's cap (bounded latency and memory).
QueueBounded == Len(queue) <= Cap

\* Stronger, structural: every queued delta's base is the frame the iPad will hold when it is
\* applied, i.e. the queue is a chain starting at ipadRef.
ChainFrom(r, q) ==
    \A i \in 1..Len(q) :
        q[i].key \/ q[i].base = (IF i = 1 THEN r ELSE q[i-1].target)
QueueIsChain == ipadRef = Garbage \/ forceKey \/ (queue # <<>> /\ Head(queue).key)
                \/ ChainFrom(ipadRef, queue)

\* Witness: frames do reach the iPad (a control config expects this "violated").
NeverDelivered == ipadRef = 0
=============================================================================
