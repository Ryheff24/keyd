---
status: awaiting_human_verify
trigger: "pairing-failure — QR code scan does nothing, no pairing attempt starts"
created: 2026-03-01T00:00:00Z
updated: 2026-03-01T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED — four interlocking bugs, all fixed and verified by tests + build.
test: 74/74 SharedProtocol tests pass; macOS BUILD SUCCEEDED.
expecting: Human confirms QR scan works on device over USB and AWDL.
next_action: Human device verification

## Symptoms

expected: Scanning the QR code on iPhone should initiate and complete pairing with the macOS agent
actual: QR code scans but nothing happens — no pairing attempt starts at all
errors: None visible — no error messages shown on either device
reproduction: Scan QR code displayed by Mac agent using iPhone camera in the keyd app. Happens every time, on both USB and AWDL.
timeline: Pairing used to work. Has stopped working at some point.

## Eliminated

- hypothesis: QR code generation or parsing is broken
  evidence: PairingManager.generatePairingQRPayload() and QRPayload decoding are correct and symmetric
  timestamp: 2026-03-01

- hypothesis: iOS never calls completeQRPairing
  evidence: PairingView.QRScannerView.metadataOutput → onQRCode → completeQRPairing chain is correct
  timestamp: 2026-03-01

## Evidence

- timestamp: 2026-03-01
  checked: macOS TransportManager.handleUSBConnectionReady()
  found: |
    When USB arrives and Mac is NOT paired:
      handleEvent(.usbConnectionArrived) → FSM moves to .pendingUSBIdentity
      if pairingManager.isPaired, case .pendingUSBIdentity = fsmState → FALSE (not paired)
      else if case .usbConnected = fsmState → FALSE (state is .pendingUSBIdentity, not .usbConnected)
    Result: NO decoder created. Mac cannot read any USB data. Identity timer fires → disconnect.
  implication: iOS pairingRequest is never received on Mac via USB.

- timestamp: 2026-03-01
  checked: macOS TransportManager.handleUSBData()
  found: Routes to pendingUSBDecoder when FSM is not .usbConnected; pendingUSBDecoder is nil in unpaired mode → data silently dropped.
  implication: Data routing was also wrong for .pendingUSBIdentity + no pending decoder.

- timestamp: 2026-03-01
  checked: macOS agentTransportTransition(.pairingCompleted) in .pendingUSBIdentity state
  found: Only .pairingAWDL case handled. .pendingUSBIdentity hits default no-op branch → FSM stays stuck, identity timer fires.
  implication: Even if pairing request was received, FSM wouldn't promote USB to active session.

- timestamp: 2026-03-01
  checked: macOS TransportManager.send() switch statement
  found: case .disconnected, .pendingAWDLPool, .pendingUSBIdentity: break — messages in pendingUSBIdentity state silently dropped.
  implication: pairingResponse would never reach iOS even if everything else worked.

- timestamp: 2026-03-01
  checked: iOS TransportManager.sendSessionResume() and suppressAWDLStatusUntilPaired
  found: |
    iOS FSM emits .sendSessionResume on .usbReady and .awdlReady transitions.
    sendSessionResume() did not check suppressAWDLStatusUntilPaired (which is true in pairing mode).
    Mac receives sessionResume from unknown device → sends pairingInvalidated → iOS resets connections.
    Both USB and AWDL paths affected: connection tears down before user can even scan QR code.
  implication: Root cause for "nothing happens on AWDL" — connection was dead before QR scan.

## Resolution

root_cause: |
  Four interlocking bugs in the pairing flow, all in the Mac-side unpaired USB path and the
  iOS-side session resume behavior during pairing:

  BUG 1 — Mac, USB decoder missing in unpaired mode:
    handleUSBConnectionReady() has no branch for (!isPaired && .pendingUSBIdentity).
    No decoder → no data read → identity timer fires → disconnect. Affects USB pairing.

  BUG 2 — Mac, FSM ignores pairingCompleted in pendingUSBIdentity state:
    agentTransportTransition(.pairingCompleted) only handles .pairingAWDL.
    USB pairing completion is a no-op. Identity timer fires → disconnects.

  BUG 3 — Mac, pairingResponse silently dropped in pendingUSBIdentity state:
    TransportManager.send() drops messages when fsmState == .pendingUSBIdentity.
    iOS never receives the pairing response.

  BUG 4 — iOS, sessionResume sent before pairing completes:
    iOS FSM emits .sendSessionResume on every connection event.
    Mac (unpaired) responds with pairingInvalidated → iOS resets transport → connection gone
    before user scans QR. Affects both USB and AWDL. This is why AWDL also fails despite
    the Mac correctly setting up an active decoder for unpaired AWDL connections.

fix: |
  Fix 1 — macOS/KeydAgent/Transport/TransportManager.swift, handleUSBConnectionReady():
    Added `else if !pairingManager.isPaired, case .pendingUSBIdentity = fsmState` branch
    calling makeActiveDecoder(). Mac can now read USB data during the pairing handshake.

  Fix 2 — macOS/KeydAgent/Transport/TransportManager.swift, handleUSBData():
    Added fallback to activeDecoder when pendingUSBDecoder is nil.

  Fix 3 — SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift:
    Added .pendingUSBIdentity case to agentTransportTransition(.pairingCompleted):
    transitions to .usbConnected with cancelUSBIdentityTimer, promoteToActive(.usb),
    startSecureInputPolling, updateStatusBar effects.

  Fix 4 — macOS/KeydAgent/Transport/TransportManager.swift, send():
    Added .pendingUSBIdentity to the USB send case so pairing responses can be sent
    back to iOS during the handshake.

  Fix 5 — KeydApp/KeydApp/Transport/TransportManager.swift, sendSessionResume():
    Added `guard !suppressAWDLStatusUntilPaired else { return }` to skip session resume
    during initial pairing. Pairing handshake establishes identity; premature sessionResume
    causes Mac to send pairingInvalidated and tear down the connection.

  Regression test added:
    SharedProtocol/Tests/SharedProtocolTests/TransportStateMachineTests.swift
    testPairingUSBCompletionPromotes() — verifies FSM transitions correctly for USB pairing.

verification: |
  - 74/74 SharedProtocol tests pass (including new regression test)
  - macOS KeydAgent BUILD SUCCEEDED (xcodebuild)
  - Human device test pending

files_changed:
  - SharedProtocol/Sources/SharedProtocol/TransportStateMachine.swift
  - SharedProtocol/Tests/SharedProtocolTests/TransportStateMachineTests.swift
  - macOS/KeydAgent/Transport/TransportManager.swift
  - KeydApp/KeydApp/Transport/TransportManager.swift
