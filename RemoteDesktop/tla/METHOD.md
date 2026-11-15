# TLA+ method for keyd / RemoteDesktop

Adopted on 2026-10-29 from d1preservation, the owner's most mature TLA+ project. Its sources are
`~/Documents/projects/d1preservation/tla/` (Makefile, `bounded.sh`, 54 modules and configs) and
`spec/09-tools/09.14-tla-project.md` (the history behind every rule below). Read that history
before you change a rule here. Each rule exists because something went wrong without it.

## The gate

**Does the work touch a loop, a lifecycle, concurrency, synchronization or a protocol across the
iPad↔Mac boundary? Then model it first.** The steps:

1. **As built.** Model the code that exists today, not the code you intend to write. The module
   header carries pseudo code of what it models plus source locators (`file:line`).
2. **Assumptions.** State them in the header as A1, A2, ..., each with an evidence tag. They are
   inputs, not results.
3. **Properties, each with a control.** Every invariant or temporal property needs a positive
   control: a config that breaks one mechanism and must report *exactly that property* violated.
   A property that no control can break proves nothing.
4. **TLC, then TLAPS, then code.** TLC checks bounded instances. TLAPS proves the safety
   invariants for every instance that satisfies the assumptions.

## Security lifecycles: TLAPS is required (owner, 2026-10-29)

Any lifecycle that authenticates devices or carries their traffic must be **proved with TLAPS end to
end**: pairing, connection authentication on every link, transport switching, revocation, input and
frames. A TLC pass on a bounded instance is not enough for these. TLC still runs first, for the
controls and for the counterexamples. "End to end" means the composed model of iPad, Mac and an
attacker on the network, not each piece alone. A piece proved alone (such as `PairingProofs`) is
used as an assumption of the composition, and the composition says which proved piece justifies
which assumption.

The limit, stated plainly: a TLAPS proof covers the model. The code is linked to the model by
conformance checks and trace validation (below), not by the proof.

**The cryptographic contract.** Cryptography is symbolic. Each security module states, as tagged
assumptions in its header, every one of the following that it relies on, and names the code or
evidence that is supposed to make it true:

- **Authentication:** a handshake completes only if each end's certificate matches the pin it holds.
- **Confidentiality and integrity:** a record on a session is readable and forgeable only by its
  two ends.
- **Binding:** records are bound to their session, so a replay into another session fails.
- **Key possession:** only the device that generated a private key holds it. A key that crosses the
  wire is a finding, not an assumption.
- **Resumption and 0-RTT:** say whether TLS session resumption or 0-RTT is possible. If it is,
  say whether a resumed session re-checks the current pin.
- **Compromise:** say what is out of scope (a stolen unlocked iPad, malware on the Mac, a hostile
  USB accessory).
- **Scope of "message":** say which bytes are cleartext by protocol (TLS hellos, mDNS, TCP/IP
  headers) and that the claim excludes them. Never let a property's name claim more than its scope
  (GPT 6.1 sol review, 2026-10-29).

## Evidence tags

Put a tag on every claim, in specs, headers and docs.

- `[C]` confirmed by a run or a read of the source
- `[O]` observed in logs or on a device
- `[R]` reported by a source you read but did not check
- `[I]` inferred
- `[U]` unknown

Never let an unknown transition silently become a no-op or drop out of `Next`. Model it
nondeterministically within stated bounds, or expose it as an environment action and limit the
claim to that boundary.

## Design switches and controls

- **Every mechanism is a `CONSTANT` boolean** (for example `TokenInQR`, `CloseWithQR`). `Design`
  is their conjunction.
- **The design config** sets every switch on and must pass.
- **Each control config** turns one switch off and must report its invariant violated. Name control
  configs `cfg/<PREFIX>-ctl-<what>.cfg`.
- **Redundant defences** (two mechanisms that each block the same attack, such as USB-only pairing
  and confirmation on the Mac) cannot each have a one-switch control. Drop them together in one
  control, give a TLC row showing that either alone suffices, and say so next to the control.
- **The as-built config** sets the switches to what the code does today. Its expected result is the
  bug, stated as the violated invariant.
- **Makefile rows** have the form `module:config:expected`, where expected is `pass`, `Deadlock`,
  `ActionProperty` or an invariant name. A target exits 2 on any mismatch. Check that target itself
  once by giving it a wrong expectation: it must exit 2.

## Layers (the d1 rule)

| layer | here | sees | does not see |
|---|---|---|---|
| 1 deployment | USB NCM link, Wi-Fi, AWDL, interfaces, listeners | links, binds, who can reach what | the protocol |
| 2 communication contract | `Channels.tla` | endpoints, delivery, the adversary | how a link is built |
| 3 protocols and lifecycles | pairing, session, transport FSMs, input | `Channels` only | hardware |

- **X lives in layer Y only if Y, or a layer resting on Y, depends on X.**
- **The contract is the weakest network we deploy on: public Wi-Fi.** Messages may be lost,
  duplicated or reordered. An `Outside` party may connect to any listener on Wi-Fi or AWDL and inject
  any message under any claimed sender. Only the USB cable is physical.
