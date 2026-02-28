import SwiftUI
import SharedProtocol

/// 2-column grid of macOS shortcut buttons above the keyboard.
/// Liquid Glass (.ultraThinMaterial) applied to the panel chrome.
/// Grid scales for Phase 3 app-aware shortcuts without redesign.
struct HotkeyPanel: View {
    let onHotkey: (UInt16, ModifierFlags) -> Void
    let onDestructiveHotkey: (UInt16, ModifierFlags, String) -> Void  // Requires confirmation

    private struct Hotkey: Identifiable {
        let id = UUID()
        let label: String
        let symbolName: String?
        let virtualKey: UInt16
        let modifiers: ModifierFlags
        let isDestructive: Bool

        init(_ label: String, symbol: String? = nil, key: UInt16, mods: ModifierFlags = [], destructive: Bool = false) {
            self.label = label
            self.symbolName = symbol
            self.virtualKey = key
            self.modifiers = mods
            self.isDestructive = destructive
        }
    }

    private let hotkeys: [Hotkey] = [
        Hotkey("Copy",      symbol: "doc.on.doc",           key: VirtualKey.c, mods: .command),
        Hotkey("Paste",     symbol: "doc.on.clipboard",     key: VirtualKey.v, mods: .command),
        Hotkey("Cut",       symbol: "scissors",              key: VirtualKey.x, mods: .command),
        Hotkey("Undo",      symbol: "arrow.uturn.backward", key: VirtualKey.z, mods: .command),
        Hotkey("Redo",      symbol: "arrow.uturn.forward",  key: VirtualKey.y, mods: .command),
        Hotkey("Select All",                                 key: VirtualKey.a, mods: .command),
        Hotkey("Escape",    symbol: "escape",               key: VirtualKey.escape),
        Hotkey("Tab",       symbol: "arrow.right.to.line",  key: VirtualKey.tab),
        Hotkey("Del Word",                                   key: VirtualKey.delete, mods: .command),
        Hotkey("Del Line",                                   key: VirtualKey.forwardDelete, mods: .command),
        Hotkey("Screenshot", symbol: "camera",              key: VirtualKey.four, mods: [.command, .shift]),
        Hotkey("Quit",      symbol: "xmark.circle",         key: VirtualKey.q, mods: .command, destructive: true),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(hotkeys) { hotkey in
                    hotkeyButton(hotkey)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(height: 130)
        // Liquid Glass chrome — applied to panel, NOT to individual keys
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal, 4)
    }

    private func hotkeyButton(_ hotkey: Hotkey) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if hotkey.isDestructive {
                onDestructiveHotkey(hotkey.virtualKey, hotkey.modifiers, hotkey.label)
            } else {
                onHotkey(hotkey.virtualKey, hotkey.modifiers)
            }
        }) {
            HStack(spacing: 6) {
                if let symbol = hotkey.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                }
                Text(hotkey.label)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hotkey.isDestructive
                          ? Color.red.opacity(0.15)
                          : Color(UIColor.secondarySystemBackground).opacity(0.8))
            )
        }
        .buttonStyle(.plain)
    }
}
