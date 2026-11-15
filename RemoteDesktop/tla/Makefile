# RemoteDesktop TLA+ models. Method and the reasons for every flag: METHOD.md (adopted from
# d1preservation/tla, whose spec/09-tools/09.14-tla-project.md records why each one exists).

# /usr/bin/java is a stub that cannot find a runtime inside the agent sandbox: name a JDK.
JAVA ?= /Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java
TLA2TOOLS ?= $(HOME)/.local/share/tlaplus/1.7.4/tla2tools.jar
TLAPM ?= $(HOME)/.local/share/tlaps/1.6.0-pre-5f5037f/tlapm/bin/tlapm
JTMP ?= $(or $(TMPDIR),/tmp)
METADIR ?= $(JTMP)/keyd-tlc-meta

# Every run goes through bounded.sh (own process group, killed whole on exit, interrupt or limit).
BOUNDED ?= $(CURDIR)/bounded.sh
TLC_SECONDS ?= 900
PROOF_SECONDS ?= 600
# Load must stay at 50-75% of the machine (owner): 2 workers, 2 GC threads, nice.
WORKERS ?= 2
JVM_XMX ?= 2g
TLC_RUN ?= $(BOUNDED) $(TLC_SECONDS) nice -n 10 $(JAVA) -XX:+UseParallelGC -XX:ParallelGCThreads=2 \
	-Xmx$(JVM_XMX) -Djava.io.tmpdir="$(JTMP)" -cp "$(TLA2TOOLS)" tlc2.TLC \
	-workers $(WORKERS) -metadir "$(METADIR)"
# SMT and Zenon only: never Isabelle (its poly outlived tlapm and took 16 GB of swap in d1).
TLAPM_FLAGS ?= --method smt,zenon --threads 2 --stretch 3
PSDIR ?= $(JTMP)/keyd-tlapm-path
CTLDIR ?= $(JTMP)/keyd-tlaps-ctl

.PHONY: verify check-tools syntax pairing pairing-proofs secure secure-proofs transport transport-proofs delta stripe

verify: pairing pairing-proofs secure secure-proofs transport transport-proofs delta stripe

check-tools:
	@test -x "$(JAVA)" || { echo 'Missing JDK at $(JAVA); set JAVA.' >&2; exit 1; }
	@test -r "$(TLA2TOOLS)" || { echo 'Missing tla2tools.jar at $(TLA2TOOLS); set TLA2TOOLS.' >&2; exit 1; }

syntax: check-tools
	$(JAVA) -Djava.io.tmpdir="$(JTMP)" -cp "$(TLA2TOOLS)" tla2sany.SANY $(SPEC).tla

