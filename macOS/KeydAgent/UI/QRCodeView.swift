import SwiftUI
import CoreImage.CIFilterBuiltins

/// Displays a QR code for iOS pairing scan.
/// Shown as an NSWindow on macOS agent on first launch or when pairing needed.
struct QRCodeWindowView: View {
    let pairingManager: PairingManager
    @State private var qrImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text("Pair your iPhone")
                .font(.title2)
                .fontWeight(.semibold)

            if let img = qrImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 240, height: 240)
            } else {
                ProgressView("Generating QR code...")
            }

            Text("Scan this QR code from the KeydApp on your iPhone to pair.\nThis only needs to be done once.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 280)
        }
        .padding(32)
        .frame(width: 360, height: 380)
        .onAppear { generateQR() }
    }

    private func generateQR() {
        let payload = pairingManager.generatePairingQRPayload()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        if let output = filter.outputImage {
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            let rep = NSCIImageRep(ciImage: scaled)
            let img = NSImage(size: rep.size)
            img.addRepresentation(rep)
            qrImage = img
        }
    }
}
