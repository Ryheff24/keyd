import SwiftUI
import SharedProtocol

/// 2-column grid of macOS shortcut buttons above the keyboard.
/// Liquid Glass (.ultraThinMaterial) applied to the panel chrome.
/// Grid scales for Phase 3 app-aware shortcuts without redesign.
struct HotkeyPanel: View {
    let onHotkey: (UInt16, ModifierFlags) -> Void
    let onDestructiveHotkey: (UInt16, ModifierFlags, String) -> Void  // Requires confirmation

    private enum LabelStyle {
        case iconOnly
        case textOnly
        case iconAndText
    }

    private struct Hotkey: Identifiable {
        let id = UUID()
        let label: String
        let symbolName: String?
        let labelStyle: LabelStyle
        let virtualKey: UInt16
        let modifiers: ModifierFlags
        let isDestructive: Bool

        init(
            _ label: String,
            symbol: String? = nil,
            style: LabelStyle = .textOnly,
            key: UInt16,
            mods: ModifierFlags = [],
            destructive: Bool = false
        ) {
            self.label = label
            self.symbolName = symbol
            self.labelStyle = style
            self.virtualKey = key
            self.modifiers = mods
            self.isDestructive = destructive
        }
    }

    private let hotkeys: [Hotkey] = [
        Hotkey("Copy",       symbol: "doc.on.doc",            style: .iconOnly,    key: VirtualKey.c, mods: .command),
        Hotkey("Paste",      symbol: "doc.on.clipboard",      style: .iconOnly,    key: VirtualKey.v, mods: .command),
        Hotkey("Cut",        symbol: "scissors",              style: .iconOnly,    key: VirtualKey.x, mods: .command),
        Hotkey("Undo",       symbol: "arrow.uturn.backward",  style: .iconOnly,    key: VirtualKey.z, mods: .command),
        Hotkey("Redo",       symbol: "arrow.uturn.forward",   style: .iconAndText, key: VirtualKey.y, mods: .command),
        Hotkey("Select All",                                                key: VirtualKey.a, mods: .command),
        Hotkey("Escape",     symbol: "escape",                style: .iconAndText, key: VirtualKey.escape),
        Hotkey("Tab",        symbol: "arrow.right.to.line",   style: .iconAndText, key: VirtualKey.tab),
        Hotkey("Delete Word",                                              key: VirtualKey.delete, mods: .command),
        Hotkey("Delete Line",                                              key: VirtualKey.forwardDelete, mods: .command),
        Hotkey("Screenshot",                                              key: VirtualKey.four, mods: [.command, .shift]),
        Hotkey("Quit",                                                   key: VirtualKey.q, mods: .command, destructive: true),
    ]

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let verticalPadding: CGFloat = 16
            let buttonHeight = max(48, (proxy.size.height - (verticalPadding * 2) - (spacing * 5)) / 6)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: spacing),
                    GridItem(.flexible(), spacing: spacing)
                ],
                spacing: spacing
            ) {
                ForEach(hotkeys) { hotkey in
                    hotkeyButton(hotkey, height: buttonHeight)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Liquid Glass chrome — applied to panel, NOT to individual keys
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 4)
    }

    private func hotkeyButton(_ hotkey: Hotkey, height: CGFloat) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if hotkey.isDestructive {
                onDestructiveHotkey(hotkey.virtualKey, hotkey.modifiers, hotkey.label)
            } else {
                onHotkey(hotkey.virtualKey, hotkey.modifiers)
            }
        }) {
            buttonLabel(for: hotkey)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hotkey.isDestructive
                          ? Color.red.opacity(0.18)
                          : Color(UIColor.secondarySystemBackground).opacity(0.92))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hotkey.label)
    }

    @ViewBuilder
    private func buttonLabel(for hotkey: Hotkey) -> some View {
        switch hotkey.labelStyle {
        case .iconOnly:
            Image(systemName: hotkey.symbolName ?? "circle")
                .font(.system(size: 21, weight: .semibold))
                .frame(maxWidth: .infinity)

        case .textOnly:
            Text(hotkey.label)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .iconAndText:
            HStack(spacing: 8) {
                if let symbol = hotkey.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(hotkey.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}
