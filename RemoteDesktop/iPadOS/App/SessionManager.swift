import Foundation
import UIKit
import CoreVideo
import os.log

/// iPad session orchestration: pairing -> connect -> stream.
///
/// Owns all pipeline components: transports, pairing, decoders, renderer, HUD.
/// Manages session state machine: awaitingPairing -> connecting -> streaming -> reconnecting -> disconnected.
/// Wires transport receive callbacks through decode pipeline to MetalRenderer.
@Observable
final class SessionManager {

    // MARK: - Session State

    enum State: String {
        case awaitingPairing
        case connecting
        case streaming
        case reconnecting
        case disconnected
    }

    /// Current session state.
    private(set) var state: State = .awaitingPairing {
        didSet {
            print("[CONSOLE] SessionManager state: \(oldValue.rawValue) -> \(state.rawValue)")
            Self.log.info("[SessionManager] state changed: \(oldValue.rawValue) -> \(self.state.rawValue)")
            // Cancel connecting timeout once we leave .connecting
            if oldValue == .connecting && state != .connecting {
                connectingTimeoutTimer?.invalidate()
                connectingTimeoutTimer = nil
            }
            testRunner?.noteSessionStateChanged(old: oldValue, new: state)
        }
    }

    /// Tracks whether at least one frame has been rendered since the current session started.
    /// Used by ContentView to avoid leaving the "Connecting..." overlay on top of active video.
    private(set) var hasRenderedFrameInCurrentSession: Bool = false

    // MARK: - Owned Components

    let qrPairing = QRPairing()
    let usbTransport = USBNetworkTransport()
    let wirelessTransport = WirelessTransport()
    let metalRenderer = MetalRenderer()
    /// Pointer/keyboard input to the Mac (tla/InputPath.tla).
    let inputSender = InputSender()
    let hudViewModel = HUDViewModel()
    private var lz4Decompressor: LZ4Decompressor?
    private let hevcDecoder = HEVCDecoder()
    let udpReassembler = UDPReassembler()

    // MARK: - Transport FSM

    private var currentTransport: TransportState = .idle

    // MARK: - Display Geometry (from handshake)

    private(set) var viewportWidth: Int = 0
    private(set) var viewportHeight: Int = 0
    private var macDisplayWidth: Int = 0
    private var frameRecvCount: Int = 0
    private var lastFrameReceiveUs: UInt64 = 0
    private var lastFrameReceiveSeq: UInt16 = 0
    private var frameArrivalLogCount: Int = 0
    private var macDisplayHeight: Int = 0
    private var macScaleFactor: Float = 2.0

    // MARK: - FPS Tracking (rolling window)

    private var frameTimestamps: [CFAbsoluteTime] = []
    private static let fpsWindowSize = 60
    private var fpsUpdateTimer: Timer?
    private struct HEVCHandoffTrace {
        let seq: UInt16
        let source: String
        let transport: String
        let decodeSubmitUs: UInt64
        let decodeDoneUs: UInt64
        let enqueueUs: UInt64
        let decodeMs: Double?
        let stateAtDecode: String
    }
    private struct HEVCRenderTrace {
        let dequeuedAtUs: UInt64
        let queueDelayMs: Double
        let pendingBefore: Int
        let pendingAfter: Int
        let mode: String
    }
    private let hevcHandoffTraceLock = NSLock()
    private var hevcHandoffTraceByCaptureTs: [UInt64: HEVCHandoffTrace] = [:]
    private var hevcRenderTraceByCaptureTs: [UInt64: HEVCRenderTrace] = [:]
    private let hevcHandoffQueue = DispatchQueue(label: "com.ryheff.keyd.session.hevc-handoff", qos: .userInteractive)
    private var hevcHandoffLogCount: Int = 0

    // MARK: - Latency Probe

    private var latencyProbeTimer: Timer?
    private static let latencyProbeInterval: TimeInterval = 1.0
    private var lastKeyframeRequestUs: UInt64 = 0

    // MARK: FrameLoop state (tla/FrameLoop.tla Design). Lines tagged "FL <Action>" name model steps.
    /// The connection a message arrived on: transport and that transport's connection serial.
    struct FLLink: Equatable, CustomStringConvertible {
        let usb: Bool
        let serial: UInt64
        var description: String { "\(usb ? "usb" : "wifi")#\(serial)" }
    }
    private let flLock = NSLock()
    /// HsConn: media is taken only from the connection of the newest accepted handshake.
    private var flHsLink: FLLink?
    private var flHsEpoch: UInt32 = 0
    /// KeyOnBreak/AwaitOnFail: no delta is decoded until a keyframe is (after a handshake or a
    /// decode failure). flGen bumps on each break; HEVC outputs of an older generation are dropped.
    private var flAwaiting = true
    private var flAwaitReason = "start"
    private var flAwaitSinceUs: UInt64 = 0
    private var flGen: UInt64 = 0
    private var flHevcGen = [UInt64](repeating: 0, count: 256)
    private var flLastKeyReqUs: UInt64 = 0
    private var flKeyRetryTimer: DispatchSourceTimer?
    private var flForeignDrops = 0
    private var flAwaitDrops = 0
    private var flStaleOutputs = 0
    private var lastHandshakeDisplay: (w: Int, h: Int)?
    private static let keyframeRequestCooldownUs: UInt64 = 500_000
    /// Wi-Fi frame acks sent (transport queue only).
    private var framesAcked = 0

    // MARK: - Reconnection

    private var reconnectAttempt: Int = 0
    private var reconnectTimer: Timer?
    private static let maxReconnectDelay: TimeInterval = 2.0
    private static let baseReconnectDelay: TimeInterval = 0.25
    private var connectingTimeoutTimer: Timer?
    private static let connectingTimeout: TimeInterval = 8.0

    // MARK: - Test Mode

    /// Whether running in test mode (--test-mode flag). Skips QR camera, auto-pairs, runs E2E tests.
    let isTestMode: Bool = ProcessInfo.processInfo.arguments.contains("--test-mode")

    /// Wired-only mode: disables WiFi/AWDL transport browsing.
    let isWiredOnly: Bool = ProcessInfo.processInfo.arguments.contains("--wired-only")

    /// Wireless-only mode: disables USB monitoring and starts wireless directly.
    let isWirelessOnly: Bool = ProcessInfo.processInfo.arguments.contains("--wireless-only")

    /// E2E test runner (created in test mode only).
    private(set) var testRunner: DeviceTestRunner?

    // MARK: - Logging

