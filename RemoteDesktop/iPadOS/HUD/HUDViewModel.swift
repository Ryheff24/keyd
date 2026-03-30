import SwiftUI
import Combine
import os.log

/// View model for the HUD overlay pill.
///
/// Manages compact/expanded state, auto-hide timer, transport info display,
/// and relay of user actions (eco mode, disconnect, resolution match) to SessionManager.
@Observable
final class HUDViewModel {

    // MARK: - Display State

    /// Whether the HUD is visible at all.
    var isVisible: Bool = false

    /// Whether the HUD is in expanded mode (showing full controls).
    var isExpanded: Bool = false

    // MARK: - Transport Info

    /// Current transport connection state.
    var transportState: TransportState = .idle

    /// Round-trip latency in milliseconds.
    var latencyMs: Int = 0

    /// Current frames per second.
    var fps: Int = 0

    /// Whether eco mode is active (HEVC at reduced resolution).
    var isEcoMode: Bool = false

    /// Mac capture resolution string (e.g., "2560x1664").
    var macResolution: String = "--"

    /// iPad render resolution string (e.g., "2388x1668").
    var iPadResolution: String = "--"

    /// Formatted bitrate/throughput string (e.g., "2.1 Gbps").
    var bitrateFormatted: String = "--"

    // MARK: - Transport Flash

    /// Brief color flash on transport change. Cleared after animation.
    var transportFlashColor: Color? = nil

    // MARK: - Callbacks

    /// Called when eco mode is toggled. SessionManager sets this.
    var onEcoModeChanged: ((Bool) -> Void)?

    /// Called when user requests disconnect. SessionManager sets this.
    var onDisconnect: (() -> Void)?

    /// Called when user requests resolution match. SessionManager sets this.
    var onResolutionMatch: (() -> Void)?

    // MARK: - Private

    private static let log = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "HUD")

    /// Auto-hide timer: collapses and hides after 3 seconds of no interaction.
    private var autoHideTimer: Timer?

    /// Timer to clear transport flash color after animation.
    private var flashTimer: Timer?

    private static let autoHideDuration: TimeInterval = 3.0
    private static let flashDuration: TimeInterval = 1.0

    // MARK: - Transport Icon

    /// SF Symbol name for the current transport state.
    var transportIconName: String {
        switch transportState {
        case .usbNCM:
            return "cable.connector"
        case .wifi:
            return "wifi"
        case .awdl:
            return "antenna.radiowaves.left.and.right"
        case .idle, .disconnected:
            return "xmark.circle"
        }
    }

    /// Color associated with the current transport (used for flash).
    var transportColor: Color {
        switch transportState {
        case .usbNCM:
            return .green
        case .wifi:
            return .yellow
        case .awdl:
            return .orange
        case .idle, .disconnected:
            return .gray
        }
    }

    // MARK: - Public API

    /// Show the HUD and reset the auto-hide timer.
    func show() {
        print("[CONSOLE] HUDViewModel.show() called; wasVisible=\(isVisible), wasExpanded=\(isExpanded)")
        isVisible = true
        resetAutoHideTimer()
    }

    /// Reset the auto-hide timer. Only hides the expanded panel, NOT the compact pill.
    /// The compact pill stays visible permanently during streaming for transport/FPS info.
    func resetAutoHideTimer() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: Self.autoHideDuration,
                                              repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                print("[CONSOLE] HUD auto-hide timer fired; collapsing expanded panel")
                self?.isExpanded = false
                // Keep isVisible = true — compact pill stays visible
            }
        }
    }

    /// Toggle between compact and expanded states.
    func toggleExpanded() {
        isExpanded.toggle()
        resetAutoHideTimer()
    }

    /// Toggle eco mode and notify SessionManager.
    func toggleEcoMode() {
        isEcoMode.toggle()
        onEcoModeChanged?(isEcoMode)
        resetAutoHideTimer()
    }

    /// Request disconnect via SessionManager.
    func disconnect() {
        onDisconnect?()
    }

    /// Request resolution match via SessionManager.
    func requestResolutionMatch() {
        onResolutionMatch?()
        resetAutoHideTimer()
    }

    /// Flash the transport color when the transport changes.
    /// Called by SessionManager when transport state transitions.
    func flashTransportChange(to newState: TransportState) {
        transportState = newState

        // Set flash color
        transportFlashColor = transportColor

        // Clear flash after animation duration
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashDuration,
                                           repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.transportFlashColor = nil
            }
        }

        Self.log.info("Transport changed to \(newState.rawValue)")
    }

    /// Update FPS counter. Called from the frame receive pipeline.
    func updateFPS(_ newFPS: Int) {
        fps = newFPS
    }

    /// Update latency. Called from latency probe response.
    func updateLatency(_ ms: Int) {
        latencyMs = ms
    }

    /// Update resolution info strings.
    func updateResolution(macWidth: Int, macHeight: Int, iPadWidth: Int, iPadHeight: Int) {
        macResolution = "\(macWidth)x\(macHeight)"
        iPadResolution = "\(iPadWidth)x\(iPadHeight)"
    }

    /// Update bitrate display string.
    func updateBitrate(_ formatted: String) {
        bitrateFormatted = formatted
    }

    deinit {
        autoHideTimer?.invalidate()
        flashTimer?.invalidate()
    }
}