- **Weakness controls** check that the contract stays that weak. Example: `NoForgery` *must be
  violated* on the raw contract. If such a control stops firing, the contract has become stronger
  than the real network.
- A deployment module refines the contract. Check this with a `*Refines.tla` module, plus a control
  that breaks the mapping.

## TLAPS

- **The theorem shape:** `THEOREM ASSUME Design PROVE Spec => []Inv`. Never conjoin `Design` to
  `Spec`: PTL treats a conjoined constant as a state formula and fails.
- Write one lemma per action (`<Action>KeepsInv`), and cite `Distinct`-style assumptions explicitly.
- **Proof control:** a copy of the proof with one mechanism removed from `Design` must fail **at
  exactly the proof steps of that mechanism**. The Makefile builds the copy with `sed`, checks that
  the text changed, and compares the failing steps that `proof-steps.py` reports (for example
  `NextIInv.<1>12 NextIInv.<1>15.<2>1`, each prefixed by its lemma; a failure in an unnumbered step
  is labelled by its keyword, e.g. `MacCommitOK.<1>QED`, never by the numbered step above it) with
  the expected list. Route each mechanism through its own lemma step (e.g. one commit lemma that
  every action ends in, one step per property) so its control has one place to fail. Any backend error, any failure elsewhere, or a proof
  that still goes through exits 2. An unproved obligation is not evidence of an attack, so every
  proof control also has a TLC row that shows the attack as a counterexample trace.
- **Flags:** `--method smt,zenon --threads 2 --stretch 3`, which means **never Isabelle**. An
  Isabelle `poly` process outlived tlapm and held 16 GB of swap (d1, 2026-10-23).
- tlapm 1.6.0-pre rejects `RECURSIVE` operators. Use recursive functions, binding the previous round
  once with `LET`.
- **Liveness stays in TLC.** In d1, `WF`/`SF` over 21 items ran a 4 GB heap out of memory. Prefer
  bounded formulations: bound the environment's moves, state the goal as an invariant at `Quiet`,
  **and** check with TLC, under explicit weak fairness on the system's own actions, that every
  behaviour reaches `Quiet` (`<>Quiet`). An invariant at `Quiet` alone proves nothing, since
  stuttering may never reach `Quiet`. Progress cannot be promised while the attacker may drop
  traffic forever; say which environment actions the fairness excludes.

## Running the tools safely

The owner's limit is that **load stays at 50-75% of the machine, or the run gets killed.**

- **Every TLC and tlapm run goes through `bounded.sh SECONDS CMD`.** It runs the command in its own
  process group and kills the whole group on exit, interrupt, timeout (exit 124), or if the parent
  dies. In d1, z3 and TLC processes outlived their sessions and filled RAM.
- **TLC flags:** `nice -n 10`, `-workers 2`, `-XX:ParallelGCThreads=2 -Xmx2g`,
  `-Djava.io.tmpdir=$TMPDIR`, `-metadir $TMPDIR/tlc-meta`, `-noGenerateSpecTE`.
- **`JAVA` must name a JDK** (`/Library/Java/JavaVirtualMachines/temurin-21.jdk/...`). Inside the
  sandbox, `/usr/bin/java` is a stub that cannot find a runtime.
- **tlapm runs `ps` at start, and the sandbox forbids process listing.** The Makefile therefore puts
  a header-only `ps` shim first on `PATH` when `ps` fails.
- **Parse tool output with `printf '%s\n' "$out"`, never `echo`.** macOS `sh` treats the `\c` in
  `\cup` as "stop output", which once hid tlapm's verdict.
- Run long checks in the background, never as a blocking call.
- **Tiny instances are starting bounds, not claims about every size.** If a config does not finish,
  add symmetry or a bound before citing it.

## Bridging model and code

- **Pure transition tables** (`TransportFSM.c`, `TransportFSM.swift`) are transcribed exactly. A
  conformance check enumerates every state × event in both languages and compares the result to the
  TLA+ table. Any difference fails the check.
- **Trace validation:** the `[CONSOLE]` and `os_log` lines on each side record transitions. A recorded
  run is replayed against the spec. This needs an exact event stream, so add the log lines first.
- **The limits of both.** A table check cannot see asynchronous callbacks, persistence, TLS
  configuration or cancellation. A replayed trace shows that one run fits the spec, not that every
  run does. So a model must give every asynchronous step its own action: a callback queued before
  a state change can run after it (stale callbacks, non-atomic revocation). Each code path that can
  fire late must then check a guard that the model names, such as an epoch or generation number.

## Not taken from d1 (yet)

- **`d1 job run` leases** (a machine-wide job budget, tied to d1's Go tool). `bounded.sh`, `nice` and
  the worker cap cover the same risk here.
- **`d1 tla views`** (DOT/SVG state graphs and control traces). It is worth porting later, as a small
  script using TLC's `-dump dot` and `-dumpTrace json`.
- **d1's evidence-ledger census of game binaries.** That is domain-specific.