# One TLC run per row (module:cfg:expected); expected is pass, Deadlock, a property name, or
# Temporal (TLC 1.7.4 does not name a violated temporal property; such a cfg checks only one).
# printf, never echo: macOS sh treats the \c in \cup as "stop output".
define tlc_rows
	@fail=0; for row in $(1); do mod=$${row%%:*}; rest=$${row#*:}; cfg=$${rest%%:*}; want=$${rest##*:}; \
	  out=$$($(TLC_RUN) -config $$cfg $$mod.tla 2>&1); st=$$?; \
	  if [ $$st = 124 ]; then got=timeout; \
	  elif printf '%s\n' "$$out" | grep -q "No error has been found"; then got=pass; \
	  elif printf '%s\n' "$$out" | grep -q "^Error: Deadlock reached"; then got=Deadlock; \
	  else got=$$(printf '%s\n' "$$out" | sed -n -e 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/\1/p' -e 's/^Error: Temporal property \([A-Za-z0-9_]*\) was violated.*/\1/p' \
	    -e 's/^Error: Temporal properties were violated.*/Temporal/p' | head -1); fi; \
	  states=$$(printf '%s\n' "$$out" | grep -o "[0-9,]* distinct states found" | tail -1); \
	  if [ "$$got" = "$$want" ]; then echo "OK   $$mod $$cfg: $$got ($$states)"; \
	  else echo "FAIL $$mod $$cfg: wanted $$want, got $${got:-error}"; printf '%s\n' "$$out" | tail -15; fail=1; fi; \
	done; [ $$fail = 0 ] || exit 2
endef

# Pairing (B1). Owner decision 2026-10-29: pair over USB only. The design passes; the as-built
# config shows the attack; USB alone and the Mac confirmation alone each suffice; a Wi-Fi QR with
# a token holds only while nobody else sees the QR; each control reports exactly its property;
# the witness shows the owner can pair at all.
PAIRING_ROWS = Pairing:Pairing.cfg:pass \
	Pairing:cfg/PR-asbuilt.cfg:OnlyOwnerPaired \
	Pairing:cfg/PR-witness.cfg:NeverPaired \
	Pairing:cfg/PR-usb-only.cfg:pass \
	Pairing:cfg/PR-confirm-only.cfg:pass \
	Pairing:cfg/PR-wifi-token-no-leak.cfg:pass \
	Pairing:cfg/PR-ctl-wifi-token-leak.cfg:OnlyOwnerPaired \
	Pairing:cfg/PR-ctl-no-close.cfg:ListenerOnlyWhileWindow \
	Pairing:cfg/PR-ctl-server-keygen.cfg:NoPrivateKeyOnWire \
	Pairing:cfg/PR-ctl-replace.cfg:OwnerNotDisplaced

pairing: check-tools
	$(call tlc_rows,$(PAIRING_ROWS))

# TLAPS: PairingProofs must prove every obligation; its control (USBPairing and ConfirmOnMac dropped from
# Design) must leave at least one unproved.  tlapm runs ps at start and the sandbox forbids
# process listing, so a header-only ps goes first on PATH when ps fails.
pairing-proofs:
	@test -x "$(TLAPM)" || { echo 'Missing tlapm at $(TLAPM); set TLAPM.' >&2; exit 1; }
	@path="$$PATH"; if ! ps -p $$$$ >/dev/null 2>&1; then mkdir -p "$(PSDIR)" && \
	  printf '#!/bin/sh\necho "  PID  PPID   PID"\n' > "$(PSDIR)/ps" && chmod +x "$(PSDIR)/ps" && path="$(PSDIR):$$PATH"; fi; \
	  out=$$(PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) PairingProofs.tla 2>&1); \
	  [ $$? != 124 ] || { echo "FAIL PairingProofs: killed after $(PROOF_SECONDS)s"; exit 2; }; \
	  if printf '%s\n' "$$out" | grep -q "All [0-9]* obligations proved"; then echo "OK   PairingProofs: $$(printf '%s\n' "$$out" | grep -o "All [0-9]* obligations proved")"; \
	  else printf '%s\n' "$$out" | grep -B2 -A8 "ERROR\|failed" | head -40; echo "FAIL PairingProofs: not every obligation proved"; exit 2; fi; \
	  dir="$(CTLDIR)/pairing"; rm -rf "$$dir" && mkdir -p "$$dir" && cp Pairing.tla "$$dir/" && \
	  sed 's/^Design == USBPairing \/\\ CloseWithWindow \/\\ ClientKeygen \/\\ SingleAttempt \/\\ ConfirmOnMac$$/Design == CloseWithWindow \/\\ ClientKeygen \/\\ SingleAttempt/' Pairing.tla > "$$dir/Pairing.tla" && \
	  cp PairingProofs.tla "$$dir/" && \
	  ! cmp -s Pairing.tla "$$dir/Pairing.tla" || { echo "FAIL control: could not drop USBPairing and ConfirmOnMac"; exit 2; }; \
	  out=$$(cd "$$dir" && PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) PairingProofs.tla 2>&1); \
	  [ $$? != 124 ] || { echo "FAIL control (no USBPairing, no ConfirmOnMac): killed after $(PROOF_SECONDS)s"; exit 2; }; \
	  printf '%s\n' "$$out" | grep -q "obligations failed" || { echo "FAIL control (no USBPairing, no ConfirmOnMac): the proof still goes through"; exit 2; }; \
	  got=$$(printf '%s\n' "$$out" | python3 proof-steps.py PairingProofs.tla); \
	  [ "$$got" = 'SpecSafe.<1>2.<2>8' ] || { echo "FAIL control (no USBPairing, no ConfirmOnMac): fails at '$$got', expected 'SpecSafe.<1>2.<2>8' (Accept)"; exit 2; }; \
	  echo "OK   control (no USBPairing, no ConfirmOnMac): fails at $$got (Accept)"

