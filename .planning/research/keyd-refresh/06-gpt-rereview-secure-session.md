**[I] Verdict: the revisions do not establish the owner’s end-to-end requirement.** [C] Read-only review completed; `git diff` provides no patch because the directory is untracked. [U] The reported TLC/TLAPS results were not independently reproduced.

1. **High — Revocation protection omits implemented control effects.**  
   [C] `Revoke` leaves sessions alive, and `Live(r)` guards `MacSend` and `Inject`. This represents blocking those two operations after an epoch change. However, an iPad `"control"` send creates no deliverable message: only `"input"` enters `inflight`. Consequently, no modeled action handles a revoked session’s viewport, resolution, mode-change or clock request. See [SecureSession.tla:152](./RemoteDesktop/tla/SecureSession.tla:152), [239](./RemoteDesktop/tla/SecureSession.tla:239), [270](./RemoteDesktop/tla/SecureSession.tla:270).

   [C] The code forwards received bytes without session identity to an unguarded dispatcher. Resolution handling changes the display and restarts capture; viewport handling can start capture; clock handling sends a response. See [SessionManager.m:665](./RemoteDesktop/macOS/App/SessionManager.m:665), [2376](./RemoteDesktop/macOS/App/SessionManager.m:2376), [2930](./RemoteDesktop/macOS/App/SessionManager.m:2930), [2650](./RemoteDesktop/macOS/App/SessionManager.m:2650), [2785](./RemoteDesktop/macOS/App/SessionManager.m:2785).

   **[I] Counterexample:** establish a session → `showPairingQR` deletes the pin → the surviving connection submits a resolution request → display/capture effects still execute. After `resetPairing`, USB receive callbacks also lack a current-connection check and process content before examining cancellation/error. Wireless has a connection-identity check, but that does not revoke a connection surviving `showPairingQR`. See [USBNetworkTransport.m:1091](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:1091), [WirelessTransport.m:988](./RemoteDesktop/macOS/Transport/WirelessTransport.m:988).

   **Fix:** model control delivery and its effects; carry connection identity and authentication epoch through callbacks; authorize every effect and send against current lifecycle state. Also split pin verification from connection readiness: the model currently combines verification and epoch assignment atomically, excluding verification-before-revoke/READY-after-revoke races. See [SecureSession.tla:178](./RemoteDesktop/tla/SecureSession.tla:178), [USBNetworkTransport.m:251](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:251), [1027](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:1027).

2. **High — “End to end” still overstates lifecycle coverage.**  
   [C] The status row claims pairing, switching, input and frames end to end, although pairing is substituted by switches, connections are freely created, and frames have no receive/decode lifecycle. The plan separately acknowledges missing pairing refinement and actual FSM composition. See [PLAN.md:54](./RemoteDesktop/tla/PLAN.md:54), [78](./RemoteDesktop/tla/PLAN.md:78).

   **[I] Counterexample:** after a Mac link drop, the specification can stutter forever without reconnecting or delivering anything; `Safe` remains true. `Spec` contains no fairness or progress requirement. See [SecureSession.tla:302](./RemoteDesktop/tla/SecureSession.tla:302).

   **Fix / highest-value next model:** compose both actual transport FSMs with their session-layer effects, separate endpoint notifications, addresses, connection generations, authentication completion and messages in flight. Include USB→Wi-Fi fallback, Wi-Fi→USB promotion, re-plug/address change and delayed callbacks. Prove authorization safety across that composition and check explicitly conditioned progress. The implementation’s fallback logic and differing effect execution must be included, rather than only transcribing the shared table: [Mac SessionManager.m:765](./RemoteDesktop/macOS/App/SessionManager.m:765), [797](./RemoteDesktop/macOS/App/SessionManager.m:797), [iPad SessionManager.swift:586](./RemoteDesktop/iPadOS/App/SessionManager.swift:586).

3. **Medium — Switching witnesses require a down action, but not a subsequent reconnect.**  
   [C] `deadUsed` remembers historical link use; `MacLinkDown` need not remove any session; `Inject` records switches against every historical entry. See [SecureSession.tla:223](./RemoteDesktop/tla/SecureSession.tla:223), [275](./RemoteDesktop/tla/SecureSession.tla:275).

   **[I] Counterexample:** connect USB and Wi-Fi → inject over USB → drop USB at Mac → inject over the already-open Wi-Fi session. `NeverWiredToWifi` fails without reconnecting. Alternatively, close USB first; a subsequent no-op `MacLinkDown("usb")` still records the “drop.”

   [C] Wired→wired is expressible as a down action followed by a new connection ID, but there are no cable-up, interface-generation or address-change states.

   **Fix:** record the specific used session actually removed by the drop, and require destination connection creation afterward for reconnect witnesses. Add explicit interface generations for re-plug/address-change coverage.

4. **Medium — Proof controls can pass despite unrelated errors.**  
   [C] The parser recognizes only diagnostics naming exactly the requested proof file, discards failure summaries, and compares a deduplicated label set. The Makefile rejects timeout status but otherwise accepts matching labels plus an `"obligations failed"` substring. See [proof-steps.py:16](./RemoteDesktop/tla/proof-steps.py:16), [46](./RemoteDesktop/tla/proof-steps.py:46), [Makefile:148](./RemoteDesktop/tla/Makefile:148).

   **[C] Concrete reproduction:** synthetic failures at proof lines 61 and 67, plus a backend error attributed to `SecureSession.tla`, produce exactly `<1>12 <1>15.<2>1`—the accepted EpochGuard result. Thus [METHOD.md:110](./RemoteDesktop/tla/METHOD.md:110)’s “any backend error” rejection claim is false.

   **Fix:** reject unrecognized/global/imported-file errors, validate completion and failure counts, and check documented process exit statuses.

5. **Medium — Application-message scope is explicit, but coverage remains incomplete.**  
   [C] A6 explicitly excludes protocol metadata. However, pairing exchanges never update encryption/authentication accounting, and `PlainSend` does not set `unauthSent`. Therefore, `PlainSend("usb")` can leave `AllMutuallyPinned` true while sending plaintext. See [SecureSession.tla:44](./RemoteDesktop/tla/SecureSession.tla:44), [132](./RemoteDesktop/tla/SecureSession.tla:132), [283](./RemoteDesktop/tla/SecureSession.tla:283).

   **Fix:** account for every application send, including bootstrap pairing and tests; specify bootstrap authentication separately from established-session mutual pinning. Describe the current theorem as conditional safety of the enumerated abstract actions.

[C] `IInv` contains the strengthening needed for the modeled revocation: epochs never exceed `macEpoch`, and current-epoch sessions imply `macPin = I`. [I] Its induction and `ASSUME Design PROVE Spec => []Safe` structure follow for the present actions; I found no static logical defect. Design is not wholly vacuous: pair both endpoints → connect → send input → inject is enabled at the configured bounds. Zero connection bounds permit no communication, and witnesses establish existence rather than progress. See [SecureSessionProofs.tla:17](./RemoteDesktop/tla/SecureSessionProofs.tla:17), [35](./RemoteDesktop/tla/SecureSessionProofs.tla:35), [75](./RemoteDesktop/tla/SecureSessionProofs.tla:75), [SecureSession.cfg:8](./RemoteDesktop/tla/SecureSession.cfg:8).