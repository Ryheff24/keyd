import SwiftUI
import SharedProtocol

/// Root view: connection status badge at top, hotkey panel, then keyboard at bottom.
/// Full-screen keyboard layout, portrait only.
struct RootView: View {
    @EnvironmentObject var transportManager: TransportManager
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
                    ConnectionStatusBadge(state: transportManager.connectionState)
                    Spacer()
                }
                .padding(.top, 8)

                Spacer()

                // Secure input overlay
                if isSecureInputActive {
                    secureInputOverlay
                } else {
                    keyboardStack
                }
            }
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(transportManager.$connectionState) { state in
            // Update idle timer when connection state changes
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
            DebugOverlayView(isPresented: $showDebug)
                .environmentObject(transportManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showDebug = true
        }
    }

    private var keyboardStack: some View {
        VStack(spacing: 4) {
            // Hotkey panel above keyboard (UX-03)
            HotkeyPanel(
                onHotkey: { key, mods in sendHotkey(virtualKey: key, modifiers: mods) },
                onDestructiveHotkey: { key, mods, label in
                    pendingDestructiveHotkey = (key, mods)
                    showQuitConfirmation = true
                }
            )

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
                    // Long-press (0.5s) entered word-delete mode: send Cmd-Backspace
                    transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: VirtualKey.delete, keyDown: true, modifiers: .command)))
                    transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: VirtualKey.delete, keyDown: false, modifiers: .command)))
                },
                onBackspaceEnd: {
                    // No-op: word-delete is sent as a single atomic event in onBackspaceStart
                    // (unlike char-delete which is continuous -- word-delete fires once per hold trigger)
                }
            )
        }
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
        // Send key-down with modifiers; the macOS side uses defer for key-up
        transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: virtualKey, keyDown: true, modifiers: modifiers)))
        transportManager.send(.hotkeyEvent(HotkeyEvent(virtualKeyCode: virtualKey, keyDown: false, modifiers: modifiers)))
    }
}
