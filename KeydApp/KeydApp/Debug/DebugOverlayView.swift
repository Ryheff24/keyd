import SwiftUI

/// Debug overlay opened from the top status badge. Available in all builds.
/// Shows: connection event log, current transport state, retry count, last error.
struct DebugOverlayView: View {
    @EnvironmentObject var transportManager: TransportManager
    @Binding var isPresented: Bool
    let onResetPairing: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Button("Reconnect") {
                        transportManager.reconnect()
                        isPresented = false
                    }

                    Button("Reset Pairing", role: .destructive) {
                        isPresented = false
                        onResetPairing()
                    }
                }

                Section("Current State") {
                    HStack {
                        Text("Transport")
                        Spacer()
                        Text(stateLabel)
                            .foregroundColor(stateColor)
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Text("AWDL Standby")
                        Spacer()
                        Text(transportManager.allowsAWDL ? "Enabled" : "Disabled")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Connection Event Log") {
                    let log = transportManager.getEventLog()
                    if log.isEmpty {
                        Text("No events yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(log.reversed(), id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private var stateLabel: String {
        switch transportManager.connectionState {
        case .usbConnected:   return "USB Connected"
        case .awdlConnected:  return "AWDL Connected"
        case .connecting:     return "Connecting..."
        case .disconnected:   return "Disconnected"
        }
    }

    private var stateColor: Color {
        switch transportManager.connectionState {
        case .usbConnected:   return .green
        case .awdlConnected:  return .yellow
        case .connecting:     return .orange
        case .disconnected:   return .red
        }
    }
}
