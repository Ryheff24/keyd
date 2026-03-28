import SwiftUI
import AVFoundation

// MARK: - ContentView

/// Main content view for the RemoteDesktop iPad app.
///
/// Switches between session states:
/// - awaitingPairing: QR scanner (straight to camera, no onboarding)
/// - connecting: Progress spinner
/// - streaming: Metal render view (plain UIView with CAMetalLayer, NOT MTKView) + HUD overlay
/// - reconnecting: Frozen last frame + reconnecting overlay
/// - disconnected: Disconnected message
struct ContentView: View {

    @Bindable var sessionManager: SessionManager

    var body: some View {
        ZStack {
            // True black background for OLED letterbox (pixels off)
            Color.black.ignoresSafeArea()

            switch sessionManager.state {
            case .awaitingPairing:
                QRScannerView(
                    pairing: sessionManager.qrPairing,
                    onPaired: { sessionManager.onPairingComplete() }
                )
                .ignoresSafeArea()

            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Connecting...")
                        .font(.headline)
                        .foregroundStyle(.white)
                }

            case .streaming, .reconnecting:
                // Metal render view: plain UIView with CAMetalLayer (NOT MTKView)
                MetalRenderView(renderer: sessionManager.metalRenderer)
                    .ignoresSafeArea()

                // Reconnecting overlay (shown over frozen last frame)
                if sessionManager.state == .reconnecting {
                    ReconnectingOverlay(onRetryNow: { sessionManager.retryNow() })
                }

                // HUD overlay
                HUDView(viewModel: sessionManager.hudViewModel)

            case .disconnected:
                VStack(spacing: 16) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Disconnected")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            sessionManager.start()
        }
    }
}

// MARK: - MetalRenderView

/// UIViewRepresentable wrapping a plain UIView whose backing layer IS a CAMetalLayer.
///
/// CRITICAL: NOT MTKView. CAMetalDisplayLink requires owning its own CAMetalLayer,
/// which conflicts with MTKView's built-in drawable scheduling loop. The UIView's
/// layer IS a CAMetalLayer (via layerClass override), and MetalRenderer creates
/// CAMetalDisplayLink from that layer.
struct MetalRenderView: UIViewRepresentable {

    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        view.backgroundColor = .black

        // Pass the view's layer (which IS a CAMetalLayer) to MetalRenderer
        renderer.setup(metalLayer: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalHostView, context: Context) {
        // Update viewport on bounds change
        renderer.handleBoundsChange(newBounds: uiView.bounds,
                                     scale: uiView.contentScaleFactor)
    }
}

/// Plain UIView subclass whose backing layer IS a CAMetalLayer.
/// This is the correct hosting pattern for CAMetalDisplayLink.
class MetalHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

// MARK: - QRScannerView

/// UIViewRepresentable wrapping AVCaptureVideoPreviewLayer for QR scanning.
///
/// Straight to camera viewfinder (no onboarding screen -- user decision).
/// Uses QRPairing for capture session management and QR detection.
struct QRScannerView: UIViewRepresentable {

    let pairing: QRPairing
    let onPaired: () -> Void

    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .black

        pairing.onPairingComplete = { [onPaired] in
            onPaired()
        }

        // Start camera session
        if let captureSession = pairing.startScanning() {
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = containerView.bounds
            containerView.layer.addSublayer(previewLayer)

            // Store preview layer for bounds updates
            context.coordinator.previewLayer = previewLayer
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Update preview layer frame on bounds change
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - ReconnectingOverlay

/// Semi-transparent overlay shown over frozen last frame during reconnection.
///
/// Shows "Reconnecting..." text and a "Retry Now" button.
/// The last frame stays visible behind this overlay (NOT black screen --
/// frozen frame for visual continuity per user decision).
struct ReconnectingOverlay: View {

    let onRetryNow: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent black over frozen frame
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                Text("Reconnecting...")
                    .font(.headline)
                    .foregroundStyle(.white)

                Button {
                    onRetryNow()
                } label: {
                    Text("Retry Now")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                }
            }
        }
    }
}