# SecureSession (B1-B5 end to end, with the attacker on wireless links). The design passes every
# property; the as-built rows show the pairing, plaintext and leak paths; witnesses show owner
# input reaches the Mac, over two links; each control drops one mechanism and reports its property.
SECURE_ROWS = SecureSession:SecureSession.cfg:pass \
	SecureSession:cfg/SE-asbuilt-inject.cfg:InjectFromOwner \
	SecureSession:cfg/SE-asbuilt-plaintext.cfg:NoPlaintext \
	SecureSession:cfg/SE-asbuilt-leak.cfg:NoLeak \
	SecureSession:cfg/SE-witness-inject.cfg:NeverInjected \
	SecureSession:cfg/SE-asbuilt-revoke.cfg:SendOnlyToTrusted \
	SecureSession:cfg/SE-witness-wired-to-wifi.cfg:NeverWiredToWifi \
	SecureSession:cfg/SE-witness-wifi-to-wired.cfg:NeverWifiToWired \
	SecureSession:cfg/SE-witness-wifi-to-awdl.cfg:NeverWifiToAwdl \
	SecureSession:cfg/SE-witness-awdl-to-wifi.cfg:NeverAwdlToWifi \
	SecureSession:cfg/SE-witness-wired-to-wired.cfg:NeverWiredToWired \
	SecureSession:cfg/SE-usb-only-pairing.cfg:pass \
	SecureSession:cfg/SE-ctl-wifi-pairing.cfg:PairingOnlyOverUSB \
	SecureSession:cfg/SE-ctl-wifi-insecure-pairing.cfg:InjectFromOwner \
	SecureSession:cfg/SE-ctl-no-mac-pin.cfg:AllMutuallyPinned \
	SecureSession:cfg/SE-ctl-no-mac-pin-inject.cfg:InjectAuthorized \
	SecureSession:cfg/SE-ctl-no-client-pin.cfg:AllMutuallyPinned \
	SecureSession:cfg/SE-ctl-no-client-pin-leak.cfg:NoLeak \
	SecureSession:cfg/SE-ctl-no-epoch-guard.cfg:SendOnlyToTrusted \
	SecureSession:cfg/SE-ctl-no-epoch-guard-inject.cfg:InjectAuthorized \
	SecureSession:cfg/SE-ctl-test-bypass.cfg:NoLeak \
	SecureSession:cfg/SE-ctl-test-plaintext.cfg:NoPlaintext

secure: check-tools
	$(call tlc_rows,$(SECURE_ROWS))

# TLAPS end to end: SecureSessionProofs must prove every obligation, and each control (one
# mechanism removed from Design) must fail at exactly the proof steps of that mechanism, as
# reported by proof-steps.py, so a control cannot pass by breaking somewhere unrelated.
# PairingSecure and USBPairing are dropped together: either alone keeps the attacker from pairing
# (TLC row SE-usb-only-pairing). Each control also has a TLC row showing the attack (SE-ctl-*).
SECURE_PROOF_CONTROLS = PinnedMTLS ClientPinsMac EpochGuard NoTestBypass NoTestPlaintext PairingGuarantees
secure_ctl_steps = case $(1) in \
	  (PinnedMTLS) printf '%s' 'NextIInv.<1>5 NextIInv.<1>6';; \
	  (ClientPinsMac) printf '%s' 'NextIInv.<1>5 NextIInv.<1>7';; \
	  (EpochGuard) printf '%s' 'NextIInv.<1>12 NextIInv.<1>15.<2>1';; \
	  (NoTestBypass) printf '%s' 'NextIInv.<1>2';; \
	  (NoTestPlaintext) printf '%s' 'NextIInv.<1>9';; \
	  (PairingGuarantees) printf '%s' 'NextIInv.<1>1.<2>1';; esac

secure-proofs:
	@test -x "$(TLAPM)" || { echo 'Missing tlapm at $(TLAPM); set TLAPM.' >&2; exit 1; }
	@path="$$PATH"; if ! ps -p $$$$ >/dev/null 2>&1; then mkdir -p "$(PSDIR)" && \
	  printf '#!/bin/sh\necho "  PID  PPID   PID"\n' > "$(PSDIR)/ps" && chmod +x "$(PSDIR)/ps" && path="$(PSDIR):$$PATH"; fi; \
	  out=$$(PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) SecureSessionProofs.tla 2>&1); \
	  [ $$? != 124 ] || { echo "FAIL SecureSessionProofs: killed after $(PROOF_SECONDS)s"; exit 2; }; \
	  if printf '%s\n' "$$out" | grep -q "All [0-9]* obligations proved"; then echo "OK   SecureSessionProofs: $$(printf '%s\n' "$$out" | grep -o "All [0-9]* obligations proved")"; \
	  else printf '%s\n' "$$out" | grep -B2 -A8 "ERROR\|failed" | head -40; echo "FAIL SecureSessionProofs: not every obligation proved"; exit 2; fi; \
	  fail=0; for name in $(SECURE_PROOF_CONTROLS); do \
	    if [ "$$name" = PairingGuarantees ]; then expr='s/PairingSecure \/\\ USBPairing \/\\ //'; else expr="s/ \/\\\\ $$name//"; fi; \
	    dir="$(CTLDIR)/secure-$$name"; rm -rf "$$dir" && mkdir -p "$$dir" && cp SecureSessionProofs.tla "$$dir/" && \
	    sed "/^Design ==/$$expr" SecureSession.tla > "$$dir/SecureSession.tla"; \
	    if cmp -s SecureSession.tla "$$dir/SecureSession.tla"; then echo "FAIL control no-$$name: Design unchanged"; fail=1; continue; fi; \
	    out=$$(cd "$$dir" && PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) SecureSessionProofs.tla 2>&1); st=$$?; \
	    if [ $$st = 124 ]; then echo "FAIL control no-$$name: killed after $(PROOF_SECONDS)s"; fail=1; \
	    elif ! printf '%s\n' "$$out" | grep -q "obligations failed"; then echo "FAIL control no-$$name: the proof still goes through"; fail=1; \
	    else got=$$(printf '%s\n' "$$out" | python3 proof-steps.py SecureSessionProofs.tla); want=$$($(call secure_ctl_steps,$$name)); \
	      if [ "$$got" = "$$want" ]; then echo "OK   control no-$$name: fails at $$got"; \
	      else echo "FAIL control no-$$name: fails at '$$got', expected '$$want'"; fail=1; fi; fi; \
	  done; [ $$fail = 0 ] || exit 2

