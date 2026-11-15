------------------------------ MODULE FrameRing ------------------------------
(***************************************************************************)
(* iPad render path (C5 decode x C6 present): decoded LZ4 frames handed to *)
(* MetalRenderer and shown by a 120 Hz CAMetalDisplayLink.                  *)
(*                                                                         *)
(* As built [C] (2026-11-15, d328f4f): one texture. updateFrame copies     *)
(* each decoded frame into it (MTLTexture.replace) and sets frameDirty; the *)
(* display link draws whatever the texture holds. Up to 3 command buffers  *)
(* are in flight (inflightSemaphore), each sampling that texture until its *)
(* completion handler runs. Measured: display link on time (120 ticks/s),  *)
(* but arrivals bunch (median per second: 25 ticks with no new frame, 18   *)
(* with 2+), so ~20% of frames are overwritten unseen (pacing CV 0.53).    *)
(*                                                                         *)
(* Design: a ring of NSlots textures and a FIFO of decoded frames. A frame *)
(* is copied into a slot that is not queued, not shown and not referenced  *)
(* by any in-flight command buffer; if none is free, the oldest queued     *)
(* frame is dropped and its slot reused. Each tick shows at most one new   *)
(* frame, oldest first. Drain rule: if the queue has stayed non-empty      *)
(* after presenting for K ticks in a row and holds 2+ frames, drop the     *)
(* oldest, so a standing backlog cannot add a refresh of latency forever.  *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  R1 Decode happens upstream of the ring and always advances the iPad    *)
(*     reference (LZ4Decompressor / striped_decode, DeltaSync/StripeSync); *)
(*     the ring only ever drops display, never decode. Copy path: the ring *)
(*     receives a finished frame; a slot is written only by its filler.    *)
(*  R2 One producer (the receive/decode queue) and one consumer (the       *)
(*     display link); ring state changes under one lock.                   *)
(*  R3 The GPU completes command buffers in submission order; a command    *)
(*     buffer reads the slot it was encoded with until it completes.       *)
(*  R4 Content is abstracted to the frame number.                          *)
(*                                                                         *)
(* Mechanisms (CONSTANT switches):                                         *)
(*  Ring        NSlots textures with ownership; FALSE = as built (one      *)
(*              texture, overwritten in place, newest wins).               *)
(*  WaitForGPU  a slot is reusable only after its in-flight references     *)
(*              complete; FALSE = reusable as soon as it is not shown.     *)
(*  Drain       the K-tick drain rule above.                               *)
(*  Fifo        a tick shows the oldest queued frame; FALSE = shows the    *)
(*              newest and keeps the older ones queued.                    *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    NSlots,      \* textures in the ring (1 when ~Ring)
    QCap,        \* max queued frames
    InFlight,    \* max command buffers in flight (inflightSemaphore)
    K,           \* drain threshold in ticks
    MaxFrames,   \* frames 1..MaxFrames arrive
    Ring,
    WaitForGPU,
    Drain,
    Fifo

Slots == 1..NSlots
None == 0

VARIABLES
    next,        \* next frame to arrive
    content,     \* content[s]: frame held by slot s (0 = none)
    queue,       \* FIFO of slots holding decoded, not-yet-shown frames
    shown,       \* slot currently on screen (None before the first frame)
    gpu,         \* FIFO of slots referenced by in-flight command buffers
    backlog,     \* consecutive ticks that ended with a non-empty queue
    lastShown,   \* last frame number presented
    dropped,     \* frames dropped from display
    writeWhileRead,  \* a slot was written while the GPU or the screen used it
    outOfOrder       \* an older frame was presented after a newer one

vars == <<next, content, queue, shown, gpu, backlog, lastShown, dropped, writeWhileRead, outOfOrder>>

InGPU(s) == \E i \in 1..Len(gpu) : gpu[i] = s
InQueue(s) == \E i \in 1..Len(queue) : queue[i] = s
Busy(s) == InGPU(s) \/ s = shown
Free(s) == ~InQueue(s) /\ s # shown /\ (WaitForGPU => ~InGPU(s))

TypeOK ==
    /\ next \in 1..(MaxFrames + 1)
    /\ content \in [Slots -> 0..MaxFrames]
    /\ shown \in Slots \cup {None}
    /\ Len(queue) <= NSlots
    /\ Len(gpu) <= InFlight
    /\ backlog \in Nat
    /\ writeWhileRead \in BOOLEAN
    /\ outOfOrder \in BOOLEAN

Init ==
    /\ next = 1
    /\ content = [s \in Slots |-> 0]
    /\ queue = <<>>
    /\ shown = None
    /\ gpu = <<>>
    /\ backlog = 0
    /\ lastShown = 0
    /\ dropped = 0
    /\ writeWhileRead = FALSE
    /\ outOfOrder = FALSE

\* As built: copy into the one texture in place, newest wins.
ArriveAsBuilt ==
    /\ ~Ring
    /\ next <= MaxFrames
    /\ writeWhileRead' = (writeWhileRead \/ InGPU(1))
    /\ content' = [content EXCEPT ![1] = next]
    /\ dropped' = dropped + (IF queue # <<>> THEN 1 ELSE 0)
    /\ queue' = <<1>>
    /\ next' = next + 1
    /\ UNCHANGED <<shown, gpu, backlog, lastShown, outOfOrder>>

\* Design: copy into a free slot; if none, reuse the oldest queued frame's slot.
ArriveRing ==
    /\ Ring
    /\ next <= MaxFrames
    /\ \/ /\ \E s \in Slots : Free(s)
          /\ LET s == CHOOSE x \in Slots : Free(x)
             IN  /\ writeWhileRead' = (writeWhileRead \/ Busy(s))
                 /\ content' = [content EXCEPT ![s] = next]
                 /\ queue' = IF Len(queue) < QCap THEN Append(queue, s)
                             ELSE Append(Tail(queue), s)
                 /\ dropped' = dropped + (IF Len(queue) < QCap THEN 0 ELSE 1)
       \/ /\ ~\E s \in Slots : Free(s)
          /\ queue # <<>>
          /\ LET s == Head(queue)
             IN  /\ writeWhileRead' = (writeWhileRead \/ Busy(s))
                 /\ content' = [content EXCEPT ![s] = next]
                 /\ queue' = Append(Tail(queue), s)
                 /\ dropped' = dropped + 1
       \/ /\ ~\E s \in Slots : Free(s)
          /\ queue = <<>>
          /\ dropped' = dropped + 1            \* nowhere to put it: display drop only
          /\ UNCHANGED <<content, queue, writeWhileRead>>
    /\ next' = next + 1
    /\ UNCHANGED <<shown, gpu, backlog, lastShown, outOfOrder>>

\* Display-link tick: needs an in-flight slot; shows at most one new frame.
Tick ==
    /\ Len(gpu) < InFlight
    /\ \/ /\ queue = <<>>
          /\ shown # None
          /\ gpu' = Append(gpu, shown)          \* redraw the current frame
          /\ backlog' = 0
          /\ UNCHANGED <<queue, shown, lastShown, dropped, outOfOrder>>
       \/ /\ queue # <<>>
          /\ LET drain == Drain /\ backlog >= K /\ Len(queue) >= 2
                 q1    == IF drain THEN Tail(queue) ELSE queue
                 s     == IF Fifo THEN Head(q1) ELSE q1[Len(q1)]
                 rest  == IF Fifo THEN Tail(q1) ELSE SubSeq(q1, 1, Len(q1) - 1)
             IN  /\ queue' = rest
                 /\ shown' = s
                 /\ gpu' = Append(gpu, s)
                 /\ dropped' = dropped + (IF drain THEN 1 ELSE 0)
                 /\ outOfOrder' = (outOfOrder \/ content[s] < lastShown)
                 /\ lastShown' = content[s]
                 /\ backlog' = IF rest # <<>> THEN backlog + 1 ELSE 0
    /\ UNCHANGED <<next, content, writeWhileRead>>

\* GPU completes the oldest in-flight command buffer (R3).
Complete ==
    /\ gpu # <<>>
    /\ gpu' = Tail(gpu)
    /\ UNCHANGED <<next, content, queue, shown, backlog, lastShown, dropped, writeWhileRead, outOfOrder>>

Next == ArriveAsBuilt \/ ArriveRing \/ Tick \/ Complete

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties, each with a control (cfg/FR-*.cfg).

\* The CPU never writes a texture the GPU is reading or the screen is showing.
NoWriteWhileRead == ~writeWhileRead

\* Frames are presented in arrival order.
InOrder == ~outOfOrder

\* A standing backlog cannot persist: at most K ticks in a row end with frames
\* still waiting, so the queue cannot hold latency up by a refresh for long.
BoundedBacklog == backlog <= K

\* Witness: a frame reaches the screen.
NeverShown == lastShown = 0
=============================================================================