    private static let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "Session")

    // MARK: - Init

    init() {
        Self.log.info("[SessionManager] init called, initial state=\(self.state.rawValue)")
        Self.log.info("[SessionManager] qrPairing.isPaired=\(self.qrPairing.isPaired)")
        hevcDecoder.onDecodeError = { [weak self] header, status in
            guard let self else { return }
            self.flDecodeFailed(gen: self.flGenForHEVC(seq: header.seq), seq: header.seq,
                                reason: "hevc-async-error-\(status)")
        }
        hevcDecoder.onDecodedFrame = { [weak self] pixelBuffer, header, payloadLength, decodeSubmitUs, callbackUs in
            self?.scheduleDecodedHEVCFrame(pixelBuffer,
                                           header: header,
                                           payloadLength: payloadLength,
                                           decodeMs: nil,
                                           source: "async-callback",
                                           decodeSubmitUs: decodeSubmitUs,
                                           decodeDoneUs: callbackUs)
        }
        metalRenderer.onFrameDequeuedForRender = { [weak self] captureTsUs, enqueuedAtUs, dequeuedAtUs, queueDelayMs, pendingBefore, pendingAfter, mode in
            self?.logHEVCHandoffDequeue(captureTsUs: captureTsUs,
                                        enqueuedAtUs: enqueuedAtUs,
                                        dequeuedAtUs: dequeuedAtUs,
                                        queueDelayMs: queueDelayMs,
                                        pendingBefore: pendingBefore,
                                        pendingAfter: pendingAfter,
                                        mode: mode)
        }
        metalRenderer.onFrameRenderCompleted = { [weak self] captureTsUs, completionUs, queueDelayMs, gpuRoundtripMs, mode in
            self?.logHEVCHandoffPresent(captureTsUs: captureTsUs,
                                        completionUs: completionUs,
                                        queueDelayMs: queueDelayMs,
                                        gpuRoundtripMs: gpuRoundtripMs,
                                        mode: mode)
        }
        if isTestMode {
            print("[CONSOLE] SessionManager: TEST MODE enabled (wiredOnly=\(isWiredOnly), wirelessOnly=\(isWirelessOnly))")
            testRunner = DeviceTestRunner(sessionManager: self)
        }
    }

    // MARK: - Public API

    /// Start the session. Check pairing state and begin monitoring transports.
    func start() {
        Self.log.info("[SessionManager] start() called, current state=\(self.state.rawValue)")
        print("[CONSOLE] start(): isPaired=\(qrPairing.isPaired)")
        hasRenderedFrameInCurrentSession = false

        // Set up HUD callbacks
        hudViewModel.onEcoModeChanged = { [weak self] isEco in
            self?.handleEcoModeChange(isEco)
        }
        hudViewModel.onDisconnect = { [weak self] in
            self?.disconnectSession()
        }
        hudViewModel.onResolutionMatch = { [weak self] in
            self?.requestResolutionMatch()
        }
        hudViewModel.onResetPairing = { [weak self] in
            self?.resetPairingAndShowQR()
        }

        // Test mode relaunch (run-e2e-tests.sh --relaunch-ipad-after): keep the stored pairing
        // and reconnect like a real relaunch (tla/Lifecycle.tla Relaunch); the Mac's pairing
        // listener is closed by then. Pairing tests are recorded SKIPPED, the runner's convention.
        let keepPairing = ProcessInfo.processInfo.arguments.contains("--keep-pairing")
        if isTestMode && keepPairing {
            print("[CONSOLE] start(): TEST MODE --keep-pairing isPaired=\(qrPairing.isPaired) pairedHost=\(qrPairing.pairedHost ?? "nil")")
            testRunner?.runAllTests()
            testRunner?.reportTLSConnection(success: true, detail: "SKIPPED — --keep-pairing (relaunch reuses stored pairing)")
            testRunner?.reportECDHExchange(success: true, detail: "SKIPPED — --keep-pairing (relaunch reuses stored pairing)")
        }

        // Test mode: always fresh pair (Mac resets pairing in test mode too)
        if isTestMode && !keepPairing {
            qrPairing.resetPairing()
            print("[CONSOLE] start(): TEST MODE -- cleared pairing, starting auto-pair via Bonjour")
            testRunner?.runAllTests()
            state = .awaitingPairing
            qrPairing.autoPairViaBonjourForTestMode(testRunner: testRunner) { [weak self] in
                print("[CONSOLE] TEST MODE: auto-pair complete, starting transport monitoring")
                self?.onPairingComplete()
            }
            return
        }

        // Check if already paired (persisted from previous session)
        if qrPairing.isPaired {
            Self.log.info("[SessionManager] start(): already paired -- setting state to .connecting and starting transport monitoring")
            print("[CONSOLE] start(): restoring pairing, pairedHost=\(qrPairing.pairedHost ?? "nil")")
            if let macHost = qrPairing.pairedHost?.trimmingCharacters(in: .whitespacesAndNewlines),
               !macHost.isEmpty {
                print("[CONSOLE] start(): restoring pairing success, peer host=\(macHost)")
                usbTransport.setPeerAddress(macHost)
            } else {
                // pairedHost is only required for USB direct-dial.
                // Keep pairing and continue with Bonjour wireless reconnect instead of
                // forcing a QR re-pair when host metadata is missing.
                print("[CONSOLE] start(): pairedHost missing -- continuing with wireless reconnect path")
                Self.log.info("[SessionManager] pairedHost missing for restored pairing; continuing without USB peer preseed")
            }
            state = .connecting
            startTransportMonitoring()
            // If Mac's cert changed or pairing is stale, we'll never connect.
            // Fall back to QR after timeout.
            startConnectingTimeout()
        } else {
            Self.log.info("[SessionManager] start(): not paired -- setting state to .awaitingPairing (QR scanner should appear)")
            state = .awaitingPairing
        }
    }

    /// Called when QR pairing completes successfully.
    func onPairingComplete() {
        print("[CONSOLE] SessionManager.onPairingComplete() called, current state=\(state.rawValue)")
        Self.log.info("[SessionManager] onPairingComplete() called, current state=\(self.state.rawValue)")
        state = .connecting

        // Pass Mac's IP to USB transport for direct connection over USB NCM
        if let macHost = qrPairing.pairedHost {
            print("[CONSOLE] Setting USB transport peer address: \(macHost)")
            usbTransport.setPeerAddress(macHost)
        }

        print("[CONSOLE] starting transport monitoring")
        startTransportMonitoring()
        print("[CONSOLE] transport monitoring started")
        print("[CONSOLE] onPairingComplete: arming connecting timeout")
        Self.log.info("[SessionManager] onPairingComplete(): connecting timeout armed")
        startConnectingTimeout()

        // E2E test: now that pairing is done and Mac is advertising, test Bonjour discovery
        testRunner?.runBonjourDiscoveryTestAfterPairing()
    }

    /// Force an immediate reconnect attempt (user tapped "Retry Now").
    func retryNow() {
        Self.log.info("User requested immediate reconnect")
        reconnectTimer?.invalidate()
        reconnectAttempt = 0
        startTransportMonitoring()
        print("[CONSOLE] retryNow: arming connecting timeout")
        Self.log.info("[SessionManager] retryNow(): connecting timeout armed")
        startConnectingTimeout()
    }

    /// Resume session after app returns to foreground.
    func resumeFromBackground() {
        Self.log.info("[SessionManager] resumeFromBackground() called, state=\(self.state.rawValue), isPaired=\(self.qrPairing.isPaired)")
        print("[CONSOLE] resumeFromBackground: state=\(state.rawValue), usb=\(usbTransport.isConnected), wifi=\(wirelessTransport.isConnected)")

        guard qrPairing.isPaired else {
            Self.log.info("[SessionManager] resumeFromBackground(): not paired, returning early")
            return
        }

        switch state {
        case .disconnected, .reconnecting:
            state = .connecting
            reconnectAttempt = 0
            startTransportMonitoring()
            print("[CONSOLE] resumeFromBackground: reconnect path -- armed connecting timeout")
            Self.log.info("[SessionManager] resumeFromBackground(): reconnect path, connecting timeout armed")
            startConnectingTimeout()
        case .streaming:
            // App was suspended — transports may have died while we weren't running.
            // Check if any transport is still alive; if not, trigger reconnect.
            if !usbTransport.isConnected && !wirelessTransport.isConnected {
                print("[CONSOLE] resumeFromBackground: transports dead while backgrounded, reconnecting")
                Self.log.info("Transports lost while backgrounded — reconnecting")
                state = .reconnecting
                reconnectAttempt = 0
                startTransportMonitoring()
            } else {
                // Transport still alive — restart timers that were invalidated on background
                startFPSUpdateTimer()
                startLatencyProbeTimer()
            }
        case .connecting:
            // Avoid re-arming transport monitoring while a connect attempt is already in
            // flight (common on initial app launch when scenePhase also emits .active).
            // Re-starting here can duplicate timers/browse attempts and increase churn.
            print("[CONSOLE] resumeFromBackground: already connecting -- leaving existing transport monitoring in place")
            Self.log.info("[SessionManager] resumeFromBackground(): already connecting; no monitoring restart")
            reconnectAttempt = 0
            // pauseForBackground() invalidates connectingTimeoutTimer. Re-arm it on
            // foreground so we don't get stuck in .connecting forever after app/shell churn.
            print("[CONSOLE] resumeFromBackground: already connecting -- rearming connecting timeout")
            Self.log.info("[SessionManager] resumeFromBackground(): already connecting; connecting timeout re-armed")
            startConnectingTimeout()
        default:
            break
        }
    }

    /// Pause session when app goes to background.
    func pauseForBackground() {
        Self.log.info("App backgrounded -- pausing")
        udpReassembler.resetForNewStreamSession(reason: "app-background")
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        reconnectTimer?.invalidate()
        connectingTimeoutTimer?.invalidate()
    }

    /// Reset pairing credentials and return to QR scanner.
    func resetPairingAndShowQR() {
        print("[CONSOLE] resetPairingAndShowQR: clearing pairing and returning to QR")
        Self.log.info("User requested pairing reset")
        udpReassembler.resetForNewStreamSession(reason: "reset-pairing")
        flResetLinks(reason: "reset-pairing")
        reconnectTimer?.invalidate()
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        connectingTimeoutTimer?.invalidate()
        usbTransport.stopMonitoring()
        usbTransport.clearLinkLocalPeerAddress()
        wirelessTransport.stopBrowsing()
        metalRenderer.stop()
        qrPairing.resetPairing()
        let transition = TransportFSM.transition(from: currentTransport, on: .disconnected)
        currentTransport = transition.state
        hasRenderedFrameInCurrentSession = false
        state = .awaitingPairing
    }

    /// Start a timeout for the .connecting state (tla/PairingPersistence.tla, KeepCreds +
    /// RestartOnTimeout). Not reaching the Mac is not evidence the pairing is stale (the agent
    /// may simply not be running), so the timeout never deletes credentials; only the owner's
    /// Reset Pairing does. Instead it restarts discovery, in case it stalled silently, and
    /// re-arms itself. A link that is already up is left alone so a slow handshake can finish.
    private func startConnectingTimeout() {
        connectingTimeoutTimer?.invalidate()
        connectingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.connectingTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.state == .connecting else {
                print("[CONSOLE] Connecting timeout: state=\(self.state.rawValue), nothing to do")
                return
            }
            let usbUp = self.usbTransport.isConnected
            let wifiUp = self.wirelessTransport.isConnected
            if usbUp || wifiUp {
                print("[CONSOLE] Connecting timeout: link up but not streaming yet (usb=\(usbUp), wifi=\(wifiUp)) -- keeping pairing, re-arming")
                Self.log.info("Connecting timeout: link up, not streaming yet; re-arming")
            } else {
                print("[CONSOLE] Connecting timeout: Mac not reached -- keeping pairing (pairedHost=\(self.qrPairing.pairedHost ?? "nil")), restarting discovery")
                Self.log.info("Connecting timeout: Mac not reached; keeping pairing, restarting discovery")
                self.udpReassembler.resetForNewStreamSession(reason: "connecting-timeout")
                self.usbTransport.stopMonitoring()
                self.wirelessTransport.stopBrowsing()
                self.startTransportMonitoring()
            }
            self.startConnectingTimeout()
        }
    }

    /// Disconnect and clean up the session.
    func disconnectSession() {
        Self.log.info("Disconnecting session")
        udpReassembler.resetForNewStreamSession(reason: "disconnect-session")
        flResetLinks(reason: "disconnect-session")
        state = .disconnected
        reconnectTimer?.invalidate()
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        usbTransport.stopMonitoring()
        wirelessTransport.stopBrowsing()
        metalRenderer.stop()

        let transition = TransportFSM.transition(from: currentTransport, on: .disconnected)
        currentTransport = transition.state
    }

    // MARK: - Transport Control (for multi-transport testing)

    /// Disconnect all transports and reset state for a new transport test.
    func disconnectAllTransports() {
        Self.log.info("Disconnecting all transports for transport rotation")
        udpReassembler.resetForNewStreamSession(reason: "disconnect-all-transports")
        flResetLinks(reason: "disconnect-all-transports")
        usbTransport.stopMonitoring()
        wirelessTransport.stopBrowsing()
        latencyProbeTimer?.invalidate()
        fpsUpdateTimer?.invalidate()
        currentTransport = .idle
        state = .connecting
        frameRecvCount = 0
    }

    /// Start only USB NCM transport monitoring (disables wireless).
    func startUSBOnly() {
        Self.log.info("Starting USB NCM only")
        udpReassembler.resetForNewStreamSession(reason: "start-usb-only")
        wirelessTransport.stopBrowsing()
        usbTransport.startMonitoring()
    }

    /// Start only wireless transport browsing (disables USB).
    func startWirelessOnly() {
        Self.log.info("Starting wireless only")
        udpReassembler.resetForNewStreamSession(reason: "start-wireless-only")
        usbTransport.stopMonitoring()
        wirelessTransport.startBrowsing()
    }

    // MARK: - Resolution Match

    /// Send resolution match request to Mac via TCP.
    /// Uses InputEventHeader type=0x21 with iPad screen dimensions payload.
    func requestResolutionMatch() {
        Self.log.info("Sending resolution match request to Mac")

        let timestamp = currentTimestampUs()
        let header = InputEventHeader(type: InputEventType.resMatchRequest.rawValue, tsUs: timestamp)
        var data = header.serialize()

        // Append iPad screen dimensions as ResolutionMatchPayload
        let iPadWidth = UInt32(UIScreen.main.nativeBounds.width)
        let iPadHeight = UInt32(UIScreen.main.nativeBounds.height)
        let payload = ResolutionMatchPayload(iPadWidth: iPadWidth, iPadHeight: iPadHeight)
        data.append(payload.serialize())

        sendInputEventToMac(data)

        hudViewModel.resetAutoHideTimer()
    }

    // MARK: - Peer Address Update

    /// Mac sends its new USB NCM IP before switching from WiFi to USB.
    /// Update the USB transport peer address so reconnection uses the correct IP.
    private func handlePeerAddressUpdate(_ data: Data) {
        let payloadData = data.dropFirst(InputEventHeader.size)
        guard let ipString = String(data: payloadData, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) else {
            return
        }
        guard !ipString.isEmpty else { return }

        print("[CONSOLE] Peer address update from Mac: \(ipString)")
        Self.log.info("Updating USB peer address to \(ipString) (Mac switching to USB NCM)")
        usbTransport.setPeerAddress(ipString)
    }

    // MARK: - Viewport Report

    /// Compute the actual rendered viewport in pixels, matching MetalRenderer.computeViewport logic.
    /// Accounts for letterbox/pillarbox when Mac and iPad aspect ratios differ.
    static func computeViewportPixels(macWidth: Int, macHeight: Int,
                                       screenWidth: Int, screenHeight: Int) -> (width: Int, height: Int) {
        guard macWidth > 0, macHeight > 0, screenWidth > 0, screenHeight > 0 else {
            return (screenWidth, screenHeight)
        }

        let macAspect = Float(macWidth) / Float(macHeight)
        let screenAspect = Float(screenWidth) / Float(screenHeight)

        if macAspect > screenAspect {
            // Mac wider → full iPad width, letterbox top/bottom
            let scale = screenAspect / macAspect
            let vpHeight = Int(Float(screenHeight) * scale)
            // Round to even for HEVC encoder compatibility
            return (screenWidth & ~1, vpHeight & ~1)
        } else if macAspect < screenAspect {
            // Mac taller → full iPad height, pillarbox left/right
            let scale = macAspect / screenAspect
            let vpWidth = Int(Float(screenWidth) * scale)
            return (vpWidth & ~1, screenHeight & ~1)
        } else {
            return (screenWidth & ~1, screenHeight & ~1)
        }
    }

    /// Send viewport dimensions to Mac so it captures/encodes at the right resolution.
    private func sendViewportReport(width: Int, height: Int, link: FLLink? = nil) {
        let header = InputEventHeader(type: InputEventType.viewportReport.rawValue,
                                      tsUs: currentTimestampUs())
        var data = header.serialize()
        let payload = ViewportReportPayload(viewportWidth: UInt32(width),
                                            viewportHeight: UInt32(height))
        data.append(payload.serialize())
        // tla/FrameLoop.tla VpOnHsConn: on the handshake's connection, which the Mac streams on
        // (USB-first could pick a connection the Mac is not using yet, and the viewport is lost).
        if let link {
            let sent = flSend(data, on: link)
            print("[CONSOLE] FL IpadVp link=\(link) sent=\(sent ? 1 : 0) \(width)x\(height)")
            if sent { return }
        }
        sendInputEventToMac(data)
    }

    // MARK: - Private: Transport Monitoring

    private func startTransportMonitoring() {
        // Wire UDPReassembler: delivers complete frames to handleReceivedFrame
        udpReassembler.onFrameReassembled = { [weak self] data in
            self?.handleReceivedFrame(data)
        }
        udpReassembler.onRecoveryNeeded = { [weak self] in
            // The reassembler holds deltas itself until a keyframe; ask the Mac for one on the
            // handshake's connection (KeyRetry), whatever the transport.
            self?.flRequestKey(reason: "reassembler-gap", force: true)
        }

        // Set up USB NCM transport callbacks.
        // USBNetworkTransport gates onInterfaceChanged(true) on having both the
        // interface AND the Mac's link-local peer address, so no artificial delay
        // is needed here. Fire the FSM event immediately.
        usbTransport.onInterfaceChanged = { [weak self] appeared, interface in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("[CONSOLE] USB NCM onInterfaceChanged: appeared=\(appeared), usbConnected=\(self.usbTransport.isConnected), wifiConnected=\(self.wirelessTransport.isConnected)")
                self.handleTransportEvent(appeared ? .wiredAppeared : .wiredDisappeared)
            }
        }

        // USB media arrives via TCP (reliable delivery over USB NCM).
        // UDP/DTLS is confirmed broken for USB NCM media — tested both batch sends
        // and completion-paced sequential sends, both produce black screen.
        // Root cause: USB NCM DTLS path drops data regardless of send pacing.
        // TCP with TCP_NODELAY gives 0% loss at 1ms RTT.
        // handleInputReceived detects MediaFrameHeader and routes to handleReceivedFrame.
        usbTransport.onMediaReceived = nil

        usbTransport.onInputReceivedFrom = { [weak self] data, serial in
            self?.handleInputReceived(data, link: FLLink(usb: true, serial: serial))
        }

        // Set up wireless transport callbacks
        wirelessTransport.onConnectionChanged = { [weak self] connected, isAWDL in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if connected {
                    self.handleTransportEvent(isAWDL ? .awdlAvailable : .wifiAvailable)
                } else {
                    self.handleTransportEvent(isAWDL ? .awdlUnavailable : .wifiUnavailable)
                }
            }
        }

        // Wireless media arrives as UDP chunks -- route through reassembler
        wirelessTransport.onMediaReceived = { [weak self] data in
            self?.udpReassembler.processChunk(data, sourceIsOrdered: false, sourceLabel: "wireless-udp")
        }

        wirelessTransport.onInputReceivedFrom = { [weak self] data, serial in
            self?.handleInputReceived(data, fromWireless: true, link: FLLink(usb: false, serial: serial))
        }

        // Start transports based on launch mode.
        if !isWirelessOnly {
            usbTransport.startMonitoring()
        } else {
            print("[CONSOLE] Wireless-only mode — USB monitoring disabled")
        }

        // Start WiFi browsing unless wired-only mode disables it.
        if !isWiredOnly {
            let wifiDelay: TimeInterval = usbTransport.isConnected ? 0 : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + wifiDelay) { [weak self] in
                guard let self = self else { return }
                if self.isWirelessOnly {
                    print("[CONSOLE] Starting WiFi browsing (wireless-only mode)")
                } else {
                    print("[CONSOLE] Starting WiFi browsing (background fallback)")
                }
                self.wirelessTransport.startBrowsing()
            }
        } else {
            print("[CONSOLE] Wired-only mode — WiFi/AWDL browsing disabled")
        }
    }

    // MARK: - Private: Transport FSM

    private func handleTransportEvent(_ event: TransportEvent) {
        print("[CONSOLE] handleTransportEvent: \(event) (current: \(currentTransport.rawValue))")
        let transition = TransportFSM.transition(from: currentTransport, on: event)

        guard transition.state != currentTransport || !transition.effects.isEmpty else {
            print("[CONSOLE] handleTransportEvent: no state change, skipping")
            return
        }

        print("[CONSOLE] Transport FSM: \(currentTransport.rawValue) -> \(transition.state.rawValue), effects=\(transition.effects)")
        Self.log.info("Transport: \(self.currentTransport.rawValue) -> \(transition.state.rawValue)")
        currentTransport = transition.state

        // Execute effects
        for effect in transition.effects {
            executeTransportEffect(effect)
        }

        // Immediate fallback: when transitioning to .disconnected, check if the
        // alternate transport is still connected and switch to it immediately.
        // This avoids the reconnect/backoff cycle and keeps streaming uninterrupted.
        if transition.state == .disconnected && state == .streaming {
            if wirelessTransport.isConnected {
                let awdl = wirelessTransport.isAWDL
                print("[CONSOLE] Immediate wireless fallback — wireless still connected (AWDL=\(awdl)), switching directly")
                DispatchQueue.main.async {
                    self.hudViewModel.flashTransportChange(to: .disconnected)
                }
                handleTransportEvent(awdl ? .awdlAvailable : .wifiAvailable)
                return
            }
            if usbTransport.isConnected {
                print("[CONSOLE] Immediate USB fallback — USB still connected, switching directly")
                DispatchQueue.main.async {
                    self.hudViewModel.flashTransportChange(to: .disconnected)
                }
                handleTransportEvent(.wiredAppeared)
                return
            }
        }

        // Update session state based on transport
        switch transition.state {
        case .usbNCM, .wifi, .awdl:
            if state == .reconnecting || state == .connecting {
                // Don't transition to streaming yet -- wait for handshake
                Self.log.info("Transport connected, awaiting handshake")
            }
            // E2E test: report transport detection
            testRunner?.reportTransportDetected(type: transition.state.rawValue)
        case .disconnected:
            if state == .streaming {
                state = .reconnecting
                latencyProbeTimer?.invalidate()
                scheduleReconnect()
            }
        case .idle:
            break
        }

        // Flash HUD on transport change
        DispatchQueue.main.async {
            self.hudViewModel.flashTransportChange(to: transition.state)
        }
    }

    private func executeTransportEffect(_ effect: TransportEffect) {
        switch effect {
        case .bindUSBNCM:
            print("[CONSOLE] Effect: bind USB NCM — starting USB monitoring")
            usbTransport.startMonitoring()
        case .connectWiFi:
            print("[CONSOLE] Effect: connect Wi-Fi — starting Bonjour browse")
            wirelessTransport.startBrowsing()
        case .connectAWDL:
            print("[CONSOLE] Effect: connect AWDL — starting Bonjour browse (p2p)")
            wirelessTransport.startBrowsing()
        case .disconnectCurrent:
            // No-op: keep both transports alive for instant fallback.
            // USB and WiFi connections persist across transport switches.
            // The Mac side is already a no-op here. Data routing is handled by
            // sendInputEventToMac (checks usbTransport.isConnected first).
            print("[CONSOLE] Effect: disconnectCurrent — no-op, keeping transports alive for fallback")
        case .switchEncodeLZ4:
            Self.log.info("Effect: switch to LZ4 decode path")
            hudViewModel.isEcoMode = false
        case .switchEncodeHEVC:
            Self.log.info("Effect: switch to HEVC decode path")
        case .notifyTransportChange:
            Self.log.info("Effect: notify transport change")
        }
    }

    // MARK: - Private: Frame Receive Pipeline

    /// Handle a received media frame from either transport.
    ///
    /// 1. Parse MediaFrameHeader (25 bytes).
    /// 2. Validate magic.
    /// 3. Route to HEVC or LZ4 decoder.
    /// 4. Send decoded pixels to MetalRenderer.
    private func handleReceivedFrame(_ data: Data) {
        guard data.count > MediaFrameHeader.size else {
            print("[CONSOLE] handleReceivedFrame: too small (\(data.count) bytes)")
            return
        }

        // Parse header
        guard let header = MediaFrameHeader.parse(from: data) else {
            print("[CONSOLE] handleReceivedFrame: magic mismatch")
            return
        }

        let payloadOffset = MediaFrameHeader.size
        let payloadLength = data.count - payloadOffset

        frameRecvCount += 1
        testRunner?.noteReceivedFrameHeader(header)
        let receiveNowUs = keydrdHostTimeUs()
        let interArrivalMs: Double = lastFrameReceiveUs > 0
            ? Double(Int64(receiveNowUs) - Int64(lastFrameReceiveUs)) / 1_000.0
            : 0.0
        let seqDelta = lastFrameReceiveUs > 0
            ? Int((Int(header.seq) - Int(lastFrameReceiveSeq) + 65536) % 65536)
            : 0
        let rendererStats = metalRenderer.statsSnapshot()
        let reassemblyStats = udpReassembler.statsSnapshot()
        frameArrivalLogCount += 1
        let starvationSignal = lastFrameReceiveUs > 0 &&
            interArrivalMs >= 35.0 &&
            !rendererStats.hasPendingFrame &&
            rendererStats.pendingDepth == 0 &&
            reassemblyStats.pendingFrames == 0
        if starvationSignal || seqDelta > 1 || frameArrivalLogCount <= 10 || frameArrivalLogCount % 240 == 0 {
            print("[CONSOLE] SessionManager: frame-arrival seq=\(header.seq) prevSeq=\(lastFrameReceiveSeq) seqDelta=\(seqDelta) interArrival=\(String(format: "%.2f", interArrivalMs))ms payload=\(payloadLength)B transport=\(currentTransport.rawValue) rendererPending=\(rendererStats.hasPendingFrame ? 1 : 0) rendererDepth=\(rendererStats.pendingDepth) reasmPending=\(reassemblyStats.pendingFrames) reasmOOO=\(reassemblyStats.outOfOrderBuffered) state=\(state.rawValue) starvationSignal=\(starvationSignal)")
        }
        lastFrameReceiveUs = receiveNowUs
        lastFrameReceiveSeq = header.seq

        // Pipeline latency probe: capture → iPad receive (before decode)
        if header.tsUs > 0 {
            let nowUs = receiveNowUs
            let recvElapsedMs = (Int64(nowUs) - Int64(header.tsUs) + (testRunner?.clockOffsetForProbe ?? 0)) / 1000
            if frameRecvCount <= 10 || frameRecvCount % 100 == 0 {
                if testRunner?.clockOffsetCalibratedForLogging == true {
                    print("[CONSOLE] LATENCY-PROBE ipad-recv: \(recvElapsedMs)ms since capture (seq=\(header.seq))")
                } else {
                    print("[CONSOLE] LATENCY-PROBE ipad-recv: pending clock sync (seq=\(header.seq), captureTsUs=\(header.tsUs), nowUs=\(nowUs))")
                }
            }
        }

        if frameRecvCount <= 3 {
            print("[CONSOLE] handleReceivedFrame: seq=\(header.seq) flags=0x\(String(header.flags, radix: 16)) payload=\(payloadLength) isHEVC=\(header.isHEVC) isKey=\(header.isKeyframe)")
        }

        // tla/FrameLoop.tla KeyOnBreak/AwaitOnFail: after a handshake or a failed decode, no
        // delta is decoded until a keyframe is.
        guard let flFrameGen = flAdmitForDecode(header) else { return }

        // Route to decoder based on flags
        let decodeStart = CACurrentMediaTime()
        if header.isHEVC {
            // HEVC decode path (wireless/eco mode)
            let decodeSubmitUs = keydrdHostTimeUs()
            let decodeResult = hevcDecoder.decode(frameData: data,
                                                  payloadOffset: payloadOffset,
                                                  payloadLength: payloadLength,
                                                  header: header)
            let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000.0
            switch decodeResult {
            case .decoded(let pixelBuffer):
                scheduleDecodedHEVCFrame(pixelBuffer,
                                         header: header,
                                         payloadLength: payloadLength,
                                         decodeMs: decodeMs,
                                         source: "decode-inline",
                                         decodeSubmitUs: decodeSubmitUs,
                                         decodeDoneUs: keydrdHostTimeUs())
            case .deferred:
                if frameRecvCount <= 10 || frameRecvCount % 240 == 0 || decodeMs > 6.0 {
                    print("[CONSOLE] USBTransport: frame-pipeline seq=\(header.seq) transport=\(currentTransport.rawValue) hevc=true payload=\(payloadLength)B decodeMs=\(String(format: "%.2f", decodeMs)) recvCount=\(frameRecvCount) status=deferred")
                }
                return
            case .failed:
                flDecodeFailed(gen: flFrameGen, seq: header.seq, reason: "hevc-submit-failed")
                testRunner?.noteHEVCDecodeFailure(seq: header.seq)
                if frameRecvCount <= 5 {
                    print("[CONSOLE] handleReceivedFrame: HEVC decode FAILED for seq=\(header.seq)")
                }
                return
            }
        } else {
            // LZ4 decode path (wired mode)
            guard let decompressor = lz4Decompressor else {
                Self.log.error("LZ4 decompressor not initialized (no handshake yet)")
                flDecodeFailed(gen: flFrameGen, seq: header.seq, reason: "lz4-no-decompressor")
                return
            }

            let frameBytes = macDisplayWidth * macDisplayHeight * 4
            // Safety: skip frames where dimensions don't match decompressor buffer
            guard frameBytes > 0, frameBytes <= decompressor.frameBytes else {
                if frameRecvCount <= 20 || frameRecvCount % 500 == 0 {
                    print("[CONSOLE] LZ4: skipping frame, frameBytes=\(frameBytes) bufCap=\(decompressor.frameBytes) macDims=\(macDisplayWidth)x\(macDisplayHeight)")
                }
                flDecodeFailed(gen: flFrameGen, seq: header.seq, reason: "lz4-size-mismatch")
                return
            }

            guard let pixels = decompressor.decompress(frameData: data,
                                                       payloadOffset: payloadOffset,
                                                       payloadLength: payloadLength,
                                                       header: header,
                                                       frameBytes: frameBytes) else {
                if frameRecvCount <= 20 || frameRecvCount % 500 == 0 {
                    print("[CONSOLE] LZ4: decompress returned nil, frameBytes=\(frameBytes) payload=\(payloadLength) seq=\(header.seq)")
                }
                flDecodeFailed(gen: flFrameGen, seq: header.seq, reason: "lz4-decompress-nil")
                return
            }

            // End-to-end picture check: same sampled hash the Mac logs pre-compress (FRAME-HASH mac).
            if header.seq % 30 == 0 {
                let h = frame_sample_hash(pixels, frameBytes)
                print("[CONSOLE] FRAME-HASH ipad seq=\(header.seq) hash=\(String(format: "%016llx", h))")
            }

            // Report decoded dimensions for resolution test
            testRunner?.reportDecodedFrameDimensions(width: macDisplayWidth, height: macDisplayHeight)

            metalRenderer.updateFrame(pixels, width: macDisplayWidth, height: macDisplayHeight, captureTimestampUs: header.tsUs)
            let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000.0
            if frameRecvCount <= 10 || frameRecvCount % 240 == 0 || decodeMs > 6.0 {
                print("[CONSOLE] USBTransport: frame-pipeline seq=\(header.seq) transport=\(currentTransport.rawValue) hevc=false payload=\(payloadLength)B decodeMs=\(String(format: "%.2f", decodeMs)) recvCount=\(frameRecvCount)")
            }
            let decompressedSize = frameBytes
            // Record frame timestamp for FPS calculation
            recordFrameTimestamp()

            if !hasRenderedFrameInCurrentSession {
                DispatchQueue.main.async {
                    self.hasRenderedFrameInCurrentSession = true
                }
            }

            // E2E test: report frame received + decompressed
            testRunner?.reportFrameReceived(header: header, decompressedSize: decompressedSize)

            // Transition to streaming on first frame
            if state == .connecting || state == .reconnecting {
                print("[CONSOLE] LC IpadFrame from=\(state.rawValue) -> streaming (frame before handshake)")
                DispatchQueue.main.async {
                    self.state = .streaming
                    self.reconnectAttempt = 0
                    self.hudViewModel.show()
                }
            }
        }
    }

    private func scheduleDecodedHEVCFrame(_ pixelBuffer: CVPixelBuffer,
                                          header: MediaFrameHeader,
                                          payloadLength: Int,
                                          decodeMs: Double?,
                                          source: String,
                                          decodeSubmitUs: UInt64,
                                          decodeDoneUs: UInt64) {
        // AwaitOnFail: a decode error (or a new handshake) since this frame was submitted means
        // its picture rests on a broken chain; drop it.
        guard flIsCurrentHEVCOutput(seq: header.seq) else {
            flStaleOutputs += 1
            if flStaleOutputs <= 10 || flStaleOutputs % 120 == 0 {
                print("[CONSOLE] FL IpadStaleOutput seq=\(header.seq) source=\(source) count=\(flStaleOutputs)")
            }
            return
        }
        FrameTimeline.shared.decoded(tsUs: header.tsUs, submitUs: decodeSubmitUs, doneUs: decodeDoneUs)
        let scheduleUs = keydrdHostTimeUs()
        hevcHandoffQueue.async { [weak self] in
            guard let self else { return }
            let queueWaitMs = Double(Int64(keydrdHostTimeUs()) - Int64(scheduleUs)) / 1_000.0
            if queueWaitMs >= 10.0 || self.frameRecvCount <= 10 || self.frameRecvCount % 240 == 0 {
                print("[CONSOLE] SessionManager: hevc-handoff queue-enter seq=\(header.seq) source=\(source) queueWait=\(String(format: "%.2f", queueWaitMs))ms state=\(self.state.rawValue)")
            }
            self.handleDecodedHEVCFrame(pixelBuffer,
                                        header: header,
                                        payloadLength: payloadLength,
                                        decodeMs: decodeMs,
                                        source: source,
                                        decodeSubmitUs: decodeSubmitUs,
                                        decodeDoneUs: decodeDoneUs)
        }
    }

    private func handleDecodedHEVCFrame(_ pixelBuffer: CVPixelBuffer,
                                        header: MediaFrameHeader,
                                        payloadLength: Int,
                                        decodeMs: Double?,
                                        source: String,
                                        decodeSubmitUs: UInt64,
                                        decodeDoneUs: UInt64) {
        let decompressedSize = CVPixelBufferGetDataSize(pixelBuffer)
        if frameRecvCount <= 3 {
            if let decodeMs {
                print("[CONSOLE] handleReceivedFrame: HEVC decoded OK, \(decompressedSize) bytes, decode=\(String(format: "%.1f", decodeMs))ms source=\(source)")
            } else {
                print("[CONSOLE] handleReceivedFrame: HEVC decoded OK, \(decompressedSize) bytes, source=\(source)")
            }
        }

        // Report decoded dimensions for resolution test
        let decodedW = CVPixelBufferGetWidth(pixelBuffer)
        let decodedH = CVPixelBufferGetHeight(pixelBuffer)
        testRunner?.reportDecodedFrameDimensions(width: decodedW, height: decodedH)

        let enqueueStartUs = keydrdHostTimeUs()
        hevcHandoffTraceLock.lock()
        hevcHandoffTraceByCaptureTs[header.tsUs] = HEVCHandoffTrace(seq: header.seq,
                                                                    source: source,
                                                                    transport: currentTransport.rawValue,
                                                                    decodeSubmitUs: decodeSubmitUs,
                                                                    decodeDoneUs: decodeDoneUs,
                                                                    enqueueUs: enqueueStartUs,
                                                                    decodeMs: decodeMs,
                                                                    stateAtDecode: state.rawValue)
        if hevcHandoffTraceByCaptureTs.count > 256 {
            let oldestKeys = hevcHandoffTraceByCaptureTs.keys.sorted().prefix(64)
            for key in oldestKeys {
                hevcHandoffTraceByCaptureTs.removeValue(forKey: key)
            }
        }
        hevcHandoffTraceLock.unlock()

        // Zero-copy: pass CVPixelBuffer directly to Metal via IOSurface
        metalRenderer.updateFrameFromPixelBuffer(pixelBuffer, captureTimestampUs: header.tsUs)
        let enqueueDoneUs = keydrdHostTimeUs()
        hevcHandoffLogCount += 1
        let enqueueMs = Double(Int64(enqueueDoneUs) - Int64(enqueueStartUs)) / 1_000.0
        let decodeMsLabel = decodeMs.map { String(format: "%.2f", $0) } ?? "n/a"
        if enqueueMs >= 4.0 || hevcHandoffLogCount <= 10 || hevcHandoffLogCount % 240 == 0 {
            print("[CONSOLE] SessionManager: hevc-handoff enqueue seq=\(header.seq) source=\(source) state=\(state.rawValue) transport=\(currentTransport.rawValue) decodeToEnqueue=\(String(format: "%.2f", Double(Int64(enqueueStartUs) - Int64(decodeDoneUs)) / 1_000.0))ms enqueueCost=\(String(format: "%.2f", enqueueMs))ms decodeMs=\(decodeMsLabel)")
        }

        if let decodeMs {
            if frameRecvCount <= 10 || frameRecvCount % 240 == 0 || decodeMs > 6.0 {
                print("[CONSOLE] USBTransport: frame-pipeline seq=\(header.seq) transport=\(currentTransport.rawValue) hevc=true payload=\(payloadLength)B decodeMs=\(String(format: "%.2f", decodeMs)) recvCount=\(frameRecvCount) status=decoded source=\(source)")
            }
        } else if frameRecvCount <= 10 || frameRecvCount % 240 == 0 {
            print("[CONSOLE] USBTransport: frame-pipeline-async seq=\(header.seq) transport=\(currentTransport.rawValue) hevc=true payload=\(payloadLength)B recvCount=\(frameRecvCount) source=\(source)")
        }

        // Record frame timestamp for FPS calculation
        recordFrameTimestamp()

        if !hasRenderedFrameInCurrentSession {
            DispatchQueue.main.async {
                self.hasRenderedFrameInCurrentSession = true
            }
        }

        // E2E test: report frame received + decompressed
        testRunner?.reportFrameReceived(header: header, decompressedSize: decompressedSize)

        // Transition to streaming on first frame
        if state == .connecting || state == .reconnecting {
            print("[CONSOLE] LC IpadFrame from=\(state.rawValue) -> streaming (frame before handshake, HEVC/TCP)")
            DispatchQueue.main.async {
                self.state = .streaming
                self.reconnectAttempt = 0
                self.hudViewModel.show()
            }
        }
    }

    private func logHEVCHandoffDequeue(captureTsUs: UInt64,
                                       enqueuedAtUs: UInt64,
                                       dequeuedAtUs: UInt64,
                                       queueDelayMs: Double,
                                       pendingBefore: Int,
                                       pendingAfter: Int,
                                       mode: String) {
        hevcHandoffTraceLock.lock()
        guard let trace = hevcHandoffTraceByCaptureTs[captureTsUs] else {
            hevcHandoffTraceLock.unlock()
            return
        }
        hevcHandoffTraceLock.unlock()
        hevcHandoffTraceLock.lock()
        hevcRenderTraceByCaptureTs[captureTsUs] = HEVCRenderTrace(dequeuedAtUs: dequeuedAtUs,
                                                                  queueDelayMs: queueDelayMs,
                                                                  pendingBefore: pendingBefore,
                                                                  pendingAfter: pendingAfter,
                                                                  mode: mode)
        if hevcRenderTraceByCaptureTs.count > 256 {
            let oldestKeys = hevcRenderTraceByCaptureTs.keys.sorted().prefix(64)
            for key in oldestKeys {
                hevcRenderTraceByCaptureTs.removeValue(forKey: key)
            }
        }
        hevcHandoffTraceLock.unlock()
        let submitToDequeueMs = Double(Int64(dequeuedAtUs) - Int64(trace.decodeSubmitUs)) / 1_000.0
        let decodeToDequeueMs = Double(Int64(dequeuedAtUs) - Int64(trace.decodeDoneUs)) / 1_000.0
        if queueDelayMs >= 20.0 || pendingBefore >= 4 || trace.seq % 240 == 0 {
            let enqueueToDequeueMs = Double(Int64(dequeuedAtUs) - Int64(enqueuedAtUs)) / 1_000.0
            print("[CONSOLE] SessionManager: hevc-handoff dequeue seq=\(trace.seq) source=\(trace.source) mode=\(mode) state=\(state.rawValue) stateAtDecode=\(trace.stateAtDecode) transport=\(trace.transport) pending=\(pendingBefore)->\(pendingAfter) queueDelay=\(String(format: "%.2f", queueDelayMs))ms enqueueToDequeue=\(String(format: "%.2f", enqueueToDequeueMs))ms decodeToDequeue=\(String(format: "%.2f", decodeToDequeueMs))ms submitToDequeue=\(String(format: "%.2f", submitToDequeueMs))ms")
        }
    }

    private func logHEVCHandoffPresent(captureTsUs: UInt64,
                                       completionUs: UInt64,
                                       queueDelayMs: Double,
                                       gpuRoundtripMs: Double,
                                       mode: String) {
        hevcHandoffTraceLock.lock()
        guard let trace = hevcHandoffTraceByCaptureTs.removeValue(forKey: captureTsUs) else {
            hevcHandoffTraceLock.unlock()
            return
        }
        let renderTrace = hevcRenderTraceByCaptureTs.removeValue(forKey: captureTsUs)
        hevcHandoffTraceLock.unlock()
        let submitToPresentMs = Double(Int64(completionUs) - Int64(trace.decodeSubmitUs)) / 1_000.0
        let decodeToPresentMs = Double(Int64(completionUs) - Int64(trace.decodeDoneUs)) / 1_000.0
        let enqueueToPresentMs = Double(Int64(completionUs) - Int64(trace.enqueueUs)) / 1_000.0
        let dequeueToPresentMs: Double
        if let renderTrace {
            dequeueToPresentMs = Double(Int64(completionUs) - Int64(renderTrace.dequeuedAtUs)) / 1_000.0
        } else {
            dequeueToPresentMs = max(0.0, submitToPresentMs - enqueueToPresentMs)
        }
        let postDequeuePipelineMs = max(0.0, submitToPresentMs - queueDelayMs)
        if submitToPresentMs >= 40.0 || queueDelayMs >= 20.0 || dequeueToPresentMs >= 16.0 || trace.seq % 240 == 0 {
            let pendingLabel: String
            if let renderTrace {
                pendingLabel = "\(renderTrace.pendingBefore)->\(renderTrace.pendingAfter)"
            } else {
                pendingLabel = "n/a"
            }
            let dequeueMode = renderTrace?.mode ?? mode
            print("[CONSOLE] SessionManager: hevc-handoff present seq=\(trace.seq) source=\(trace.source) mode=\(dequeueMode) state=\(state.rawValue) pending=\(pendingLabel) submitToPresent=\(String(format: "%.2f", submitToPresentMs))ms decodeToPresent=\(String(format: "%.2f", decodeToPresentMs))ms enqueueToPresent=\(String(format: "%.2f", enqueueToPresentMs))ms dequeueToPresent=\(String(format: "%.2f", dequeueToPresentMs))ms queueDelay=\(String(format: "%.2f", queueDelayMs))ms postDequeuePipeline=\(String(format: "%.2f", postDequeuePipelineMs))ms gpuRoundtrip=\(String(format: "%.2f", gpuRoundtripMs))ms")
        }
    }

    /// Handle session handshake from Mac.
    /// Configures viewport, decompressor, and HUD before first frame.
    private func handleSessionHandshake(_ handshake: SessionHandshakeMessage, link: FLLink) {
        Self.log.info("Session handshake: \(handshake.displayWidth)x\(handshake.displayHeight)@\(handshake.scaleFactor)x, maxFps=\(handshake.maxFps)")

        let hsW = Int(handshake.displayWidth), hsH = Int(handshake.displayHeight)
        macScaleFactor = handshake.scaleFactor
        // A repeat handshake for the same Mac display (a route change, a session restart) keeps
        // the frame geometry the Mac last set with a geometry update: the keyframe the handshake
        // owes may arrive before the next geometry update, and must decode at the current size.
        if let last = lastHandshakeDisplay, last.w == hsW, last.h == hsH, lz4Decompressor != nil {
            print("[CONSOLE] FL IpadHsGeometry kept=\(macDisplayWidth)x\(macDisplayHeight) display=\(hsW)x\(hsH)")
        } else {
            macDisplayWidth = hsW
            macDisplayHeight = hsH

            // Initialize LZ4 decompressor with frame size
            let frameBytes = macDisplayWidth * macDisplayHeight * 4
            lz4Decompressor = LZ4Decompressor(frameBytes: frameBytes)

            // Configure renderer viewport
            metalRenderer.setMacDisplaySize(width: macDisplayWidth, height: macDisplayHeight)
            print("[CONSOLE] FL IpadHsGeometry set=\(hsW)x\(hsH)")
        }
        lastHandshakeDisplay = (hsW, hsH)

        // Compute viewport pixel dimensions and tell Mac to capture/encode at this size.
        // This avoids encoding pixels the iPad can't display (e.g. 3600x2338 → 2752x1787).
        let iPadPixelWidth = Int(UIScreen.main.nativeBounds.width)
        let iPadPixelHeight = Int(UIScreen.main.nativeBounds.height)
        // nativeBounds is portrait-locked; use landscape (wider dimension first)
        let screenW = max(iPadPixelWidth, iPadPixelHeight)
        let screenH = min(iPadPixelWidth, iPadPixelHeight)

        let (vpW, vpH) = Self.computeViewportPixels(
            macWidth: hsW, macHeight: hsH,
            screenWidth: screenW, screenHeight: screenH
        )
        // Store for E2E test verification
        viewportWidth = vpW
        viewportHeight = vpH

        sendViewportReport(width: vpW, height: vpH, link: link)

        // Input: geometry for pointer mapping, then HELD on this new connection (InputPath Connect).
        let sender = inputSender
        let w = hsW, h = hsH  // the Mac display (only its aspect ratio maps touches)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sender.send = { [weak self] data in self?.sendInputEventReturningLink(data) }
            sender.macDisplaySize = CGSize(width: w, height: h)
            sender.connectionEstablished(link: self.currentInputLink)
        }
        Self.log.info("Sent viewport report: \(vpW)x\(vpH) (iPad screen: \(screenW)x\(screenH), Mac: \(self.macDisplayWidth)x\(self.macDisplayHeight))")

        // Update HUD with resolution info
        DispatchQueue.main.async {
            self.hudViewModel.updateResolution(
                macWidth: self.macDisplayWidth,
                macHeight: self.macDisplayHeight,
                iPadWidth: screenW,
                iPadHeight: screenH
            )
        }

        // Start latency probe timer
        startLatencyProbeTimer()

        // Start FPS update timer
        startFPSUpdateTimer()

        print("[CONSOLE] LC IpadHandshake from=\(state.rawValue) -> streaming")
        state = .streaming
        DispatchQueue.main.async {
            print("[CONSOLE] Session handshake complete; forcing HUD visible")
            self.hudViewModel.show()
        }

        // E2E test: report handshake
        testRunner?.reportSessionHandshake(handshake)
    }

    /// Render a CVPixelBuffer from HEVC decode to Metal.
    private func renderCVPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)

        metalRenderer.updateFrame(UnsafeRawPointer(baseAddress),
                                   width: actualWidth,
                                   height: actualHeight)
    }

    // MARK: - Private: Input Event Handling (from Mac)

    /// Handle input data received from Mac (handshakes, latency probes, control messages).
    /// Media frames primarily arrive via UDP chunks, but oversized frames fall back to TCP.
    private var wirelessLZ4Dropped = 0

    private func handleInputReceived(_ data: Data, fromWireless: Bool = false, link: FLLink) {
        // Check handshake FIRST — both handshake and media frame share KEYDRD_MAGIC,
        // but handshake has a more specific discriminator (magic + msgType at offset 2)
        if let handshake = SessionHandshakeMessage.parse(from: data) {
            print("[CONSOLE] handleInputReceived: parsed as SESSION HANDSHAKE \(handshake.displayWidth)x\(handshake.displayHeight) link=\(link)")
            // tla/FrameLoop.tla HsConn + EpochMonotone: only a handshake with a newer epoch counts
            // (a late one from a replaced connection, or a relaunched Mac's lower epoch, would
            // otherwise move media back to a dead or stale connection).
            guard flAcceptHandshake(epoch: handshake.reserved, link: link) else { return }
            udpReassembler.resetForNewStreamSession(reason: "fl-handshake")
            handleSessionHandshake(handshake, link: link)
            return
        }

        // Check if this is a media frame sent over TCP (fallback for large HEVC
        // frames) or over UDP. Route all HEVC frames through the reassembler so
        // single-chunk, multi-chunk, and TCP-fallback delivery all share one
        // sequencing path.
        if data.count >= MediaFrameHeader.size,
           let mediaHeader = MediaFrameHeader.parse(from: data) {
            // tla/DeltaSync.tla DropOldLink: LZ4 frames are valid only on the USB connection.
            // One that arrives over wireless was compressed before USB connected (seen
            // 2026-11-16: the switch keyframe reached the iPad over AWDL after USB deltas and
            // reset the reference to an older frame).
            if fromWireless && !mediaHeader.isHEVC {
                wirelessLZ4Dropped += 1
                print("[CONSOLE] LZ4 over wireless dropped seq=\(mediaHeader.seq) key=\(mediaHeader.isKeyframe) bytes=\(data.count) total=\(wirelessLZ4Dropped)")
                return
            }
            FrameTimeline.shared.frameComplete(mediaHeader, bytes: data.count)
            if mediaHeader.isHEVC && mediaHeader.chunkTotal <= 1 &&
                wirelessTransport.isConnected && !usbTransport.isConnected {
                sendFrameAck(seq: mediaHeader.seq)
            }
            // tla/FrameLoop.tla HsConn: media only from the handshake's connection. (The ack
            // above stays ahead of this filter: it measures the network, not the picture.)
            guard flIsHsLink(link) else {
                flForeignDrops += 1
                if flForeignDrops <= 10 || flForeignDrops % 120 == 0 {
                    print("[CONSOLE] FL IpadForeign seq=\(mediaHeader.seq) key=\(mediaHeader.isKeyframe) link=\(link) hsLink=\(flHsLinkDescription) count=\(flForeignDrops)")
                }
                return
            }
            if mediaHeader.chunkTotal > 1 || mediaHeader.isHEVC {
                if mediaHeader.chunkTotal > 1 && !mediaHeader.isHEVC {
                    print("[CONSOLE] handleInputReceived: routing chunked non-HEVC frame via reassembler seq=\(mediaHeader.seq) chunk=\(mediaHeader.chunkIdx + 1)/\(mediaHeader.chunkTotal)")
                }
                let sourceLabel = wirelessTransport.isConnected && !usbTransport.isConnected ? "wireless-tcp-media" : "input-tcp-media"
                udpReassembler.processChunk(data, sourceIsOrdered: true, sourceLabel: sourceLabel)
            } else {
                handleReceivedFrame(data)
            }
            return
        }

        // Parse as InputEventHeader
        guard let header = InputEventHeader.parse(from: data) else { return }

        switch header.type {
        case 0x28:  // KEYDRD_INPUT_TEST_FILLER (test mode bandwidth probe)
            testRunner?.noteBandwidthFiller(bytes: data.count + 4, atUs: keydrdHostTimeUs())

        case 0x27:  // KEYDRD_INPUT_TEST_REPORT (test mode)
            testRunner?.reportInputTestReply(data)

        case InputEventType.latencyProbe.rawValue:
            handleLatencyProbeResponse(header)

        case InputEventType.clockSyncResp.rawValue:
            handleClockSyncResponse(data)

        case InputEventType.modeChange.rawValue:
            handleModeChangeFromMac(data)

        case InputEventType.resMatchResponse.rawValue:
            handleResolutionMatchResponse(data)

        case InputEventType.geometryUpdate.rawValue:
            handleGeometryUpdate(data)

        case 0x25: // KEYDRD_INPUT_PEER_ADDRESS_UPDATE
            handlePeerAddressUpdate(data)

        default:
            Self.log.debug("Unhandled input event type: 0x\(String(header.type, radix: 16))")
        }
    }

    // MARK: - Private: Latency Probe

    private func startLatencyProbeTimer() {
        DispatchQueue.main.async {
            self.latencyProbeTimer?.invalidate()
            print("[CONSOLE] startLatencyProbeTimer: scheduling on main run loop, state=\(self.state.rawValue), interval=\(Self.latencyProbeInterval)s")
            let timer = Timer(timeInterval: Self.latencyProbeInterval, repeats: true) { [weak self] _ in
                self?.sendLatencyProbe()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.latencyProbeTimer = timer
        }
    }

    /// Send a latency probe to Mac. Mac echoes it back immediately.
    /// Round-trip time / 2 = one-way latency estimate.
    private func sendLatencyProbe() {
        guard state == .streaming else {
            print("[CONSOLE] sendLatencyProbe: skipped, state=\(state.rawValue)")
            return
        }

        let timestamp = currentTimestampUs()
        let header = InputEventHeader(type: InputEventType.latencyProbe.rawValue, tsUs: timestamp)
        let data = header.serialize()
        print("[CONSOLE] sendLatencyProbe: sending tsUs=\(timestamp), usbConnected=\(usbTransport.isConnected), wifiConnected=\(wirelessTransport.isConnected)")
        sendInputEventToMac(data)
    }

    /// Handle echoed latency probe from Mac.
    private func handleLatencyProbeResponse(_ header: InputEventHeader) {
        let now = currentTimestampUs()
        // An echo can never be newer than now; a misframed message can. Unsigned
        // subtraction would trap (SIGTRAP crash on 2026-11-15), so drop it instead.
        guard header.tsUs <= now else {
            print("[CONSOLE] handleLatencyProbeResponse: DROPPED invalid echo sent=\(header.tsUs) > now=\(now)")
            return
        }
        let roundTripUs = now - header.tsUs
        let oneWayMs = Int(roundTripUs / 2000)  // microseconds -> milliseconds, halved

        print("[CONSOLE] handleLatencyProbeResponse: now=\(now), sent=\(header.tsUs), rttUs=\(roundTripUs), oneWayMs=\(oneWayMs)")

        DispatchQueue.main.async {
            self.hudViewModel.updateLatency(oneWayMs)
        }

        // E2E test: report latency probe response
        testRunner?.reportLatencyProbeResponse(rttUs: roundTripUs)
    }

    // MARK: - Private: Clock Sync (Cristian's Algorithm)

    /// Handle clock sync response from Mac. Routes to test runner for offset calibration.
    private func handleClockSyncResponse(_ data: Data) {
        // t4: iPad receive host time (immediately on arrival)
        let t4Us = keydrdHostTimeUs()

        // Parse payload after 9-byte InputEventHeader
        let payloadData = data.dropFirst(InputEventHeader.size)
        guard let resp = ClockSyncResponse.parse(from: Data(payloadData)) else { return }

        testRunner?.reportClockSyncResponse(t1Us: resp.t1iPadUs, t2Us: resp.t2MacUs,
                                            t3Us: resp.t3MacUs, t4Us: t4Us)
    }

    // MARK: - Private: Mode Change from Mac

    private func handleModeChangeFromMac(_ data: Data) {
        Self.log.info("Received mode change notification from Mac")
        // Transport change -- HUD flashes transport color
        // The actual transport state is already updated via the FSM
        // This notification is for informational HUD purposes
    }

    // MARK: - Private: Resolution Match Response

    private func handleResolutionMatchResponse(_ data: Data) {
        guard let response = ResolutionMatchResponse.parse(
            from: data, offset: InputEventHeader.size
        ) else {
            Self.log.error("Failed to parse resolution match response")
            return
        }

        let result = ResolutionMatchResult(rawValue: response.result)
        switch result {
        case .ok:
            Self.log.info("Resolution match succeeded: \(response.newWidth)x\(response.newHeight)@\(response.newScale)x")
        case .failed:
            Self.log.error("Resolution match failed")
        case .noMode:
            Self.log.info("No suitable display mode found for iPad aspect ratio")
        case .none:
            Self.log.error("Unknown resolution match result: \(response.result)")
        }
    }

    // MARK: - Private: Geometry Update

    private func handleGeometryUpdate(_ data: Data) {
        guard let geo = GeometryUpdatePayload.parse(
            from: data, offset: InputEventHeader.size
        ) else {
            Self.log.error("Failed to parse geometry update")
            return
        }

        let oldW = macDisplayWidth
        let oldH = macDisplayHeight

        macDisplayWidth = Int(geo.displayWidth)
        macDisplayHeight = Int(geo.displayHeight)
        macScaleFactor = geo.scaleFactor

        print("[CONSOLE] Geometry update: \(oldW)x\(oldH) -> \(macDisplayWidth)x\(macDisplayHeight)@\(macScaleFactor)x")
        Self.log.info("Geometry update: \(geo.displayWidth)x\(geo.displayHeight)@\(geo.scaleFactor)x")

        // Only GROW the LZ4 decompressor buffer, never shrink.
        // During transport rotation, stale frames at the old (larger) size may still
        // be in transit. Shrinking the buffer causes LZ4_decompress_safe to overrun → crash.
        let newFrameBytes = macDisplayWidth * macDisplayHeight * 4
        if let existing = lz4Decompressor {
            if newFrameBytes > existing.frameBytes {
                print("[CONSOLE] LZ4 decompressor: growing buffer \(existing.frameBytes) -> \(newFrameBytes)")
                lz4Decompressor = LZ4Decompressor(frameBytes: newFrameBytes)
            }
        } else {
            lz4Decompressor = LZ4Decompressor(frameBytes: newFrameBytes)
        }

        // Recalculate MetalRenderer viewport with new Mac dimensions.
        // This uses the actual capture dimensions from Mac (which may differ slightly
        // from the viewport we reported, e.g. after display mode match).
        metalRenderer.setMacDisplaySize(width: macDisplayWidth, height: macDisplayHeight)

        // Update stored viewport dimensions to match the new capture dims.
        // Do NOT send a new viewport report back to Mac — that would create a loop.
        // The Mac has already matched its display mode and is encoding at these dims.
        viewportWidth = macDisplayWidth
        viewportHeight = macDisplayHeight

        // Update HUD resolution display
        DispatchQueue.main.async {
            self.hudViewModel.updateResolution(
                macWidth: self.macDisplayWidth,
                macHeight: self.macDisplayHeight,
                iPadWidth: Int(UIScreen.main.nativeBounds.width),
                iPadHeight: Int(UIScreen.main.nativeBounds.height)
            )
        }
    }

    // MARK: - Private: FPS Counter (rolling window)

    /// Record a frame arrival timestamp for rolling FPS calculation.
    private func recordFrameTimestamp() {
        let now = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            self.frameTimestamps.append(now)

            // Keep only the last N timestamps
            if self.frameTimestamps.count > Self.fpsWindowSize {
                self.frameTimestamps.removeFirst(self.frameTimestamps.count - Self.fpsWindowSize)
            }
        }
    }

    /// Compute current FPS from the rolling window of frame timestamps.
    private func computeCurrentFPS() -> Int {
        guard frameTimestamps.count >= 2 else { return 0 }
        let oldest = frameTimestamps.first!
        let newest = frameTimestamps.last!
        let elapsed = newest - oldest
        guard elapsed > 0 else { return 0 }
        return Int(Double(frameTimestamps.count - 1) / elapsed)
    }

    /// Start a timer that updates the HUD FPS display every second.
    private func startFPSUpdateTimer() {
        DispatchQueue.main.async {
            self.fpsUpdateTimer?.invalidate()
            print("[CONSOLE] startFPSUpdateTimer: scheduling on main run loop, state=\(self.state.rawValue), frameTimestamps=\(self.frameTimestamps.count)")
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let currentFPS = self.computeCurrentFPS()
                print("[CONSOLE] fpsTimerTick: frameTimestamps=\(self.frameTimestamps.count), computedFPS=\(currentFPS), state=\(self.state.rawValue)")
                DispatchQueue.main.async {
                    self.hudViewModel.updateFPS(currentFPS)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.fpsUpdateTimer = timer
        }
    }

    // MARK: - Private: Eco Mode

    private func handleEcoModeChange(_ isEco: Bool) {
        Self.log.info("Eco mode: \(isEco)")

        // Send eco mode change to Mac via TCP
        let timestamp = currentTimestampUs()
        let header = InputEventHeader(type: InputEventType.modeChange.rawValue, tsUs: timestamp)
        var data = header.serialize()

        // Append subtype byte, then 0x01/0x00 for on/off
        var subtype = ModeChangeSubtype.eco.rawValue
        data.append(Data(bytes: &subtype, count: 1))
        var enabled: UInt8 = isEco ? 1 : 0
        data.append(Data(bytes: &enabled, count: 1))

        sendInputEventToMac(data)
    }

    /// Acknowledge a whole HEVC frame received on the Wi-Fi TCP stream (cumulative seq). The Mac
    /// encodes only while sent-but-unacked frames stay under its limit (tla/WiFiSendLoop.tla
    /// AckGate). Runs on the transport queue as the frame is drained, before decode, so the ack
    /// measures the network queue and nothing else.
    private func sendFrameAck(seq: UInt16) {
        let header = InputEventHeader(type: InputEventType.frameAck.rawValue, tsUs: currentTimestampUs())
        var data = header.serialize()
        data.append(UInt8(seq & 0xFF))
        data.append(UInt8(seq >> 8))
        wirelessTransport.sendInputEvent(data)
        framesAcked += 1
        if framesAcked <= 5 || framesAcked % 600 == 0 {
            print("[CONSOLE] SessionManager: frame ack sent seq=\(seq) count=\(framesAcked)")
        }
    }

    // MARK: - FrameLoop (tla/FrameLoop.tla Design)

    /// HsConn + EpochMonotone: accept a handshake only with a newer epoch than any before; it
    /// moves media to its connection and owes a keyframe.
    private func flAcceptHandshake(epoch: UInt32, link: FLLink) -> Bool {
        let nowUs = keydrdHostTimeUs()
        flLock.lock()
        let prevEpoch = flHsEpoch
        let prevLink = flHsLink
        let accept = epoch > flHsEpoch
        if accept {
            flHsEpoch = epoch
            flHsLink = link
            flEnterAwaitLocked(reason: "handshake", nowUs: nowUs)
        }
        flLock.unlock()
        print("[CONSOLE] FL IpadHs ep=\(epoch) link=\(link) accepted=\(accept ? 1 : 0) prevEp=\(prevEpoch) prevLink=\(prevLink?.description ?? "none")")
        if accept { flStartKeyRetryTimer() }
        return accept
    }

    private func flIsHsLink(_ link: FLLink) -> Bool {
        flLock.lock(); defer { flLock.unlock() }
        return flHsLink == link
    }

    private var flHsLinkDescription: String {
        flLock.lock(); defer { flLock.unlock() }
        return flHsLink?.description ?? "none"
    }

    /// Caller holds flLock. A new break: await a keyframe; outputs submitted before are stale.
    private func flEnterAwaitLocked(reason: String, nowUs: UInt64) {
        // The app starts awaiting (flAwaiting = true, since 0): the first handshake starts the clock.
        if !flAwaiting || flAwaitSinceUs == 0 {
            flAwaiting = true
            flAwaitReason = reason
            flAwaitSinceUs = nowUs
        }
        flGen &+= 1
        // After a handshake the Mac already owes the key: KeyRetry waits its full 500 ms, or a
        // request could cross the key in flight and make the Mac hold valid deltas for a second
        // one. A decode failure is news to the Mac: the caller requests at once.
        flLastKeyReqUs = nowUs
    }

    /// The decode gate. nil: drop this frame (a delta while awaiting a key). Otherwise the
    /// generation the frame decodes in.
    private func flAdmitForDecode(_ header: MediaFrameHeader) -> UInt64? {
        let nowUs = keydrdHostTimeUs()
        flLock.lock()
        if flAwaiting && !header.isKeyframe {
            flAwaitDrops += 1
            let n = flAwaitDrops, reason = flAwaitReason, since = flAwaitSinceUs
            flLock.unlock()
            if n <= 10 || n % 120 == 0 {
                print("[CONSOLE] FL IpadAwaitDrop seq=\(header.seq) hevc=\(header.isHEVC) reason=\(reason) sinceMs=\((nowUs &- since) / 1000) count=\(n)")
            }
            return nil
        }
        var cleared: (String, UInt64, UInt32)? = nil
        if flAwaiting {
            flAwaiting = false
            cleared = (flAwaitReason, flAwaitSinceUs, flHsEpoch)
        }
        let gen = flGen
        if header.isHEVC { flHevcGen[Int(header.seq & 0xFF)] = gen }
        flLock.unlock()
        if let c = cleared {
            let (reason, since, ep) = c
            print("[CONSOLE] FL IpadKey seq=\(header.seq) hevc=\(header.isHEVC) ep=\(ep) reason=\(reason) waitMs=\((nowUs &- since) / 1000) gen=\(gen)")
        }
        return gen
    }

    private func flGenForHEVC(seq: UInt16) -> UInt64 {
        flLock.lock(); defer { flLock.unlock() }
        return flHevcGen[Int(seq & 0xFF)]
    }

    private func flIsCurrentHEVCOutput(seq: UInt16) -> Bool {
        flLock.lock(); defer { flLock.unlock() }
        return flHevcGen[Int(seq & 0xFF)] == flGen
    }

    /// AwaitOnFail: a frame of the current generation failed to decode: the picture chain is
    /// broken until a keyframe decodes.
    private func flDecodeFailed(gen: UInt64, seq: UInt16, reason: String) {
        let nowUs = keydrdHostTimeUs()
        flLock.lock()
        let current = (gen == flGen)
        if current { flEnterAwaitLocked(reason: reason, nowUs: nowUs) }
        flLock.unlock()
        print("[CONSOLE] FL IpadFail seq=\(seq) reason=\(reason) gen=\(gen) current=\(current ? 1 : 0)")
        if current { flRequestKey(reason: reason, force: true) }
    }

    /// Send on one connection (the handshake's): false if it is no longer current.
    private func flSend(_ data: Data, on link: FLLink) -> Bool {
        link.usb ? usbTransport.sendInputEvent(data, onSerial: link.serial)
                 : wirelessTransport.sendInputEvent(data, onSerial: link.serial)
    }

    /// KeyRetry: REQUEST_KEYFRAME (either codec) on the handshake's connection, at most every
    /// 500 ms unless forced.
    private func flRequestKey(reason: String, force: Bool) {
        let nowUs = keydrdHostTimeUs()
        flLock.lock()
        guard let link = flHsLink, force || nowUs &- flLastKeyReqUs >= 500_000 else {
            flLock.unlock()
            return
        }
        flLastKeyReqUs = nowUs
        let awaiting = flAwaiting, since = flAwaitSinceUs
        flLock.unlock()
        let header = InputEventHeader(type: InputEventType.modeChange.rawValue, tsUs: currentTimestampUs())
        var data = header.serialize()
        var subtype = ModeChangeSubtype.requestKeyframe.rawValue
        data.append(Data(bytes: &subtype, count: 1))
        let sent = flSend(data, on: link)
        print("[CONSOLE] FL IpadKeyRetry reason=\(reason) link=\(link) sent=\(sent ? 1 : 0) awaiting=\(awaiting ? 1 : 0) sinceMs=\(awaiting ? (nowUs &- since) / 1000 : 0)")
    }

    private func flStartKeyRetryTimer() {
        flLock.lock()
        let started = flKeyRetryTimer != nil
        if !started {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.flLock.lock()
                let awaiting = self.flAwaiting && self.flHsLink != nil
                self.flLock.unlock()
                if awaiting { self.flRequestKey(reason: "await", force: false) }
            }
            flKeyRetryTimer = t
            t.resume()
        }
        flLock.unlock()
    }

    /// All transports torn down (pairing reset, disconnect): the next handshake starts over.
    private func flResetLinks(reason: String) {
        flLock.lock()
        flHsLink = nil
        flHsEpoch = 0
        flAwaiting = true
        flAwaitReason = reason
        flGen &+= 1
        flLock.unlock()
        print("[CONSOLE] FL IpadReset reason=\(reason)")
    }

    private func requestImmediateKeyframe() {
        guard wirelessTransport.isConnected, !usbTransport.isConnected else { return }

        let timestamp = currentTimestampUs()
        if lastKeyframeRequestUs > 0,
           timestamp > lastKeyframeRequestUs,
           timestamp - lastKeyframeRequestUs < Self.keyframeRequestCooldownUs {
            print("[CONSOLE] SessionManager: keyframe request suppressed (cooldown \(timestamp - lastKeyframeRequestUs)us < \(Self.keyframeRequestCooldownUs)us)")
            return
        }
        lastKeyframeRequestUs = timestamp

        let header = InputEventHeader(type: InputEventType.modeChange.rawValue, tsUs: timestamp)
        var data = header.serialize()
        var subtype = ModeChangeSubtype.requestKeyframe.rawValue
        data.append(Data(bytes: &subtype, count: 1))
        print("[CONSOLE] SessionManager: requesting immediate HEVC keyframe for recovery (ts_us=\(timestamp))")
        sendInputEventToMac(data)
    }

    // MARK: - Private: Transport Send Helpers

    private func sendInputEventToMac(_ data: Data) {
        _ = sendInputEventReturningLink(data)
    }

    /// Sends on the link input uses now (USB first) and says which; nil if none.
    fileprivate func sendInputEventReturningLink(_ data: Data) -> InputSender.Link? {
        if usbTransport.isConnected {
            usbTransport.sendInputEvent(data)
            return .usb
        } else if wirelessTransport.isConnected {
            wirelessTransport.sendInputEvent(data)
            return .wifi
        }
        return nil
    }

    /// E2E: ask the Mac to enter or leave eco mode (HEVC encoder restart), as the eco toggle does.
    func sendEcoModeForTest(_ on: Bool) { handleEcoModeChange(on) }

    /// E2E: a KEYDRD_INPUT_TEST_CONTROL command (JSON) to the Mac's input test harness.
    func sendInputTestControl(_ cmd: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        var data = InputEventHeader(type: 0x26, tsUs: currentTimestampUs()).serialize()
        data.append(json)
        sendInputEventToMac(data)
    }

    /// E2E: which link input uses now, for test details.
    var inputLinkDescription: String {
        switch currentInputLink { case .usb: return "usb"; case .wifi: return "wifi"; case nil: return "none" }
    }

    /// Link input would use now.
    private var currentInputLink: InputSender.Link? {
        usbTransport.isConnected ? .usb : (wirelessTransport.isConnected ? .wifi : nil)
    }

    // MARK: - Private: Reconnection

    /// Schedule a reconnect attempt with exponential backoff.
    /// Backoff: 0.5s, 1s, 2s, 4s, 8s max.
    private func scheduleReconnect() {
        let delay = min(
            Self.baseReconnectDelay * pow(2.0, Double(reconnectAttempt)),
            Self.maxReconnectDelay
        )

        Self.log.info("Scheduling reconnect attempt \(self.reconnectAttempt + 1) in \(delay)s")
        udpReassembler.resetForNewStreamSession(reason: "schedule-reconnect-attempt-\(reconnectAttempt + 1)")

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.reconnectAttempt += 1
            self.startTransportMonitoring()
        }
    }

    // MARK: - Private: Utilities

    private func currentTimestampUs() -> UInt64 {
        keydrdHostTimeUs()
    }

    deinit {
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        reconnectTimer?.invalidate()
    }
}
