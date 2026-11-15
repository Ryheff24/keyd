[I] The model is not faithful enough to validate daily switching. I found no logical counterexample to `SwitchingSafe` as written, but its three safety predicates cover substantially less than the implementation’s switching contract.

Read-only review completed; no files changed and neither TLC nor `tlapm` was run. [U] The reported state counts and obligation results remain unverified.

1. **High — [C] Independent control/media failures are omitted, making recovery too generous.**  
   The model has one connection per channel and kills it only when its physical link drops ([TransportAgreement.tla:237](./RemoteDesktop/tla/TransportAgreement.tla:237), [:488](./RemoteDesktop/tla/TransportAgreement.tla:488)). Real wireless TCP can fail while DTLS remains present: both transports retain `isConnected`, suppress the disconnect event, and attempt control replacement ([Mac wireless:716](./RemoteDesktop/macOS/Transport/WirelessTransport.m:716), [iPad wireless:507](./RemoteDesktop/iPadOS/Transport/WirelessTransport.swift:507)). Conversely, media loss can preserve the TCP session.

   **Counterexample [I]:** stream wirelessly → wireless TCP fails while media remains → USB becomes ready, then disconnects → fallback sees wireless `isConnected == true`, but control sends find no TCP connection. The model cannot represent this state and its lost handshake/viewport traffic.

   `MacFrame` also turns the iPad streaming merely from transport availability ([model:291](./RemoteDesktop/tla/TransportAgreement.tla:291)); real capture can be deferred pending viewport/media readiness, and LZ4 reception rejects frames without a decompressor ([Mac session:936](./RemoteDesktop/macOS/App/SessionManager.m:936), [iPad session:755](./RemoteDesktop/iPadOS/App/SessionManager.swift:755)).

   **Smallest fix:** transcribe independent control/media readiness and failure, including replacement and capture prerequisites; restrict the convergence claim until then.

2. **High — [C] USB loss, polling, and callback identity are mistranscribed.**  
   `IpadUsbLost` always clears `ipad.sees["usb"]` ([model:375](./RemoteDesktop/tla/TransportAgreement.tla:375)). Actual IP-based TCP failure clears `inputConnection` but clears `isConnected` only if `mediaConnection == nil`; cancellation merely logs, and receive EOF/error merely returns ([iPad USB:659](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:659), [:797](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:797)). No FSM event is emitted: that header claim is correct, but the modeled routing-flag update is not.

   Polling also compares **local IPv4 addresses**, not a cable-presence Boolean. Both implementations scan `AF_INET` link-local candidates; an address change triggers work even without observing disappearance ([Mac USB:327](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:327), [:398](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:398), [iPad USB:337](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:337), [:401](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:401)). The model misses IPv6-only links, local-address changes while “up,” and candidate/interface ambiguity.

   Mac disappearance synchronously tears down sockets and clears `isConnected` before its interface event; modeled `MacIfaceDown` leaves `sees["usb"]` true and later supplies a separate loss event ([Mac USB:409](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:409), [model:248](./RemoteDesktop/tla/TransportAgreement.tla:248)).

   **Counterexamples [I]:** TCP dies while the media object remains → iPad continues routing to dead USB; or rapid re-plug changes the local IP → real polling reconnects although modeled `IpadIfaceUp` remains disabled. An old iPad TCP failure can also clear a newly installed connection because that handler lacks an identity guard.

   **Smallest fix:** distinguish observed addresses, current connection identity, routing flag, and queued callbacks; transcribe teardown ordering.

