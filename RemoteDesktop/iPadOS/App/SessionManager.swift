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

    private var displayWidth: Int = 0
    private var displayHeight: Int = 0
    private var displayScaleFactor: Float = 2.0

    // MARK: - FPS Tracking

    private var frameCount: Int = 0
    private var fpsTimer: Timer?
    private var lastFPSUpdate: Date = Date()

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

        // Start FPS tracking timer (1-second interval)
        startFPSTimer()
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
        fpsTimer?.invalidate()
        reconnectTimer?.invalidate()
    }

    /// Disconnect and clean up the session.
    func disconnectSession() {
        Self.log.info("Disconnecting session")
        state = .disconnected
        reconnectTimer?.invalidate()
        fpsTimer?.invalidate()
        usbTransport.stopMonitoring()
        wirelessTransport.stopBrowsing()
        metalRenderer.stop()

        let transition = TransportFSM.transition(from: currentTransport, on: .disconnected)
        currentTransport = transition.state
    }

    // MARK: - Resolution Match

    /// Send resolution match request to Mac via TCP.
    /// Uses InputEventHeader with type=0x20 (modeChange).
    func requestResolutionMatch() {
        Self.log.info("Sending resolution match request to Mac")

        // Build mode change input event with subtype for resolution match
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let header = InputEventHeader(type: InputEventType.modeChange.rawValue, tsUs: timestamp)
        var data = header.serialize()

        // Append subtype byte: 0x01 = resolution match request
        var subtype: UInt8 = 0x01
        data.append(Data(bytes: &subtype, count: 1))

        // Send via active transport
        if usbTransport.isConnected {
            usbTransport.sendInputEvent(data)
        } else if wirelessTransport.isConnected {
            wirelessTransport.sendInputEvent(data)
        }

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

        // Check if this is a session handshake message
        if !header.isHEVC && !header.isKeyframe && !header.isDelta {
            // Could be a handshake or control message -- check msgType
            if let handshake = SessionHandshakeMessage.parse(from: data) {
                handleSessionHandshake(handshake)
                return
            }
        }

        // Route to decoder based on flags
        if header.isHEVC {
            // HEVC decode path (wireless/eco mode)
            guard let pixelBuffer = hevcDecoder.decode(data: payload, header: header) else {
                return
            }
            renderCVPixelBuffer(pixelBuffer, width: Int(header.payloadSize), height: 0)
        } else {
            // LZ4 decode path (wired mode)
            guard let decompressor = lz4Decompressor else {
                Self.log.error("LZ4 decompressor not initialized (no handshake yet)")
                return
            }

            let frameBytes = displayWidth * displayHeight * 4
            guard let pixels = decompressor.decompress(data: payload,
                                                        header: header,
                                                        frameBytes: frameBytes) else {
                return
            }

            metalRenderer.updateFrame(pixels, width: displayWidth, height: displayHeight)
        }

        // Update frame counter for FPS
        frameCount += 1

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
    private func handleSessionHandshake(_ handshake: SessionHandshakeMessage) {
        Self.log.info("Session handshake: \(handshake.displayWidth)x\(handshake.displayHeight)@\(handshake.scaleFactor)x, maxFps=\(handshake.maxFps)")

        displayWidth = Int(handshake.displayWidth)
        displayHeight = Int(handshake.displayHeight)
        displayScaleFactor = handshake.scaleFactor

        // Initialize LZ4 decompressor with frame size
        let frameBytes = displayWidth * displayHeight * 4
        lz4Decompressor = LZ4Decompressor(frameBytes: frameBytes)

        // Configure renderer viewport
        metalRenderer.setMacDisplaySize(width: displayWidth, height: displayHeight)

        // Update HUD with resolution info
        DispatchQueue.main.async {
            self.hudViewModel.updateResolution(
                macWidth: self.displayWidth,
                macHeight: self.displayHeight,
                iPadWidth: Int(UIScreen.main.nativeBounds.width),
                iPadHeight: Int(UIScreen.main.nativeBounds.height)
            )
        }

        state = .streaming
    }

    /// Render a CVPixelBuffer from HEVC decode to Metal.
    private func renderCVPixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)

        metalRenderer.updateFrame(UnsafeRawPointer(baseAddress),
                                   width: actualWidth,
                                   height: actualHeight)
    }

    /// Handle input data received from Mac (latency probes, control messages).
    private func handleInputReceived(_ data: Data) {
        guard let header = InputEventHeader.parse(from: data) else { return }

        if header.type == InputEventType.latencyProbe.rawValue {
            // Calculate round-trip latency
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let latencyUs = now - header.tsUs
            let latencyMs = Int(latencyUs / 1000)

            DispatchQueue.main.async {
                self.hudViewModel.updateLatency(latencyMs)
            }
        }
    }

    // MARK: - Private: FPS Timer

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentFPS = self.frameCount
            self.frameCount = 0
            DispatchQueue.main.async {
                self.hudViewModel.updateFPS(currentFPS)
            }
        }
    }

    // MARK: - Private: Eco Mode

    private func handleEcoModeChange(_ isEco: Bool) {
        Self.log.info("Eco mode: \(isEco)")

        // Send eco mode change to Mac via TCP
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let header = InputEventHeader(type: InputEventType.modeChange.rawValue, tsUs: timestamp)
        var data = header.serialize()

        // Append subtype byte: 0x02 = eco mode change, then 0x01/0x00 for on/off
        var subtype: UInt8 = 0x02
        data.append(Data(bytes: &subtype, count: 1))
        var enabled: UInt8 = isEco ? 1 : 0
        data.append(Data(bytes: &enabled, count: 1))

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

    deinit {
        fpsTimer?.invalidate()
        reconnectTimer?.invalidate()
    }
}
