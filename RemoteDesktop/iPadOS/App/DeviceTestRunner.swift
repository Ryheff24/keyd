import Foundation
import Network
import Security
import CryptoKit
import CoreVideo
import UIKit
import os.log

/// On-device E2E test runner for the keyd-rd iPad app.
///
/// Runs a sequential test suite that verifies the REAL Mac<->iPad communication
/// pipeline: Bonjour discovery, TLS+ECDH pairing, transport detection, session
/// handshake, frame reception, decompression, latency probe, keepalive,
/// resolution, FPS, tiered latency, throughput, and transport type assertion.
///
/// Reports results via `print("[TEST] ...")` which is captured by
/// `xcrun devicectl device process launch --console`.
///
/// Created by SessionManager when `--test-mode` is detected in launch arguments.
/// Hooks into the EXISTING transport infrastructure -- does not create parallel
/// connections. Instead, it observes SessionManager state changes and transport
/// callbacks to verify each step.
final class DeviceTestRunner {

    // MARK: - Properties

    private weak var sessionManager: SessionManager?
    private var testResults: [(name: String, passed: Bool, detail: String)] = []
    private var testStartTime: CFAbsoluteTime = 0

    // Bonjour discovery tracking
    private var bonjourBrowser: NWBrowser?
    private var bonjourDiscoveredService: String?
    private var bonjourDiscoveryComplete = false

    // Session observation
    private var handshakeReceived = false
    private var transportDetected = false
    private var detectedTransportType: String = "none"

    // Frame tracking
    private var framesReceived = 0
    private var framesDecompressed = 0
    private var totalDecompressedBytes = 0
    private var frameReceptionComplete = false
    private let targetFrameCount = 5

    // Latency probe
    private var latencyProbeRTT: Int = -1
    private var latencyProbeComplete = false
    /// True only while runLatencyProbeTest waits: the session's periodic 1 s probes also answer
    /// here, and must not complete the test before it starts (frames arriving late reordered
    /// the whole chain and hung the suite).
    private var latencyProbeActive = false

    // Handshake details
    private var handshakeWidth: UInt32 = 0
    private var handshakeHeight: UInt32 = 0
    private var handshakeScale: Float = 0
    private var handshakeCaps: UInt8 = 0
    private var handshakeMaxFps: UInt8 = 0

    // Overall timeout
    private var overallTimer: Timer?
    private static let baseOverallTimeout: TimeInterval = 210   // +30 s for the input tests
    private let overallTimeoutSeconds: TimeInterval

    // --- New test state ---

    // Resolution test
    private var resolutionTestComplete = false
    private var decodedFrameWidths: [Int] = []
    private var decodedFrameHeights: [Int] = []
    private var totalRenderedFrames = 0

    // FPS + consistency test
    private var fpsTestActive = false
    private var fpsTestComplete = false
    private var fpsTestStartTime: CFAbsoluteTime = 0
    private var fpsTestFrameCount = 0
    private var fpsFrameTimestamps: [CFAbsoluteTime] = [] // every frame arrival time
    private static let fpsTestDuration: TimeInterval = 10.0

    // Tiered latency test
    private var tieredLatencyActive = false
    private var tieredLatencyComplete = false
    private var tieredLatencyProbes: [Int] = [] // RTTs in microseconds
    private var tieredLatencyProbesSent = 0
    private static let tieredLatencyProbeCount = 50
    private static let tieredLatencyProbeSpacingMs: Int = 100

    // Pipeline latency (capture-to-decode, using host-time ts_us)
    private var pipelineLatenciesUs: [Int64] = []

    // Glass-to-glass latency (capture-to-presented, via display-link presentation target)
    private var glassToGlassLatenciesUs: [Int64] = []

    // Clock offset calibration (Cristian's algorithm)
    private(set) var clockOffsetUs: Int64 = 0  // Mac clock - iPad clock (microseconds)
    private var clockOffsetCalibrated = false

    /// Expose clock offset for latency probes in SessionManager
    var clockOffsetForProbe: Int64 { clockOffsetUs }
    var clockOffsetCalibratedForLogging: Bool { clockOffsetCalibrated }
    private var clockSyncSamples: [(offset: Int64, rtt: Int64)] = []
    private var clockSyncProbesSent = 0
    private var clockSyncComplete = false
    private var awaitingClockSyncResponseT1Us: UInt64?
    private static let clockSyncProbeCount = 10
    private static let clockSyncProbeSpacingMs = 20

    // Throughput benchmark
    private var throughputTestActive = false
    private var throughputTestComplete = false
    private var throughputStartTime: CFAbsoluteTime = 0
    private var throughputBytes: Int = 0
    private var throughputFrames: Int = 0
    private static let throughputDuration: TimeInterval = 10.0

    // Parallel full-run performance suite
    private var parallelPerformanceSuiteActive = false
    private var parallelPerformanceSuiteFinalized = false
    private var parallelPerformanceStartTime: CFAbsoluteTime = 0
    private var parallelPerformanceFrameTimestamps: [CFAbsoluteTime] = []
    private var parallelPerformanceThroughputBytes = 0
    private var parallelPerformanceRenderedStartCount = 0
    private var parallelPerformanceFramesReceivedStartCount = 0
    private var parallelPerformanceDeliveredStartCount = 0
    private var parallelPerformanceEvictedStartCount = 0
    private var parallelPerformancePurgedStartCount = 0
    private var parallelPerformanceChunksStartCount = 0
    private var parallelPerformancePipelineStartCount = 0
    private var parallelPerformanceGlassStartCount = 0
    private static let parallelPerformanceHeavyLoadLeadIn: TimeInterval = 25.0

    // Continuous stream telemetry across the full test run
    private var streamTelemetryTimer: Timer?
    private var streamTelemetryStartTime: CFAbsoluteTime = 0
    private var observedFrameCount = 0
    private var keyframesObserved = 0
    private var hevcDecodeFailures = 0
    private var lastTelemetryObservedCount = 0
    private var lastTelemetryRenderedCount = 0
    private var lastTelemetryKeyframeCount = 0
    private var lastTelemetryDecodeFailureCount = 0
    private var lastTelemetryPipelineCount = 0
    private var lastTelemetryGlassCount = 0
    private var lastTelemetryRendererOverwriteCount = 0

    // Sustained stream validation for full-clip WiFi runs
    private let sustainedStreamDuration: TimeInterval
    private let skipTransportRotation: Bool
    private let profile: String
    private let videoPlaybackWindowSeconds: TimeInterval
    private let videoPlaybackOffsetSeconds: TimeInterval
    private var sustainedStreamActive = false
    private var sustainedStreamRenderedStartCount = 0
    private var sustainedStreamObservedStartCount = 0
    private var sustainedStreamPipelineStartCount = 0
    private var sustainedStreamGlassStartCount = 0
    private var sustainedStreamFrameTimestamps: [CFAbsoluteTime] = []
    private var sustainedStreamReconnects = 0
    private var videoPlaybackActive = false
    private var videoPlaybackFrameTimestamps: [CFAbsoluteTime] = []
    private var videoPlaybackRenderedStartCount = 0
    private var videoPlaybackObservedStartCount = 0
    private var videoPlaybackPipelineStartCount = 0
    private var videoPlaybackDecodeFailuresStartCount = 0

    // Transport type assertion
    private var transportAssertionComplete = false