3. **High — [C] T2 assumes application-message delivery that the code does not provide.**  
   iPad input sends are unframed TCP writes. Mac USB and wireless receivers pass arbitrary receive regions directly to a handler that processes one header ([iPad wireless:406](./RemoteDesktop/iPadOS/Transport/WirelessTransport.swift:406), [Mac USB:1089](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:1089), [Mac wireless:980](./RemoteDesktop/macOS/Transport/WirelessTransport.m:980), [Mac session:2376](./RemoteDesktop/macOS/App/SessionManager.m:2376)).

   **Counterexample [I]:** the post-handshake viewport report is split across receives, or coalesced after another input message → it is discarded or never dispatched → no required viewport-driven startup. `MacRecvVp` instead receives a complete report.

   Headers also do not make stale cross-channel state harmless. A delayed wireless handshake/geometry update can arrive after newer USB geometry and overwrite global dimensions or recreate the decompressor ([iPad session:989](./RemoteDesktop/iPadOS/App/SessionManager.swift:989), [:1223](./RemoteDesktop/iPadOS/App/SessionManager.swift:1223)).

   The model’s Boolean/value slots actually allow arbitrary ordering between message types; they **collapse repeated messages and omit their geometry/session versions**. “No cross-channel reordering” is therefore an inaccurate description of the abstraction.

   **Smallest fix:** treat complete-message framing as an explicit unproved assumption, and retain enough message identity/content to check stale updates and required-message recovery.

4. **High — [C] The iPad’s timeout and lifecycle transitions are missing.**  
   After eight seconds in `.connecting`, the iPad stops transports, resets pairing, and enters `.awaitingPairing` ([iPad session:111](./RemoteDesktop/iPadOS/App/SessionManager.swift:111), [:344](./RemoteDesktop/iPadOS/App/SessionManager.swift:344)). Backgrounding cancels reconnect/connecting timers; foregrounding can restart monitoring and re-arm the timeout ([session:262](./RemoteDesktop/iPadOS/App/SessionManager.swift:262)). Scene-phase callbacks invoke these paths.

   **Counterexample [I]:** links remain available, but discovery/TLS/handshake takes over eight seconds → real iPad returns to QR; the model permits arbitrarily delayed eventual streaming. Bounded physical flapping does not exclude this.

   iPad reconnection calls `startTransportMonitoring`, not merely an availability check ([session:1370](./RemoteDesktop/iPadOS/App/SessionManager.swift:1370)); FSM connection effects also start monitoring/browsing. The model omits those lifecycle effects.

   The header’s “address … never cleared” is false without a scope qualification: explicit pairing reset calls `clearLinkLocalPeerAddress` ([session:330](./RemoteDesktop/iPadOS/App/SessionManager.swift:330)).

   **Smallest fix:** add timeout/background/resume actions, or explicitly limit claims to foreground operation before timeout and outside reset.

5. **High — [C/I] The security composition lacks a connection-identity obligation.**  
   TransportAgreement reuses `"usb"`/`"wl"` slots; SecureSession authenticates individual session IDs and, in its design, pairing epochs ([SecureSession:181](./RemoteDesktop/tla/SecureSession.tla:181), [:293](./RemoteDesktop/tla/SecureSession.tla:293)). There is no mapping between them.

   **Counterexample [I]:** USB connection A is replaced by pending B → A’s late READY handler sets `isConnected` and calls `onTransportConnected` → routing sends the application handshake through current pointer B. Mac USB READY lacks the identity check present in its loss branch ([Mac USB:1023](./RemoteDesktop/macOS/Transport/USBNetworkTransport.m:1023)). Separately, `showPairingQR` resets pairing while existing sessions can remain ([Mac session:510](./RemoteDesktop/macOS/App/SessionManager.m:510)); switching back to one requires the security model’s epoch guard.

   [C] Normal connection construction does install pin verification, including USB retry. **This trace does not demonstrate a TLS bypass.**

   **Smallest fix:** require every routed send and accepted callback to map to the same current connection ID, authenticated peer and permitted pairing epoch. Buffered traffic, replacement, revocation and resumption must preserve that mapping; channel availability alone cannot discharge authentication.

