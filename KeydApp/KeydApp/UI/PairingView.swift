import SwiftUI
import AVFoundation

/// QR code scanner view shown on first launch (before keyboard is active).
/// Uses AVFoundation camera to scan the QR code displayed by the macOS agent.
struct PairingView: View {
    @ObservedObject var pairingManager: PairingManager
    @EnvironmentObject var transportManager: TransportManager
    @State private var scannerSessionID = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Pair with Mac")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Open KeydAgent on your Mac and scan the QR code shown there.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal)

                ConnectionStatusBadge(state: transportManager.connectionState)

                Text(connectionHint)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal)

                // Camera scanner view
                QRScannerRepresentable { qrString in
                    Task { @MainActor in
                        await pairingManager.completeQRPairing(
                            qrString: qrString,
                            transportManager: transportManager
                        )
                    }
                }
                .id(scannerSessionID)
                .frame(width: 260, height: 260)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                )

                if !recentEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transport Log")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.85))

                        ForEach(recentEvents, id: \.self) { event in
                            Text(event)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.ultraThinMaterial.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if pairingManager.isPairing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Pairing...")
                            .foregroundColor(.white)
                    }
                }

                if let error = pairingManager.pairingError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button("Scan Again") {
                            resetScanner()
                        }

                        Button("Retry Connection") {
                            transportManager.reconnect()
                            resetScanner()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        // Liquid Glass overlay on the scanner box
        .background(.ultraThinMaterial.opacity(0.3))
    }

    private var connectionHint: String {
        switch transportManager.connectionState {
        case .usbConnected:
            return "USB is ready. Scan the QR code shown by KeydAgent."
        case .awdlConnected:
            return "AWDL is active, but first-time pairing should be done over USB."
        case .connecting:
            return transportManager.allowsAWDL
                ? "Preparing the Mac connection."
                : "Checking for the USB connection. Keep the iPhone plugged into your Mac while pairing."
        case .disconnected:
            return transportManager.allowsAWDL
                ? "Keep KeydAgent open and the devices nearby."
                : "First-time pairing uses USB. Connect the iPhone to your Mac, keep KeydAgent open, then scan the QR code."
        }
    }

    private var recentEvents: [String] {
        Array(transportManager.getEventLog().suffix(4))
    }

    private func resetScanner() {
        pairingManager.pairingError = nil
        scannerSessionID = UUID()
    }
}

/// UIViewRepresentable wrapper for AVFoundation QR code scanner.
struct QRScannerRepresentable: UIViewRepresentable {
    let onQRCode: (String) -> Void

    func makeUIView(context: Context) -> QRScannerView {
        let view = QRScannerView()
        view.onQRCode = onQRCode
        return view
    }

    func updateUIView(_ uiView: QRScannerView, context: Context) {}
}

/// UIView that uses AVCaptureSession to scan QR codes.
final class QRScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onQRCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        self.previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else { return }
        hasScanned = true
        session.stopRunning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onQRCode?(str)
    }
}
