import SwiftUI

/// Shake-to-reveal debug overlay. Available in all builds.
/// Shows: connection event log, current transport state, retry count, last error.
struct DebugOverlayView: View {
    @EnvironmentObject var transportManager: TransportManager
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Current State") {
                    HStack {
                        Text("Transport")
                        Spacer()
                        Text(stateLabel)
                            .foregroundColor(stateColor)
                            .fontWeight(.semibold)
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
