import SwiftUI

/// Frosted glass HUD overlay pill with compact and expanded states.
///
/// Compact state (top-center): transport icon + latency + FPS.
/// Expanded state: quality/eco toggle, resolution, bitrate, match resolution, disconnect.
/// Auto-hides after 3 seconds. Revealed by swipe down from top of screen.
///
/// Uses `.ultraThinMaterial` for frosted glass effect.
/// Does NOT use UIScreenEdgePanGestureRecognizer (RD-APP-07: system edge swipes not intercepted).
struct HUDView: View {

    @Bindable var viewModel: HUDViewModel

    var body: some View {
        ZStack(alignment: .top) {
            // Swipe-down detection zone at top of screen (top 44pt)
            swipeDetectionZone

            if viewModel.isVisible {
                VStack(spacing: 0) {
                    // Compact pill (always visible when HUD is shown)
                    compactPill
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                viewModel.toggleExpanded()
                            }
                        }

                    // Expanded panel (below pill)
                    if viewModel.isExpanded {
                        expandedPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isExpanded)
    }

    // MARK: - Swipe Detection Zone

    /// Invisible zone at top 44pt of screen to detect swipe-down gesture.
    /// Uses DragGesture, NOT UIScreenEdgePanGestureRecognizer (RD-APP-07).
    private var swipeDetectionZone: some View {
        Color.clear
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        // Only trigger on downward swipes
                        if value.translation.height > 30 {
                            print("[CONSOLE] HUD swipe-down detected: height=\(value.translation.height)")
                            viewModel.show()
                        } else {
                            print("[CONSOLE] HUD swipe ignored: height=\(value.translation.height)")
                        }
                    }
            )
            .frame(maxWidth: .infinity)
    }

    // MARK: - Compact Pill

    /// Compact pill showing transport icon + latency + FPS.
    /// Font: `.system(.caption, design: .monospaced)`.
    /// Background: `.ultraThinMaterial` (frosted glass).
    private var compactPill: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.transportIconName)
                .font(.system(.caption))

            Text("\(viewModel.latencyMs)ms")
                .font(.system(.caption, design: .monospaced))

            Text("\(viewModel.fps)fps")
                .font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            ZStack {
                // Frosted glass
                Capsule()
                    .fill(.ultraThinMaterial)

                // Transport flash overlay
                if let flashColor = viewModel.transportFlashColor {
                    Capsule()
                        .fill(flashColor.opacity(0.3))
                        .animation(.easeOut(duration: 0.5), value: viewModel.transportFlashColor == nil)
                }
            }
        }
        .clipShape(Capsule())
    }

    // MARK: - Expanded Panel

    /// Expanded panel with full connection controls.
    /// Same frosted glass background. Animates with spring transition.
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Eco mode toggle
            Toggle(isOn: Binding(
                get: { viewModel.isEcoMode },
                set: { _ in viewModel.toggleEcoMode() }
            )) {
                Label("Eco Mode", systemImage: "leaf")
                    .font(.system(.callout))
            }
            .tint(.green)

            Divider()
                .background(.white.opacity(0.3))

            // Resolution info
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac: \(viewModel.macResolution)")
                    .font(.system(.caption, design: .monospaced))
                Text("iPad: \(viewModel.iPadResolution)")
                    .font(.system(.caption, design: .monospaced))
            }

            // Bitrate
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(.caption))
                Text(viewModel.bitrateFormatted)
                    .font(.system(.caption, design: .monospaced))
            }

            Divider()
                .background(.white.opacity(0.3))

            // Match iPad Resolution button
            Button {
                viewModel.requestResolutionMatch()
            } label: {
                Label("Match iPad Resolution", systemImage: "arrow.left.arrow.right.square")
                    .font(.system(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Reset Pairing button — clears credentials, returns to QR scanner
            Button(role: .destructive) {
                viewModel.resetPairing()
            } label: {
                Label("Reset Pairing", systemImage: "qrcode")
                    .font(.system(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Disconnect button (destructive)
            Button(role: .destructive) {
                viewModel.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .font(.system(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
        .onTapGesture {
            // Reset auto-hide on any tap within expanded panel
            viewModel.resetAutoHideTimer()
        }
    }
}
