import SwiftUI

/// Connection status overlay for devices without Dynamic Island.
/// ActivityKit Live Activity handles Dynamic Island on supported devices.
/// This view is the fallback — always visible in the app chrome.
struct ConnectionStatusBadge: View {
    let state: TransportManager.State

    private var color: Color {
        switch state {
        case .usbConnected:   return .green
        case .awdlConnected:  return .yellow
        case .connecting:     return .orange
        case .disconnected:   return .red
        }
    }

    private var label: String {
        switch state {
        case .usbConnected:   return "USB"
        case .awdlConnected:  return "AWDL"
        case .connecting:     return "Connecting..."
        case .disconnected:   return "Disconnected"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}
