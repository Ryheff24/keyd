import Foundation
import Network
import Security
import CryptoKit
import os.log

/// On-device E2E test runner for the keyd-rd iPad app.
///
/// Runs a sequential test suite that verifies the REAL Mac<->iPad communication
/// pipeline: Bonjour discovery, TLS+ECDH pairing, transport detection, session
/// handshake, frame reception, decompression, latency probe, and keepalive.
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

    // Handshake details
    private var handshakeWidth: UInt32 = 0
    private var handshakeHeight: UInt32 = 0
    private var handshakeScale: Float = 0
    private var handshakeCaps: UInt8 = 0
    private var handshakeMaxFps: UInt8 = 0

    // Overall timeout
    private var overallTimer: Timer?
    private static let overallTimeout: TimeInterval = 55 // leave room for script timeout

    private let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "E2ETest")

    // MARK: - Init

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Public API

    /// Run the full E2E test suite. Called from SessionManager after start().
    func runAllTests() {
        testStartTime = CFAbsoluteTimeGetCurrent()
        print("[TEST] START: on-device E2E test suite")
        print("[TEST] INFO: device=iPad, timestamp=\(ISO8601DateFormatter().string(from: Date()))")

        // Set overall timeout
        overallTimer = Timer.scheduledTimer(withTimeInterval: Self.overallTimeout, repeats: false) { [weak self] _ in
            self?.onTimeout()
        }

        // Tests 1-3 (TLS, ECDH) are reported by the auto-pairing flow in QRPairing.
        // Test 4 (Bonjour discovery) runs after pairing completes, when the Mac
        // starts advertising _keydrd._tcp via startTransportMonitoring.
        // Tests 5+ are driven by SessionManager state change callbacks.
    }

    /// Run the Bonjour discovery test. Called after pairing completes and
    /// transport monitoring starts (Mac is now advertising _keydrd._tcp).
    func runBonjourDiscoveryTestAfterPairing() {
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

        let discoveryTimeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.bonjourDiscoveryComplete else { return }
            self.bonjourDiscoveryComplete = true
            self.recordResult(name: "bonjour-discovery", passed: false, detail: "timeout after 10s")
            self.bonjourBrowser?.cancel()
            self.bonjourBrowser = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: discoveryTimeout)

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
        recordResult(name: "tls-connection", passed: success, detail: detail)
    }

    // MARK: - Test 3: ECDH Exchange (called from QRPairing auto-pair)

    func reportECDHExchange(success: Bool, detail: String) {
        recordResult(name: "ecdh-exchange", passed: success, detail: detail)

        // After ECDH, pairing is complete. Tests 4+ happen via session lifecycle.
    }

    // MARK: - Test 4: Transport Detection (called from SessionManager)

    func reportTransportDetected(type: String) {
        guard !transportDetected else { return }
        transportDetected = true
        detectedTransportType = type
        recordResult(name: "transport-detected", passed: true, detail: "type: \(type)")
    }

    // MARK: - Test 5: Session Handshake (called from SessionManager)

    func reportSessionHandshake(_ handshake: SessionHandshakeMessage) {
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
        framesReceived += 1
        if decompressedSize > 0 {
            framesDecompressed += 1
            totalDecompressedBytes += decompressedSize
        }

        if framesReceived >= targetFrameCount && !frameReceptionComplete {
            frameReceptionComplete = true

            let mode = header.isHEVC ? "HEVC" : "LZ4"
            recordResult(name: "frame-reception", passed: true,
                        detail: "received: \(framesReceived) frames, mode: \(mode)")

            if framesDecompressed >= targetFrameCount {
                let avgSize = totalDecompressedBytes / framesDecompressed
                recordResult(name: "frame-decompression", passed: true,
                            detail: "\(framesDecompressed) frames, avg-size: \(avgSize)")
            } else {
                recordResult(name: "frame-decompression", passed: false,
                            detail: "only \(framesDecompressed)/\(targetFrameCount) decompressed")
            }

            // After enough frames, start latency test
            runLatencyProbeTest()
        }
    }

    // MARK: - Test 8: Latency Probe

    private func runLatencyProbeTest() {
        print("[TEST] RUNNING: latency-probe")

        guard let sm = sessionManager else {
            recordResult(name: "latency-probe", passed: false, detail: "sessionManager nil")
            runKeepaliveTest()
            return
        }

        // Send a latency probe and measure round-trip
        let sentTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
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
            self.recordResult(name: "latency-probe", passed: false, detail: "timeout after 5s")
            self.runKeepaliveTest()
        }
    }

    func reportLatencyProbeResponse(rttUs: UInt64) {
        guard !latencyProbeComplete else { return }
        latencyProbeComplete = true

        let rttMs = Int(rttUs / 1000)
        latencyProbeRTT = rttMs
        recordResult(name: "latency-probe", passed: true, detail: "rtt: \(rttMs)ms")

        runKeepaliveTest()
    }

    // MARK: - Test 9: Keepalive

    private func runKeepaliveTest() {
        print("[TEST] RUNNING: keepalive")

        guard let sm = sessionManager else {
            recordResult(name: "keepalive", passed: false, detail: "sessionManager nil")
            finishTests()
            return
        }

        // Send a keepalive and verify we remain connected after 3 seconds
        let header = InputEventHeader(type: InputEventType.keepalive.rawValue,
                                      tsUs: UInt64(Date().timeIntervalSince1970 * 1_000_000))
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
                self?.finishTests()
                return
            }

            let stillConnected = sm.usbTransport.isConnected || sm.wirelessTransport.isConnected
            self.recordResult(name: "keepalive", passed: stillConnected,
                            detail: stillConnected ? "still connected after 3s" : "disconnected")
            self.finishTests()
        }
    }

    // MARK: - Results

    private func recordResult(name: String, passed: Bool, detail: String) {
        testResults.append((name: name, passed: passed, detail: detail))
        let status = passed ? "PASS" : "FAIL"
        print("[TEST] \(status): \(name) (\(detail))")
    }

    private func finishTests() {
        overallTimer?.invalidate()
        overallTimer = nil

        let elapsed = CFAbsoluteTimeGetCurrent() - testStartTime
        let passCount = testResults.filter { $0.passed }.count
        let failCount = testResults.filter { !$0.passed }.count
        let total = testResults.count

        print("[TEST] COMPLETE: \(passCount)/\(total) passed, \(failCount) failed (elapsed: \(String(format: "%.1f", elapsed))s)")
    }

    private func onTimeout() {
        print("[TEST] TIMEOUT: overall test timeout reached (\(Self.overallTimeout)s)")

        // Report remaining tests as failed
        let completedTests = Set(testResults.map { $0.name })
        let allTests = ["bonjour-discovery", "tls-connection", "ecdh-exchange",
                       "transport-detected", "session-handshake", "frame-reception",
                       "frame-decompression", "latency-probe", "keepalive"]

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