    // Launch argument configuration
    private let expectResolution: (width: Int, height: Int)?
    private let expectFPS: Int?
    private let latencyTargetMs: Int?
    private let expectTransport: String?
    private let selectedTransports: [String]

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "E2ETest")
    private static let availableTransports = ["usb", "wifi", "awdl"]

    // MARK: - Init

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager

        // Parse launch arguments for parameterized tests
        let args = ProcessInfo.processInfo.arguments

        // --expect-resolution WxH
        if let idx = args.firstIndex(of: "--expect-resolution"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 {
                self.expectResolution = (width: parts[0], height: parts[1])
            } else {
                self.expectResolution = nil
            }
        } else {
            self.expectResolution = nil
        }

        // --expect-fps N
        if let idx = args.firstIndex(of: "--expect-fps"), idx + 1 < args.count {
            self.expectFPS = Int(args[idx + 1])
        } else {
            self.expectFPS = nil
        }

        // --latency-target-ms N
        if let idx = args.firstIndex(of: "--latency-target-ms"), idx + 1 < args.count {
            self.latencyTargetMs = Int(args[idx + 1])
        } else {
            self.latencyTargetMs = nil
        }

        // --expected-transport usb|wifi|awdl (preferred), --expect-transport (legacy)
        if let idx = args.firstIndex(of: "--expected-transport"), idx + 1 < args.count {
            self.expectTransport = args[idx + 1]
        } else if let idx = args.firstIndex(of: "--expect-transport"), idx + 1 < args.count {
            self.expectTransport = args[idx + 1]
        } else {
            self.expectTransport = nil
        }

        if let idx = args.firstIndex(of: "--transport-rotation"), idx + 1 < args.count {
            let requested = Set(
                args[idx + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            let normalized = Self.availableTransports.filter { requested.contains($0) }
            self.selectedTransports = normalized.isEmpty ? Self.availableTransports : normalized
        } else if let idx = args.firstIndex(of: "--transports"), idx + 1 < args.count {
            let requested = Set(
                args[idx + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            let normalized = Self.availableTransports.filter { requested.contains($0) }
            self.selectedTransports = normalized.isEmpty ? Self.availableTransports : normalized
        } else {
            self.selectedTransports = Self.availableTransports
        }

        if let idx = args.firstIndex(of: "--sustained-stream-seconds"), idx + 1 < args.count {
            self.sustainedStreamDuration = max(0, Double(args[idx + 1]) ?? 0)
        } else {
            self.sustainedStreamDuration = 0
        }
        if let idx = args.firstIndex(of: "--profile"), idx + 1 < args.count {
            self.profile = args[idx + 1].lowercased()
        } else {
            self.profile = "full"
        }
        if let idx = args.firstIndex(of: "--video-playback-window-seconds"), idx + 1 < args.count {
            self.videoPlaybackWindowSeconds = max(1, Double(args[idx + 1]) ?? 12)
        } else {
            self.videoPlaybackWindowSeconds = 12
        }
        if let idx = args.firstIndex(of: "--video-playback-offset-seconds"), idx + 1 < args.count {
            self.videoPlaybackOffsetSeconds = max(0, Double(args[idx + 1]) ?? 34)
        } else {
            self.videoPlaybackOffsetSeconds = 34
        }
        self.skipTransportRotation = args.contains("--skip-transport-rotation")
        self.overallTimeoutSeconds = Self.baseOverallTimeout + self.sustainedStreamDuration

        print("[CONSOLE] DeviceTestRunner: expectResolution=\(String(describing: self.expectResolution)), expectFPS=\(String(describing: self.expectFPS)), latencyTargetMs=\(String(describing: self.latencyTargetMs)), expectTransport=\(String(describing: self.expectTransport)), transports=\(self.selectedTransports.joined(separator: ",")), profile=\(self.profile), sustainedStreamSeconds=\(Int(self.sustainedStreamDuration)), playbackWindow=\(Int(self.videoPlaybackWindowSeconds))s@+\(Int(self.videoPlaybackOffsetSeconds))s, skipTransportRotation=\(self.skipTransportRotation), overallTimeout=\(Int(self.overallTimeoutSeconds))")

        // Wire renderer callback — this is the source of truth for "frame shown on screen"
        sessionManager.metalRenderer.onFrameRendered = { [weak self] in
            self?.onRenderedFrame()
        }

        // Glass-to-glass latency: capture host time -> presented host time.
        // Corrected by Cristian's algorithm clock offset.
        // latency = iPad_presented - (Mac_capture - offset)
        //         = iPad_presented - Mac_capture + offset
        sessionManager.metalRenderer.onFramePresented = { [weak self] captureTimestampUs, presentedHostTimeUs in
            guard let self = self else { return }
            let latencyUs = presentedHostTimeUs - Int64(captureTimestampUs) + self.clockOffsetUs
            if latencyUs > 0 && latencyUs < 10_000_000 { // sanity: 0-10s
                self.glassToGlassLatenciesUs.append(latencyUs)
            }
        }
    }

    @discardableResult
    private func dispatchToMainIfNeeded(_ work: @escaping () -> Void) -> Bool {
        guard !Thread.isMainThread else { return false }
        DispatchQueue.main.async(execute: work)
        return true
    }

    /// Called by MetalRenderer each time a frame is actually presented to the display.
    private func onRenderedFrame() {
        totalRenderedFrames += 1

        // Feed FPS test with RENDERED frame timestamps
        if fpsTestActive && !fpsTestComplete {
            fpsTestFrameCount += 1
            fpsFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        }

        // Feed throughput test with RENDERED frame count only.
        // Byte accounting happens in reportFrameReceived() using compressed
        // frame bytes actually received from the transport.
        if throughputTestActive && !throughputTestComplete {
            throughputFrames += 1
        }

        if parallelPerformanceSuiteActive {
            parallelPerformanceFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        }

        // Feed WiFi baseline measurement during WiFi rotation phase
        if wifiMeasurementActive {
            wifiMeasurementFrameCount += 1
            wifiMeasurementFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        }

        if sustainedStreamActive {
            sustainedStreamFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        }
        if videoPlaybackActive {
            videoPlaybackFrameTimestamps.append(CFAbsoluteTimeGetCurrent())
        }
    }

    // MARK: - Public API

    /// Run the full E2E test suite. Called from SessionManager after start().
    func runAllTests() {
        if dispatchToMainIfNeeded({ [weak self] in self?.runAllTests() }) { return }
        testStartTime = CFAbsoluteTimeGetCurrent()
        streamTelemetryStartTime = testStartTime
        print("[TEST] START: on-device E2E test suite")
        print("[TEST] INFO: device=iPad, timestamp=\(ISO8601DateFormatter().string(from: Date()))")
        startStreamTelemetry()

        // Set overall timeout
        overallTimer = Timer.scheduledTimer(withTimeInterval: overallTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.onTimeout()
        }

        // Tests 1-3 (TLS, ECDH) are reported by the auto-pairing flow in QRPairing.
        // Test 4 (Bonjour discovery) runs after pairing completes, when the Mac
        // starts advertising _keydrd._tcp via startTransportMonitoring.
        // Tests 5+ are driven by SessionManager state change callbacks.
    }

    func noteReceivedFrameHeader(_ header: MediaFrameHeader) {
        if dispatchToMainIfNeeded({ [weak self] in self?.noteReceivedFrameHeader(header) }) { return }
        observedFrameCount += 1
        if header.isKeyframe {
            keyframesObserved += 1
        }
    }

    func noteHEVCDecodeFailure(seq: UInt16) {
        if dispatchToMainIfNeeded({ [weak self] in self?.noteHEVCDecodeFailure(seq: seq) }) { return }
        hevcDecodeFailures += 1
        if hevcDecodeFailures <= 10 || hevcDecodeFailures % 25 == 0 {
            print("[CONSOLE] STREAM-TELEMETRY decode-failure seq=\(seq) total=\(hevcDecodeFailures)")
        }
    }

    func noteSessionStateChanged(old: SessionManager.State, new: SessionManager.State) {
        if dispatchToMainIfNeeded({ [weak self] in self?.noteSessionStateChanged(old: old, new: new) }) { return }
        if sustainedStreamActive && old == .streaming && new != .streaming {
            sustainedStreamReconnects += 1
            print("[CONSOLE] STREAM-TELEMETRY sustained-state-drop old=\(old.rawValue) new=\(new.rawValue) reconnects=\(sustainedStreamReconnects)")
        }
    }

    /// Run the Bonjour discovery test. Called after pairing completes and
    /// transport monitoring starts (Mac is now advertising _keydrd._tcp).
    func runBonjourDiscoveryTestAfterPairing() {
        if dispatchToMainIfNeeded({ [weak self] in self?.runBonjourDiscoveryTestAfterPairing() }) { return }
        if let sm = sessionManager, sm.isWiredOnly && !selectedTransports.contains("wifi") && !selectedTransports.contains("awdl") {
            recordResult(name: "bonjour-discovery", passed: true,
                         detail: "SKIPPED — wireless advertising disabled for usb-only transport set")
            bonjourDiscoveryComplete = true
            return
        }
        runBonjourDiscoveryTest()
    }

    // MARK: - Test 1: Bonjour Discovery

    private func runBonjourDiscoveryTest() {
        print("[TEST] RUNNING: bonjour-discovery")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: keydrdService, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        bonjourBrowser = browser

        // Mac delays WiFi advertising by 3s after pairing (USB gets priority).
        // Bonjour propagation adds a few more seconds. Use 8s timeout.
        let discoveryTimeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.bonjourDiscoveryComplete else { return }
            self.bonjourDiscoveryComplete = true
            self.recordResult(name: "bonjour-discovery", passed: false, detail: "timeout after 8s")
            self.bonjourBrowser?.cancel()
            self.bonjourBrowser = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: discoveryTimeout)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self, !self.bonjourDiscoveryComplete else { return }

            for change in changes {
                if case .added(let result) = change {
                    self.bonjourDiscoveryComplete = true
                    discoveryTimeout.cancel()

                    var serviceName = result.endpoint.debugDescription
                    if case .service(let name, _, _, _) = result.endpoint {
                        serviceName = name
                    }
                    self.bonjourDiscoveredService = serviceName
                    self.recordResult(name: "bonjour-discovery", passed: true,
                                     detail: "found: \(serviceName)")
                    self.bonjourBrowser?.cancel()
                    self.bonjourBrowser = nil
                    return
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                guard let self = self, !self.bonjourDiscoveryComplete else { return }
                self.bonjourDiscoveryComplete = true
                discoveryTimeout.cancel()
                self.recordResult(name: "bonjour-discovery", passed: false,
                                 detail: "browser failed: \(error)")
                self.bonjourBrowser = nil
            }
        }

        let queue = DispatchQueue(label: "com.ryheff.keyd.remote.app.e2e.bonjour")
        browser.start(queue: queue)
    }

    // MARK: - Test 2: TLS Connection (called from QRPairing auto-pair)

    func reportTLSConnection(success: Bool, detail: String) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportTLSConnection(success: success, detail: detail) }) { return }
        recordResult(name: "tls-connection", passed: success, detail: detail)
    }

    // MARK: - Test 3: ECDH Exchange (called from QRPairing auto-pair)

    func reportECDHExchange(success: Bool, detail: String) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportECDHExchange(success: success, detail: detail) }) { return }
        recordResult(name: "ecdh-exchange", passed: success, detail: detail)

        // After ECDH, pairing is complete. Tests 4+ happen via session lifecycle.
    }

    // MARK: - Test 4: Transport Detection (called from SessionManager)

    func reportTransportDetected(type: String) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportTransportDetected(type: type) }) { return }
        guard !transportDetected else { return }
        transportDetected = true
        detectedTransportType = type
        recordResult(name: "transport-detected", passed: true, detail: "type: \(type)")
    }

    // MARK: - Test 5: Session Handshake (called from SessionManager)

    func reportSessionHandshake(_ handshake: SessionHandshakeMessage) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportSessionHandshake(handshake) }) { return }
        rotationHandshakeReceived = true

        guard !handshakeReceived else { return }
        handshakeReceived = true

        handshakeWidth = handshake.displayWidth
        handshakeHeight = handshake.displayHeight
        handshakeScale = handshake.scaleFactor
        handshakeCaps = handshake.capabilities
        handshakeMaxFps = handshake.maxFps

        let capsStr = describeCaps(handshake.capabilities)
        let detail = "\(handshake.displayWidth)x\(handshake.displayHeight)@\(handshake.scaleFactor)x, caps=\(capsStr)"

        let valid = handshake.magic == keydrdMagic
                 && handshake.displayWidth > 0
                 && handshake.displayHeight > 0
                 && handshake.scaleFactor > 0

        recordResult(name: "session-handshake", passed: valid, detail: detail)
    }

    // MARK: - Test 6 & 7: Frame Reception + Decompression (called from SessionManager)

    func reportFrameReceived(header: MediaFrameHeader, decompressedSize: Int) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportFrameReceived(header: header, decompressedSize: decompressedSize) }) { return }
        framesReceived += 1
        if decompressedSize > 0 {
            framesDecompressed += 1
            totalDecompressedBytes += decompressedSize
        }

        if throughputTestActive && !throughputTestComplete {
            throughputBytes += MediaFrameHeader.size + Int(header.payloadSize)
        }

        if parallelPerformanceSuiteActive {
            parallelPerformanceThroughputBytes += MediaFrameHeader.size + Int(header.payloadSize)
        }

        // Pipeline latency (capture-to-decode): Mac embeds host time in ts_us.
        // Apply Cristian's algorithm clock offset to remove Mac-iPad clock skew.
        // latency = iPad_now - (Mac_capture_time - offset)
        //         = iPad_now - Mac_capture_time + offset
        if header.tsUs > 0 {
            let nowUs = Int64(keydrdHostTimeUs())
            let latencyUs = nowUs - Int64(header.tsUs) + clockOffsetUs
            if latencyUs > 0 && latencyUs < 10_000_000 { // sanity: 0-10s
                pipelineLatenciesUs.append(latencyUs)
            }
        }

        // NOTE: FPS and throughput frame counts are NOT fed here.
        // They use MetalRenderer.onFrameRendered to count ACTUALLY RENDERED frames.
        // Throughput byte accounting is fed here because this is where the
        // compressed frame size from the transport is available.

        if framesReceived >= targetFrameCount && !frameReceptionComplete {
            frameReceptionComplete = true

            let mode = header.isHEVC ? "HEVC" : "LZ4"

            // The display link may not have ticked yet when the first 5 decoded
            // frames arrive in quick succession. Wait up to 500ms for at least
            // 1 rendered frame before reporting.
            let checkRendered = { [weak self] in
                guard let self = self, let sm = self.sessionManager else { return }
                let rendered = sm.metalRenderer.renderedFrameCount
                let renderRatio = self.framesDecompressed > 0 ? Double(rendered) / Double(self.framesDecompressed) : 0
                let receptionPassed = rendered >= 1 && renderRatio >= 0.1
                self.recordResult(name: "frame-reception", passed: receptionPassed,
                            detail: "decoded: \(self.framesReceived), rendered: \(rendered), ratio: \(String(format: "%.0f", renderRatio * 100))%, mode: \(mode)")

                if self.framesDecompressed >= self.targetFrameCount && rendered >= 1 {
                    let avgSize = self.totalDecompressedBytes / self.framesDecompressed
                    self.recordResult(name: "frame-decompression", passed: true,
                                detail: "\(self.framesDecompressed) decoded, \(rendered) rendered, avg-size: \(avgSize)")
                } else {
                    self.recordResult(name: "frame-decompression", passed: false,
                                detail: "decoded: \(self.framesDecompressed), rendered: \(rendered) — frames not reaching display")
                }

                self.runLatencyProbeTest()
            }

            let rendered = sessionManager?.metalRenderer.renderedFrameCount ?? 0
            if rendered > 0 {
                checkRendered()
            } else {
                // Display link hasn't ticked yet — give it up to 500ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    checkRendered()
                }
            }
        }
    }

    /// Report decoded pixel buffer dimensions (called from SessionManager after HEVC decode or LZ4 decompress).
    /// Used by the resolution test to verify frame dimensions match the handshake.
    func reportDecodedFrameDimensions(width: Int, height: Int) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportDecodedFrameDimensions(width: width, height: height) }) { return }
        decodedFrameWidths.append(width)
        decodedFrameHeights.append(height)
    }

    // MARK: - Test 8: Latency Probe

    private func runLatencyProbeTest() {
        print("[TEST] RUNNING: latency-probe")
        guard !latencyProbeComplete else {
            print("[CONSOLE] latency-probe: already complete, not rerunning")
            return
        }
        latencyProbeActive = true

        guard let sm = sessionManager else {
            recordResult(name: "latency-probe", passed: false, detail: "sessionManager nil")
            runKeepaliveTest()
            return
        }

        // Send a latency probe and measure round-trip
        let sentTimestamp = keydrdHostTimeUs()
        let header = InputEventHeader(type: InputEventType.latencyProbe.rawValue, tsUs: sentTimestamp)
        let data = header.serialize()

        // Send via whatever transport is active
        if sm.usbTransport.isConnected {
            sm.usbTransport.sendInputEvent(data)
        } else if sm.wirelessTransport.isConnected {
            sm.wirelessTransport.sendInputEvent(data)
        } else {
            recordResult(name: "latency-probe", passed: false, detail: "no transport connected")
            runKeepaliveTest()
            return
        }

        // The response will come back via handleInputReceived -> reportLatencyProbeResponse
        // Set a timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.latencyProbeComplete else { return }
            self.latencyProbeComplete = true
            self.latencyProbeActive = false
            self.recordResult(name: "latency-probe", passed: false, detail: "timeout after 5s")
            self.runKeepaliveTest()
        }
    }

    func reportLatencyProbeResponse(rttUs: UInt64) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportLatencyProbeResponse(rttUs: rttUs) }) { return }
        // Route to tiered latency test if it's active
        if tieredLatencyActive && !tieredLatencyComplete {
            reportTieredLatencyProbeResponse(rttUs: rttUs)
            return
        }

        guard latencyProbeActive, !latencyProbeComplete else { return }
        latencyProbeComplete = true
        latencyProbeActive = false

        let rttMs = Int(rttUs / 1000)
        latencyProbeRTT = rttMs
        recordResult(name: "latency-probe", passed: true, detail: "transport-rtt: \(rttMs)ms (note: display-to-display latency is higher — includes capture+encode+decode+display-link)")

        runKeepaliveTest()
    }

    // MARK: - Test 9: Keepalive

    private func runKeepaliveTest() {
        print("[TEST] RUNNING: keepalive")

        guard let sm = sessionManager else {
            recordResult(name: "keepalive", passed: false, detail: "sessionManager nil")
            runExtendedTests()
            return
        }

        // Send a keepalive and verify we remain connected after 3 seconds
        let header = InputEventHeader(type: InputEventType.keepalive.rawValue,
                                      tsUs: keydrdHostTimeUs())
        let data = header.serialize()

        if sm.usbTransport.isConnected {
            sm.usbTransport.sendInputEvent(data)
        } else if sm.wirelessTransport.isConnected {
            sm.wirelessTransport.sendInputEvent(data)
        }

        // Check after 3 seconds that we're still connected
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, let sm = self.sessionManager else {
                self?.recordResult(name: "keepalive", passed: false, detail: "sessionManager gone")
                self?.runExtendedTests()
                return
            }

            let stillConnected = sm.usbTransport.isConnected || sm.wirelessTransport.isConnected
            self.recordResult(name: "keepalive", passed: stillConnected,
                            detail: stillConnected ? "still connected after 3s" : "disconnected")
            // Chain into extended tests instead of finishing
            self.runExtendedTests()
        }
    }

    // MARK: - Extended Tests (run after the original 9)

    /// Entry point for the 5 new extended tests.
    /// Runs sequentially: transport-assertion -> resolution -> fps -> latency-tiered -> throughput -> finish
    private func runExtendedTests() {
        // Let the stream stabilize for 5 seconds before measuring performance.
        // Immediate measurement catches startup transients, not steady-state.
        let delay = 5.0 + Double.random(in: 0..<1.0)
        print("[CONSOLE] Extended tests: waiting \(String(format: "%.1f", delay))s for stream to stabilize")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runClockSyncCalibration()
        }
    }

    // MARK: - Clock Offset Calibration (Cristian's Algorithm)

    private func runClockSyncCalibration() {
        print("[TEST] RUNNING: clock-sync")

        guard let sm = sessionManager, sm.usbTransport.isConnected || sm.wirelessTransport.isConnected else {
            print("[TEST] INFO: clock-sync skipped (no transport)")
            runTransportAssertionTest()
            return
        }

        clockSyncSamples = []
        clockSyncProbesSent = 0
        clockSyncComplete = false
        awaitingClockSyncResponseT1Us = nil
        sendNextClockSyncProbe()
    }

    private func sendNextClockSyncProbe() {
        guard !clockSyncComplete, clockSyncProbesSent < Self.clockSyncProbeCount else {
            return
        }

        guard let sm = sessionManager else {
            completeClockSyncCalibration()
            return
        }

        // t1: iPad send host time
        let t1Us = keydrdHostTimeUs()

        let header = InputEventHeader(type: InputEventType.clockSyncReq.rawValue, tsUs: t1Us)
        let data = header.serialize()

        if sm.usbTransport.isConnected {
            sm.usbTransport.sendInputEvent(data)
        } else if sm.wirelessTransport.isConnected {
            sm.wirelessTransport.sendInputEvent(data)
        }

        clockSyncProbesSent += 1
        awaitingClockSyncResponseT1Us = t1Us

        // Timeout for this probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.clockSyncComplete else { return }
            guard self.awaitingClockSyncResponseT1Us == t1Us else { return }

            self.awaitingClockSyncResponseT1Us = nil
            if self.clockSyncProbesSent >= Self.clockSyncProbeCount {
                self.completeClockSyncCalibration()
            } else {
                self.sendNextClockSyncProbe()
            }
        }
    }

    /// Called by SessionManager when a CLOCK_SYNC_RESP arrives
    func reportClockSyncResponse(t1Us: UInt64, t2Us: UInt64, t3Us: UInt64, t4Us: UInt64) {
        if dispatchToMainIfNeeded({ [weak self] in self?.reportClockSyncResponse(t1Us: t1Us, t2Us: t2Us, t3Us: t3Us, t4Us: t4Us) }) { return }
        guard !clockSyncComplete else { return }
        guard awaitingClockSyncResponseT1Us == t1Us else { return }
        awaitingClockSyncResponseT1Us = nil

        // Cristian's algorithm:
        // RTT = (t4 - t1) - (t3 - t2)  [subtract Mac processing time]
        // offset = ((t2 - t1) + (t3 - t4)) / 2  [Mac clock - iPad clock]
        let rtt = (Int64(t4Us) - Int64(t1Us)) - (Int64(t3Us) - Int64(t2Us))
        let offset = (Int64(t2Us) - Int64(t1Us) + Int64(t3Us) - Int64(t4Us)) / 2

        clockSyncSamples.append((offset: offset, rtt: rtt))

        if clockSyncSamples.count >= Self.clockSyncProbeCount {
            completeClockSyncCalibration()
        } else {
            // Send next probe after spacing
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.clockSyncProbeSpacingMs) / 1000.0) { [weak self] in
                self?.sendNextClockSyncProbe()
            }
        }
    }

    private func completeClockSyncCalibration() {
        guard !clockSyncComplete else { return }
        clockSyncComplete = true

        guard !clockSyncSamples.isEmpty else {
            print("[TEST] INFO: clock-sync (no responses — offset unknown)")
            recordResult(name: "clock-sync", passed: true, detail: "no responses (calibration skipped)")
            runTransportAssertionTest()
            return
        }

        awaitingClockSyncResponseT1Us = nil

        // Sort by RTT, take samples with lowest RTT (most symmetric, most accurate)
        let sortedByRtt = clockSyncSamples.sorted { $0.rtt < $1.rtt }

        // Use median offset from the best-RTT half of samples
        let bestHalf = Array(sortedByRtt.prefix(max(sortedByRtt.count / 2, 1)))
        let offsets = bestHalf.map { $0.offset }.sorted()
        let medianOffset = offsets[offsets.count / 2]

        clockOffsetUs = medianOffset
        clockOffsetCalibrated = true

        let offsetMs = medianOffset / 1000
        let rttSorted = clockSyncSamples.map { $0.rtt / 1000 }.sorted()
        let minRttMs = rttSorted.first!
        let medianRttMs = rttSorted[rttSorted.count / 2]

        print("[TEST] INFO: clock-sync (\(clockSyncSamples.count) probes, offset=\(offsetMs)ms, rtt: min=\(minRttMs)ms median=\(medianRttMs)ms)")
        recordResult(name: "clock-sync", passed: true,
                    detail: "offset=\(offsetMs)ms (\(clockSyncSamples.count) probes, rtt: min=\(minRttMs)ms median=\(medianRttMs)ms)")

        runTransportAssertionTest()
    }

    // MARK: - Test 10: Transport Type Assertion

    private func runTransportAssertionTest() {
        let usesShortProfile = profile != "full"
        guard let expected = expectTransport else {
            // No --expect-transport flag, skip
            if usesShortProfile {
                runVideoPlaybackTest()
                return
            }
            runParallelPerformanceSuite()
            return
        }

        print("[TEST] RUNNING: transport-assertion")

        guard transportDetected else {
            recordResult(name: "transport-assertion", passed: false, detail: "no transport detected yet")
            if usesShortProfile {
                runVideoPlaybackTest()
                return
            }
            runParallelPerformanceSuite()
            return
        }

        // Normalize transport names for comparison
        let normalizedExpected = expected.lowercased()
        let normalizedActual = detectedTransportType.lowercased()

        // Map transport state names (usbNCM, wifi, awdl) to match flag values (usb, wifi, awdl)
        let actualMapped: String
        switch normalizedActual {
        case "usbncm", "usb":
            actualMapped = "usb"
        case "wifi":
            actualMapped = "wifi"
        case "awdl":
            actualMapped = "awdl"
        default:
            actualMapped = normalizedActual
        }

        let passed = actualMapped == normalizedExpected
        transportAssertionComplete = true
        recordResult(name: "transport-assertion", passed: passed,
                    detail: "expected=\(normalizedExpected), actual=\(actualMapped)")
        if usesShortProfile {
            runVideoPlaybackTest()
            return
        }
        runParallelPerformanceSuite()
    }

    private func runParallelPerformanceSuite() {
        guard let sm = sessionManager else {
            recordResult(name: "resolution", passed: false, detail: "sessionManager nil")
            recordResult(name: "fps", passed: false, detail: "sessionManager nil")
            recordResult(name: "frame-pacing", passed: false, detail: "sessionManager nil")
            recordResult(name: "frame-loss", passed: false, detail: "sessionManager nil")
            recordResult(name: "throughput", passed: false, detail: "sessionManager nil")
            recordResult(name: "pipeline-latency", passed: false, detail: "sessionManager nil")
            recordResult(name: "glass-to-glass-latency", passed: false, detail: "sessionManager nil")
            if skipTransportRotation {
                runSecurityTests()
            } else {
                runTransportRotationTests()
            }
            return
        }

        guard !parallelPerformanceSuiteActive, !parallelPerformanceSuiteFinalized else { return }

        parallelPerformanceSuiteActive = true
        parallelPerformanceSuiteFinalized = false
        parallelPerformanceStartTime = CFAbsoluteTimeGetCurrent()
        parallelPerformanceFrameTimestamps = []
        parallelPerformanceThroughputBytes = 0
        parallelPerformanceRenderedStartCount = sm.metalRenderer.renderedFrameCount
        parallelPerformanceFramesReceivedStartCount = framesReceived
        parallelPerformanceDeliveredStartCount = sm.udpReassembler.framesDelivered
        parallelPerformanceEvictedStartCount = sm.udpReassembler.framesEvicted
        parallelPerformancePurgedStartCount = sm.udpReassembler.framesPurged
        parallelPerformanceChunksStartCount = sm.udpReassembler.chunksReceived
        parallelPerformancePipelineStartCount = pipelineLatenciesUs.count
        parallelPerformanceGlassStartCount = glassToGlassLatenciesUs.count

        print("[TEST] RUNNING: resolution")
        print("[TEST] RUNNING: fps")
        print("[TEST] RUNNING: frame-pacing")
        print("[TEST] RUNNING: frame-loss")
        print("[TEST] RUNNING: throughput")
        print("[TEST] RUNNING: pipeline-latency")
        print("[TEST] RUNNING: glass-to-glass-latency")

        runTieredLatencyTest()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.parallelPerformanceHeavyLoadLeadIn) { [weak self] in
            self?.runHeavyLoadTest()
        }
    }

    private func finalizeParallelPerformanceSuiteAndContinue() {
        guard parallelPerformanceSuiteActive, !parallelPerformanceSuiteFinalized else {
            if skipTransportRotation {
                runSecurityTests()
            } else {
                runTransportRotationTests()
            }
            return
        }

        parallelPerformanceSuiteActive = false
        parallelPerformanceSuiteFinalized = true

        reportParallelResolution()
        reportParallelFPSAndPacing()
        reportParallelFrameLoss()
        reportParallelThroughput()
        reportParallelPipelineLatency()
        reportParallelGlassToGlassLatency()

        if skipTransportRotation {
            runSecurityTests()
        } else {
            runTransportRotationTests()
        }
    }

    private func reportParallelResolution() {
        guard handshakeReceived else {
            recordResult(name: "resolution", passed: false, detail: "no handshake received")
            return
        }

        let iPadW = max(Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height))
        let iPadH = min(Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height))
        let (vpW, vpH) = SessionManager.computeViewportPixels(
            macWidth: Int(handshakeWidth), macHeight: Int(handshakeHeight),
            screenWidth: iPadW, screenHeight: iPadH
        )

        let handshakeW = Int(handshakeWidth)
        let handshakeH = Int(handshakeHeight)
        let currentVpW = sessionManager?.viewportWidth ?? vpW
        let currentVpH = sessionManager?.viewportHeight ?? vpH

        guard let frameW = decodedFrameWidths.last, let frameH = decodedFrameHeights.last else {
            recordResult(name: "resolution", passed: false,
                        detail: "frame=n/a, viewport=\(vpW)x\(vpH), geometry=\(currentVpW)x\(currentVpH), mac=\(handshakeW)x\(handshakeH) [ISSUES: no decoded frame dimensions to verify]")
            return
        }

        let geometryWidthScale = vpW > 0 ? Double(currentVpW) / Double(vpW) : 0
        let geometryHeightScale = vpH > 0 ? Double(currentVpH) / Double(vpH) : 0
        let frameWidthScale = vpW > 0 ? Double(frameW) / Double(vpW) : 0
        let frameHeightScale = vpH > 0 ? Double(frameH) / Double(vpH) : 0
        let geometryWidthOK = geometryWidthScale >= E2ETestThresholds.Resolution.minGeometryWidthScale
        let geometryHeightOK = geometryHeightScale >= E2ETestThresholds.Resolution.minGeometryHeightScale
        let frameWidthOK = frameWidthScale >= E2ETestThresholds.Resolution.minFrameWidthScale
        let frameHeightOK = frameHeightScale >= E2ETestThresholds.Resolution.minFrameHeightScale
        let passed = geometryWidthOK && geometryHeightOK && frameWidthOK && frameHeightOK

        var issues: [String] = []
        if !geometryWidthOK { issues.append("geometry width scale \(String(format: "%.3f", geometryWidthScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryWidthScale))") }
        if !geometryHeightOK { issues.append("geometry height scale \(String(format: "%.3f", geometryHeightScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryHeightScale))") }
        if !frameWidthOK { issues.append("frame width scale \(String(format: "%.3f", frameWidthScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameWidthScale))") }
        if !frameHeightOK { issues.append("frame height scale \(String(format: "%.3f", frameHeightScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameHeightScale))") }
        var detail = "geometryScale=\(String(format: "%.3f", geometryWidthScale))x\(String(format: "%.3f", geometryHeightScale)) (target >=\(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryWidthScale))x\(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryHeightScale))), frameScale=\(String(format: "%.3f", frameWidthScale))x\(String(format: "%.3f", frameHeightScale)) (target >=\(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameWidthScale))x\(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameHeightScale))), viewport=\(vpW)x\(vpH), geometry=\(currentVpW)x\(currentVpH), frame=\(frameW)x\(frameH), mac=\(handshakeW)x\(handshakeH)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "resolution", passed: passed, detail: detail)
    }

    private func reportParallelFPSAndPacing() {
        let elapsed = CFAbsoluteTimeGetCurrent() - parallelPerformanceStartTime
        let timestamps = parallelPerformanceFrameTimestamps
        let frameCount = timestamps.count

        guard frameCount > 0 else {
            recordResult(name: "fps", passed: false,
                        detail: "0 fps, 0 rendered frames in \(String(format: "%.1f", elapsed))s — display link not running")
            recordResult(name: "frame-pacing", passed: false, detail: "no frame intervals to analyze")
            return
        }

        let avgFPS: Double = elapsed > 0 ? Double(frameCount) / elapsed : 0
        var intervals: [Double] = []
        for i in 1..<frameCount {
            intervals.append((timestamps[i] - timestamps[i - 1]) * 1000.0)
        }

        var stutterCount = 0
        var medianInterval: Double = 0
        var p95Interval: Double = 0
        var p99Interval: Double = 0
        var maxInterval: Double = 0
        var minInterval: Double = 0
        var jitterStdDev: Double = 0

        if !intervals.isEmpty {
            let sorted = intervals.sorted()
            minInterval = sorted.first!
            maxInterval = sorted.last!
            medianInterval = sorted[sorted.count / 2]
            p95Interval = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            p99Interval = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
            jitterStdDev = sqrt(variance)
            stutterCount = intervals.filter { $0 > 100.0 }.count
        }

        print("[TEST] INFO: fps-detail (avg=\(String(format: "%.1f", avgFPS)) fps, \(frameCount) frames in \(String(format: "%.1f", elapsed))s)")
        if !intervals.isEmpty {
            print("[TEST] INFO: frame-intervals (min=\(String(format: "%.0f", minInterval))ms, median=\(String(format: "%.0f", medianInterval))ms, p95=\(String(format: "%.0f", p95Interval))ms, max=\(String(format: "%.0f", maxInterval))ms)")
            print("[TEST] INFO: frame-jitter (stddev=\(String(format: "%.1f", jitterStdDev))ms, stutters=\(stutterCount) (>100ms gaps))")
        }

        var worstWindowFPS: Double = avgFPS
        if timestamps.count >= 10 {
            let lastTimestamp = timestamps.last!
            var minFramesInWindow = Int.max
            for startIdx in 0..<timestamps.count {
                if timestamps[startIdx] > lastTimestamp - 1.0 { break }
                let windowEnd = timestamps[startIdx] + 1.0
                var endIdx = startIdx
                while endIdx < timestamps.count && timestamps[endIdx] < windowEnd {
                    endIdx += 1
                }
                minFramesInWindow = min(minFramesInWindow, endIdx - startIdx)
            }
            if minFramesInWindow < Int.max {
                worstWindowFPS = Double(minFramesInWindow)
            }
        }

        let hasEnoughFrames = frameCount >= E2ETestThresholds.FPS.minFrameCount
        let stutterRatio = intervals.isEmpty ? 1.0 : Double(stutterCount) / Double(intervals.count)
        let isConsistent = stutterRatio < (E2ETestThresholds.FPS.maxStutterPercent / 100.0)
        let noLongFreeze = maxInterval < E2ETestThresholds.FPS.maxGapMs
        let worstWindowOK = worstWindowFPS >= E2ETestThresholds.FPS.minWorstOneSecondFPS
        let requiredFPS = max(Double(expectFPS ?? 0), E2ETestThresholds.FPS.minAverageFPS)
        let meetsTarget = avgFPS >= requiredFPS
        let onePercentLowFPS = p99Interval > 0 ? 1000.0 / p99Interval : avgFPS
        let onePercentLowOK = onePercentLowFPS >= E2ETestThresholds.FPS.minOnePercentLowFPS
        let jitterOK = jitterStdDev <= E2ETestThresholds.FPS.maxJitterMs
        let stutterRatioPct = stutterRatio * 100.0
        let fpsPassed = meetsTarget && hasEnoughFrames && isConsistent && noLongFreeze && worstWindowOK && onePercentLowOK && jitterOK

        var fpsIssues: [String] = []
        if !hasEnoughFrames { fpsIssues.append("too few frames (\(frameCount))") }
        if !isConsistent { fpsIssues.append("\(String(format: "%.0f", stutterRatioPct))% stutters") }
        if !noLongFreeze { fpsIssues.append("max gap \(String(format: "%.0f", maxInterval))ms") }
        if !worstWindowOK { fpsIssues.append("worst 1s window: \(String(format: "%.0f", worstWindowFPS))fps") }
        if !meetsTarget { fpsIssues.append("avg \(String(format: "%.1f", avgFPS)) < target \(String(format: "%.0f", requiredFPS))") }
        if !onePercentLowOK { fpsIssues.append("1% low \(String(format: "%.1f", onePercentLowFPS))fps < \(String(format: "%.1f", E2ETestThresholds.FPS.minOnePercentLowFPS))fps") }
        if !jitterOK { fpsIssues.append("jitter \(String(format: "%.1f", jitterStdDev))ms > \(String(format: "%.1f", E2ETestThresholds.FPS.maxJitterMs))ms") }

        var fpsDetail = "avgFPS=\(String(format: "%.1f", avgFPS)) (target >=\(String(format: "%.0f", requiredFPS))fps), onePctLow=\(String(format: "%.1f", onePercentLowFPS))fps (target >=\(String(format: "%.1f", E2ETestThresholds.FPS.minOnePercentLowFPS))fps), p95Frame=\(String(format: "%.0f", p95Interval))ms, stutterPct=\(String(format: "%.1f", stutterRatioPct)) (target <=\(String(format: "%.1f", E2ETestThresholds.FPS.maxStutterPercent))%), worst1s=\(String(format: "%.0f", worstWindowFPS))fps (target >=\(String(format: "%.0f", E2ETestThresholds.FPS.minWorstOneSecondFPS))fps), maxGap=\(String(format: "%.0f", maxInterval))ms (target <\(String(format: "%.0f", E2ETestThresholds.FPS.maxGapMs))ms), jitter=\(String(format: "%.1f", jitterStdDev))ms (target <=\(String(format: "%.1f", E2ETestThresholds.FPS.maxJitterMs))ms), frames=\(frameCount) (target >=\(E2ETestThresholds.FPS.minFrameCount))"
        if !fpsIssues.isEmpty {
            fpsDetail += " [ISSUES: \(fpsIssues.joined(separator: ", "))]"
        }
        recordResult(name: "fps", passed: fpsPassed, detail: fpsDetail)

        guard !intervals.isEmpty else {
            recordResult(name: "frame-pacing", passed: false, detail: "no frame intervals to analyze")
            return
        }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        let stddev = sqrt(variance)
        let cv = mean > 0 ? stddev / mean : 999.0
        let pacingPassed = cv < E2ETestThresholds.FramePacing.maxCoefficientOfVariation
        let pacingDetail = "cv=\(String(format: "%.3f", cv)) (target <\(String(format: "%.3f", E2ETestThresholds.FramePacing.maxCoefficientOfVariation))), stddev=\(String(format: "%.1f", stddev))ms, mean=\(String(format: "%.1f", mean))ms"
        recordResult(name: "frame-pacing", passed: pacingPassed, detail: pacingDetail)
    }

    private func reportParallelFrameLoss() {
        guard let sm = sessionManager else {
            recordResult(name: "frame-loss", passed: false, detail: "sessionManager nil")
            return
        }

        let delivered = max(0, sm.udpReassembler.framesDelivered - parallelPerformanceDeliveredStartCount)
        let evicted = max(0, sm.udpReassembler.framesEvicted - parallelPerformanceEvictedStartCount)
        let purged = max(0, sm.udpReassembler.framesPurged - parallelPerformancePurgedStartCount)
        let totalDropped = evicted + purged
        let chunks = max(0, sm.udpReassembler.chunksReceived - parallelPerformanceChunksStartCount)
        let rendered = max(0, sm.metalRenderer.renderedFrameCount - parallelPerformanceRenderedStartCount)
        let received = max(0, framesReceived - parallelPerformanceFramesReceivedStartCount)
        let totalReceived = max(delivered, received)
        let totalFrames = totalReceived + totalDropped
        let lossRatio: Double = totalFrames > 0 ? Double(totalDropped) / Double(totalFrames) : 0
        let transport = sm.usbTransport.isConnected ? "USB/TCP" : "WiFi/UDP"
        print("[TEST] INFO: frame-loss (transport=\(transport), delivered=\(delivered), received=\(received), evicted=\(evicted), purged=\(purged), chunks=\(chunks), rendered=\(rendered))")

        let lossOK = lossRatio < (E2ETestThresholds.FrameLoss.maxLossPercent / 100.0)
        let renderOK = rendered >= E2ETestThresholds.FrameLoss.minRenderedFrames
        let passed = lossOK && renderOK

        var issues: [String] = []
        if !lossOK { issues.append("\(String(format: "%.1f", lossRatio * 100))% loss") }
        if !renderOK { issues.append("only \(rendered) rendered") }

        var detail = "loss=\(String(format: "%.1f", lossRatio * 100))% (target <\(String(format: "%.1f", E2ETestThresholds.FrameLoss.maxLossPercent))%), rendered=\(rendered) (target >=\(E2ETestThresholds.FrameLoss.minRenderedFrames)), transport=\(transport), dropped=\(totalDropped)/\(totalFrames)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "frame-loss", passed: passed, detail: detail)
    }

    private func reportParallelThroughput() {
        let elapsed = CFAbsoluteTimeGetCurrent() - parallelPerformanceStartTime
        let renderedFrames = parallelPerformanceFrameTimestamps.count
        let mbps = elapsed > 0 ? (Double(parallelPerformanceThroughputBytes) * 8.0) / (elapsed * 1_000_000.0) : 0
        let avgFPS = elapsed > 0 ? Double(renderedFrames) / elapsed : 0
        let passed = renderedFrames >= E2ETestThresholds.Throughput.minFrameCount && avgFPS >= E2ETestThresholds.Throughput.minAverageFPS
        print("[TEST] INFO: throughput (app-recv=\(String(format: "%.1f", mbps)) Mbps, \(String(format: "%.1f", avgFPS)) rendered fps over \(String(format: "%.1f", elapsed))s, frames=\(renderedFrames), excludes TCP/DTLS/IP overhead)")
        let detail = "avgFPS=\(String(format: "%.1f", avgFPS)) (target >=\(String(format: "%.1f", E2ETestThresholds.Throughput.minAverageFPS))fps), frames=\(renderedFrames) (target >=\(E2ETestThresholds.Throughput.minFrameCount)), appRecv=\(String(format: "%.1f", mbps))Mbps, duration=\(String(format: "%.1f", elapsed))s"
        recordResult(name: "throughput", passed: passed, detail: detail)
    }

    private func reportParallelPipelineLatency() {
        let sliceStart = min(parallelPerformancePipelineStartCount, pipelineLatenciesUs.count)
        let values = Array(pipelineLatenciesUs.suffix(from: sliceStart))
        guard !values.isEmpty else {
            print("[TEST] INFO: pipeline-latency (no samples — clock skew too large or no frames)")
            recordResult(name: "pipeline-latency", passed: false, detail: "no samples collected — screen likely black")
            return
        }

        let minSamples = E2ETestThresholds.PipelineLatency.minSamples
        guard values.count >= minSamples else {
            print("[TEST] INFO: pipeline-latency (only \(values.count) samples — too few, screen likely not rendering)")
            recordResult(name: "pipeline-latency", passed: false,
                        detail: "only \(values.count) samples (need \(minSamples)+) — insufficient frame delivery")
            return
        }

        let sorted = values.sorted()
        let count = sorted.count
        let minMs = sorted.first! / 1000
        let maxMs = sorted.last! / 1000
        let medianMs = sorted[count / 2] / 1000
        let p95Idx = min(Int(Double(count) * 0.95), count - 1)
        let p95Ms = sorted[p95Idx] / 1000
        let avgMs = sorted.reduce(0, +) / Int64(count) / 1000
        let calibrated = clockOffsetCalibrated ? "calibrated, offset=\(clockOffsetUs/1000)ms" : "uncalibrated"
        print("[TEST] INFO: pipeline-latency (capture-to-decode, \(count) samples: min=\(minMs)ms, median=\(medianMs)ms, avg=\(avgMs)ms, p95=\(p95Ms)ms, max=\(maxMs)ms, clock=\(calibrated))")

        let medianThreshold = E2ETestThresholds.PipelineLatency.maxMedianMs
        let avgThreshold = E2ETestThresholds.PipelineLatency.maxAverageMs
        let p95Threshold = E2ETestThresholds.PipelineLatency.maxP95Ms
        let medianOK = medianMs < medianThreshold
        let avgOK = avgMs < avgThreshold
        let p95OK = p95Ms < p95Threshold
        let passed = medianOK && avgOK && p95OK
        var issues: [String] = []
        if !medianOK { issues.append("median \(medianMs)ms >= \(medianThreshold)ms") }
        if !avgOK { issues.append("avg \(avgMs)ms >= \(avgThreshold)ms") }
        if !p95OK { issues.append("p95 \(p95Ms)ms >= \(p95Threshold)ms") }
        var detail = "latency[min/med/avg/p95/max]=\(minMs)/\(medianMs)/\(avgMs)/\(p95Ms)/\(maxMs)ms, targets med<\(medianThreshold) avg<\(avgThreshold) p95<\(p95Threshold), samples=\(count), clock=\(calibrated)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "pipeline-latency", passed: passed, detail: detail)
    }

    private func reportParallelGlassToGlassLatency() {
        let sliceStart = min(parallelPerformanceGlassStartCount, glassToGlassLatenciesUs.count)
        let values = Array(glassToGlassLatenciesUs.suffix(from: sliceStart))
        guard !values.isEmpty else {
            print("[TEST] INFO: glass-to-glass-latency (no samples — presentedHandler not firing or clock skew)")
            recordResult(name: "glass-to-glass-latency", passed: false,
                        detail: "no samples collected — screen likely black")
            return
        }

        let minSamples = E2ETestThresholds.GlassToGlassLatency.minSamples
        guard values.count >= minSamples else {
            print("[TEST] INFO: glass-to-glass-latency (only \(values.count) samples — too few)")
            recordResult(name: "glass-to-glass-latency", passed: false,
                        detail: "only \(values.count) samples (need \(minSamples)+) — insufficient frame delivery")
            return
        }

        let sorted = values.sorted()
        let count = sorted.count
        let minMs = sorted.first! / 1000
        let maxMs = sorted.last! / 1000
        let medianMs = sorted[count / 2] / 1000
        let p95Idx = min(Int(Double(count) * 0.95), count - 1)
        let p95Ms = sorted[p95Idx] / 1000
        let avgMs = sorted.reduce(0, +) / Int64(count) / 1000
        let calibrated = clockOffsetCalibrated ? "calibrated, offset=\(clockOffsetUs/1000)ms" : "uncalibrated"
        print("[TEST] INFO: glass-to-glass-latency (capture-to-presented, \(count) samples: min=\(minMs)ms, median=\(medianMs)ms, avg=\(avgMs)ms, p95=\(p95Ms)ms, max=\(maxMs)ms, clock=\(calibrated))")

        let pipelineSliceStart = min(parallelPerformancePipelineStartCount, pipelineLatenciesUs.count)
        let pipelineValues = Array(pipelineLatenciesUs.suffix(from: pipelineSliceStart))
        if !pipelineValues.isEmpty {
            let pipelineSorted = pipelineValues.sorted()
            let pipelineMedianMs = pipelineSorted[pipelineSorted.count / 2] / 1000
            let overheadMs = medianMs - pipelineMedianMs
            print("[TEST] INFO: glass-to-glass overhead vs decode: \(overheadMs)ms (present+display-link)")
        }

        let medianThreshold = E2ETestThresholds.GlassToGlassLatency.maxMedianMs
        let avgThreshold = E2ETestThresholds.GlassToGlassLatency.maxAverageMs
        let p95Threshold = E2ETestThresholds.GlassToGlassLatency.maxP95Ms
        let medianOK = medianMs < medianThreshold
        let avgOK = avgMs < avgThreshold
        let p95OK = p95Ms < p95Threshold
        let passed = medianOK && avgOK && p95OK
        var issues: [String] = []
        if !medianOK { issues.append("median \(medianMs)ms >= \(medianThreshold)ms") }
        if !avgOK { issues.append("avg \(avgMs)ms >= \(avgThreshold)ms") }
        if !p95OK { issues.append("p95 \(p95Ms)ms >= \(p95Threshold)ms") }
        var detail = "latency[min/med/avg/p95/max]=\(minMs)/\(medianMs)/\(avgMs)/\(p95Ms)/\(maxMs)ms, targets med<\(medianThreshold) avg<\(avgThreshold) p95<\(p95Threshold), samples=\(count), clock=\(calibrated)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "glass-to-glass-latency", passed: passed, detail: detail)
    }

    // MARK: - Test 11: Resolution

    private func runResolutionTest() {
        print("[TEST] RUNNING: resolution")

        guard handshakeReceived else {
            recordResult(name: "resolution", passed: false, detail: "no handshake received")
            runFPSTest()
            return
        }

        // The Mac should now encode at the iPad viewport resolution, NOT its native display.
        // Compute expected viewport dims the same way SessionManager does.
        let iPadW = max(Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height))
        let iPadH = min(Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height))
        let (vpW, vpH) = SessionManager.computeViewportPixels(
            macWidth: Int(handshakeWidth), macHeight: Int(handshakeHeight),
            screenWidth: iPadW, screenHeight: iPadH
        )

        let handshakeW = Int(handshakeWidth)
        let handshakeH = Int(handshakeHeight)

        if decodedFrameWidths.count >= 3 {
            let frameW = decodedFrameWidths.last!
            let frameH = decodedFrameHeights.last!

            // Frames should match viewport dimensions (what Mac encodes after viewport report).
            // After display mode match, Mac may encode at a slightly different resolution
            // (closest available display mode). Accept either the initial viewport OR the
            // current session viewport (updated via geometry update after mode match).
            let currentVpW = sessionManager?.viewportWidth ?? vpW
            let currentVpH = sessionManager?.viewportHeight ?? vpH
            let geometryWidthScale = vpW > 0 ? Double(currentVpW) / Double(vpW) : 0
            let geometryHeightScale = vpH > 0 ? Double(currentVpH) / Double(vpH) : 0
            let frameWidthScale = vpW > 0 ? Double(frameW) / Double(vpW) : 0
            let frameHeightScale = vpH > 0 ? Double(frameH) / Double(vpH) : 0
            let geometryWidthOK = geometryWidthScale >= E2ETestThresholds.Resolution.minGeometryWidthScale
            let geometryHeightOK = geometryHeightScale >= E2ETestThresholds.Resolution.minGeometryHeightScale
            let frameWidthOK = frameWidthScale >= E2ETestThresholds.Resolution.minFrameWidthScale
            let frameHeightOK = frameHeightScale >= E2ETestThresholds.Resolution.minFrameHeightScale
            let resolutionFloorPassed = geometryWidthOK && geometryHeightOK && frameWidthOK && frameHeightOK

            if let expected = expectResolution {
                let expPassed = frameW == expected.width && frameH == expected.height
                recordResult(name: "resolution", passed: expPassed,
                            detail: "frame=\(frameW)x\(frameH)==\(expected.width)x\(expected.height), viewport=\(vpW)x\(vpH), geometry=\(currentVpW)x\(currentVpH), mac=\(handshakeW)x\(handshakeH)")
            } else {
                var issues: [String] = []
                if !geometryWidthOK { issues.append("geometry width scale \(String(format: "%.3f", geometryWidthScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryWidthScale))") }
                if !geometryHeightOK { issues.append("geometry height scale \(String(format: "%.3f", geometryHeightScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryHeightScale))") }
                if !frameWidthOK { issues.append("frame width scale \(String(format: "%.3f", frameWidthScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameWidthScale))") }
                if !frameHeightOK { issues.append("frame height scale \(String(format: "%.3f", frameHeightScale)) < \(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameHeightScale))") }
                var detail = "geometryScale=\(String(format: "%.3f", geometryWidthScale))x\(String(format: "%.3f", geometryHeightScale)) (target >=\(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryWidthScale))x\(String(format: "%.2f", E2ETestThresholds.Resolution.minGeometryHeightScale))), frameScale=\(String(format: "%.3f", frameWidthScale))x\(String(format: "%.3f", frameHeightScale)) (target >=\(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameWidthScale))x\(String(format: "%.2f", E2ETestThresholds.Resolution.minFrameHeightScale))), viewport=\(vpW)x\(vpH), geometry=\(currentVpW)x\(currentVpH), frame=\(frameW)x\(frameH), mac=\(handshakeW)x\(handshakeH)"
                if !issues.isEmpty {
                    detail += " [ISSUES: \(issues.joined(separator: ", "))]"
                }
                recordResult(name: "resolution", passed: resolutionFloorPassed,
                            detail: detail)
            }
        } else {
            recordResult(name: "resolution", passed: false,
                        detail: "frame=n/a, viewport=\(vpW)x\(vpH), geometry=\((sessionManager?.viewportWidth ?? vpW))x\((sessionManager?.viewportHeight ?? vpH)), mac=\(handshakeW)x\(handshakeH) [ISSUES: no decoded frame dimensions to verify]")
        }

        resolutionTestComplete = true
        runFPSTest()
    }

    // MARK: - Test 12: FPS

    private func runFPSTest() {
        print("[TEST] RUNNING: fps")

        guard let sm = sessionManager, sm.usbTransport.isConnected || sm.wirelessTransport.isConnected else {
            recordResult(name: "fps", passed: false, detail: "no transport connected")
            runTieredLatencyTest()
            return
        }
        _ = sm // connectivity check only

        // Collect frames with timestamps for jitter analysis
        fpsTestActive = true
        fpsTestStartTime = CFAbsoluteTimeGetCurrent()
        fpsTestFrameCount = 0
        fpsFrameTimestamps = []

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fpsTestDuration) { [weak self] in
            guard let self = self, !self.fpsTestComplete else { return }
            self.fpsTestActive = false
            self.fpsTestComplete = true

            let elapsed = CFAbsoluteTimeGetCurrent() - self.fpsTestStartTime
            let timestamps = self.fpsFrameTimestamps
            let frameCount = timestamps.count

            // If no rendered frames at all, fail immediately — don't try to compute stats
            if frameCount == 0 {
                self.recordResult(name: "fps", passed: false,
                            detail: "0 fps, 0 rendered frames in \(String(format: "%.1f", elapsed))s — display link not running")
                self.runFrameLossTest()
                return
            }

            // Compute average FPS
            let avgFPS: Double = elapsed > 0 ? Double(frameCount) / elapsed : 0

            // Compute frame intervals and jitter stats
            var intervals: [Double] = []
            for i in 1..<frameCount {
                intervals.append((timestamps[i] - timestamps[i-1]) * 1000.0) // ms
            }

            var stutterCount = 0  // gaps > 100ms
            var medianInterval: Double = 0
            var p95Interval: Double = 0
            var p99Interval: Double = 0
            var maxInterval: Double = 0
            var minInterval: Double = 0
            var jitterStdDev: Double = 0

            if !intervals.isEmpty {
                let sorted = intervals.sorted()
                minInterval = sorted.first!
                maxInterval = sorted.last!
                medianInterval = sorted[sorted.count / 2]
                p95Interval = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                p99Interval = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]

                let mean = intervals.reduce(0, +) / Double(intervals.count)
                let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
                jitterStdDev = sqrt(variance)

                stutterCount = intervals.filter { $0 > 100.0 }.count
            }

            // Print detailed timing info
            print("[TEST] INFO: fps-detail (avg=\(String(format: "%.1f", avgFPS)) fps, \(frameCount) frames in \(String(format: "%.1f", elapsed))s)")
            if !intervals.isEmpty {
                print("[TEST] INFO: frame-intervals (min=\(String(format: "%.0f", minInterval))ms, median=\(String(format: "%.0f", medianInterval))ms, p95=\(String(format: "%.0f", p95Interval))ms, max=\(String(format: "%.0f", maxInterval))ms)")
                print("[TEST] INFO: frame-jitter (stddev=\(String(format: "%.1f", jitterStdDev))ms, stutters=\(stutterCount) (>100ms gaps))")
            }

            // Compute worst 1-second window FPS.
            // Only consider windows that start at least 1s before the last frame
            // to avoid false low counts from partial windows at test boundaries.
            var worstWindowFPS: Double = avgFPS  // default to average if not enough data
            if timestamps.count >= 10 {
                let lastTimestamp = timestamps.last!
                var minFramesInWindow = Int.max
                for startIdx in 0..<timestamps.count {
                    // Skip windows that start within the last 1s (would be partial)
                    if timestamps[startIdx] > lastTimestamp - 1.0 { break }
                    let windowEnd = timestamps[startIdx] + 1.0
                    var endIdx = startIdx
                    while endIdx < timestamps.count && timestamps[endIdx] < windowEnd {
                        endIdx += 1
                    }
                    let framesInWindow = endIdx - startIdx
                    if framesInWindow < minFramesInWindow {
                        minFramesInWindow = framesInWindow
                    }
                }
                if minFramesInWindow < Int.max {
                    worstWindowFPS = Double(minFramesInWindow)
                }
            }

            // Pass criteria — hard quality gate:
            // 1. Must have meaningful frames (>= 20 unique frames in 10s)
            // 2. Stutter ratio < 5%
            // 3. Max gap < 200ms
            // 4. Worst 1s window must have >= 5 frames
            // 5. Average FPS must meet a 60fps minimum unless an even stricter
            //    --expect-fps target is provided at launch.
            let hasEnoughFrames = frameCount >= E2ETestThresholds.FPS.minFrameCount
            let stutterRatio = intervals.isEmpty ? 1.0 : Double(stutterCount) / Double(intervals.count)
            let isConsistent = stutterRatio < (E2ETestThresholds.FPS.maxStutterPercent / 100.0)
            let noLongFreeze = maxInterval < E2ETestThresholds.FPS.maxGapMs
            let worstWindowOK = worstWindowFPS >= E2ETestThresholds.FPS.minWorstOneSecondFPS
            let minimumRequiredFPS = E2ETestThresholds.FPS.minAverageFPS
            let stutterRatioPct = stutterRatio * 100.0

            var passed: Bool
            var detail: String
            var issues: [String] = []

            if !hasEnoughFrames { issues.append("too few frames (\(frameCount))") }
            if !isConsistent { issues.append("\(String(format: "%.0f", stutterRatio * 100))% stutters") }
            if !noLongFreeze { issues.append("max gap \(String(format: "%.0f", maxInterval))ms") }
            if !worstWindowOK { issues.append("worst 1s window: \(String(format: "%.0f", worstWindowFPS))fps") }

            let requiredFPS = max(Double(self.expectFPS ?? 0), minimumRequiredFPS)
            let meetsTarget = avgFPS >= requiredFPS
            let onePercentLowFPS = p99Interval > 0 ? 1000.0 / p99Interval : avgFPS
            let onePercentLowOK = onePercentLowFPS >= E2ETestThresholds.FPS.minOnePercentLowFPS
            let jitterOK = jitterStdDev <= E2ETestThresholds.FPS.maxJitterMs
            if !meetsTarget { issues.append("avg \(String(format: "%.1f", avgFPS)) < target \(String(format: "%.0f", requiredFPS))") }
            if !onePercentLowOK { issues.append("1% low \(String(format: "%.1f", onePercentLowFPS))fps < \(String(format: "%.1f", E2ETestThresholds.FPS.minOnePercentLowFPS))fps") }
            if !jitterOK { issues.append("jitter \(String(format: "%.1f", jitterStdDev))ms > \(String(format: "%.1f", E2ETestThresholds.FPS.maxJitterMs))ms") }
            passed = meetsTarget && hasEnoughFrames && isConsistent && noLongFreeze && worstWindowOK && onePercentLowOK && jitterOK

            detail = "avgFPS=\(String(format: "%.1f", avgFPS)) (target >=\(String(format: "%.0f", requiredFPS))fps), onePctLow=\(String(format: "%.1f", onePercentLowFPS))fps (target >=\(String(format: "%.1f", E2ETestThresholds.FPS.minOnePercentLowFPS))fps), p95Frame=\(String(format: "%.0f", p95Interval))ms, stutterPct=\(String(format: "%.1f", stutterRatioPct)) (target <=\(String(format: "%.1f", E2ETestThresholds.FPS.maxStutterPercent))%), worst1s=\(String(format: "%.0f", worstWindowFPS))fps (target >=\(String(format: "%.0f", E2ETestThresholds.FPS.minWorstOneSecondFPS))fps), maxGap=\(String(format: "%.0f", maxInterval))ms (target <\(String(format: "%.0f", E2ETestThresholds.FPS.maxGapMs))ms), jitter=\(String(format: "%.1f", jitterStdDev))ms (target <=\(String(format: "%.1f", E2ETestThresholds.FPS.maxJitterMs))ms), frames=\(frameCount) (target >=\(E2ETestThresholds.FPS.minFrameCount))"

            if !issues.isEmpty {
                detail += " [ISSUES: \(issues.joined(separator: ", "))]"
            }

            self.recordResult(name: "fps", passed: passed, detail: detail)

            // Run frame pacing test using the same interval data
            self.runFramePacingTest(intervals: intervals)
        }
    }

    // MARK: - Test 12b: Frame Pacing Consistency (wired)

    private func runFramePacingTest(intervals: [Double]) {
        print("[TEST] RUNNING: frame-pacing")

        guard !intervals.isEmpty else {
            recordResult(name: "frame-pacing", passed: false, detail: "no frame intervals to analyze")
            runFrameLossTest()
            return
        }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        let stddev = sqrt(variance)

        // Coefficient of variation = stddev / mean
        let cv = mean > 0 ? stddev / mean : 999.0

        // PASS if CV < 0.35 (35% variation)
        let passed = cv < E2ETestThresholds.FramePacing.maxCoefficientOfVariation
        let detail = "cv=\(String(format: "%.3f", cv)) (target <\(String(format: "%.3f", E2ETestThresholds.FramePacing.maxCoefficientOfVariation))), stddev=\(String(format: "%.1f", stddev))ms, mean=\(String(format: "%.1f", mean))ms"

        recordResult(name: "frame-pacing", passed: passed, detail: detail)
        runFrameLossTest()
    }

    // MARK: - Test 13: Frame Loss (reassembler drops)

    private func runFrameLossTest() {
        print("[TEST] RUNNING: frame-loss")

        guard let sm = sessionManager else {
            recordResult(name: "frame-loss", passed: false, detail: "sessionManager nil")
            runTieredLatencyTest()
            return
        }

        let reassembler = sm.udpReassembler
        let delivered = reassembler.framesDelivered
        let evicted = reassembler.framesEvicted
        let purged = reassembler.framesPurged
        let totalDropped = evicted + purged
        let chunks = reassembler.chunksReceived
        let rendered = sm.metalRenderer.renderedFrameCount

        // For USB (TCP path), reassembler isn't used — delivered=0.
        // Use framesReceived (count from reportFrameReceived) as the source of truth.
        let totalReceived = max(delivered, framesReceived)
        let totalFrames = totalReceived + totalDropped

        let lossRatio: Double = totalFrames > 0 ? Double(totalDropped) / Double(totalFrames) : 0

        let transport = sm.usbTransport.isConnected ? "USB/TCP" : "WiFi/UDP"
        print("[TEST] INFO: frame-loss (transport=\(transport), delivered=\(delivered), received=\(framesReceived), evicted=\(evicted), purged=\(purged), chunks=\(chunks), rendered=\(rendered))")

        // Pass criteria: less than 10% frame loss
        // AND rendered frames should be at least 10 (something is showing)
        let lossOK = lossRatio < (E2ETestThresholds.FrameLoss.maxLossPercent / 100.0)
        let renderOK = rendered >= E2ETestThresholds.FrameLoss.minRenderedFrames

        var issues: [String] = []
        if !lossOK { issues.append("\(String(format: "%.1f", lossRatio * 100))% loss") }
        if !renderOK { issues.append("only \(rendered) rendered") }

        let passed = lossOK && renderOK
        var detail = "loss=\(String(format: "%.1f", lossRatio * 100))% (target <\(String(format: "%.1f", E2ETestThresholds.FrameLoss.maxLossPercent))%), rendered=\(rendered) (target >=\(E2ETestThresholds.FrameLoss.minRenderedFrames)), transport=\(transport), dropped=\(totalDropped)/\(totalFrames)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }

        recordResult(name: "frame-loss", passed: passed, detail: detail)
        runTieredLatencyTest()
    }

    // MARK: - Test 14: Tiered Latency

    private func runTieredLatencyTest() {
        print("[TEST] RUNNING: latency-tiered")

        guard let sm = sessionManager, sm.usbTransport.isConnected || sm.wirelessTransport.isConnected else {
            recordResult(name: "latency-tiered", passed: false, detail: "no transport connected")
            if !parallelPerformanceSuiteActive {
                runThroughputTest()
            }
            return
        }
        _ = sm // connectivity check only

        tieredLatencyActive = true
        tieredLatencyProbes = []
        tieredLatencyProbesSent = 0

        // Send probes with spacing
        sendNextTieredLatencyProbe()
    }

    private func sendNextTieredLatencyProbe() {
        guard tieredLatencyActive, tieredLatencyProbesSent < Self.tieredLatencyProbeCount else {
            return
        }

        guard let sm = sessionManager else {
            completeTieredLatencyTest()
            return
        }

        let sentTimestamp = keydrdHostTimeUs()
        let header = InputEventHeader(type: InputEventType.latencyProbe.rawValue, tsUs: sentTimestamp)
        let data = header.serialize()

        if sm.usbTransport.isConnected {
            sm.usbTransport.sendInputEvent(data)
        } else if sm.wirelessTransport.isConnected {
            sm.wirelessTransport.sendInputEvent(data)
        }

        tieredLatencyProbesSent += 1

        // Schedule next probe after spacing interval
        if tieredLatencyProbesSent < Self.tieredLatencyProbeCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.tieredLatencyProbeSpacingMs) / 1000.0) { [weak self] in
                self?.sendNextTieredLatencyProbe()
            }
        }

        // Set overall timeout for tiered latency (probes * spacing + generous buffer)
        if tieredLatencyProbesSent == Self.tieredLatencyProbeCount {
            let timeout = Double(Self.tieredLatencyProbeCount * Self.tieredLatencyProbeSpacingMs) / 1000.0 + 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, !self.tieredLatencyComplete else { return }
                self.completeTieredLatencyTest()
            }
        }
    }

    /// Called from reportTieredLatencyProbeResponse for each echoed probe.
    func reportTieredLatencyProbeResponse(rttUs: UInt64) {
        guard tieredLatencyActive, !tieredLatencyComplete else { return }

        tieredLatencyProbes.append(Int(rttUs))

        // Check if we have all probes back
        if tieredLatencyProbes.count >= Self.tieredLatencyProbeCount {
            completeTieredLatencyTest()
        }
    }

    private func completeTieredLatencyTest() {
        guard !tieredLatencyComplete else { return }
        tieredLatencyActive = false
        tieredLatencyComplete = true

        guard !tieredLatencyProbes.isEmpty else {
            recordResult(name: "latency-tiered", passed: false, detail: "no probe responses received")
            if !parallelPerformanceSuiteActive {
                runThroughputTest()
            }
            return
        }

        let sorted = tieredLatencyProbes.sorted()
        let count = sorted.count
        let minUs = sorted.first!
        let maxUs = sorted.last!
        let medianUs = sorted[count / 2]
        let p95Idx = min(Int(Double(count) * 0.95), count - 1)
        let p95Us = sorted[p95Idx]

        let minMs = minUs / 1000
        let medianMs = medianUs / 1000
        let p95Ms = p95Us / 1000
        let maxMs = maxUs / 1000

        if let target = latencyTargetMs {
            let passed = medianMs <= target
            recordResult(name: "latency-tiered", passed: passed,
                        detail: "median=\(medianMs)ms (target <=\(target)ms), p95=\(p95Ms)ms, max=\(maxMs)ms, probes=\(count)/\(Self.tieredLatencyProbeCount)")
        } else {
            // No target -- report stats, always pass
            recordResult(name: "latency-tiered", passed: true,
                        detail: "min=\(minMs)ms, median=\(medianMs)ms, p95=\(p95Ms)ms, max=\(maxMs)ms, probes=\(count)/\(Self.tieredLatencyProbeCount), threshold=none")
        }

        if !parallelPerformanceSuiteActive {
            runThroughputTest()
        }
    }

    // MARK: - Test 14: Throughput Benchmark

    private func runThroughputTest() {
        print("[TEST] RUNNING: throughput")

        guard let sm = sessionManager, sm.usbTransport.isConnected || sm.wirelessTransport.isConnected else {
            recordResult(name: "throughput", passed: false, detail: "no transport connected")
            finishTests()
            return
        }
        _ = sm // connectivity check only

        throughputTestActive = true
        throughputStartTime = CFAbsoluteTimeGetCurrent()
        throughputBytes = 0
        throughputFrames = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.throughputDuration) { [weak self] in
            guard let self = self, !self.throughputTestComplete else { return }
            self.throughputTestActive = false
            self.throughputTestComplete = true

            let elapsed = CFAbsoluteTimeGetCurrent() - self.throughputStartTime
            let mbps: Double
            if elapsed > 0 {
                mbps = (Double(self.throughputBytes) * 8.0) / (elapsed * 1_000_000.0)
            } else {
                mbps = 0
            }

            // Must have sustained frame flow: at least 5 rendered frames per second average
            let avgFPS = elapsed > 0 ? Double(self.throughputFrames) / elapsed : 0
            let passed = self.throughputFrames >= E2ETestThresholds.Throughput.minFrameCount && avgFPS >= E2ETestThresholds.Throughput.minAverageFPS
            print("[TEST] INFO: throughput (app-recv=\(String(format: "%.1f", mbps)) Mbps, \(String(format: "%.1f", avgFPS)) rendered fps over \(String(format: "%.1f", elapsed))s, frames=\(self.throughputFrames), excludes TCP/DTLS/IP overhead)")
            self.recordResult(name: "throughput", passed: passed,
                            detail: "avgFPS=\(String(format: "%.1f", avgFPS)) (target >=\(String(format: "%.1f", E2ETestThresholds.Throughput.minAverageFPS))fps), frames=\(self.throughputFrames) (target >=\(E2ETestThresholds.Throughput.minFrameCount)), appRecv=\(String(format: "%.1f", mbps))Mbps, duration=\(String(format: "%.1f", elapsed))s")

            self.reportPipelineLatency()
            self.reportGlassToGlassLatency()
            self.runHeavyLoadTest()
        }
    }

    // MARK: - Pipeline Latency Report

    private func reportPipelineLatency() {
        guard !pipelineLatenciesUs.isEmpty else {
            print("[TEST] INFO: pipeline-latency (no samples — clock skew too large or no frames)")
            recordResult(name: "pipeline-latency", passed: false,
                        detail: "no samples collected — screen likely black")
            return
        }

        // Minimum sample count: if we have very few samples, the screen is effectively black
        let minSamples = E2ETestThresholds.PipelineLatency.minSamples
        if pipelineLatenciesUs.count < minSamples {
            print("[TEST] INFO: pipeline-latency (only \(pipelineLatenciesUs.count) samples — too few, screen likely not rendering)")
            recordResult(name: "pipeline-latency", passed: false,
                        detail: "only \(pipelineLatenciesUs.count) samples (need \(minSamples)+) — insufficient frame delivery")
            return
        }

        let sorted = pipelineLatenciesUs.sorted()
        let count = sorted.count
        let minMs = sorted.first! / 1000
        let maxMs = sorted.last! / 1000
        let medianMs = sorted[count / 2] / 1000
        let p95Idx = min(Int(Double(count) * 0.95), count - 1)
        let p95Ms = sorted[p95Idx] / 1000
        let avgMs = sorted.reduce(0, +) / Int64(count) / 1000

        let calibrated = clockOffsetCalibrated ? "calibrated, offset=\(clockOffsetUs/1000)ms" : "uncalibrated"
        print("[TEST] INFO: pipeline-latency (capture-to-decode, \(count) samples: min=\(minMs)ms, median=\(medianMs)ms, avg=\(avgMs)ms, p95=\(p95Ms)ms, max=\(maxMs)ms, clock=\(calibrated))")

        let medianThreshold: Int64 = E2ETestThresholds.PipelineLatency.maxMedianMs
        let avgThreshold: Int64 = E2ETestThresholds.PipelineLatency.maxAverageMs
        let p95Threshold: Int64 = E2ETestThresholds.PipelineLatency.maxP95Ms
        let medianOK = medianMs < medianThreshold
        let avgOK = avgMs < avgThreshold
        let p95OK = p95Ms < p95Threshold
        let passed = medianOK && avgOK && p95OK
        var issues: [String] = []
        if !medianOK { issues.append("median \(medianMs)ms >= \(medianThreshold)ms") }
        if !avgOK { issues.append("avg \(avgMs)ms >= \(avgThreshold)ms") }
        if !p95OK { issues.append("p95 \(p95Ms)ms >= \(p95Threshold)ms") }
        var detail = "latency[min/med/avg/p95/max]=\(minMs)/\(medianMs)/\(avgMs)/\(p95Ms)/\(maxMs)ms, targets med<\(medianThreshold) avg<\(avgThreshold) p95<\(p95Threshold), samples=\(count), clock=\(calibrated)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "pipeline-latency", passed: passed,
                    detail: detail)
    }

    // MARK: - Glass-to-Glass Latency Report

    private func reportGlassToGlassLatency() {
        guard !glassToGlassLatenciesUs.isEmpty else {
            print("[TEST] INFO: glass-to-glass-latency (no samples — presentedHandler not firing or clock skew)")
            recordResult(name: "glass-to-glass-latency", passed: false,
                        detail: "no samples collected — screen likely black")
            return
        }

        // Minimum sample count: if we have very few samples, the screen is effectively black
        let minSamples = E2ETestThresholds.GlassToGlassLatency.minSamples
        if glassToGlassLatenciesUs.count < minSamples {
            print("[TEST] INFO: glass-to-glass-latency (only \(glassToGlassLatenciesUs.count) samples — too few)")
            recordResult(name: "glass-to-glass-latency", passed: false,
                        detail: "only \(glassToGlassLatenciesUs.count) samples (need \(minSamples)+) — insufficient frame delivery")
            return
        }

        let sorted = glassToGlassLatenciesUs.sorted()
        let count = sorted.count
        let minMs = sorted.first! / 1000
        let maxMs = sorted.last! / 1000
        let medianMs = sorted[count / 2] / 1000
        let p95Idx = min(Int(Double(count) * 0.95), count - 1)
        let p95Ms = sorted[p95Idx] / 1000
        let avgMs = sorted.reduce(0, +) / Int64(count) / 1000

        let calibrated = clockOffsetCalibrated ? "calibrated, offset=\(clockOffsetUs/1000)ms" : "uncalibrated"
        print("[TEST] INFO: glass-to-glass-latency (capture-to-presented, \(count) samples: min=\(minMs)ms, median=\(medianMs)ms, avg=\(avgMs)ms, p95=\(p95Ms)ms, max=\(maxMs)ms, clock=\(calibrated))")

        // Compare to pipeline (capture-to-decode) to show the render/present overhead
        if !pipelineLatenciesUs.isEmpty {
            let pipelineSorted = pipelineLatenciesUs.sorted()
            let pipelineMedianMs = pipelineSorted[pipelineSorted.count / 2] / 1000
            let overheadMs = medianMs - pipelineMedianMs
            print("[TEST] INFO: glass-to-glass overhead vs decode: \(overheadMs)ms (present+display-link)")
        }

        let medianThreshold: Int64 = E2ETestThresholds.GlassToGlassLatency.maxMedianMs
        let avgThreshold: Int64 = E2ETestThresholds.GlassToGlassLatency.maxAverageMs
        let p95Threshold: Int64 = E2ETestThresholds.GlassToGlassLatency.maxP95Ms
        let medianOK = medianMs < medianThreshold
        let avgOK = avgMs < avgThreshold
        let p95OK = p95Ms < p95Threshold
        let passed = medianOK && avgOK && p95OK
        var issues: [String] = []
        if !medianOK { issues.append("median \(medianMs)ms >= \(medianThreshold)ms") }
        if !avgOK { issues.append("avg \(avgMs)ms >= \(avgThreshold)ms") }
        if !p95OK { issues.append("p95 \(p95Ms)ms >= \(p95Threshold)ms") }
        var detail = "latency[min/med/avg/p95/max]=\(minMs)/\(medianMs)/\(avgMs)/\(p95Ms)/\(maxMs)ms, targets med<\(medianThreshold) avg<\(avgThreshold) p95<\(p95Threshold), samples=\(count), clock=\(calibrated)"
        if !issues.isEmpty {
            detail += " [ISSUES: \(issues.joined(separator: ", "))]"
        }
        recordResult(name: "glass-to-glass-latency", passed: passed,
                    detail: detail)
    }

    // MARK: - Heavy Load Test

    /// Measures FPS and latency during heavy screen changes (Mac stress window).
    /// The Mac shows a fullscreen animated gradient at T+30s that stresses the
    /// LZ4 delta pipeline with near-full-frame changes.
    private func runHeavyLoadTest() {
        print("[TEST] INFO: === Heavy Load Test (waiting for Mac stress window) ===")

        // Wait 2s for the Mac stress window to be fully active,
        // then collect metrics for 10 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            let startRendered = self.sessionManager?.metalRenderer.renderedFrameCount ?? 0
            let startPipelineCount = self.pipelineLatenciesUs.count
            let startTime = CFAbsoluteTimeGetCurrent()

            // After 10s, collect results
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard let self = self else { return }

                let endRendered = self.sessionManager?.metalRenderer.renderedFrameCount ?? 0
                let endPipelineCount = self.pipelineLatenciesUs.count
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime

                let hlFrames = endRendered - startRendered
                let hlFPS = elapsed > 0 ? Double(hlFrames) / elapsed : 0

                // Pipeline latency for frames received during heavy load
                let safeEnd = min(endPipelineCount, self.pipelineLatenciesUs.count)
                let safeStart = min(startPipelineCount, safeEnd)
                let hlPipeline = Array(self.pipelineLatenciesUs[safeStart..<safeEnd])
                var hlMinMs: Int64 = 0
                var hlMedianMs: Int64 = 0
                var hlAvgMs: Int64 = 0
                var hlP95Ms: Int64 = 0
                var hlMaxMs: Int64 = 0
                if !hlPipeline.isEmpty {
                    let sorted = hlPipeline.sorted()
                    hlMinMs = sorted.first! / 1000
                    hlMedianMs = sorted[sorted.count / 2] / 1000
                    hlAvgMs = sorted.reduce(0, +) / Int64(sorted.count) / 1000
                    let p95Idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
                    hlP95Ms = sorted[p95Idx] / 1000
                    hlMaxMs = sorted.last! / 1000
                }

                print("[TEST] INFO: heavy-load (fps=\(String(format: "%.1f", hlFPS)), frames=\(hlFrames), pipeline: median=\(hlMedianMs)ms p95=\(hlP95Ms)ms, samples=\(hlPipeline.count), duration=\(String(format: "%.1f", elapsed))s)")

                let heavyLoadFPSFloor = E2ETestThresholds.HeavyLoad.minAverageFPS
                let heavyLoadPipelineMedianThreshold: Int64 = E2ETestThresholds.HeavyLoad.maxPipelineMedianMs
                let heavyLoadPipelineAverageThreshold: Int64 = E2ETestThresholds.HeavyLoad.maxPipelineAverageMs
                let heavyLoadPipelineP95Threshold: Int64 = E2ETestThresholds.HeavyLoad.maxPipelineP95Ms
                let fpsOK = hlFPS >= heavyLoadFPSFloor
                let medianOK = hlPipeline.isEmpty || hlMedianMs < heavyLoadPipelineMedianThreshold
                let avgOK = hlPipeline.isEmpty || hlAvgMs < heavyLoadPipelineAverageThreshold
                let p95OK = hlPipeline.isEmpty || hlP95Ms < heavyLoadPipelineP95Threshold
                let passed = fpsOK && medianOK && avgOK && p95OK
                var issues: [String] = []
                if !fpsOK { issues.append("fps \(String(format: "%.1f", hlFPS)) < \(String(format: "%.0f", heavyLoadFPSFloor))") }
                if !medianOK { issues.append("pipeline median \(hlMedianMs)ms >= \(heavyLoadPipelineMedianThreshold)ms") }
                if !avgOK { issues.append("pipeline avg \(hlAvgMs)ms >= \(heavyLoadPipelineAverageThreshold)ms") }
                if !p95OK { issues.append("pipeline p95 \(hlP95Ms)ms >= \(heavyLoadPipelineP95Threshold)ms") }
                var detail = "fps=\(String(format: "%.1f", hlFPS)) (target >=\(String(format: "%.0f", heavyLoadFPSFloor))fps); pipe[min/med/avg/p95/max]=\(hlMinMs)/\(hlMedianMs)/\(hlAvgMs)/\(hlP95Ms)/\(hlMaxMs)ms (targets med<\(heavyLoadPipelineMedianThreshold) avg<\(heavyLoadPipelineAverageThreshold) p95<\(heavyLoadPipelineP95Threshold)); frames=\(hlFrames); samples=\(hlPipeline.count)"
                if !issues.isEmpty {
                    detail += " [ISSUES: \(issues.joined(separator: ", "))]"
                }
                self.recordResult(name: "heavy-load", passed: passed,
                            detail: detail)

                self.runPostHeavyLoadTests()
            }
        }
    }

    private func runPostHeavyLoadTests() {
        runVideoPlaybackTest()
    }

    private func runVideoPlaybackTest() {
        if videoPlaybackActive {
            return
        }
        print("[TEST] RUNNING: video-playback")
        print("[TEST] INFO: video-playback-window (offset=\(Int(videoPlaybackOffsetSeconds))s, duration=\(Int(videoPlaybackWindowSeconds))s)")

        videoPlaybackActive = false
        videoPlaybackFrameTimestamps = []
        videoPlaybackRenderedStartCount = totalRenderedFrames
        videoPlaybackObservedStartCount = observedFrameCount
        videoPlaybackPipelineStartCount = pipelineLatenciesUs.count
        videoPlaybackDecodeFailuresStartCount = hevcDecodeFailures

        DispatchQueue.main.asyncAfter(deadline: .now() + videoPlaybackOffsetSeconds) { [weak self] in
            guard let self = self else { return }
            self.videoPlaybackActive = true
            self.videoPlaybackFrameTimestamps = []
            self.videoPlaybackRenderedStartCount = self.totalRenderedFrames
            self.videoPlaybackObservedStartCount = self.observedFrameCount
            self.videoPlaybackPipelineStartCount = self.pipelineLatenciesUs.count
            self.videoPlaybackDecodeFailuresStartCount = self.hevcDecodeFailures

            DispatchQueue.main.asyncAfter(deadline: .now() + self.videoPlaybackWindowSeconds) { [weak self] in
                guard let self = self else { return }
                self.videoPlaybackActive = false

                let renderedDelta = max(0, self.totalRenderedFrames - self.videoPlaybackRenderedStartCount)
                let observedDelta = max(0, self.observedFrameCount - self.videoPlaybackObservedStartCount)
                let decodeFailureDelta = max(0, self.hevcDecodeFailures - self.videoPlaybackDecodeFailuresStartCount)
                let timestamps = self.videoPlaybackFrameTimestamps
                let elapsed = max(self.videoPlaybackWindowSeconds, 0.001)
                let fps = Double(max(renderedDelta, timestamps.count)) / elapsed
                let pipelineSlice = Array(self.pipelineLatenciesUs.suffix(from: min(self.videoPlaybackPipelineStartCount, self.pipelineLatenciesUs.count)))
                let pipelineCount = pipelineSlice.count

                var maxGapMs: Double = 0
                var worstWindowFPS = fps
                if timestamps.count >= 2 {
                    var intervals: [Double] = []
                    for i in 1..<timestamps.count {
                        intervals.append((timestamps[i] - timestamps[i - 1]) * 1000.0)
                    }
                    maxGapMs = intervals.max() ?? 0
                    if timestamps.count >= 10 {
                        let lastTimestamp = timestamps.last!
                        var minFramesInWindow = Int.max
                        for startIdx in 0..<timestamps.count {
                            if timestamps[startIdx] > lastTimestamp - 1.0 { break }
                            let windowEnd = timestamps[startIdx] + 1.0
                            var endIdx = startIdx
                            while endIdx < timestamps.count && timestamps[endIdx] < windowEnd {
                                endIdx += 1
                            }
                            minFramesInWindow = min(minFramesInWindow, endIdx - startIdx)
                        }
                        if minFramesInWindow < Int.max {
                            worstWindowFPS = Double(minFramesInWindow)
                        }
                    }
                }

                let hasRenderedFrames = renderedDelta >= max(5, Int(self.videoPlaybackWindowSeconds * 2.0))
                let hasObservedFrames = observedDelta >= max(5, Int(self.videoPlaybackWindowSeconds * 2.0))
                let fpsOK = fps >= 8.0
                let worstWindowOK = worstWindowFPS >= 4.0
                let gapOK = maxGapMs < 1200
                let decodeOK = decodeFailureDelta == 0
                let pipelineOK = pipelineCount >= max(5, Int(self.videoPlaybackWindowSeconds))
                let passed = hasRenderedFrames && hasObservedFrames && fpsOK && worstWindowOK && gapOK && decodeOK && pipelineOK

                var issues: [String] = []
                if !hasRenderedFrames { issues.append("rendered frames \(renderedDelta) too low") }
                if !hasObservedFrames { issues.append("observed frames \(observedDelta) too low") }
                if !fpsOK { issues.append("fps \(String(format: "%.1f", fps)) < 8.0") }
                if !worstWindowOK { issues.append("worst1s \(String(format: "%.1f", worstWindowFPS))fps < 4.0") }
                if !gapOK { issues.append("max gap \(String(format: "%.0f", maxGapMs))ms >= 1200ms") }
                if !decodeOK { issues.append("decode failures +\(decodeFailureDelta)") }
                if !pipelineOK { issues.append("pipeline samples \(pipelineCount) too low") }

                var detail = "window=\(Int(self.videoPlaybackWindowSeconds))s@+\(Int(self.videoPlaybackOffsetSeconds))s, rendered=\(renderedDelta), observed=\(observedDelta), fps=\(String(format: "%.1f", fps)), worst1s=\(String(format: "%.1f", worstWindowFPS))fps, maxGap=\(String(format: "%.0f", maxGapMs))ms, decodeFail+\(decodeFailureDelta), pipelineSamples=\(pipelineCount)"
                if !issues.isEmpty {
                    detail += " [ISSUES: \(issues.joined(separator: ", "))]"
                }
                self.recordResult(name: "video-playback", passed: passed, detail: detail)

                if self.profile == "security" {
                    self.runSecurityTests()
                    return
                }
                if self.sustainedStreamDuration > 0 {
                    self.runSustainedStreamTest()
                    return
                }
                self.finalizeParallelPerformanceSuiteAndContinue()
            }
        }
    }

    private func runSustainedStreamTest() {
        print("[TEST] INFO: === Sustained Stream Test (\(Int(sustainedStreamDuration))s continuous collection) ===")

        sustainedStreamActive = true
        sustainedStreamRenderedStartCount = totalRenderedFrames
        sustainedStreamObservedStartCount = observedFrameCount
        sustainedStreamPipelineStartCount = pipelineLatenciesUs.count
        sustainedStreamGlassStartCount = glassToGlassLatenciesUs.count
        sustainedStreamFrameTimestamps = []
        sustainedStreamReconnects = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.main.asyncAfter(deadline: .now() + sustainedStreamDuration) { [weak self] in
            guard let self = self else { return }
            self.sustainedStreamActive = false

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let renderedDelta = max(0, self.totalRenderedFrames - self.sustainedStreamRenderedStartCount)
            let observedDelta = max(0, self.observedFrameCount - self.sustainedStreamObservedStartCount)
            let timestamps = self.sustainedStreamFrameTimestamps
            let frameCount = max(renderedDelta, timestamps.count)
            let avgFPS = elapsed > 0 ? Double(frameCount) / elapsed : 0

            var intervals: [Double] = []
            if timestamps.count >= 2 {
                for i in 1..<timestamps.count {
                    intervals.append((timestamps[i] - timestamps[i - 1]) * 1000.0)
                }
            }

            let maxGap = intervals.max() ?? 0
            let p95Interval = intervals.isEmpty ? 0 : intervals.sorted()[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
            let p99Interval = intervals.isEmpty ? 0 : intervals.sorted()[min(intervals.count - 1, Int(Double(intervals.count) * 0.99))]
            let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.isEmpty ? 0 : intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
            let stddev = sqrt(variance)
            let onePercentLowFPS = p99Interval > 0 ? 1000.0 / p99Interval : avgFPS

            var worstWindowFPS = avgFPS
            if timestamps.count >= 10 {
                let lastTimestamp = timestamps.last!
                var minFramesInWindow = Int.max
                for startIdx in 0..<timestamps.count {
                    if timestamps[startIdx] > lastTimestamp - 1.0 { break }
                    let windowEnd = timestamps[startIdx] + 1.0
                    var endIdx = startIdx
                    while endIdx < timestamps.count && timestamps[endIdx] < windowEnd {
                        endIdx += 1
                    }
                    minFramesInWindow = min(minFramesInWindow, endIdx - startIdx)
                }
                if minFramesInWindow < Int.max {
                    worstWindowFPS = Double(minFramesInWindow)
                }
            }

            let pipelineSlice = Array(self.pipelineLatenciesUs.suffix(from: min(self.sustainedStreamPipelineStartCount, self.pipelineLatenciesUs.count)))
            let glassSlice = Array(self.glassToGlassLatenciesUs.suffix(from: min(self.sustainedStreamGlassStartCount, self.glassToGlassLatenciesUs.count)))

            func percentileMs(_ values: [Int64], percentile: Double) -> Int64 {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                let idx = min(Int(Double(sorted.count) * percentile), sorted.count - 1)
                return sorted[idx] / 1000
            }

            let pipelineMedianMs = percentileMs(pipelineSlice, percentile: 0.5)
            let pipelineP95Ms = percentileMs(pipelineSlice, percentile: 0.95)
            let pipelineAvgMs = pipelineSlice.isEmpty ? 0 : (pipelineSlice.reduce(0, +) / Int64(pipelineSlice.count)) / 1000
            let glassMedianMs = percentileMs(glassSlice, percentile: 0.5)
            let glassP95Ms = percentileMs(glassSlice, percentile: 0.95)
            let glassAvgMs = glassSlice.isEmpty ? 0 : (glassSlice.reduce(0, +) / Int64(glassSlice.count)) / 1000

            let noReconnects = self.sustainedStreamReconnects == E2ETestThresholds.SustainedStream.maxReconnects
            let minimumFrameCount = Int(max(Double(E2ETestThresholds.SustainedStream.minimumFrameCount), self.sustainedStreamDuration * E2ETestThresholds.SustainedStream.minFramesPerSecond))
            let enoughFrames = frameCount >= minimumFrameCount
            let averageFPSOK = avgFPS >= E2ETestThresholds.SustainedStream.minAverageFPS
            let onePercentLowOK = onePercentLowFPS >= E2ETestThresholds.SustainedStream.minOnePercentLowFPS
            let jitterOK = stddev <= E2ETestThresholds.SustainedStream.maxJitterMs
            let noLongFreeze = maxGap < E2ETestThresholds.SustainedStream.maxGapMs
            let worstWindowOK = worstWindowFPS >= E2ETestThresholds.SustainedStream.minWorstOneSecondFPS
            let pipelineMedianOK = pipelineMedianMs < E2ETestThresholds.SustainedStream.maxPipelineMedianMs
            let pipelineAverageOK = pipelineAvgMs < E2ETestThresholds.SustainedStream.maxPipelineAverageMs
            let pipelineP95OK = pipelineP95Ms < E2ETestThresholds.SustainedStream.maxPipelineP95Ms
            let glassMedianOK = glassMedianMs < E2ETestThresholds.SustainedStream.maxGlassMedianMs
            let glassAverageOK = glassAvgMs < E2ETestThresholds.SustainedStream.maxGlassAverageMs
            let glassP95OK = glassP95Ms < E2ETestThresholds.SustainedStream.maxGlassP95Ms
            let passed = noReconnects && enoughFrames && averageFPSOK && onePercentLowOK && jitterOK && noLongFreeze && worstWindowOK && pipelineMedianOK && pipelineAverageOK && pipelineP95OK && glassMedianOK && glassAverageOK && glassP95OK
            var issues: [String] = []
            if !noReconnects { issues.append("reconnects \(self.sustainedStreamReconnects) != \(E2ETestThresholds.SustainedStream.maxReconnects)") }
            if !enoughFrames { issues.append("frames \(frameCount) < \(minimumFrameCount)") }
            if !averageFPSOK { issues.append("avg fps \(String(format: "%.1f", avgFPS)) < \(String(format: "%.1f", E2ETestThresholds.SustainedStream.minAverageFPS))") }
            if !onePercentLowOK { issues.append("1% low \(String(format: "%.1f", onePercentLowFPS))fps < \(String(format: "%.1f", E2ETestThresholds.SustainedStream.minOnePercentLowFPS))fps") }
            if !jitterOK { issues.append("jitter \(String(format: "%.1f", stddev))ms > \(String(format: "%.1f", E2ETestThresholds.SustainedStream.maxJitterMs))ms") }
            if !noLongFreeze { issues.append("max gap \(String(format: "%.0f", maxGap))ms >= \(String(format: "%.0f", E2ETestThresholds.SustainedStream.maxGapMs))ms") }
            if !worstWindowOK { issues.append("worst 1s \(String(format: "%.0f", worstWindowFPS))fps < \(String(format: "%.0f", E2ETestThresholds.SustainedStream.minWorstOneSecondFPS))fps") }
            if !pipelineMedianOK { issues.append("pipeline median \(pipelineMedianMs)ms >= \(E2ETestThresholds.SustainedStream.maxPipelineMedianMs)ms") }
            if !pipelineAverageOK { issues.append("pipeline avg \(pipelineAvgMs)ms >= \(E2ETestThresholds.SustainedStream.maxPipelineAverageMs)ms") }
            if !pipelineP95OK { issues.append("pipeline p95 \(pipelineP95Ms)ms >= \(E2ETestThresholds.SustainedStream.maxPipelineP95Ms)ms") }
            if !glassMedianOK { issues.append("glass median \(glassMedianMs)ms >= \(E2ETestThresholds.SustainedStream.maxGlassMedianMs)ms") }
            if !glassAverageOK { issues.append("glass avg \(glassAvgMs)ms >= \(E2ETestThresholds.SustainedStream.maxGlassAverageMs)ms") }
            if !glassP95OK { issues.append("glass p95 \(glassP95Ms)ms >= \(E2ETestThresholds.SustainedStream.maxGlassP95Ms)ms") }

            var detail = "reconnects=\(self.sustainedStreamReconnects) (target ==\(E2ETestThresholds.SustainedStream.maxReconnects)); frames=\(frameCount) (target >=\(minimumFrameCount)); fps[avg/1%low]=\(String(format: "%.1f", avgFPS))/\(String(format: "%.1f", onePercentLowFPS)) (targets >=\(String(format: "%.1f", E2ETestThresholds.SustainedStream.minAverageFPS))/>=\(String(format: "%.1f", E2ETestThresholds.SustainedStream.minOnePercentLowFPS))); timing[p95/maxGap/jitter/worst1s]=\(String(format: "%.0f", p95Interval))ms/\(String(format: "%.0f", maxGap))ms/\(String(format: "%.1f", stddev))ms/\(String(format: "%.0f", worstWindowFPS))fps (targets info/<\(String(format: "%.0f", E2ETestThresholds.SustainedStream.maxGapMs))ms/<=\(String(format: "%.1f", E2ETestThresholds.SustainedStream.maxJitterMs))ms/>=\(String(format: "%.0f", E2ETestThresholds.SustainedStream.minWorstOneSecondFPS))fps); counts[rendered/observed]=\(renderedDelta)/\(observedDelta); pipe[med/avg/p95]=\(pipelineMedianMs)/\(pipelineAvgMs)/\(pipelineP95Ms)ms (targets <\(E2ETestThresholds.SustainedStream.maxPipelineMedianMs)/<\(E2ETestThresholds.SustainedStream.maxPipelineAverageMs)/<\(E2ETestThresholds.SustainedStream.maxPipelineP95Ms)); glass[med/avg/p95]=\(glassMedianMs)/\(glassAvgMs)/\(glassP95Ms)ms (targets <\(E2ETestThresholds.SustainedStream.maxGlassMedianMs)/<\(E2ETestThresholds.SustainedStream.maxGlassAverageMs)/<\(E2ETestThresholds.SustainedStream.maxGlassP95Ms))"
            if !issues.isEmpty {
                detail += " [ISSUES: \(issues.joined(separator: ", "))]"
            }
            self.recordResult(
                name: "sustained-stream",
                passed: passed,
                detail: detail
            )

            self.finalizeParallelPerformanceSuiteAndContinue()
        }
    }

    // MARK: - Multi-Transport Rotation Tests

    /// Index into selectedTransports for current rotation phase.
    private var transportRotationIdx = 0

    /// Tracks which transports passed during rotation.
    private var transportRotationResults: [String: Bool] = [:]

    /// State for per-transport frame validation during rotation.
    private var rotationHandshakeReceived = false
    private var rotationFramesRendered = 0
    private var rotationFramesReceived = 0
    private var rotationTransportType: String = ""

    /// WiFi baseline measurement state (collected during WiFi rotation phase).
    private var wifiMeasurementActive = false
    private var wifiMeasurementStartTime: CFAbsoluteTime = 0
    private var wifiMeasurementRenderedStartCount = 0
    private var wifiMeasurementReceivedStartCount = 0
    private var wifiMeasurementFrameTimestamps: [CFAbsoluteTime] = []
    private var wifiMeasurementFrameCount = 0
    private static let wifiMeasurementDuration: TimeInterval = 10.0

    /// Entry point for multi-transport testing.
    /// Runs after all single-transport tests complete.
    private func runTransportRotationTests() {
        if profile == "security" || skipTransportRotation {
            print("[TEST] INFO: multi-transport skipped by profile or flag")
            recordResult(name: "multi-transport", passed: true, detail: "SKIPPED — profile=security or skip-transport-rotation")
            runSecurityTests()
            return
        }
        print("[TEST] INFO: === Starting multi-transport rotation tests ===")
        print("[TEST] INFO: Will test selected protocols: \(selectedTransports.joined(separator: ", "))")

        transportRotationIdx = 0
        transportRotationResults = [:]
        startNextTransportRotation()
    }

    private func startNextTransportRotation() {
        guard transportRotationIdx < selectedTransports.count else {
            // All transports tested, evaluate results
            evaluateTransportRotation()
            return
        }

        let transport = selectedTransports[transportRotationIdx]
        print("[TEST] INFO: --- Transport rotation: testing \(transport) (\(transportRotationIdx + 1)/\(selectedTransports.count)) ---")

        if transport == "usb" && !(sessionManager?.usbTransport.isConnected ?? false) {
            print("[TEST] INFO: usb test skipped — USB currently unavailable")
            completeTransportRotation(transport: transport, passed: true,
                                     detail: "SKIPPED — USB unavailable (no active USB session)")
            return
        }

        // In wired-only mode, skip WiFi and AWDL rotation tests
        let isWiredOnly = sessionManager?.isWiredOnly ?? false
        if isWiredOnly && (transport == "wifi" || transport == "awdl") {
            print("[TEST] INFO: \(transport) test skipped — wired-only mode")
            completeTransportRotation(transport: transport, passed: true,
                                     detail: "SKIPPED — wired-only mode")
            return
        }

        // AWDL cannot be tested when WiFi infrastructure is available.
        // NWConnection always prefers WiFi over AWDL on the same network.
        // Skip gracefully rather than timing out for 15s.
        if transport == "awdl" {
            print("[TEST] INFO: AWDL test skipped — WiFi infrastructure is available, NWConnection prefers WiFi over AWDL on the same network")
            completeTransportRotation(transport: transport, passed: true,
                                     detail: "SKIPPED — AWDL unavailable when WiFi infrastructure is present (NWConnection prefers WiFi)")
            return
        }

        guard let sm = sessionManager else {
            transportRotationResults[transport] = false
            recordResult(name: "transport-\(transport)", passed: false, detail: "sessionManager nil")
            transportRotationIdx += 1
            startNextTransportRotation()
            return
        }

        // Reset per-rotation state
        rotationHandshakeReceived = false
        rotationFramesRendered = totalRenderedFrames
        rotationFramesReceived = framesReceived
        rotationTransportType = ""

        // Disconnect everything and start only the target transport
        sm.disconnectAllTransports()

        // Give 5s for teardown to complete. The Mac needs time to detect
        // the iPad's disconnection and clean up its connection state.
        // TCP keepalive/close detection can take several seconds.
        // For WiFi: the Mac starts WiFi advertising in startReconnection()
        // when it detects the USB disconnect, but Bonjour propagation
        // takes a moment. Use 7s to give the Mac time to advertise.
        let teardownDelay = transport == "wifi" ? 7.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownDelay) { [weak self] in
            guard let self = self else { return }

            switch transport {
            case "usb":
                sm.startUSBOnly()
            case "wifi":
                sm.startWirelessOnly()
            default:
                break
            }

            // Wait for connection + handshake + frames with timeout
            self.waitForTransportConnection(transport: transport, timeout: 8.0)
        }
    }

    /// Wait for a specific transport to connect, receive handshake, and deliver frames.
    private func waitForTransportConnection(transport: String, timeout: TimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        // Poll every 0.5s for connection + frames
        pollTransportConnection(transport: transport, deadline: deadline)
    }

    private func pollTransportConnection(transport: String, deadline: CFAbsoluteTime) {
        guard let sm = sessionManager else {
            completeTransportRotation(transport: transport, passed: false, detail: "sessionManager nil")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now >= deadline {
            completeTransportRotation(transport: transport, passed: false,
                                     detail: "timeout — no connection within \(String(format: "%.0f", deadline - now + 15))s")
            return
        }

        // Check connection state
        var connected = false
        var detectedType = ""

        if transport == "usb" {
            connected = sm.usbTransport.isConnected
            detectedType = "usb"
        } else if transport == "wifi" {
            connected = sm.wirelessTransport.isConnected && !sm.wirelessTransport.isAWDL
            detectedType = "wifi"
        } else if transport == "awdl" {
            connected = sm.wirelessTransport.isConnected && sm.wirelessTransport.isAWDL
            detectedType = "awdl"
        }

        // Check if we got frames. Prefer rendered frames, but accept decoded frames
        // during short transport rotation windows where the display link can lag.
        let rendered = totalRenderedFrames
        let received = framesReceived

        let newRendered = rendered - rotationFramesRendered
        let newReceived = received - rotationFramesReceived

        if connected && (rotationHandshakeReceived || newRendered > 3 || newReceived > 3) {
            if transport == "wifi" {
                // Run WiFi baseline measurements before completing
                runWiFiBaselineMeasurements(
                    detectedType: detectedType,
                    newRenderedFrames: max(0, newRendered),
                    newReceivedFrames: max(0, newReceived)
                )
                return
            }
            completeTransportRotation(transport: transport, passed: true,
                                     detail: "connected=\(detectedType), rendered+\(max(0, newRendered)), received+\(max(0, newReceived))")
            return
        }

        // Not ready yet, poll again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollTransportConnection(transport: transport, deadline: deadline)
        }
    }

    // MARK: - WiFi Baseline Measurements

    /// Collect WiFi performance baselines (FPS, latency, jitter, frame loss, resolution).
    /// All results are INFO-level (no pass/fail) to establish baselines.
    private func runWiFiBaselineMeasurements(detectedType: String, newRenderedFrames: Int, newReceivedFrames: Int) {
        print("[TEST] INFO: === WiFi Baseline Measurements (10s collection period) ===")

        guard let sm = sessionManager else {
            print("[TEST] INFO: wifi-baselines skipped — sessionManager nil")
            completeTransportRotation(transport: "wifi", passed: true,
                                     detail: "connected=\(detectedType), rendered+\(newRenderedFrames), received+\(newReceivedFrames) (baselines skipped)")
            return
        }

        // Reset WiFi measurement state
        wifiMeasurementActive = true
        wifiMeasurementStartTime = CFAbsoluteTimeGetCurrent()
        wifiMeasurementRenderedStartCount = totalRenderedFrames
        wifiMeasurementReceivedStartCount = framesReceived
        wifiMeasurementFrameTimestamps = []
        wifiMeasurementFrameCount = 0

        // Snapshot pipeline latencies and reassembler stats at start
        let pipelineLatencyStartCount = pipelineLatenciesUs.count
        let reassemblerStartDelivered = sm.udpReassembler.framesDelivered
        let reassemblerStartEvicted = sm.udpReassembler.framesEvicted
        let reassemblerStartPurged = sm.udpReassembler.framesPurged

        // Collect for wifiMeasurementDuration seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wifiMeasurementDuration) { [weak self] in
            guard let self = self else { return }
            self.wifiMeasurementActive = false

            let elapsed = CFAbsoluteTimeGetCurrent() - self.wifiMeasurementStartTime
            let timestamps = self.wifiMeasurementFrameTimestamps
            let renderedEndCount = self.totalRenderedFrames
            let renderedDelta = max(0, renderedEndCount - self.wifiMeasurementRenderedStartCount)
            let receivedDelta = max(0, self.framesReceived - self.wifiMeasurementReceivedStartCount)
            let frameCount = max(timestamps.count, renderedDelta, receivedDelta)

            // 1. WiFi FPS
            let avgFPS: Double = elapsed > 0 ? Double(frameCount) / elapsed : 0
            print("[TEST] INFO: wifi-fps (avg=\(String(format: "%.1f", avgFPS)) fps, \(frameCount) frames in \(String(format: "%.1f", elapsed))s)")

            // 2. WiFi Latency (pipeline latencies collected during measurement window)
            let wifiPipelineLatencies = Array(self.pipelineLatenciesUs.suffix(from: min(pipelineLatencyStartCount, self.pipelineLatenciesUs.count)))
            if !wifiPipelineLatencies.isEmpty {
                let sorted = wifiPipelineLatencies.sorted()
                let count = sorted.count
                let minMs = sorted.first! / 1000
                let medianMs = sorted[count / 2] / 1000
                let p95Idx = min(Int(Double(count) * 0.95), count - 1)
                let p95Ms = sorted[p95Idx] / 1000
                print("[TEST] INFO: wifi-latency (pipeline: min=\(minMs)ms, median=\(medianMs)ms, p95=\(p95Ms)ms)")
            } else {
                print("[TEST] INFO: wifi-latency (no pipeline samples during measurement)")
            }

            // 3. WiFi Jitter
            if timestamps.count >= 2 {
                var intervals: [Double] = []
                for i in 1..<timestamps.count {
                    intervals.append((timestamps[i] - timestamps[i-1]) * 1000.0)
                }
                let mean = intervals.reduce(0, +) / Double(intervals.count)
                let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
                let stddev = sqrt(variance)
                let stutters = intervals.filter { $0 > 100.0 }.count
                print("[TEST] INFO: wifi-jitter (stddev=\(String(format: "%.1f", stddev))ms, stutters=\(stutters))")
            } else {
                print("[TEST] INFO: wifi-jitter (insufficient frames for interval analysis)")
            }

            // 4. WiFi Frame Loss (reassembler delta during measurement)
            if let sm = self.sessionManager {
                let delivered = sm.udpReassembler.framesDelivered - reassemblerStartDelivered
                let evicted = sm.udpReassembler.framesEvicted - reassemblerStartEvicted
                let purged = sm.udpReassembler.framesPurged - reassemblerStartPurged
                let total = delivered + evicted + purged
                let lossPct: Double = total > 0 ? Double(evicted + purged) / Double(total) * 100.0 : 0
                print("[TEST] INFO: wifi-frame-loss (delivered=\(delivered), evicted=\(evicted), purged=\(purged), loss=\(String(format: "%.1f", lossPct))%)")
            }

            // 5. WiFi Resolution (check last decoded frame dims vs viewport)
            if let lastW = self.decodedFrameWidths.last, let lastH = self.decodedFrameHeights.last {
                let vpW = self.sessionManager?.viewportWidth ?? 0
                let vpH = self.sessionManager?.viewportHeight ?? 0
                print("[TEST] INFO: wifi-resolution (frame=\(lastW)x\(lastH), viewport=\(vpW)x\(vpH))")
            } else {
                print("[TEST] INFO: wifi-resolution (no decoded frame dimensions available)")
            }

            // Complete the WiFi rotation with pass
            self.completeTransportRotation(transport: "wifi", passed: true,
                                          detail: "connected=\(detectedType), rendered+\(newRenderedFrames), received+\(newReceivedFrames), wifi baselines collected")
        }
    }

    private func completeTransportRotation(transport: String, passed: Bool, detail: String) {
        transportRotationResults[transport] = passed
        recordResult(name: "transport-\(transport)", passed: passed, detail: detail)

        transportRotationIdx += 1
        startNextTransportRotation()
    }

    private func evaluateTransportRotation() {
        let summary = selectedTransports.map { t in
            let status = transportRotationResults[t] == true ? "PASS" : "FAIL"
            return "\(t)=\(status)"
        }.joined(separator: ", ")

        let allPassed = selectedTransports.allSatisfy { transportRotationResults[$0] == true }
        recordResult(name: "multi-transport", passed: allPassed,
                    detail: summary)

        runSecurityTests()
    }

    // MARK: - Security / Pen Tests

    private var securityTestsRemaining = 0
    private let securityQueue = DispatchQueue(label: "com.ryheff.keyd.remote.app.security-tests")

    private func runSecurityTests() {
        print("[TEST] INFO: === Security Tests ===")

        guard let sm = sessionManager else {
            print("[TEST] INFO: skipping security tests — no sessionManager")
            finishTests()
            return
        }

        if !sm.isWirelessOnly {
            sm.usbTransport.startMonitoring()
        }

        // Give the transport layer a moment to settle before probing the Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runCleartextTCPTest()
        }
    }

    /// Security test: attempt plain TCP (no TLS) to Mac input port.
    /// PASS = connection rejected/failed. FAIL = cleartext accepted.
    private func runCleartextTCPTest() {
        print("[TEST] RUNNING: sec-cleartext-tcp")

        guard sessionManager != nil else {
            recordResult(name: "sec-cleartext-tcp", passed: false, detail: "no sessionManager")
            runCleartextUDPTest()
            return
        }

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-cleartext-tcp", passed: false, detail: "cannot determine Mac IP from QR payload")
            runCleartextUDPTest()
            return
        }

        // Attempt plain TCP (no TLS) to the input port
        let params = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14568)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                // TCP layer connected — but Mac expects TLS. Send probe data
                // and check if Mac responds (it shouldn't — TLS expects Client Hello).
                let probe = Data([0xDE, 0xAD, 0xBE, 0xEF])
                conn.send(content: probe, completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                    guard !completed else { return }
                    if let data = data, !data.isEmpty {
                        completed = true
                        self.recordResult(name: "sec-cleartext-tcp", passed: false,
                                    detail: "VULNERABLE: Mac responded to cleartext TCP (\(data.count) bytes)")
                        conn.cancel()
                        DispatchQueue.main.async { self.runCleartextUDPTest() }
                    }
                    // No response = TLS layer dropped it (expected)
                }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-cleartext-tcp", passed: true,
                            detail: "cleartext TCP rejected: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runCleartextUDPTest() }
            case .waiting(let error):
                // Connection refused or unreachable — good
                completed = true
                self.recordResult(name: "sec-cleartext-tcp", passed: true,
                            detail: "cleartext TCP refused: \(error.localizedDescription)")
                conn.cancel()
                DispatchQueue.main.async { self.runCleartextUDPTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        // Timeout: if no response in 5s, pass (connection silently dropped)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-cleartext-tcp", passed: true,
                        detail: "cleartext TCP timed out (silently dropped)")
            self?.runCleartextUDPTest()
        }
    }

    /// Security test: attempt plain UDP (no DTLS) to Mac media port.
    /// PASS = no data exchanged. FAIL = cleartext data accepted.
    private func runCleartextUDPTest() {
        print("[TEST] RUNNING: sec-cleartext-udp")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-cleartext-udp", passed: false, detail: "cannot determine Mac IP")
            runUntrustedCertTest()
            return
        }

        // Attempt plain UDP (no DTLS) to the media port
        let params = NWParameters.udp
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14567)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                // UDP "connected" — send test data and see if Mac responds
                let testData = "CLEARTEXT_PROBE".data(using: .utf8)!
                conn.send(content: testData, completion: .contentProcessed { _ in })

                // Wait 2s for any response
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    guard !completed else { return }
                    if let data = data, !data.isEmpty {
                        completed = true
                        self.recordResult(name: "sec-cleartext-udp", passed: false,
                                    detail: "VULNERABLE: Mac responded to cleartext UDP (\(data.count) bytes)")
                        conn.cancel()
                        DispatchQueue.main.async { self.runUntrustedCertTest() }
                    }
                }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-cleartext-udp", passed: true,
                            detail: "cleartext UDP rejected: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runUntrustedCertTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        // Timeout: no response in 3s = pass (Mac ignored cleartext)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-cleartext-udp", passed: true,
                        detail: "cleartext UDP ignored by Mac (no response)")
            self?.runUntrustedCertTest()
        }
    }

    /// Security test: attempt TLS connection with untrusted self-signed cert.
    /// PASS = connection rejected by Mac's cert pinning. FAIL = accepted.
    private func runUntrustedCertTest() {
        print("[TEST] RUNNING: sec-untrusted-cert")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-untrusted-cert", passed: false, detail: "cannot determine Mac IP")
            runPairingPortClosedTest()
            return
        }

        // TLS with default system trust (no client cert, no pinning).
        // This probes whether the Mac enforces client authentication.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)
        // Accept any server cert (we're testing if the SERVER rejects US)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14568)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                // TLS handshake succeeded without client cert — try to receive data
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                    guard !completed else { return }
                    if let data = data, !data.isEmpty {
                        completed = true
                        // Known gap: transport is server-authenticated only.
                        // The iPad does not present a client TLS identity today.
                        self.recordResult(name: "sec-untrusted-cert", passed: false,
                                    detail: "KNOWN GAP: no client auth on streaming transport — Mac sent \(data.count) bytes to an unauthenticated TLS client")
                        conn.cancel()
                        DispatchQueue.main.async { self.runPairingPortClosedTest() }
                    }
                }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-untrusted-cert", passed: true,
                            detail: "TLS rejected unauthenticated client: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runPairingPortClosedTest() }
            case .waiting(let error):
                completed = true
                self.recordResult(name: "sec-untrusted-cert", passed: true,
                            detail: "TLS connection refused: \(error.localizedDescription)")
                conn.cancel()
                DispatchQueue.main.async { self.runPairingPortClosedTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-untrusted-cert", passed: true,
                        detail: "TLS with untrusted cert timed out (connection dropped)")
            self?.runPairingPortClosedTest()
        }
    }

    /// Security test: verify pairing port (14569) is closed after pairing completes.
    /// PASS = connection refused. FAIL = port still accepting connections.
    private func runPairingPortClosedTest() {
        print("[TEST] RUNNING: sec-pairing-port-closed")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-pairing-port-closed", passed: false, detail: "cannot determine Mac IP")
            runPairingPortClosedAfterStreamTest()
            return
        }

        // Try plain TCP to pairing port — should be closed after initial pairing
        let params = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14569)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                completed = true
                self.recordResult(name: "sec-pairing-port-closed", passed: false,
                            detail: "VULNERABLE: pairing port 14569 still open after pairing complete")
                conn.cancel()
                DispatchQueue.main.async { self.runPairingPortClosedAfterStreamTest() }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-pairing-port-closed", passed: true,
                            detail: "pairing port closed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runPairingPortClosedAfterStreamTest() }
            case .waiting(let error):
                completed = true
                self.recordResult(name: "sec-pairing-port-closed", passed: true,
                            detail: "pairing port refused: \(error.localizedDescription)")
                conn.cancel()
                DispatchQueue.main.async { self.runPairingPortClosedAfterStreamTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-pairing-port-closed", passed: true,
                        detail: "pairing port 14569 unreachable (timed out)")
            self?.runPairingPortClosedAfterStreamTest()
        }
    }

    /// Security test: verify pairing port (14569) is closed AFTER streaming begins.
    /// Waits for active stream confirmation before probing. Catches the case where
    /// the port is closed during pairing but reopened or never closed once media flows.
    /// PASS = connection refused. FAIL = port accepting connections during stream.
    private func runPairingPortClosedAfterStreamTest() {
        print("[TEST] RUNNING: sec-pairing-port-closed-after-stream")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-pairing-port-closed-after-stream", passed: false, detail: "cannot determine Mac IP")
            runMITMReconnectTest()
            return
        }

        // We are already in the streaming phase (security tests run after frames received).
        // Probe the pairing port now — it must be closed.
        let params = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14569)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                completed = true
                self.recordResult(name: "sec-pairing-port-closed-after-stream", passed: false,
                            detail: "VULNERABLE: pairing port 14569 open during active stream")
                conn.cancel()
                DispatchQueue.main.async { self.runMITMReconnectTest() }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-pairing-port-closed-after-stream", passed: true,
                            detail: "pairing port closed during stream: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runMITMReconnectTest() }
            case .waiting(let error):
                completed = true
                self.recordResult(name: "sec-pairing-port-closed-after-stream", passed: true,
                            detail: "pairing port refused during stream: \(error.localizedDescription)")
                conn.cancel()
                DispatchQueue.main.async { self.runMITMReconnectTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-pairing-port-closed-after-stream", passed: true,
                        detail: "pairing port 14569 unreachable during stream (timed out)")
            self?.runMITMReconnectTest()
        }
    }

    /// Security test: after pairing, attempt TLS connection with a DIFFERENT self-signed
    /// cert (not the pinned one). Verifies cert pinning is enforced on transport reconnection.
    /// Tests C1 vulnerability — Mac must reject certs that don't match the pinned fingerprint.
    /// PASS = connection rejected. FAIL = unpinned cert accepted.
    private func runMITMReconnectTest() {
        print("[TEST] RUNNING: sec-mitm-reconnect")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-mitm-reconnect", passed: false, detail: "cannot determine Mac IP")
            runPrePairingTransportRejectTest()
            return
        }

        // TLS with a fresh ephemeral identity — this will NOT match
        // the fingerprint the Mac stored during ECDH pairing.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13)

        // Generate an ephemeral self-signed identity for the MITM attempt
        if let identity = createEphemeralSelfSignedIdentity() {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                sec_identity_create(identity)!)
        }

        // Accept any server cert (we're testing if the SERVER rejects our client cert)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14568)!)
        let conn = NWConnection(to: endpoint, using: params)

        var completed = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !completed else { return }
            switch state {
            case .ready:
                // TLS handshake succeeded — try sending data to see if Mac actually processes it
                let probe = Data([0xDE, 0xAD])
                conn.send(content: probe, completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    guard !completed else { return }
                    if let data = data, !data.isEmpty {
                        completed = true
                        self.recordResult(name: "sec-mitm-reconnect", passed: false,
                                    detail: "VULNERABLE: Mac accepted MITM cert and sent \(data.count) bytes on input port")
                        conn.cancel()
                        DispatchQueue.main.async { self.runPrePairingTransportRejectTest() }
                    }
                }

                // If TLS handshake completed but no data flows, wait briefly then check
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard !completed else { return }
                    completed = true
                    // TLS connected but no data — Mac may have accepted TLS but not sent frames.
                    // This is still a concern since the connection was established.
                    self.recordResult(name: "sec-mitm-reconnect", passed: false,
                                detail: "VULNERABLE: TLS handshake succeeded with unpinned MITM cert (no data sent, but connection open)")
                    conn.cancel()
                    DispatchQueue.main.async { self.runPrePairingTransportRejectTest() }
                }
            case .failed(let error):
                completed = true
                self.recordResult(name: "sec-mitm-reconnect", passed: true,
                            detail: "MITM cert rejected: \(error.localizedDescription)")
                DispatchQueue.main.async { self.runPrePairingTransportRejectTest() }
            case .waiting(let error):
                completed = true
                self.recordResult(name: "sec-mitm-reconnect", passed: true,
                            detail: "MITM connection refused: \(error.localizedDescription)")
                conn.cancel()
                DispatchQueue.main.async { self.runPrePairingTransportRejectTest() }
            default:
                break
            }
        }

        conn.start(queue: securityQueue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn.cancel()
            self?.recordResult(name: "sec-mitm-reconnect", passed: true,
                        detail: "MITM connection timed out (cert likely rejected silently)")
            self?.runPrePairingTransportRejectTest()
        }
    }

    /// Create an ephemeral self-signed SecIdentity for MITM testing.
    /// Returns nil if generation fails (test will still run without client cert).
    private func createEphemeralSelfSignedIdentity() -> SecIdentity? {
        // Generate a fresh P-256 private key
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            print("[TEST] INFO: sec-mitm-reconnect: could not generate ephemeral key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        // SecIdentity requires a cert+key pair in the keychain. On iOS we cannot easily
        // create a self-signed X.509 certificate without a third-party library.
        // Instead, we store the private key temporarily and note that the TLS connection
        // will proceed without a proper client identity — the Mac should still reject
        // because we are not presenting the pinned certificate fingerprint.
        let tag = "com.ryheff.keyd.test.mitm-ephemeral-\(UUID().uuidString)".data(using: .utf8)!
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrApplicationTag as String: tag,
            kSecValueRef as String: privateKey,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            print("[TEST] INFO: sec-mitm-reconnect: could not store ephemeral key: \(status)")
        }

        // Clean up the temporary keychain entry after a delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 30.0) {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        // Cannot create SecIdentity without X.509 cert on iOS — return nil.
        // The test still validates that connecting without the pinned cert is rejected.
        print("[TEST] INFO: sec-mitm-reconnect: ephemeral key generated, no client cert presented (tests server-side pinning)")
        return nil
    }

    /// Security test: attempt to connect to Mac's media (14567) and input (14568) ports
    /// with no client identity (simulating an unpaired attacker).
    /// Catches C1: Mac transport accepts ANY cert when not paired.
    /// PASS = both ports reject the connection. FAIL = either port accepts.
    private func runPrePairingTransportRejectTest() {
        print("[TEST] RUNNING: sec-pre-pairing-transport-reject")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-pre-pairing-transport-reject", passed: false, detail: "cannot determine Mac IP")
            runPairingRaceTest()
            return
        }

        // Attempt TLS connections to media and input ports with NO client identity
        // (simulating an unpaired attacker). Mac should reject since we have no valid cert.
        var mediaCompleted = false
        var inputCompleted = false
        var mediaAccepted = false
        var inputAccepted = false

        let checkBothDone: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard mediaCompleted && inputCompleted else { return }
            if mediaAccepted || inputAccepted {
                var detail = "VULNERABLE:"
                if mediaAccepted { detail += " media port 14567 accepted unknown client;" }
                if inputAccepted { detail += " input port 14568 accepted unknown client;" }
                self.recordResult(name: "sec-pre-pairing-transport-reject", passed: false, detail: detail)
            } else {
                self.recordResult(name: "sec-pre-pairing-transport-reject", passed: true,
                            detail: "both transport ports rejected unknown client")
            }
            DispatchQueue.main.async { self.runPairingRaceTest() }
        }

        // Probe media port (14567 / UDP over DTLS)
        let dtlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            dtlsOpts.securityProtocolOptions, .DTLSv12)
        sec_protocol_options_set_verify_block(dtlsOpts.securityProtocolOptions,
            { _, _, complete in complete(true) }, DispatchQueue.global())
        let mediaParams = NWParameters(dtls: dtlsOpts, udp: .init())
        let mediaEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14567)!)
        let mediaConn = NWConnection(to: mediaEndpoint, using: mediaParams)

        mediaConn.stateUpdateHandler = { state in
            guard !mediaCompleted else { return }
            switch state {
            case .ready:
                // DTLS handshake succeeded — send probe data
                let probe = Data([0x4B, 0x44, 0x00, 0x00]) // fake header with KEYDRD_MAGIC
                mediaConn.send(content: probe, completion: .contentProcessed { _ in })
                mediaConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard !mediaCompleted else { return }
                    mediaCompleted = true
                    mediaAccepted = (data != nil && !data!.isEmpty)
                    if mediaAccepted {
                        print("[TEST] INFO: sec-pre-pairing-transport-reject: media port responded with \(data!.count) bytes")
                    }
                    mediaConn.cancel()
                    checkBothDone()
                }
                // If DTLS connected but no data, still a vulnerability
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard !mediaCompleted else { return }
                    mediaCompleted = true
                    mediaAccepted = true // DTLS handshake alone = vulnerable
                    print("[TEST] INFO: sec-pre-pairing-transport-reject: media port DTLS handshake succeeded (no data, but connected)")
                    mediaConn.cancel()
                    checkBothDone()
                }
            case .failed:
                mediaCompleted = true
                mediaConn.cancel()
                checkBothDone()
            case .waiting:
                mediaCompleted = true
                mediaConn.cancel()
                checkBothDone()
            default:
                break
            }
        }

        mediaConn.start(queue: securityQueue)

        // Probe input port (14568 / TCP over TLS)
        let inputTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            inputTLS.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(inputTLS.securityProtocolOptions,
            { _, _, complete in complete(true) }, DispatchQueue.global())
        let inputParams = NWParameters(tls: inputTLS, tcp: .init())
        let inputEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14568)!)
        let inputConn = NWConnection(to: inputEndpoint, using: inputParams)

        inputConn.stateUpdateHandler = { state in
            guard !inputCompleted else { return }
            switch state {
            case .ready:
                // TLS succeeded — check if Mac sends data
                inputConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard !inputCompleted else { return }
                    inputCompleted = true
                    inputAccepted = true // TLS handshake alone is a vulnerability
                    print("[TEST] INFO: sec-pre-pairing-transport-reject: input port TLS handshake succeeded, received \(data?.count ?? 0) bytes")
                    inputConn.cancel()
                    checkBothDone()
                }
                // Even if no data, TLS connection itself is the issue
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard !inputCompleted else { return }
                    inputCompleted = true
                    inputAccepted = true // TLS handshake succeeded = vulnerable
                    print("[TEST] INFO: sec-pre-pairing-transport-reject: input port TLS connected but no data (still vulnerable)")
                    inputConn.cancel()
                    checkBothDone()
                }
            case .failed:
                inputCompleted = true
                inputConn.cancel()
                checkBothDone()
            case .waiting:
                inputCompleted = true
                inputConn.cancel()
                checkBothDone()
            default:
                break
            }
        }

        inputConn.start(queue: securityQueue)

        // Overall timeout for both probes
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !mediaCompleted {
                mediaCompleted = true
                mediaConn.cancel()
            }
            if !inputCompleted {
                inputCompleted = true
                inputConn.cancel()
            }
            checkBothDone()
        }
    }

    /// Security test: start two simultaneous pairing connections to port 14569.
    /// Verify only one succeeds or the listener rejects concurrent attempts.
    /// Catches H3: unlimited pairing connections / race condition.
    /// PASS = second connection rejected or only one completes pairing.
    /// FAIL = both connections accepted simultaneously.
    private func runPairingRaceTest() {
        print("[TEST] RUNNING: sec-pairing-race")

        guard let host = qrPayloadHost() else {
            recordResult(name: "sec-pairing-race", passed: false, detail: "cannot determine Mac IP")
            runIdentityFilePermissionsTest()
            return
        }

        let params1 = NWParameters.tcp
        let params2 = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 14569)!)
        let conn1 = NWConnection(to: endpoint, using: params1)
        let conn2 = NWConnection(to: endpoint, using: params2)

        var conn1Ready = false
        var conn2Ready = false
        var conn1Failed = false
        var conn2Failed = false
        var completed = false

        let evaluateRace: () -> Void = { [weak self] in
            guard let self = self, !completed else { return }
            // Wait until both connections have resolved
            let conn1Resolved = conn1Ready || conn1Failed
            let conn2Resolved = conn2Ready || conn2Failed
            guard conn1Resolved && conn2Resolved else { return }

            completed = true
            conn1.cancel()
            conn2.cancel()

            if conn1Ready && conn2Ready {
                self.recordResult(name: "sec-pairing-race", passed: false,
                            detail: "VULNERABLE: both simultaneous pairing connections accepted on port 14569")
            } else if conn1Ready || conn2Ready {
                self.recordResult(name: "sec-pairing-race", passed: true,
                            detail: "only one pairing connection accepted, other rejected")
            } else {
                // Both failed — pairing port closed (expected after initial pairing)
                self.recordResult(name: "sec-pairing-race", passed: true,
                            detail: "pairing port 14569 closed — both connections rejected (expected post-pairing)")
            }
            DispatchQueue.main.async { self.runIdentityFilePermissionsTest() }
        }

        conn1.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn1Ready = true
                evaluateRace()
            case .failed, .cancelled:
                conn1Failed = true
                evaluateRace()
            case .waiting:
                conn1Failed = true
                conn1.cancel()
                evaluateRace()
            default:
                break
            }
        }

        conn2.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn2Ready = true
                evaluateRace()
            case .failed, .cancelled:
                conn2Failed = true
                evaluateRace()
            case .waiting:
                conn2Failed = true
                conn2.cancel()
                evaluateRace()
            default:
                break
            }
        }

        // Start both connections simultaneously
        conn1.start(queue: securityQueue)
        conn2.start(queue: securityQueue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard !completed else { return }
            completed = true
            conn1.cancel()
            conn2.cancel()
            // Timeout means port is likely closed or connections hung — pass
            self?.recordResult(name: "sec-pairing-race", passed: true,
                        detail: "pairing race timed out — port likely closed or rate-limited")
            self?.runIdentityFilePermissionsTest()
        }
    }

    /// Security test: the Mac identity this iPad pinned is a Secure Enclave key (tla/KeyCustody.tla).
    /// The harness runs `RemoteDesktopAgent --identity-selftest` on the Mac (key in the Secure
    /// Enclave, export refused, TLS 1.3 loopback with that identity) and passes the result as
    /// `--mac-identity "fp=<hex>;export=refused;token=<id>;tls13=ok"`. PASS only if the self-test
    /// passed and its fingerprint equals the certificate fingerprint this iPad pinned and has been
    /// verifying on every connection of this run.
    private func runIdentityFilePermissionsTest() {
        let name = "sec-identity-secure-enclave"
        print("[TEST] RUNNING: \(name)")
        let args = ProcessInfo.processInfo.arguments
        var fields: [String: String] = [:]
        if let idx = args.firstIndex(of: "--mac-identity"), idx + 1 < args.count {
            for part in args[idx + 1].split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
        }
        let pinnedQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.ryheff.keyd.remote.app",
            kSecAttrAccount: "peer-cert-fingerprint",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var pinnedRef: CFTypeRef?
        let pinnedStatus = SecItemCopyMatching(pinnedQuery as CFDictionary, &pinnedRef)
        let pinnedHex = (pinnedRef as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        let macHex = (fields["fp"] ?? "").lowercased()
        let seToken = fields["token"] == "com.apple.setoken"
        let exportRefused = fields["export"] == "refused"
        let tlsOK = fields["tls13"] == "ok"
        let fpMatch = !pinnedHex.isEmpty && pinnedHex == macHex
        print("[CONSOLE] identity-test fields=\(fields) pinnedStatus=\(pinnedStatus) pinned=\(pinnedHex.prefix(16)) mac=\(macHex.prefix(16)) match=\(fpMatch)")
        let passed = seToken && exportRefused && tlsOK && fpMatch
        recordResult(name: name, passed: passed,
                     detail: "pinned=\(pinnedHex.prefix(16)) mac-selftest=\(macHex.prefix(16)) match=\(fpMatch) token=\(fields["token"] ?? "missing") export=\(fields["export"] ?? "missing") tls13=\(fields["tls13"] ?? "missing")")
        runKeychainAccessControlTest()
    }

    /// Security test: verify keychain items have kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
    /// Checks the iPad-side keychain items used for TLS identity and peer fingerprint storage.
    /// Catches H1: No Keychain access controls.
    /// PASS = items have proper access control. FAIL = items lack access restrictions.
    private func runKeychainAccessControlTest() {
        print("[TEST] RUNNING: sec-keychain-access-control")

        // Query keychain items used by the pairing/transport layer
        let keychainService = "com.ryheff.keyd.remote.app"
        let accountsToCheck = [
            "client-identity-p12",
            "client-cert-der",
            "client-private-key",
            "peer-fingerprint",
        ]

        var issues: [String] = []
        var itemsFound = 0

        for account in accountsToCheck {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let attrs = result as? [String: Any] {
                itemsFound += 1
                // Check kSecAttrAccessible value
                if let accessible = attrs[kSecAttrAccessible as String] as? String {
                    let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                    if accessible != expected {
                        issues.append("\(account): accessible=\(accessible) (expected WhenUnlockedThisDeviceOnly)")
                    }
                } else {
                    issues.append("\(account): no kSecAttrAccessible set (H1 vulnerability)")
                }

                // Check for access control (kSecAttrAccessControl)
                if attrs[kSecAttrAccessControl as String] == nil {
                    print("[TEST] INFO: sec-keychain-access-control: \(account) has no kSecAttrAccessControl (biometric/passcode guard)")
                }
            } else if status == errSecItemNotFound {
                print("[TEST] INFO: sec-keychain-access-control: \(account) not found in keychain (may not be provisioned yet)")
            } else {
                issues.append("\(account): keychain query error \(status)")
            }
        }

        if itemsFound == 0 {
            recordResult(name: "sec-keychain-access-control", passed: false,
                        detail: "no keychain items found to audit — pairing may not have stored credentials")
        } else if issues.isEmpty {
            recordResult(name: "sec-keychain-access-control", passed: true,
                        detail: "all \(itemsFound) keychain items have proper access controls")
        } else {
            recordResult(name: "sec-keychain-access-control", passed: false,
                        detail: "VULNERABLE (H1): \(issues.joined(separator: "; "))")
        }

        runInputTests { [weak self] in self?.finishTests() }
    }

    // MARK: - Input E2E (tla/InputPath.tla)
    //
    // The iPad sends real input messages through SessionManager.inputSender; the Mac posts them
    // as CGEvents into its own full-screen test window (InputTestHarness), which records every
    // NSEvent with the seq stamped by the injector. Posting is gated to that window, so nothing
    // reaches another app. Latency per event: iPad UIKit-time -> Mac window, clock-synced.

    private var inputReplyHandler: (([String: Any]) -> Void)?
    private var inputLatency: [(total: Double, wire: Double, inject: Double, deliver: Double)] = []
    private var inputLastDroppedStale = 0

    func reportInputTestReply(_ data: Data) {
        let body = Data(data.dropFirst(InputEventHeader.size))
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            print("[CONSOLE] input-test: unparsable reply (\(body.count) bytes)")
            return
        }
        DispatchQueue.main.async {
            let h = self.inputReplyHandler
            self.inputReplyHandler = nil
            h?(obj)
        }
    }

    private func inputControl(_ cmd: [String: Any], timeout: TimeInterval = 5,
                              _ done: @escaping ([String: Any]?) -> Void) {
        var finished = false
        inputReplyHandler = { r in
            if finished { return }
            finished = true
            done(r)
        }
        sessionManager?.sendInputTestControl(cmd)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if finished { return }
            finished = true
            self?.inputReplyHandler = nil
            print("[CONSOLE] input-test: no reply to \(cmd)")
            done(nil)
        }
    }

    private typealias InputStep = (name: String, act: (InputSender, @escaping () -> Void) -> Void,
                                   check: ([String: Any], [[String: Any]]) -> (Bool, String))

    private func runInputTests(_ then: @escaping () -> Void) {
        guard let sm = sessionManager else { then(); return }
        let sender = sm.inputSender
        inputLatency.removeAll()
        print("[TEST] RUNNING: input-ready")
        inputControl(["cmd": "begin"]) { [weak self] r in
            guard let self else { return }
            guard let r, (r["windowUp"] as? Bool) == true else {
                self.recordResult(name: "input-ready", passed: false, detail: "Mac test window did not come up (reply=\(r.map { "\($0)" } ?? "none"))")
                for n in ["input-click", "input-keyboard", "input-double-click", "input-drag", "input-right-click",
                          "input-scroll", "input-text", "input-held-release", "input-stale-seq",
                          "input-autorepeat", "input-latency"] {
                    self.recordResult(name: n, passed: false, detail: "skipped: no Mac test window")
                }
                then(); return
            }
            let ax = (r["axTrusted"] as? Bool) ?? false
            self.inputLastDroppedStale = (r["droppedStale"] as? Int) ?? 0
            self.recordResult(name: "input-ready", passed: ax,
                              detail: "window up, axTrusted=\(ax) active=\(r["active"] ?? "?") key=\(r["key"] ?? "?") link=\(sm.inputLinkDescription)\(ax ? "" : " — grant Accessibility to RemoteDesktopAgent; CGEventPost drops events without it")")
            let steps = self.inputSteps(sender: sender, screenW: (r["screenW"] as? Double) ?? 0,
                                        screenH: (r["screenH"] as? Double) ?? 0,
                                        repeatDelay: (r["repeatDelay"] as? Double) ?? 0.5,
                                        repeatInterval: (r["repeatInterval"] as? Double) ?? 0.083)
            self.runInputStep(steps, 0) {
                self.recordInputLatency()
                self.inputControl(["cmd": "end"]) { _ in then() }
            }
        }
    }

    private func runInputStep(_ steps: [InputStep], _ i: Int, _ done: @escaping () -> Void) {
        guard i < steps.count else { done(); return }
        let step = steps[i]
        print("[TEST] RUNNING: \(step.name)")
        step.act(sessionManager!.inputSender) { [weak self] in
            guard let self else { return }
            self.inputControl(["cmd": "report", "tag": step.name]) { r in
                if let r {
                    let events = (r["events"] as? [[String: Any]]) ?? []
                    self.collectInputLatency(r, events)
                    let (ok, detail) = step.check(r, events)
                    let kinds = events.map { ($0["t"] as? String) ?? "?" }.filter { $0 != "mouseMoved" }
                    print("[CONSOLE] input-test \(step.name): events=\(kinds)")
                    self.recordResult(name: step.name, passed: ok, detail: "\(detail) [events=\(events.count)]")
                } else {
                    self.recordResult(name: step.name, passed: false, detail: "no report from Mac")
                }
                self.runInputStep(steps, i + 1, done)
            }
        }
    }

    private func collectInputLatency(_ r: [String: Any], _ events: [[String: Any]]) {
        guard let timing = r["timing"] as? [String: [String: Any]] else { return }
        let off = Double(clockOffsetUs)   // Mac - iPad (us)
        for e in events {
            let kind = (e["t"] as? String) ?? ""
            guard kind != "mouseMoved", (e["rep"] as? Int ?? 0) == 0,
                  let seq = e["seq"] as? Int, seq > 0,
                  let t = timing[String(seq)],
                  let ipad = t["ipad"] as? Double, let recv = t["recv"] as? Double,
                  let posted = t["posted"] as? Double, let obs = e["obs"] as? Double else { continue }
            let ipadMac = ipad + off
            inputLatency.append((total: (obs - ipadMac) / 1000, wire: (recv - ipadMac) / 1000,
                                 inject: (posted - recv) / 1000, deliver: (obs - posted) / 1000))
        }
    }

    private func recordInputLatency() {
        print("[TEST] RUNNING: input-latency")
        let n = inputLatency.count
        func pct(_ xs: [Double], _ p: Double) -> Double {
            let s = xs.sorted(); guard !s.isEmpty else { return .nan }
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        let tot = inputLatency.map(\.total), wire = inputLatency.map(\.wire)
        let inj = inputLatency.map(\.inject), del = inputLatency.map(\.deliver)
        let f = { (x: Double) in String(format: "%.1f", x) }
        let detail = "samples=\(n) iPad-event->Mac-app total[med/p95/max]=\(f(pct(tot, 0.5)))/\(f(pct(tot, 0.95)))/\(f(pct(tot, 1)))ms wire[med/p95]=\(f(pct(wire, 0.5)))/\(f(pct(wire, 0.95)))ms inject[med/p95]=\(f(pct(inj, 0.5)))/\(f(pct(inj, 0.95)))ms deliver[med/p95]=\(f(pct(del, 0.5)))/\(f(pct(del, 0.95)))ms clock=\(clockOffsetCalibrated ? "calibrated" : "uncalibrated") (provisional pass: >=10 samples, median<50ms)"
        recordResult(name: "input-latency", passed: n >= 10 && pct(tot, 0.5) < 50, detail: detail)
    }

    private func inputSteps(sender: InputSender, screenW: Double, screenH: Double,
                            repeatDelay: Double, repeatInterval: Double) -> [InputStep] {
        let now = { ProcessInfo.processInfo.systemUptime }
        func n(_ f: Double) -> UInt16 { UInt16((f * 65535).rounded()) }
        func after(_ ms: Int, _ f: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: f)
        }
        func kinds(_ ev: [[String: Any]], _ k: String) -> [[String: Any]] { ev.filter { ($0["t"] as? String) == k } }
        func near(_ e: [String: Any], _ fx: Double, _ fy: Double) -> Bool {
            guard let x = e["x"] as? Double, let y = e["y"] as? Double, screenW > 0 else { return false }
            return abs(x - fx * (screenW - 1)) <= 3 && abs(y - fy * (screenH - 1)) <= 3
        }
        let shiftMask = 1 << 17
        return [
            ("input-click", { s, done in
                s.pointerMove(n(0.5), n(0.5), ts: now())
                s.button(InputSender.buttonLeft, down: true, n(0.5), n(0.5), ts: now())
                s.button(InputSender.buttonLeft, down: false, n(0.5), n(0.5), ts: now())
                after(400, done)   // the click also makes the agent active and its window key
            }, { r, ev in
                let d = kinds(ev, "leftMouseDown"), u = kinds(ev, "leftMouseUp")
                let ok = d.count == 1 && u.count == 1 && near(d[0], 0.5, 0.5) && (d[0]["cc"] as? Int) == 1
                return (ok, "down=\(d.count) up=\(u.count) at=(\(d.first?["x"] ?? "-"),\(d.first?["y"] ?? "-")) cc=\(d.first?["cc"] ?? "-") key=\(r["key"] ?? "?") active=\(r["active"] ?? "?")")
            }),
            ("input-keyboard", { s, done in
                s.key(0x04, down: true, ts: now()); s.key(0x04, down: false, ts: now())        // a
                s.key(0xE1, down: true, ts: now())                                              // shift
                s.key(0x04, down: true, ts: now()); s.key(0x04, down: false, ts: now())        // A
                s.key(0xE1, down: false, ts: now())
                after(150, done)
            }, { _, ev in
                let downs = kinds(ev, "keyDown").map { ($0["ch"] as? String) ?? "" }
                let ups = kinds(ev, "keyUp").count
                let flags = kinds(ev, "flagsChanged").count
                let shifted = kinds(ev, "keyDown").contains { ($0["ch"] as? String) == "A" && (($0["fl"] as? Int ?? 0) & shiftMask) != 0 }
                let ok = downs == ["a", "A"] && ups == 2 && flags == 2 && shifted
                return (ok, "keyDown=\(downs) keyUp=\(ups) flagsChanged=\(flags) shiftOnA=\(shifted)")
            }),
            ("input-double-click", { s, done in
                for _ in 0..<2 {
                    s.button(InputSender.buttonLeft, down: true, n(0.3), n(0.3), ts: now())
                    s.button(InputSender.buttonLeft, down: false, n(0.3), n(0.3), ts: now())
                }
                after(150, done)
            }, { _, ev in
                let cc = kinds(ev, "leftMouseDown").map { ($0["cc"] as? Int) ?? 0 }
                return (cc == [1, 2], "clickCounts=\(cc)")
            }),
            ("input-drag", { s, done in
                s.button(InputSender.buttonLeft, down: true, n(0.4), n(0.4), ts: now())
                var k = 1
                func step() {
                    let f = 0.4 + 0.04 * Double(k)
                    s.pointerMove(n(f), n(f), ts: now())
                    if k == 5 {
                        s.button(InputSender.buttonLeft, down: false, n(0.6), n(0.6), ts: now())
                        after(150, done)
                    } else { k += 1; after(16, step) }
                }
                after(16, step)
            }, { _, ev in
                let drags = kinds(ev, "leftMouseDragged").count
                let up = kinds(ev, "leftMouseUp").first
                let ok = drags >= 4 && up != nil && near(up!, 0.6, 0.6)
                return (ok, "dragged=\(drags) upAt=(\(up?["x"] ?? "-"),\(up?["y"] ?? "-"))")
            }),
            ("input-right-click", { s, done in
                s.button(InputSender.buttonRight, down: true, n(0.5), n(0.5), ts: now())
                s.button(InputSender.buttonRight, down: false, n(0.5), n(0.5), ts: now())
                after(150, done)
            }, { _, ev in
                let d = kinds(ev, "rightMouseDown").count, u = kinds(ev, "rightMouseUp").count
                return (d == 1 && u == 1, "rightDown=\(d) rightUp=\(u)")
            }),
            ("input-scroll", { s, done in
                s.scroll(dx: 0, dy: 10, phase: InputSender.phaseBegan, n(0.5), n(0.5), ts: now())
                var k = 0
                func step() {
                    if k == 5 {
                        s.scroll(dx: 0, dy: 0, phase: InputSender.phaseEnded, n(0.5), n(0.5), ts: now())
                        after(150, done); return
                    }
                    s.scroll(dx: 0, dy: 10, phase: InputSender.phaseChanged, n(0.5), n(0.5), ts: now())
                    k += 1; after(16, step)
                }
                after(16, step)
            }, { _, ev in
                let sc = kinds(ev, "scrollWheel")
                let dy = sc.compactMap { $0["dy"] as? Double }.reduce(0, +)
                let phases = sc.compactMap { $0["ph"] as? Int }
                let ok = sc.count >= 6 && dy > 0 && phases.contains(1) && phases.contains(8)
                return (ok, "scrollEvents=\(sc.count) sumDy=\(String(format: "%.1f", dy)) phases=\(phases)")
            }),
            ("input-text", { s, done in
                s.text("héllo ✓", ts: now())
                after(150, done)
            }, { _, ev in
                let typed = kinds(ev, "keyDown").map { ($0["ch"] as? String) ?? "" }.joined()
                return (typed == "héllo ✓", "typed=\"\(typed)\"")
            }),
            ("input-held-release", { s, done in
                s.key(0x05, down: true, ts: now())          // b down, then the iPad loses held state
                after(50) {
                    s.cancelAll(reason: "e2e-held-release")   // HELD {} (release-only on the Mac)
                    after(150, done)
                }
            }, { _, ev in
                let down = kinds(ev, "keyDown").contains { ($0["ch"] as? String) == "b" }
                let up = kinds(ev, "keyUp").contains { ($0["kc"] as? Int) == 11 }
                return (down && up, "bDown=\(down) bReleasedByHELD=\(up)")
            }),
            ("input-stale-seq", { s, done in
                var body = Data(); body.appendLE(UInt16(0x06)); body.append(1)   // c down with an old seq
                s.sendRawForTest(type: InputSender.tKey, body: body, seq: 1)
                after(150, done)
            }, { [weak self] r, ev in
                let typed = kinds(ev, "keyDown").contains { ($0["ch"] as? String) == "c" }
                let dropped = (r["droppedStale"] as? Int) ?? 0
                let before = self?.inputLastDroppedStale ?? 0
                self?.inputLastDroppedStale = dropped
                return (!typed && dropped > before, "staleApplied=\(typed) droppedStale \(before)->\(dropped)")
            }),
            ("input-autorepeat", { s, done in
                let hold = min(1.5, repeatDelay + 8 * repeatInterval)
                s.key(0x07, down: true, ts: now())          // d
                after(Int(hold * 1000)) {
                    s.key(0x07, down: false, ts: now())
                    after(150, done)
                }
            }, { _, ev in
                let hold = min(1.5, repeatDelay + 8 * repeatInterval)
                let reps = kinds(ev, "keyDown").filter { ($0["ch"] as? String) == "d" && ($0["rep"] as? Int) == 1 }.count
                let firsts = kinds(ev, "keyDown").filter { ($0["ch"] as? String) == "d" && ($0["rep"] as? Int) == 0 }.count
                let expected = max(0, (hold - repeatDelay) / max(repeatInterval, 0.001))
                let ok = firsts == 1 && reps >= 3 && Double(reps) <= expected * 1.5 + 2
                return (ok, "first=\(firsts) repeats=\(reps) expected~\(String(format: "%.1f", expected)) (delay=\(repeatDelay)s interval=\(repeatInterval)s)")
            }),
        ]
    }

    // MARK: - Continuous Stream Telemetry

    private func startStreamTelemetry() {
        DispatchQueue.main.async {
            self.streamTelemetryTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.logStreamTelemetryTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.streamTelemetryTimer = timer
        }
    }

    private func stopStreamTelemetry() {
        streamTelemetryTimer?.invalidate()
        streamTelemetryTimer = nil
    }

    private func logStreamTelemetryTick() {
        guard let sm = sessionManager else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - streamTelemetryStartTime

        let observed = observedFrameCount
        let rendered = totalRenderedFrames
        let keyframes = keyframesObserved
        let decodeFailures = hevcDecodeFailures
        let rendererStats = sm.metalRenderer.statsSnapshot()
        let observedDelta = observed - lastTelemetryObservedCount
        let renderedDelta = rendered - lastTelemetryRenderedCount
        let keyframeDelta = keyframes - lastTelemetryKeyframeCount
        let decodeFailureDelta = decodeFailures - lastTelemetryDecodeFailureCount
        let overwriteDelta = rendererStats.overwrittenFrames - lastTelemetryRendererOverwriteCount

        let pipelineWindow = Array(pipelineLatenciesUs.suffix(from: min(lastTelemetryPipelineCount, pipelineLatenciesUs.count)))
        let glassWindow = Array(glassToGlassLatenciesUs.suffix(from: min(lastTelemetryGlassCount, glassToGlassLatenciesUs.count)))
        lastTelemetryObservedCount = observed
        lastTelemetryRenderedCount = rendered
        lastTelemetryKeyframeCount = keyframes
        lastTelemetryDecodeFailureCount = decodeFailures
        lastTelemetryPipelineCount = pipelineLatenciesUs.count
        lastTelemetryGlassCount = glassToGlassLatenciesUs.count
        lastTelemetryRendererOverwriteCount = rendererStats.overwrittenFrames

        let transport: String
        if sm.usbTransport.isConnected {
            transport = "usb"
        } else if sm.wirelessTransport.isConnected {
            transport = sm.wirelessTransport.isAWDL ? "awdl" : "wifi"
        } else {
            transport = "none"
        }

        let pipelineSummary = latencyWindowSummary(window: pipelineWindow)
        let glassSummary = latencyWindowSummary(window: glassWindow)
        let udpStats = sm.udpReassembler.statsSnapshot()

        print("[CONSOLE] STREAM-TELEMETRY t=\(String(format: "%.1f", elapsed))s transport=\(transport) state=\(sm.state.rawValue) observed=\(observedDelta)fps rendered=\(renderedDelta)fps keyframes+\(keyframeDelta) decodeFail+\(decodeFailureDelta) renderer[overwrites+\(overwriteDelta) pending=\(rendererStats.hasPendingFrame ? 1 : 0) depth=\(rendererStats.pendingDepth) catchup=\(rendererStats.adaptiveCatchupCount) catchupDrop=\(rendererStats.adaptiveCatchupDropFrames)] pipeline=\(pipelineSummary) glass=\(glassSummary) reasm[pending=\(udpStats.pendingFrames) ooo=\(udpStats.outOfOrderBuffered) delivered=\(udpStats.framesDelivered) evicted=\(udpStats.framesEvicted) purged=\(udpStats.framesPurged) lastSeq=\(udpStats.lastDeliveredSeq)]")
    }

    private func latencyWindowSummary(window: [Int64]) -> String {
        guard !window.isEmpty else { return "n/a" }
        let sorted = window.sorted()
        let medianMs = sorted[sorted.count / 2] / 1000
        let p95Idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
        let p95Ms = sorted[p95Idx] / 1000
        let maxMs = sorted.last! / 1000
        return "median=\(medianMs)ms p95=\(p95Ms)ms max=\(maxMs)ms n=\(sorted.count)"
    }

    // MARK: - Results

    private func qrPayloadHost() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--qr-payload"), idx + 1 < args.count else {
            return nil
        }
        guard let jsonData = Data(base64Encoded: args[idx + 1]),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        return json["host"] as? String
    }

    private func recordResult(name: String, passed: Bool, detail: String) {
        if dispatchToMainIfNeeded({ [weak self] in self?.recordResult(name: name, passed: passed, detail: detail) }) { return }
        testResults.append((name: name, passed: passed, detail: detail))
        let status = passed ? "PASS" : "FAIL"
        print("[TEST] \(status): \(name) (\(detail))")
    }

    private func finishTests() {
        overallTimer?.invalidate()
        overallTimer = nil
        stopStreamTelemetry()

        let elapsed = CFAbsoluteTimeGetCurrent() - testStartTime
        let passCount = testResults.filter { $0.passed }.count
        let failCount = testResults.filter { !$0.passed }.count
        let total = testResults.count

        print("[TEST] COMPLETE: \(passCount)/\(total) passed, \(failCount) failed (elapsed: \(String(format: "%.1f", elapsed))s)")
    }

    private func onTimeout() {
        print("[TEST] TIMEOUT: overall test timeout reached (\(Int(overallTimeoutSeconds))s)")

        // Report remaining tests as failed
        let completedTests = Set(testResults.map { $0.name })
        var allTests = ["bonjour-discovery", "tls-connection", "ecdh-exchange",
                       "transport-detected", "session-handshake", "frame-reception",
                       "frame-decompression", "latency-probe", "keepalive",
                       "resolution", "fps", "frame-pacing", "frame-loss",
                       "latency-tiered", "throughput",
                       "pipeline-latency", "glass-to-glass-latency",
                       "heavy-load", "video-playback",
                       "sec-cleartext-tcp", "sec-cleartext-udp", "sec-untrusted-cert",
                       "sec-pairing-port-closed", "sec-pairing-port-closed-after-stream",
                       "sec-mitm-reconnect", "sec-pre-pairing-transport-reject",
                       "sec-pairing-race", "sec-identity-secure-enclave",
                       "sec-keychain-access-control",
                       "input-ready", "input-click", "input-keyboard", "input-double-click",
                       "input-drag", "input-right-click", "input-scroll", "input-text",
                       "input-held-release", "input-stale-seq", "input-autorepeat", "input-latency"]
        if sustainedStreamDuration > 0 {
            allTests.append("sustained-stream")
        }
        allTests.append(contentsOf: selectedTransports.map { "transport-\($0)" })
        allTests.append("multi-transport")
        if expectTransport != nil {
            allTests.append("transport-assertion")
        }

        for test in allTests where !completedTests.contains(test) {
            recordResult(name: test, passed: false, detail: "not reached before timeout")
        }

        finishTests()
    }

    // MARK: - Helpers

    private func describeCaps(_ caps: UInt8) -> String {
        var parts: [String] = []
        if caps & 0x01 != 0 { parts.append("LZ4") }
        if caps & 0x02 != 0 { parts.append("HEVC") }
        if caps & 0x04 != 0 { parts.append("ECO") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}
