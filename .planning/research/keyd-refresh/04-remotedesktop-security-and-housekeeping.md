# RemoteDesktop: security audit and housekeeping (2026-10-29)

RemoteDesktop (keyd-rd) has absorbed keyd v1's job (keyboard and mouse from the iPad), so it is the product to
harden. Threat model: **an attacker on the same public Wi-Fi network or within AWDL range**. They can reach any
listening port, race the pairing, sniff traffic and spoof Bonjour. They get nothing from the USB link.
A successful attack gives them full keyboard and mouse control of the Mac, which is equivalent to running code on it.

Every finding below was read in the source by the orchestrator. Nothing has been changed yet.

## What is already right

- Steady state is mutual TLS 1.3 with pinned SHA-256 fingerprints on both ends. On the Mac,
  `peer_authentication_required` is set, and the verify block fails closed when no fingerprint is stored
  (`macOS/Transport/USBNetworkTransport.m:229-262`, `WirelessTransport.m:188-250`). On the iPad, the verify
  block also fails closed (`iPadOS/Transport/WirelessTransport.swift:98-106,219-222`, `USBNetworkTransport.swift:101-106,220-254`).
- Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`PairingManager.m:880`, `QRPairing.swift:1111`).
- The QR code authenticates the Mac to the iPad, because it carries the Mac certificate fingerprint.

## Findings

### P0: fix before using it on any network that isn't yours

1. **Pairing does not authenticate the iPad.** The pairing listener (`PairingManager.m:1015-1070`) is TLS
   with a server identity only: there is no client authentication and no secret from the QR code. Whoever
   connects first and sends 1-256 bytes (`handlePairingConnection`, `:629-750`) completes pairing. The Mac
   then stores that client's fingerprint (`completePairing`, `:771-846`) and replies with a **freshly generated
   client private key and certificate** (`pairingResponsePayloadWithMacPublicKey`, `:489-515`). A new
   connection also replaces any pairing already in progress (`:633-638`), so an attacker can hijack a real
   pairing mid-flight.
2. **The pairing listener stays open on every interface indefinitely.** It binds `::` (`:1042`). It stops only
   on success (`:711`). Closing the QR window (`QRWindow`, `SessionManager.m:20-24`; Escape just calls `close`)
   does not stop it, and there is no timeout or attempt limit. "Reset pairing" (`SessionManager.m:622-627`)
   re-enters the awaiting-pairing state, so on a café network the Mac sits waiting for anyone to claim it.
3. **The Mac generates the iPad's private key and sends it over the network** (`ensureProvisionedClientIdentity`,
   `:428-487`). The key should never leave the iPad. mTLS is also labelled "best-effort — mTLS optional"
   (`:490`, `:520-522`). Pairing must fail closed instead.
4. **The Mac's TLS identity is a file in `/tmp`** (`/tmp/keydrd-tls/identity.p12`, passphrase `keydrd`,
   `PairingManager.m:98,106`), created by `scripts/mac-debug.sh:72-82` and `run-apps.sh`. Anyone who can read
   that file can impersonate the Mac. The agent also cannot start without the debug script.
5. **Test-mode trust bypasses ship in the production apps.**
   - `QRPairing.swift:448-470` `completePairingTestMode` has a verify block that returns `complete(true)`.
     It is reachable via the `--qr-payload` launch argument (`:403-445`).
   - The Mac app writes the full QR payload to `/tmp/keydrd-test-qr.json` under `--test-mode`
     (`SessionManager.m:527-535`, `AppDelegate.m:36-39`).
   - `DeviceTestRunner.swift` (3,345 lines) compiles into the iPad app.

   All of this has to be `#if DEBUG`-only or moved into test targets.

### P1: public-network posture

