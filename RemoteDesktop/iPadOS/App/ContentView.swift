import SwiftUI
import AVFoundation
import os.log

private let contentLog = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "ContentView")
private let scannerPaneLog = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "QRScannerPane")
private let scannerViewLog = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "QRScannerView")
private let cameraPreviewLog = Logger(subsystem: "com.ryheff.keyd.remote.app", category: "CameraPreviewView")

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
        let _ = contentLog.info("[ContentView] body evaluated, sessionManager.state = \(sessionManager.state.rawValue)")
        ZStack {
            // True black background for OLED letterbox (pixels off)
            Color.black.ignoresSafeArea()

            switch sessionManager.state {
            case .awaitingPairing:
                if sessionManager.isTestMode {
                    let _ = contentLog.info("[ContentView] rendering .awaitingPairing -> TEST MODE (no camera)")
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Test Mode: Auto-pairing...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                } else {
                let _ = contentLog.info("[ContentView] rendering .awaitingPairing -> QRScannerPane")
                QRScannerPane(
                    pairing: sessionManager.qrPairing,
                    onPaired: { sessionManager.onPairingComplete() }
                )
                }

            case .connecting, .streaming, .reconnecting:
                let _ = contentLog.info("[ContentView] rendering .connecting/.streaming/.reconnecting (state=\(sessionManager.state.rawValue))")
                // Metal render view present from .connecting so the display link is
                // ready when frames arrive (avoids rendered=0 race at stream start).
                MetalRenderView(renderer: sessionManager.metalRenderer)
                    .ignoresSafeArea()

                if sessionManager.state == .connecting {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Connecting...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }

                // Reconnecting overlay (shown over frozen last frame)
                if sessionManager.state == .reconnecting {
                    ReconnectingOverlay(onRetryNow: { sessionManager.retryNow() })
                }

                // HUD overlay (streaming/reconnecting only)
                if sessionManager.state != .connecting {
                    HUDView(viewModel: sessionManager.hudViewModel)
                }

            case .disconnected:
                let _ = contentLog.info("[ContentView] rendering .disconnected")
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
            contentLog.info("[ContentView] onAppear fired, calling sessionManager.start()")
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

// MARK: - QRScannerPane

/// Camera viewfinder in a glass-bordered pane, sized to the camera's native 4:3 aspect ratio.
/// Shows a loading indicator while the camera initializes.
struct QRScannerPane: View {

    let pairing: QRPairing
    let onPaired: () -> Void

    @State private var cameraReady = false

    var body: some View {
        let _ = scannerPaneLog.info("[QRScannerPane] body evaluated, cameraReady = \(self.cameraReady)")
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let pad: CGFloat = 48
            let textSpace: CGFloat = 52
            let availW = geo.size.width - pad * 2
            let availH = geo.size.height - pad * 2 - textSpace
            // Camera is 4:3 native — in portrait the rotated feed is 3:4
            let ratio: CGFloat = isLandscape ? (4.0 / 3.0) : (3.0 / 4.0)

            let fitW = availW
            let fitH = fitW / ratio
            let (viewW, viewH) = fitH <= availH
                ? (fitW, fitH)
                : (availH * ratio, availH)

            let _ = scannerPaneLog.info("[QRScannerPane] GeometryReader: geo=\(geo.size.width)x\(geo.size.height), computed frame=\(viewW)x\(viewH), isLandscape=\(isLandscape)")

            VStack(spacing: 16) {
                ZStack {
                    // Glass pane background — visible as border
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Camera is always rendered (starts capture session)
                    QRScannerView(pairing: pairing, onPaired: onPaired)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(4)
                        .opacity(cameraReady ? 1 : 0)

                    // Loading overlay — shown until camera is running
                    if !cameraReady {
                        let _ = scannerPaneLog.info("[QRScannerPane] showing 'Starting camera...' overlay (cameraReady=false)")
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.secondary)
                            Text("Starting camera...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: viewW, height: viewH)

                Text("Scan QR code from Mac menu bar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            print("[CONSOLE] QRScannerPane.onAppear, isSessionRunning=\(pairing.isSessionRunning)")
            scannerPaneLog.info("[QRScannerPane] onAppear: checking isSessionRunning=\(pairing.isSessionRunning)")
            if pairing.isSessionRunning {
                print("[CONSOLE] session already running! setting cameraReady=true")
                scannerPaneLog.info("[QRScannerPane] session already running, setting cameraReady=true immediately")
                cameraReady = true
            }
            pairing.onSessionStarted = {
                print("[CONSOLE] onSessionStarted callback fired! setting cameraReady=true")
                scannerPaneLog.info("[QRScannerPane] onSessionStarted callback fired, setting cameraReady=true")
                withAnimation(.easeIn(duration: 0.3)) {
                    cameraReady = true
                }
            }
        }
    }
}

// MARK: - QRScannerView

/// UIViewRepresentable wrapping AVCaptureVideoPreviewLayer for QR scanning.
struct QRScannerView: UIViewRepresentable {

    let pairing: QRPairing
    let onPaired: () -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        scannerViewLog.info("[QRScannerView] makeUIView called")
        let view = CameraPreviewView()
        view.backgroundColor = .black

        pairing.onPairingComplete = { [onPaired] in
            scannerViewLog.info("[QRScannerView] onPairingComplete callback fired")
            onPaired()
        }

        scannerViewLog.info("[QRScannerView] calling pairing.startScanning()")
        if let captureSession = pairing.startScanning() {
            scannerViewLog.info("[QRScannerView] captureSession obtained: \(String(describing: captureSession)), isRunning=\(captureSession.isRunning)")
            view.previewLayer.session = captureSession
            view.previewLayer.videoGravity = .resizeAspectFill
            scannerViewLog.info("[QRScannerView] previewLayer.session assigned, now calling beginRunning()")
            // Start AFTER preview layer assignment to avoid beginConfiguration race
            pairing.beginRunning()
        } else {
            scannerViewLog.error("[QRScannerView] pairing.startScanning() returned nil -- no capture session")
        }

        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        scannerViewLog.info("[QRScannerView] updateUIView called, previewLayer.session=\(String(describing: uiView.previewLayer.session)), connection=\(String(describing: uiView.previewLayer.connection))")
    }
}

/// UIView whose backing layer IS an AVCaptureVideoPreviewLayer.
/// The layer resizes automatically with the view — no manual frame updates needed.
/// Updates videoRotationAngle on orientation change via layoutSubviews.
class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        cameraPreviewLog.info("[CameraPreviewView] init(frame:) called, frame=\(frame.debugDescription)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cameraPreviewLog.info("[CameraPreviewView] init(coder:) called")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cameraPreviewLog.info("[CameraPreviewView] layoutSubviews called, bounds=\(self.bounds.debugDescription), window=\(String(describing: self.window))")

        guard let connection = previewLayer.connection else {
            cameraPreviewLog.warning("[CameraPreviewView] layoutSubviews: previewLayer.connection is nil, session=\(String(describing: self.previewLayer.session)), session.isRunning=\(self.previewLayer.session?.isRunning ?? false)")
            return
        }

        cameraPreviewLog.info("[CameraPreviewView] layoutSubviews: connection exists, isActive=\(connection.isActive), isEnabled=\(connection.isEnabled)")

        let angle: CGFloat
        if let scene = window?.windowScene {
            switch scene.interfaceOrientation {
            case .portrait:            angle = 90
            case .portraitUpsideDown:   angle = 270
            case .landscapeLeft:        angle = 180
            case .landscapeRight:       angle = 0
            @unknown default:           angle = 90
            }
            cameraPreviewLog.info("[CameraPreviewView] layoutSubviews: orientation=\(scene.interfaceOrientation.rawValue), computed angle=\(angle)")
        } else {
            angle = 90
            cameraPreviewLog.info("[CameraPreviewView] layoutSubviews: no windowScene, defaulting angle=90")
        }

        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            cameraPreviewLog.info("[CameraPreviewView] layoutSubviews: set videoRotationAngle=\(angle)")
        } else {
            cameraPreviewLog.warning("[CameraPreviewView] layoutSubviews: angle \(angle) NOT supported")
        }
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