# TransportAgreement (B3, H3, C3): switching between USB, Wi-Fi and AWDL on both sides at once.
# The design passes every property and always comes to rest; each as-built row is one switching
# bug found in the code; the witnesses settle in good order across every kind of switch (wired to
# wireless, wireless to wired, Wi-Fi to AWDL and back, re-plug, re-plug to a new address); each
# control drops one mechanism and reports its property.
TRANSPORT_ROWS = TransportAgreement:TransportAgreement.cfg:pass \
	TransportAgreement:cfg/TA-asbuilt-no-addr.cfg:RestStreams \
	TransportAgreement:cfg/TA-asbuilt-addr-change.cfg:RestStreams \
	TransportAgreement:cfg/TA-asbuilt-replug.cfg:RestUsesUsb \
	TransportAgreement:cfg/TA-asbuilt-codec.cfg:RestCodec \
	TransportAgreement:cfg/TA-asbuilt-labels.cfg:RestLabels \
	TransportAgreement:cfg/TA-asbuilt-idle.cfg:RestIdleAlone \
	TransportAgreement:cfg/TA-asbuilt-settles.cfg:pass \
	TransportAgreement:cfg/TA-witness-wired-to-wifi.cfg:NeverWiredToWifi \
	TransportAgreement:cfg/TA-witness-wifi-to-wired.cfg:NeverWifiToWired \
	TransportAgreement:cfg/TA-witness-wifi-to-awdl.cfg:NeverWifiToAwdl \
	TransportAgreement:cfg/TA-witness-awdl-to-wifi.cfg:NeverAwdlToWifi \
	TransportAgreement:cfg/TA-witness-wired-to-wired.cfg:NeverWiredToWired \
	TransportAgreement:cfg/TA-witness-replug-new-addr.cfg:NeverReplugNewAddr \
	TransportAgreement:cfg/TA-ctl-no-resync.cfg:CodecMatches \
	TransportAgreement:cfg/TA-ctl-no-resync-rest.cfg:RestCodec \
	TransportAgreement:cfg/TA-ctl-no-addr.cfg:RestStreams \
	TransportAgreement:cfg/TA-ctl-no-derived.cfg:LabelsMatch \
	TransportAgreement:cfg/TA-ctl-no-derived-stream.cfg:StreamOnlyWithRoute \
	TransportAgreement:cfg/TA-ctl-no-derived-rest.cfg:RestLabels \
	TransportAgreement:cfg/TA-ctl-no-ipad-resync.cfg:RestStreams \
	TransportAgreement:cfg/TA-ctl-no-fairness.cfg:Temporal

transport: check-tools
	$(call tlc_rows,$(TRANSPORT_ROWS))

# DeltaSync (H4 x C5, 2026-11-15): lossless XOR-delta frames over USB TCP. The design gates
# before compression and never drops a compressed frame. As built (drop after compression)
# corrupts the picture, with or without periodic keyframes, and breaks the chain of bases.
# Without the gate and without the drop the queue is unbounded. The gate alone suffices.
DELTA_ROWS = DeltaSync:DeltaSync.cfg:pass \
	DeltaSync:cfg/DS-asbuilt.cfg:NoCorruption \
	DeltaSync:cfg/DS-asbuilt-keyframes.cfg:NoCorruption \
	DeltaSync:cfg/DS-asbuilt-chain.cfg:QueueIsChain \
	DeltaSync:cfg/DS-ctl-no-gate.cfg:QueueBounded \
	DeltaSync:cfg/DS-gate-and-drop.cfg:pass \
	DeltaSync:cfg/DS-witness.cfg:NeverDelivered

