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
    private(set) var state: State = .awaitingPairing

    // MARK: - Owned Components

    let qrPairing = QRPairing()
    let usbTransport = USBNetworkTransport()
    let wirelessTransport = WirelessTransport()
    let metalRenderer = MetalRenderer()
    let hudViewModel = HUDViewModel()
    private var lz4Decompressor: LZ4Decompressor?
    private let hevcDecoder = HEVCDecoder()

    // MARK: - Transport FSM

    private var currentTransport: TransportState = .idle

    // MARK: - Display Geometry (from handshake)

    private var macDisplayWidth: Int = 0
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
    private static let maxReconnectDelay: TimeInterval = 8.0
    private static let baseReconnectDelay: TimeInterval = 0.5

    // MARK: - Logging

    private static let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "Session")

    // MARK: - Public API

    /// Start the session. Check pairing state and begin monitoring transports.
    func start() {
        Self.log.info("SessionManager starting")

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

        // Check if already paired
        if qrPairing.isPaired {
            Self.log.info("Already paired -- starting transport monitoring")
            state = .connecting
            startTransportMonitoring()
        } else {
            Self.log.info("Not paired -- awaiting QR scan")
            state = .awaitingPairing
        }
    }

    /// Called when QR pairing completes successfully.
    func onPairingComplete() {
        Self.log.info("Pairing complete -- starting transport monitoring")
        state = .connecting
        startTransportMonitoring()
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
        Self.log.info("App foregrounded -- resuming session")

        guard qrPairing.isPaired else { return }

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

    // MARK: - Private: Transport Monitoring

    private func startTransportMonitoring() {
        // Set up USB NCM transport callbacks
        usbTransport.onInterfaceChanged = { [weak self] appeared, interface in
            DispatchQueue.main.async {
                self?.handleTransportEvent(appeared ? .wiredAppeared : .wiredDisappeared)
            }
        }

        usbTransport.onMediaReceived = { [weak self] data in
            self?.handleReceivedFrame(data)
        }

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

        wirelessTransport.onMediaReceived = { [weak self] data in
            self?.handleReceivedFrame(data)
        }

        wirelessTransport.onInputReceived = { [weak self] data in
            self?.handleInputReceived(data)
        }

        // Start both transport monitors
        usbTransport.startMonitoring()
        wirelessTransport.startBrowsing()
    }

    // MARK: - Private: Transport FSM

    private func handleTransportEvent(_ event: TransportEvent) {
        let transition = TransportFSM.transition(from: currentTransport, on: event)

        guard transition.state != currentTransport || !transition.effects.isEmpty else {
            return
        }

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
            Self.log.info("Effect: bind USB NCM")
        case .connectWiFi:
            Self.log.info("Effect: connect Wi-Fi")
        case .connectAWDL:
            Self.log.info("Effect: connect AWDL")
        case .disconnectCurrent:
            Self.log.info("Effect: disconnect current transport")
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
    /// 1. Parse MediaFrameHeader (24 bytes).
    /// 2. Validate magic.
    /// 3. Route to HEVC or LZ4 decoder.
    /// 4. Send decoded pixels to MetalRenderer.
    private func handleReceivedFrame(_ data: Data) {
        guard data.count > MediaFrameHeader.size else {
            Self.log.error("Frame too small: \(data.count) bytes")
            return
        }

        // Parse header
        guard let header = MediaFrameHeader.parse(from: data) else {
            Self.log.error("Invalid frame header (magic mismatch)")
            return
        }

        // Extract payload (everything after the 24-byte header)
        let payload = data.subdata(in: MediaFrameHeader.size..<data.count)

        // Route to decoder based on flags
        if header.isHEVC {
            // HEVC decode path (wireless/eco mode)
            guard let pixelBuffer = hevcDecoder.decode(data: payload, header: header) else {
                return
            }
            renderCVPixelBuffer(pixelBuffer)
        } else {
            // LZ4 decode path (wired mode)
            guard let decompressor = lz4Decompressor else {
                Self.log.error("LZ4 decompressor not initialized (no handshake yet)")
                return
            }

            let frameBytes = macDisplayWidth * macDisplayHeight * 4
            guard let pixels = decompressor.decompress(data: payload,
                                                        header: header,
                                                        frameBytes: frameBytes) else {
                return
            }

            metalRenderer.updateFrame(pixels, width: macDisplayWidth, height: macDisplayHeight)
        }

        // Record frame timestamp for FPS calculation
        recordFrameTimestamp()

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

        // Update HUD with resolution info
        DispatchQueue.main.async {
            self.hudViewModel.updateResolution(
                macWidth: self.macDisplayWidth,
                macHeight: self.macDisplayHeight,
                iPadWidth: Int(UIScreen.main.nativeBounds.width),
                iPadHeight: Int(UIScreen.main.nativeBounds.height)
            )
        }

        // Start latency probe timer
        startLatencyProbeTimer()

        // Start FPS update timer
        startFPSUpdateTimer()

        state = .streaming
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
    private func handleInputReceived(_ data: Data) {
        // First check if it's a session handshake (different struct format)
        if let handshake = SessionHandshakeMessage.parse(from: data) {
            handleSessionHandshake(handshake)
            return
        }

        // Parse as InputEventHeader
        guard let header = InputEventHeader.parse(from: data) else { return }

        switch header.type {
        case InputEventType.latencyProbe.rawValue:
            handleLatencyProbeResponse(header)

        case InputEventType.modeChange.rawValue:
            handleModeChangeFromMac(data)

        case InputEventType.resMatchResponse.rawValue:
            handleResolutionMatchResponse(data)

        case InputEventType.geometryUpdate.rawValue:
            handleGeometryUpdate(data)

        default:
            Self.log.debug("Unhandled input event type: 0x\(String(header.type, radix: 16))")
        }
    }

    // MARK: - Private: Latency Probe

    private func startLatencyProbeTimer() {
        latencyProbeTimer?.invalidate()
        latencyProbeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.latencyProbeInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendLatencyProbe()
        }
    }

    /// Send a latency probe to Mac. Mac echoes it back immediately.
    /// Round-trip time / 2 = one-way latency estimate.
    private func sendLatencyProbe() {
        guard state == .streaming else { return }

        let timestamp = currentTimestampUs()
        let header = InputEventHeader(type: InputEventType.latencyProbe.rawValue, tsUs: timestamp)
        let data = header.serialize()
        sendInputEventToMac(data)
    }

    /// Handle echoed latency probe from Mac.
    private func handleLatencyProbeResponse(_ header: InputEventHeader) {
        let now = currentTimestampUs()
        let roundTripUs = now - header.tsUs
        let oneWayMs = Int(roundTripUs / 2000)  // microseconds -> milliseconds, halved

        DispatchQueue.main.async {
            self.hudViewModel.updateLatency(oneWayMs)
        }
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

        Self.log.info("Geometry update: \(geo.displayWidth)x\(geo.displayHeight)@\(geo.scaleFactor)x")

        macDisplayWidth = Int(geo.displayWidth)
        macDisplayHeight = Int(geo.displayHeight)
        macScaleFactor = geo.scaleFactor

        // Reinitialize LZ4 decompressor with new frame size
        let frameBytes = macDisplayWidth * macDisplayHeight * 4
        lz4Decompressor = LZ4Decompressor(frameBytes: frameBytes)

        // Recalculate MetalRenderer viewport
        metalRenderer.setMacDisplaySize(width: macDisplayWidth, height: macDisplayHeight)

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
        fpsUpdateTimer?.invalidate()
        fpsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentFPS = self.computeCurrentFPS()
            DispatchQueue.main.async {
                self.hudViewModel.updateFPS(currentFPS)
            }
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
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    deinit {
        fpsUpdateTimer?.invalidate()
        latencyProbeTimer?.invalidate()
        reconnectTimer?.invalidate()
    }
}
