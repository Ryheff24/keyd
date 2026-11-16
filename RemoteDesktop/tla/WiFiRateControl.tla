---------------------------- MODULE WiFiRateControl ----------------------------
(***************************************************************************)
(* The Mac's Wi-Fi adaptive rate loop: once a second it picks the encoder  *)
(* bitrate and the capture/encoder frame rate.  Sits on top of the ack     *)
(* gate (WiFiSendLoop.tla): the gate already paces sends; this loop picks  *)
(* how big frames are and how often the screen is captured.                *)
(*                                                                         *)
(* As built [C] (2026-11-16, macOS SessionManager.m):                      *)
(*   evaluateWiFiAdaptiveRateControl (:2184-2468) once per second:         *)
(*     severe if preDrops >= 3 (among others); healthy needs preDrops = 0. *)
(*     severe -> FPS down to 52 then 30, bitrate down 1.5 Mbps (floor 5); *)
(*     healthy for 10 windows -> FPS +2, bitrate +0.5 Mbps.                *)
(*   applyWiFiAdaptiveRateTargets (:2569-2630) sets the encoder AND        *)
(*     _capture.captureFPS (:2622): a downshift slows screen capture.      *)
(*   Every ack-gate hold counts as a pre-encode drop (:1404).              *)
(* Observed [O] run cfe6597: ack-gate holds p50 17/s; target fell to the   *)
(*   floor 30 fps / 5 Mbps within 2 s and stayed there for the whole run   *)
(*   (219 windows), although the link moved 36 Mb/s (p50) on big frames.  *)
(*   598 of 980 delivery gaps >= 50 ms were link holds on small frames     *)
(*   (scratch ft_cfe.txt): holds happen whatever the bitrate.              *)
(* Rejected design [O] run ddfd000: bitrate following half an ack-measured *)
(*   delivery rate (windowed max, iPad-clock spans).  After each link hold *)
(*   queued frames arrive at radio burst speed, so samples read 40-460     *)
(*   Mb/s on a ~36 Mb/s link; the bitrate sat at 20-30 Mbps, frames       *)
(*   averaged 50-117 KB, fps fell 40 -> 29, g2g p95 143 -> 243 ms.  No     *)
(*   capacity estimate is assumed here; the target is a fixed level T.     *)
(*                                                                         *)
(* Model: levels 0..N.  rate = bitrate level, cap = what the link carries, *)
(* T = the fixed target level, fps = "hi" (60) or "lo".  T is per link:     *)
(*   10 Mbps on infrastructure, 20 Mbps on AWDL (2026-11-16); a link change *)
(*   is a new connection and restarts the encoder, so T is constant here.  *)
(* One Window step = one 1 s evaluation.  `holds` = this window saw gate   *)
(* holds; the link can hold in any window (H1), and a rate above capacity  *)
(* always causes holds (H2).                                               *)
(*                                                                         *)
(* Design switches:                                                        *)
(*   IgnoreHolds: under the ack gate, gate holds are pacing, not           *)
(*                congestion.  The bitrate moves one step a window toward  *)
(*                the fixed target T; overload above capacity is absorbed  *)
(*                by the gate skipping captures, not by this loop.         *)
(*   KeepFps:     under the ack gate the frame rate stays at 60; the gate  *)
(*                skips captures the link cannot take.                     *)
(*                                                                         *)
(* Assumptions:                                                            *)
(*  H1 [O] Link holds occur in any window, independent of the bitrate.     *)
(*  H2 [I] A bitrate above capacity causes holds in that window.           *)
(*  H3 [I] Capacity changes at most MaxCapChanges times.                   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS N, T, MaxCapChanges, IgnoreHolds, KeepFps

Levels == 0..N

VARIABLES rate, fps, cap, holds, capChanges

vars == <<rate, fps, cap, holds, capChanges>>

Design == IgnoreHolds /\ KeepFps /\ TRUE

TypeOK ==
    /\ rate \in Levels /\ fps \in {"hi", "lo"}
    /\ cap \in Levels
    /\ holds \in BOOLEAN /\ capChanges \in 0..MaxCapChanges

Init ==
    /\ rate \in Levels /\ fps = "hi"
    /\ cap \in Levels
    /\ holds = FALSE /\ capChanges = 0

Toward(r, t) == IF r < t THEN r + 1 ELSE IF r > t THEN r - 1 ELSE r

\* One evaluation.  The window's holds are chosen by the link (H1, H2).
Window ==
    /\ holds' \in IF rate > cap THEN {TRUE} ELSE BOOLEAN
    /\ IF IgnoreHolds
         THEN rate' = Toward(rate, T)
         ELSE rate' = IF holds' THEN (IF rate > 0 THEN rate - 1 ELSE 0)
                                ELSE (IF rate < N THEN rate + 1 ELSE N)
    /\ fps' = IF KeepFps THEN "hi" ELSE IF holds' THEN "lo" ELSE "hi"
    /\ UNCHANGED <<cap, capChanges>>

CapChange ==
    /\ capChanges < MaxCapChanges
    /\ cap' \in Levels /\ capChanges' = capChanges + 1
    /\ UNCHANGED <<rate, fps, holds>>

Next == Window \/ CapChange

Spec == Init /\ [][Next]_vars

FairSpec == Spec /\ WF_vars(Window)

------------------------------------------------------------------------------
(* Properties *)

\* Capture and encoding keep 60 fps (the gate, not the frame rate, absorbs
\* holds).
FpsKept == fps = "hi"

\* The bitrate settles at its target: never latched at the floor by holds.
Settles == <>[](rate = T)

\* Witness: the bitrate sits at its target above the floor while the link holds.
NeverSettledThroughHolds == ~(rate = T /\ rate > 0 /\ holds)
=============================================================================
