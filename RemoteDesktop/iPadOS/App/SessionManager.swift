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
            testRunner?.noteSessionStateChanged(old: oldValue, new: state)
        }
    }

    // MARK: - Owned Components

    let qrPairing = QRPairing()
    let usbTransport = USBNetworkTransport()
    let wirelessTransport = WirelessTransport()
    let metalRenderer = MetalRenderer()
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
    private var macDisplayHeight: Int = 0
    private var macScaleFactor: Float = 2.0

    // MARK: - FPS Tracking (rolling window)

    private var frameTimestamps: [CFAbsoluteTime] = []
    private static let fpsWindowSize = 60
    private var fpsUpdateTimer: Timer?

    // MARK: - Latency Probe

    private var latencyProbeTimer: Timer?
    private static let latencyProbeInterval: TimeInterval = 1.0

    // MARK: - Reconnection

    private var reconnectAttempt: Int = 0
    private var reconnectTimer: Timer?
    private static let maxReconnectDelay: TimeInterval = 2.0
    private static let baseReconnectDelay: TimeInterval = 0.25

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
        if isTestMode {
            print("[CONSOLE] SessionManager: TEST MODE enabled (wiredOnly=\(isWiredOnly), wirelessOnly=\(isWirelessOnly))")
            testRunner = DeviceTestRunner(sessionManager: self)
        }
    }

    // MARK: - Public API

    /// Start the session. Check pairing state and begin monitoring transports.
    func start() {
        Self.log.info("[SessionManager] start() called, current state=\(self.state.rawValue)")

        // Mac regenerates TLS identity on every dev launch (avoids keychain ACL
        // issues from code-signature changes). Clear iPad side too so both start
        // fresh — auto-reconnect across Mac relaunches isn't possible anyway.
        qrPairing.resetPairing()
        print("[CONSOLE] start(): cleared stale pairing (Mac regenerates TLS identity each launch)")

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

        // Test mode: skip QR camera, auto-pair via Bonjour discovery
        if isTestMode {
            print("[CONSOLE] start(): TEST MODE -- skipping QR, starting auto-pair via Bonjour")
            testRunner?.runAllTests()
            state = .awaitingPairing
            qrPairing.autoPairViaBonjourForTestMode(testRunner: testRunner) { [weak self] in
                print("[CONSOLE] TEST MODE: auto-pair complete, starting transport monitoring")
                self?.onPairingComplete()
            }
            return
        }

        // Check if already paired
        if qrPairing.isPaired {
            Self.log.info("[SessionManager] start(): already paired -- setting state to .connecting and starting transport monitoring")
            state = .connecting
            startTransportMonitoring()
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

        // E2E test: now that pairing is done and Mac is advertising, test Bonjour discovery
        testRunner?.runBonjourDiscoveryTestAfterPairing()
    }

    /// Force an immediate reconnect attempt (user tapped "Retry Now").
    func retryNow() {
        Self.log.info("User requested immediate reconnect")
        reconnectTimer?.invalidate()
        reconnectAttempt = 0
        startTransportMonitoring()
    }

    /// Resume session after app returns to foreground.
    func resumeFromBackground() {
        Self.log.info("[SessionManager] resumeFromBackground() called, state=\(self.state.rawValue), isPaired=\(self.qrPairing.isPaired)")

        guard qrPairing.isPaired else {
            Self.log.info("[SessionManager] resumeFromBackground(): not paired, returning early")
            return
        }

        switch state {
        case .disconnected, .reconnecting:
            state = .connecting
            reconnectAttempt = 0
            startTransportMonitoring()
        case .streaming:
            // Already streaming, nothing to do
            break
        default:
            break
        }
    }

    /// Pause session when app goes to background.
    func pauseForBackground() {
        Self.log.info("App backgrounded -- pausing")
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        reconnectTimer?.invalidate()
    }

    /// Disconnect and clean up the session.
    func disconnectSession() {
        Self.log.info("Disconnecting session")
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
        wirelessTransport.stopBrowsing()
        usbTransport.startMonitoring()
    }

    /// Start only wireless transport browsing (disables USB).
    func startWirelessOnly() {
        Self.log.info("Starting wireless only")
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
    private func sendViewportReport(width: Int, height: Int) {
        let header = InputEventHeader(type: InputEventType.viewportReport.rawValue,
                                      tsUs: currentTimestampUs())
        var data = header.serialize()
        let payload = ViewportReportPayload(viewportWidth: UInt32(width),
                                            viewportHeight: UInt32(height))
        data.append(payload.serialize())
        sendInputEventToMac(data)
    }

    // MARK: - Private: Transport Monitoring

    private func startTransportMonitoring() {
        // Wire UDPReassembler: delivers complete frames to handleReceivedFrame
        udpReassembler.onFrameReassembled = { [weak self] data in
            self?.handleReceivedFrame(data)
        }

        // Set up USB NCM transport callbacks
        usbTransport.onInterfaceChanged = { [weak self] appeared, interface in
            DispatchQueue.main.async {
                self?.handleTransportEvent(appeared ? .wiredAppeared : .wiredDisappeared)
            }
        }

        // USB media arrives via TCP (reliable delivery over USB NCM).
        // UDP/DTLS is confirmed broken for USB NCM media — tested both batch sends
        // and completion-paced sequential sends, both produce black screen.
        // Root cause: USB NCM DTLS path drops data regardless of send pacing.
        // TCP with TCP_NODELAY gives 0% loss at 1ms RTT.
        // handleInputReceived detects MediaFrameHeader and routes to handleReceivedFrame.
        usbTransport.onMediaReceived = nil

        usbTransport.onInputReceived = { [weak self] data in
            self?.handleInputReceived(data)
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
            self?.udpReassembler.processChunk(data)
        }

        wirelessTransport.onInputReceived = { [weak self] data in
            self?.handleInputReceived(data)
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
            print("[CONSOLE] Effect: disconnect current transport")
            usbTransport.stopMonitoring()
            wirelessTransport.stopBrowsing()
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

        // Extract payload (everything after the 24-byte header)
        let payload = data.subdata(in: MediaFrameHeader.size..<data.count)

        frameRecvCount += 1
        testRunner?.noteReceivedFrameHeader(header)

        // Pipeline latency probe: capture → iPad receive (before decode)
        if header.tsUs > 0 {
            let nowUs = keydrdHostTimeUs()
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
            print("[CONSOLE] handleReceivedFrame: seq=\(header.seq) flags=0x\(String(header.flags, radix: 16)) payload=\(payload.count) isHEVC=\(header.isHEVC) isKey=\(header.isKeyframe)")
        }

        // Route to decoder based on flags
        var decompressedSize = 0
        let decodeStart = CACurrentMediaTime()
        if header.isHEVC {
            // HEVC decode path (wireless/eco mode)
            guard let pixelBuffer = hevcDecoder.decode(data: payload, header: header) else {
                testRunner?.noteHEVCDecodeFailure(seq: header.seq)
                if frameRecvCount <= 5 {
                    print("[CONSOLE] handleReceivedFrame: HEVC decode FAILED for seq=\(header.seq)")
                }
                return
            }
            decompressedSize = CVPixelBufferGetDataSize(pixelBuffer)
            let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000.0
            if frameRecvCount <= 3 {
                print("[CONSOLE] handleReceivedFrame: HEVC decoded OK, \(decompressedSize) bytes, decode=\(String(format: "%.1f", decodeMs))ms")
            }

            // Report decoded dimensions for resolution test
            let decodedW = CVPixelBufferGetWidth(pixelBuffer)
            let decodedH = CVPixelBufferGetHeight(pixelBuffer)
            testRunner?.reportDecodedFrameDimensions(width: decodedW, height: decodedH)

            // Zero-copy: pass CVPixelBuffer directly to Metal via IOSurface
            metalRenderer.updateFrameFromPixelBuffer(pixelBuffer, captureTimestampUs: header.tsUs)
        } else {
            // LZ4 decode path (wired mode)
            guard let decompressor = lz4Decompressor else {
                Self.log.error("LZ4 decompressor not initialized (no handshake yet)")
                return
            }

            let frameBytes = macDisplayWidth * macDisplayHeight * 4
            // Safety: skip frames where dimensions don't match decompressor buffer
            guard frameBytes > 0, frameBytes <= decompressor.frameBytes else {
                if frameRecvCount <= 20 || frameRecvCount % 500 == 0 {
                    print("[CONSOLE] LZ4: skipping frame, frameBytes=\(frameBytes) bufCap=\(decompressor.frameBytes) macDims=\(macDisplayWidth)x\(macDisplayHeight)")
                }
                return
            }

            guard let pixels = decompressor.decompress(data: payload,
                                                        header: header,
                                                        frameBytes: frameBytes) else {
                if frameRecvCount <= 20 || frameRecvCount % 500 == 0 {
                    print("[CONSOLE] LZ4: decompress returned nil, frameBytes=\(frameBytes) payload=\(payload.count) seq=\(header.seq)")
                }
                return
            }

            decompressedSize = frameBytes

            // Report decoded dimensions for resolution test
            testRunner?.reportDecodedFrameDimensions(width: macDisplayWidth, height: macDisplayHeight)

            metalRenderer.updateFrame(pixels, width: macDisplayWidth, height: macDisplayHeight, captureTimestampUs: header.tsUs)
        }

        // Record frame timestamp for FPS calculation
        recordFrameTimestamp()

        // E2E test: report frame received + decompressed
        testRunner?.reportFrameReceived(header: header, decompressedSize: decompressedSize)

        // Transition to streaming on first frame
        if state == .connecting || state == .reconnecting {
            DispatchQueue.main.async {
                self.state = .streaming
                self.reconnectAttempt = 0
                self.hudViewModel.show()
            }
        }
    }

    /// Handle session handshake from Mac.
    /// Configures viewport, decompressor, and HUD before first frame.
    private func handleSessionHandshake(_ handshake: SessionHandshakeMessage) {
        Self.log.info("Session handshake: \(handshake.displayWidth)x\(handshake.displayHeight)@\(handshake.scaleFactor)x, maxFps=\(handshake.maxFps)")

        macDisplayWidth = Int(handshake.displayWidth)
        macDisplayHeight = Int(handshake.displayHeight)
        macScaleFactor = handshake.scaleFactor

        // Initialize LZ4 decompressor with frame size
        let frameBytes = macDisplayWidth * macDisplayHeight * 4
        lz4Decompressor = LZ4Decompressor(frameBytes: frameBytes)

        // Configure renderer viewport
        metalRenderer.setMacDisplaySize(width: macDisplayWidth, height: macDisplayHeight)

        // Compute viewport pixel dimensions and tell Mac to capture/encode at this size.
        // This avoids encoding pixels the iPad can't display (e.g. 3600x2338 → 2752x1787).
        let iPadPixelWidth = Int(UIScreen.main.nativeBounds.width)
        let iPadPixelHeight = Int(UIScreen.main.nativeBounds.height)
        // nativeBounds is portrait-locked; use landscape (wider dimension first)
        let screenW = max(iPadPixelWidth, iPadPixelHeight)
        let screenH = min(iPadPixelWidth, iPadPixelHeight)

        let (vpW, vpH) = Self.computeViewportPixels(
            macWidth: macDisplayWidth, macHeight: macDisplayHeight,
            screenWidth: screenW, screenHeight: screenH
        )
        // Store for E2E test verification
        viewportWidth = vpW
        viewportHeight = vpH

        sendViewportReport(width: vpW, height: vpH)
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
    private func handleInputReceived(_ data: Data) {
        // Check handshake FIRST — both handshake and media frame share KEYDRD_MAGIC,
        // but handshake has a more specific discriminator (magic + msgType at offset 2)
        if let handshake = SessionHandshakeMessage.parse(from: data) {
            print("[CONSOLE] handleInputReceived: parsed as SESSION HANDSHAKE \(handshake.displayWidth)x\(handshake.displayHeight)")
            handleSessionHandshake(handshake)
            return
        }

        // Check if this is a media frame sent over TCP (fallback for large HEVC
        // frames) or over UDP. Route all HEVC frames through the reassembler so
        // single-chunk, multi-chunk, and TCP-fallback delivery all share one
        // sequencing path.
        if data.count >= MediaFrameHeader.size,
           let mediaHeader = MediaFrameHeader.parse(from: data) {
            if mediaHeader.isHEVC {
                udpReassembler.processChunk(data)
            } else {
                handleReceivedFrame(data)
            }
            return
        }

        // Parse as InputEventHeader
        guard let header = InputEventHeader.parse(from: data) else { return }

        switch header.type {
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
        frameTimestamps.append(now)

        // Keep only the last N timestamps
        if frameTimestamps.count > Self.fpsWindowSize {
            frameTimestamps.removeFirst(frameTimestamps.count - Self.fpsWindowSize)
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

        // Append subtype byte: 0x02 = eco mode change, then 0x01/0x00 for on/off
        var subtype: UInt8 = 0x02
        data.append(Data(bytes: &subtype, count: 1))
        var enabled: UInt8 = isEco ? 1 : 0
        data.append(Data(bytes: &enabled, count: 1))

        sendInputEventToMac(data)
    }

    // MARK: - Private: Transport Send Helpers

    private func sendInputEventToMac(_ data: Data) {
        if usbTransport.isConnected {
            usbTransport.sendInputEvent(data)
        } else if wirelessTransport.isConnected {
            wirelessTransport.sendInputEvent(data)
        }
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
