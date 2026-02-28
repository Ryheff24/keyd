import SwiftUI
import SharedProtocol

/// Root view: connection status badge at top, hotkey panel, then keyboard at bottom.
/// Full-screen keyboard layout, portrait only.
struct RootView: View {
    @EnvironmentObject var transportManager: TransportManager
    @EnvironmentObject var pairingManager: PairingManager
    @State private var isSecureInputActive = false
    @State private var showQuitConfirmation = false
    @State private var pendingDestructiveHotkey: (UInt16, ModifierFlags)? = nil
    @State private var showDebug = false

    var body: some View {
        ZStack {
            // Dark background to make Liquid Glass panels pop
            Color(UIColor.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Status indicator at top (fallback for non-Dynamic Island devices)
                HStack {
                    Spacer()
                    Button {
                        showDebug = true
                    } label: {
                        ConnectionStatusBadge(state: transportManager.connectionState)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 8)

                if !transportManager.isConnected {
                    recoveryControls
                        .padding(.top, 12)
                }

                // Secure input overlay
                if isSecureInputActive {
                    secureInputOverlay
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    keyboardStack
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .opacity(transportManager.isConnected ? 1 : 0.68)
                        .allowsHitTesting(transportManager.isConnected)
                }
            }
            .padding(.bottom, 8)
        }
        .alert("Send Quit Command?", isPresented: $showQuitConfirmation) {
            Button("Send Cmd-Q", role: .destructive) {
                if let (key, mods) = pendingDestructiveHotkey {
                    sendHotkey(virtualKey: key, modifiers: mods)
                }
                pendingDestructiveHotkey = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveHotkey = nil
            }
        } message: {
            Text("This will quit the frontmost macOS app.")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            transportManager.onSecureInputChanged = { active in
                isSecureInputActive = active
            }
        }
        .sheet(isPresented: $showDebug) {
            DebugOverlayView(
                isPresented: $showDebug,
                onResetPairing: resetPairing
            )
                .environmentObject(transportManager)
        }
    }

    private var keyboardStack: some View {
        VStack(spacing: 12) {
            // Hotkey panel above keyboard (UX-03)
            HotkeyPanel(
                onHotkey: { key, mods in sendHotkey(virtualKey: key, modifiers: mods) },
                onDestructiveHotkey: { key, mods, label in
                    pendingDestructiveHotkey = (key, mods)
                    showQuitConfirmation = true
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Main keyboard (UX-03)
            KeyboardView(
                onKeyTap: { scalar in
                    transportManager.send(.keyEvent(KeyEvent(unicodeScalar: scalar, keyDown: true)))
                    transportManager.send(.keyEvent(KeyEvent(unicodeScalar: scalar, keyDown: false)))
                },
                onVirtualKeyTap: { keyCode in
                    transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: keyCode, keyDown: true)))
                    transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: keyCode, keyDown: false)))
                },
                onBackspaceStart: {
                    // Sustained backspace hold ramped into word-delete repeat: send Option-Backspace
                    sendHotkey(virtualKey: VirtualKey.delete, modifiers: .option)
                },
                onBackspaceEnd: {
                    // No-op: word-delete repeats are driven directly from backspace repeat events.
                }
            )
        }
        .padding(.top, 12)
    }

    private var recoveryControls: some View {
        Button("Retry") {
            transportManager.reconnect()
        }
        .buttonStyle(.borderedProminent)
    }

    private var secureInputOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Password Field Active")
                .font(.headline)
            Text("Keyboard input paused while a password field is focused on your Mac.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding()
    }

    private func sendHotkey(virtualKey: UInt16, modifiers: ModifierFlags) {
        transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: virtualKey, keyDown: true, modifiers: modifiers)))
        if modifiers.isEmpty {
            transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: virtualKey, keyDown: false, modifiers: modifiers)))
        }
    }

    private func resetPairing() {
        Task {
            await transportManager.invalidateRemotePairing()
            await transportManager.resetConnections()
            await pairingManager.resetPairing()
        }
    }
}