delta: check-tools
	$(call tlc_rows,$(DELTA_ROWS))

# StripeSync (H4 x C5, 2026-11-15): striped parallel LZ4. Each end joins its stripe workers
# before the frame leaves it (Mac: before flipping the reference and emitting; iPad: before
# the renderer copies). As built is one stripe. Dropping either join corrupts or tears.
STRIPE_ROWS = StripeSync:StripeSync.cfg:pass \
	StripeSync:cfg/SS-asbuilt.cfg:pass \
	StripeSync:cfg/SS-ctl-no-mac-join.cfg:NoCorruption \
	StripeSync:cfg/SS-ctl-no-mac-join-ref.cfg:MacRefUniform \
	StripeSync:cfg/SS-ctl-no-ipad-join.cfg:NoTornPublish \
	StripeSync:cfg/SS-witness.cfg:NeverPublished

stripe: check-tools
	$(call tlc_rows,$(STRIPE_ROWS))

# TLAPS: the step-by-step properties (LabelsMatch, StreamOnlyWithRoute, CodecMatches) for any
# bounds. Each control replaces one switch in Design by TRUE and must fail at exactly that
# switch's steps. AddrOnLink and IpadResync have no proof control: what they buy is progress,
# checked by TLC (TA-ctl-no-addr, TA-ctl-no-ipad-resync).
TRANSPORT_PROOF_CONTROLS = RouteResync DerivedState
transport_ctl_steps = case $(1) in \
	  (RouteResync) printf '%s' 'MacCommitOK.<1>5';; \
	  (DerivedState) printf '%s' 'IpadSetOK.<1>3 MacCommitOK.<1>3 MacCommitOK.<1>4';; esac

transport-proofs:
	@test -x "$(TLAPM)" || { echo 'Missing tlapm at $(TLAPM); set TLAPM.' >&2; exit 1; }
	@path="$$PATH"; if ! ps -p $$$$ >/dev/null 2>&1; then mkdir -p "$(PSDIR)" && \
	  printf '#!/bin/sh\necho "  PID  PPID   PID"\n' > "$(PSDIR)/ps" && chmod +x "$(PSDIR)/ps" && path="$(PSDIR):$$PATH"; fi; \
	  out=$$(PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) TransportAgreementProofs.tla 2>&1); \
	  [ $$? != 124 ] || { echo "FAIL TransportAgreementProofs: killed after $(PROOF_SECONDS)s"; exit 2; }; \
	  if printf '%s\n' "$$out" | grep -q "All [0-9]* obligations proved"; then echo "OK   TransportAgreementProofs: $$(printf '%s\n' "$$out" | grep -o "All [0-9]* obligations proved")"; \
	  else printf '%s\n' "$$out" | grep -B2 -A8 "ERROR\|failed" | head -40; echo "FAIL TransportAgreementProofs: not every obligation proved"; exit 2; fi; \
	  fail=0; for name in $(TRANSPORT_PROOF_CONTROLS); do \
	    dir="$(CTLDIR)/transport-$$name"; rm -rf "$$dir" && mkdir -p "$$dir" && cp TransportAgreementProofs.tla "$$dir/" && \
	    sed "/^Design ==/s/$$name/TRUE/" TransportAgreement.tla > "$$dir/TransportAgreement.tla"; \
	    if cmp -s TransportAgreement.tla "$$dir/TransportAgreement.tla"; then echo "FAIL control no-$$name: Design unchanged"; fail=1; continue; fi; \
	    out=$$(cd "$$dir" && PATH="$$path" $(BOUNDED) $(PROOF_SECONDS) "$(TLAPM)" $(TLAPM_FLAGS) TransportAgreementProofs.tla 2>&1); st=$$?; \
	    if [ $$st = 124 ]; then echo "FAIL control no-$$name: killed after $(PROOF_SECONDS)s"; fail=1; \
	    elif ! printf '%s\n' "$$out" | grep -q "obligations failed"; then echo "FAIL control no-$$name: the proof still goes through"; fail=1; \
	    else got=$$(printf '%s\n' "$$out" | python3 proof-steps.py TransportAgreementProofs.tla); want=$$($(call transport_ctl_steps,$$name)); \
	      if [ "$$got" = "$$want" ]; then echo "OK   control no-$$name: fails at $$got"; \
	      else echo "FAIL control no-$$name: fails at '$$got', expected '$$want'"; fail=1; fi; fi; \
	  done; [ $$fail = 0 ] || exit 2