6. **High — [C/I] The design switches contain unresolved implementation obligations.**  
   `AddrOnLink` directly copies `env.addrGen`; no discovery exchange can fail or become stale ([model:320](./RemoteDesktop/tla/TransportAgreement.tla:320)). Local-interface enumeration cannot reveal the Mac’s address.

   [I] USB-scoped Bonjour/DNS-SD is implementable with these platform APIs: publish/browse/resolve on the USB interface index, then resolve the service’s address on that interface. Apple documents [interface-scoped registration](https://developer.apple.com/library/archive/documentation/Networking/Conceptual/dns_discovery_api/Articles/registering.html) and [resolution](https://developer.apple.com/library/archive/documentation/Networking/Conceptual/dns_discovery_api/Articles/resolving.html). [U] Actual discovery over this NCM deployment remains unverified. Existing wireless Bonjour is suspended during an active session, so its availability cannot simply be assumed for USB bootstrap.

   `MacCommit` atomically reconciles route, label, codec and handshake enqueue; moreover, it forces the codec on **every Mac commit**, beyond its “route changes” description ([model:167](./RemoteDesktop/tla/TransportAgreement.tla:167)).

   **Counterexample [I]:** USB readiness changes routing while a capture callback is already producing HEVC → a frame uses the new route before codec/geometry reconciliation. Different dispatch queues and asynchronous capture configuration do not provide the modeled atomicity.

   **Smallest fix:** specify the linearization point and gate observable sends against its connection/configuration generation; refine address discovery asynchronously. Apple’s [required-interface API](https://developer.apple.com/documentation/network/nwparameters/requiredinterface) constrains routing but supplies neither discovery nor atomicity.

7. **Medium — [C] The properties and scenario rows permit misleading interpretations.**
   
   - `FsmLink("wifi") = FsmLink("awdl") = "wl"` ([model:110](./RemoteDesktop/tla/TransportAgreement.tla:110)). **Counterexample:** fallback runs over AWDL but sets the label to Wi-Fi; `LabelsMatch` and `RestLabels` still pass. They establish channel-class agreement, not link-label correctness.
   - `hsOK` is permanent, `vpKnown` is not required by `RestStreams`, and streaming is a session flag ([model:299](./RemoteDesktop/tla/TransportAgreement.tla:299), [:424](./RemoteDesktop/tla/TransportAgreement.tla:424)). An old handshake remains sufficient evidence after later switches. There is no current-session handshake/viewport/address acknowledgment or frame-progress property.
   - **Concrete scenario-row counterexample:** `InitPeerKnown = TRUE` gives generation 1; the *first* `PlugUSB` may select generation 2; the stale attempt fails and `RestStreams` fails, with no unplug whatsoever. Thus `TA-asbuilt-addr-change.cfg` need not demonstrate its named re-plug bug.
   - `Switched` genuinely records earlier good rest, but permits an intervening complete outage. It witnesses recovery, not uninterrupted switching or preservation of required messages.
   - `Rest` does not require exhausting `MaxFlaps`. However, exhausted reconnect attempts count as rest. `MaxAttempts = 1` differs from the Mac’s five attempts ([Mac session:51](./RemoteDesktop/macOS/App/SessionManager.m:51)). `Settles` establishes termination of abstract work under aggregate fairness, not a wall-clock recovery guarantee.

   **Smallest fix:** compare exact wireless labels, version readiness evidence, and require each named scenario’s history in its counterexample/witness.

   [C] Both wireless implementations classify paths only at READY; neither installs path-update handling. The model fixes `wlKind` until reconnection. [U] In-place Wi-Fi↔AWDL handover on this deployment is unverified; Apple exposes [path updates](https://developer.apple.com/documentation/network/nwconnection/pathupdatehandler), so that boundary needs an explicit assumption.

8. **Medium — [C] Codec coverage excludes an existing intentional transition.**  
   **Counterexample:** USB streaming → owner enables Eco → `handleEcoModeRequest` starts HEVC while USB remains selected ([Mac session:2818](./RemoteDesktop/macOS/App/SessionManager.m:2818)). The model cannot express this and `CodecMatches` forbids it.

   **Smallest fix:** explicitly assume Eco is disabled, or include it in codec eligibility. A USB/HEVC mismatch is not automatically a switching bug.

9. **Medium — [C] Proof-control location parsing can accept the wrong failed obligation.**  
   `proof-steps.py` ignores unnumbered `QED` boundaries and searches backward for the previous numbered step ([parser:35](./RemoteDesktop/tla/proof-steps.py:35)).

   **Concrete harness counterexample:** synthetic output reporting one unproved obligation at `MacCommitOK`’s final QED, line 121, produced `MacCommitOK.<1>5`—exactly the accepted RouteResync-control label. I ran only this parser check. It does not establish that the reported TLAPS run failed there.

   **Smallest fix:** recognize QED boundaries and reject ambiguous attribution. Lemma-name prefixes themselves improve discrimination; they did not introduce this underlying backward-scan weakness.

The six reported bugs resolve as follows:

| Reported bug | Source verdict and concrete path |
|---|---|
| First USB launch has no stored address | **[C] Real bootstrap failure:** no link-local peer → polling waits for an update; USB alone provides no route carrying that update ([iPad USB:406](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:406)). Eventually the connecting timeout returns to QR. |
| Stale address after re-plug is never retried | **[C] Qualified:** no automatic address rediscovery; terminal `.failed` has no retry. But initial `.waiting` explicitly schedules a 0.5-second **re-dial**, omitted by the model ([USB:676](./RemoteDesktop/iPadOS/Transport/USBNetworkTransport.swift:676)). “Never retried” is too broad. |
| Quick re-plug loses USB without event/retry | **[I] Real possible failure:** both polls miss disappearance, addresses remain unchanged, TCP terminates → no interface event or USB-loss FSM event forces recovery. **[U]** A brief unplug does not itself prove TCP must terminate; the model assumes that. |
| Mac stays LZ4 over Wi-Fi | **[C/I] Real path:** Wi-Fi streams → USB interface appears → LZ4 effect executes before USB TCP readiness → USB connection fails → routing remains Wi-Fi, codec remains LZ4 ([Mac session:745](./RemoteDesktop/macOS/App/SessionManager.m:745), [:822](./RemoteDesktop/macOS/App/SessionManager.m:822)). Ordinary USB removal with working fallback does request HEVC; the row’s wording is over-specific. |
| Labels drift / AWDL labelled Wi-Fi / untagged disconnect | **[C] Real:** interface appearance promotes labels before connection; fallback always emits Wi-Fi availability; USB input loss emits untagged DISCONNECTED ([Mac session:648](./RemoteDesktop/macOS/App/SessionManager.m:648), [:768](./RemoteDesktop/macOS/App/SessionManager.m:768), [iPad session:589](./RemoteDesktop/iPadOS/App/SessionManager.swift:589)). The AWDL mislabel is invisible to the stated label predicates. |
| Mac streams with no route | **[C/I] Real path:** Wi-Fi streams → USB interface promotes FSM to USB but TCP fails → wireless ends → `WIFI_UNAVAILABLE` is ignored in USB state → reconnection is not started. Session remains STREAMING without either route. This does not prove an encoder remains active: the preceding LZ4 switch stopped HEVC. |

What checked out:

- **[C]** The projected FSM state/codec table matches both implementations for the seven modeled events. USB-first routing, the Mac’s availability-check reconnect timer, and the iPad’s unchanged-state early return are correctly represented.
- **[I]** `SwitchingSafe` has a coherent induction for `TypeOK`, `LabelsMatch`, `StreamOnlyWithRoute` and `CodecMatches`, for all bounds satisfying `Bounds`. It proves neither convergence nor message preservation. I found no vacuous `MacCommitOK`/`IpadSetOK` hypothesis. `MarkType` needs no hidden Rest theorem: `LinkOf` always returns USB or the typed `wlKind`.
- **[C/I]** The mechanism-removal controls target relevant predicates; AddrOnLink appropriately has no safety-proof control. The no-fairness control meaningfully permits stuttering before rest. The witnesses’ `last`, `lastGen` and `cut` record genuine prior rests and cable cuts, subject to the weaker recovery interpretation above.