6. **Bonjour announces the Mac on every network.** It advertises `_keydrd._tcp` with an auto-generated name
   (the Mac's name) and `include_peer_to_peer` (`WirelessTransport.m:293-307`). Anyone on the network can see
   the Mac and probe it. Default to AWDL/peer-to-peer only, use a random or anonymous instance name, and offer
   an explicit "allow on this Wi-Fi network" choice for trusted networks.
7. **There is no connection limit.** The Mac allows unlimited concurrent TLS handshakes and new connections
   replace old ones. Allow one active session, refuse or queue a second, set a handshake timeout and back off
   repeated failures.
8. **The ECDH "shared secret" is dead weight.** It is derived and stored (`completePairing`) but never used,
   which suggests a protection that does not exist. Either delete it, or bind it to the session via a TLS
   exporter.
9. **The input path accepts events while the Mac is locked or in Secure Input.** Decide on a policy: at
   minimum, show a visible "remote control active" indicator on the Mac at all times (menu-bar icon state),
   and offer a one-click kill switch.
10. **Binary parsers are C and are only exercised by unit tests** (25-byte media header, 9-byte input header,
    clock sync). After pairing they are reachable only by the paired peer, but fuzz them anyway.

### Recommended pairing design

- The QR carries the Mac's cert fingerprint, a **256-bit one-time pairing token**, and an expiry (about 2 minutes).
- The iPad generates its own P-256 key in the Keychain (non-exportable) and self-signs a cert.
- The iPad connects with its cert as a TLS client identity, pins the Mac fingerprint, and sends
  `HMAC(token, iPadCertFingerprint ‖ MacCertFingerprint)`. The Mac checks it in constant time, stores the
  iPad's fingerprint, and accepts nothing else.
- On the Mac, the listener exists only while the QR window is open. It closes on success, on window close, on
  expiry, or after 3 failed attempts. One pairing attempt is accepted at a time.
- Optional: show a short code on both screens and confirm with one click on the Mac.
- Mac server identity: a Keychain-generated key using the data-protection keychain, which is stable now that
  signing is under paid team M2DUW2UUKH. No PKCS12, no `/tmp`. The memory note "login keychain hostile to dev
  builds" predates stable paid signing, so re-test it before relying on either path.

### Which first-pairing channel?

| Channel | Who can attack it | Verdict |
|---|---|---|
| **USB cable** (pairing listener bound only to the NCM interface) | Only someone physically plugging into the Mac | **Strongest.** No secret is ever shown or sent over the air. Same idea as iOS "Trust This Computer". RD already has the NCM link. |
| QR code with a one-time token (design above) | Anyone who photographs or screen-captures the QR before it expires, *and* reaches the Mac's network in time | Strong. 256 bits over a visual, short-range channel. Needs expiry, a single use, and the QR window excluded from capture (`NSWindow.sharingType = .none`; whether ScreenCaptureKit honours this on macOS 27 is unverified). |
| QR plus a confirmation on both screens (short code, one click on the Mac) | Only an attacker who has the QR *and* gets the owner to click Confirm | Closes the stolen-QR gap. Worth adding to either channel. |
| Typed PIN with a PAKE (SPAKE2/CPace) | Online guessing only | For when no camera or cable is available. Weaker than a 256-bit QR token. |
| Today's QR (fingerprint only, no token) | Anyone on the network while the listener is open | Broken. See P0 #1-2. |

Recommendation: pair over **USB by default**, offer QR + token + confirmation as the wireless fallback, and require
the one-click confirmation on the Mac in both cases.

## Housekeeping (same list as keyd, applied to RemoteDesktop)

| Item | RemoteDesktop today | Change |
|---|---|---|
| Project generation | Hand-maintained `.pbxproj` on both apps, no `project.yml` | XcodeGen + git-ignored `.xcodeproj` + `make gen` (drdabber/videocap) |
| Signing | `M2DUW2UUKH` repeated across 6 build configs | One `Signing.xcconfig` (drdabber layering) |
| Swift / targets | iPad Swift 5.0, iOS 17.0; Mac C/ObjC, macOS 14.2 | Swift 6 strict concurrency on the iPad; deployment floor is an owner decision |
| Test code in production | `DeviceTestRunner.swift`, test-mode pairing, `/tmp` QR dump | Test targets or `#if DEBUG` |
| E2E script | `run-e2e-tests.sh:676` `git add -A` and auto-commit to `main` | Stage explicit paths; commit only on request |
| Makefile | Absolute `/Users/...` paths into `RemoteDesktop/scripts` | Relative paths and a `make help` target |
| Deploy proof | Debug scripts don't prove the running pid is the new build | Promptbar `Scripts/deploy.sh` pid/mtime proof |
| Logs | `os_log` / `[CONSOLE]` only | Rotating file log with a test-host guard (Promptbar `Log.swift`) |
| Agent rules | `CLAUDE.md` and `agents.md` duplicated | One rule source |
| UI | Agent menu bar + QR `NSWindow` built by hand; iPad HUD | Liquid Glass skill adapted from drdabber; deuteranopia-safe status (shape + word) |

## Tooling for agents: Xcode 27 documentation search

Xcode 27 ships an MCP server (`xcrun mcpbridge`), and one of its tools is `DocumentationSearch`: semantic
search over Apple's developer documentation, matched to the installed SDK. It works (tested on 2026-10-29),
and it is far better than the third-party `apple-docs` MCP, which serves an old snapshot. It requires a
one-time approval, granted by opening the workspace through the bridge. `scripts/xcode-docs.sh "<query>"`
wraps it for agents. Xcode's MCP also offers `RunCodeSnippet` (compile and run an API check in project
context) and `RenderPreview` (SwiftUI snapshots), which help with "does this API exist" and visual checks.

## Corrections after the GPT 6.1 sol review (2026-10-29)

The review (`05-gpt-review-pairing-and-wire.md`) checked this audit against the source. These
corrections were re-read in the code before being accepted `[C]`:

- **Pairing request:** the Mac needs an importable P-256 public key and a successful ECDH, not just
  "1-256 bytes". It still asks for no owner authentication and no proof of possession, so the P0
  stands.
- **Reset pairing** does not open a new listener. It stops transports and clears pairing, but it
  does not cancel an existing pairing listener or connection. **"Pair iPad"** (`showPairingQR`,
  `SessionManager.m:510-512`) deletes the pin without stopping anything, so open sessions survive
  revocation.
- **Client key:** the Mac caches one client identity and sends its private key; it is not generated
  fresh per connection. The normal transports still require client auth and fail closed without a
  pin.
- **`/tmp` identity:** the scripts set 0700/0600. The fixed path and passphrase remain a finding;
  symlink and pre-created-path resistance is `[U]`.
- **Test bypass** needs the `--test-mode` launch argument. It is not remotely triggerable, but it
  ships in the app binary.
- **Connections:** wireless rejects duplicates and suspends its listener once ready. So it is not
  "unlimited", but pre-auth DoS limits are still unproven.
- **ECDH secret:** it protects no traffic, but its presence is the persisted "paired" flag on both
  sides.
- **Input while locked:** moot today. RD's Mac has no mouse or keyboard handling and no CGEvent
  calls; input is Phase 3.
- **New:** input receive hands raw TCP regions to the parser with no framing
  (`USBNetworkTransport.m:1089-1112`, `WirelessTransport.m:982-1006`). Keychain write results are
  ignored on both sides. Production DTLS asks for a minimum of TLS 1.3, and the negotiated version
  is `[U]`.
