import SwiftUI
import SharedProtocol

/// Full-width SwiftUI keyboard mimicking native iOS keyboard appearance.
/// Renders character keys, space bar, and control keys (Backspace, Return).
/// Uses a regular in-app SwiftUI view, not a keyboard extension controller.
struct KeyboardView: View {
    let onKeyTap: (UInt32) -> Void           // Unicode scalar
    let onVirtualKeyTap: (UInt16) -> Void    // Virtual key code (VirtualKey constants)
    let onBackspaceStart: () -> Void
    let onBackspaceEnd: () -> Void

    @State private var pressedKey: String? = nil
    @State private var isShifted = false
    @State private var isCapsLocked = false

    // Standard QWERTY layout rows
    private let rows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"]
    ]

    var body: some View {
        VStack(spacing: 8) {
            // Row 1
            keyRow(rows[0])
            // Row 2 (indented)
            keyRow(rows[1], indent: true)
            // Row 3 (with shift + backspace)
            HStack(spacing: 6) {
                shiftKey
                keyRow(rows[2], spacing: 6)
                backspaceKey
            }
            .padding(.horizontal, 4)
            // Bottom row: 123 | space | return
            HStack(spacing: 6) {
                numberModeKey
                spaceKey
                returnKey
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground).opacity(0.001)) // Transparent for Glass layer above
    }

    // MARK: - Key rows

    private func keyRow(_ keys: [String], indent: Bool = false, spacing: CGFloat = 6) -> some View {
        HStack(spacing: spacing) {
            if indent { Spacer().frame(width: 20) }
            ForEach(keys, id: \.self) { key in
                characterKey(key)
            }
            if indent { Spacer().frame(width: 20) }
        }
        .padding(.horizontal, 3)
    }

    private func characterKey(_ key: String) -> some View {
        let displayChar = (isShifted || isCapsLocked) ? key.uppercased() : key
        return Button(action: {
            let scalar = (displayChar.unicodeScalars.first?.value) ?? 0
            onKeyTap(scalar)
            // Auto-unshift after one key (unless caps lock)
            if isShifted && !isCapsLocked { isShifted = false }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Text(displayChar)
                .font(.system(size: 17, weight: .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Special keys

    private var shiftKey: some View {
        Button(action: {
            if isCapsLocked { isCapsLocked = false; isShifted = false }
            else if isShifted { isCapsLocked = true }
            else { isShifted = true }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Image(systemName: isCapsLocked ? "capslock.fill" : (isShifted ? "shift.fill" : "shift"))
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(UIColor.systemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var backspaceKey: some View {
        // CONTEXT.md locked decision: tap -> single char delete; hold 0.5s -> word delete (Cmd-Backspace)
        // Phase 1 implements both: single char on tap, word delete (HotkeyEvent with .command modifier) on long press
        Button(action: {
            onVirtualKeyTap(VirtualKey.delete)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Image(systemName: "delete.left")
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(UIColor.systemBackground)))
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.5, perform: {
            // After holding 0.5s: switch to word delete via Cmd-Backspace (Option-Delete on macOS)
            // HotkeyEvent with .command modifier sends Cmd-Backspace = delete word to left of cursor
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onBackspaceStart()  // Signal continuous word-delete mode begins
        })
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in onBackspaceEnd() }
        )
    }

    private var spaceKey: some View {
        Button(action: {
            onKeyTap(32)  // Space
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Text("space")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(UIColor.systemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var returnKey: some View {
        Button(action: {
            onVirtualKeyTap(VirtualKey.returnKey)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Text("return")
                .font(.system(size: 15))
                .frame(width: 88, height: 42)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(UIColor.systemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var numberModeKey: some View {
        // Phase 1: placeholder for number/symbol mode toggle
        Button(action: {}) {
            Text("123")
                .font(.system(size: 15))
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(UIColor.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}
