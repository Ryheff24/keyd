import SwiftUI
import UIKit
import SharedProtocol

/// Keeps the stock iOS keyboard active and forwards its input to the Mac.
/// The visible keyboard is provided by UIKit; this view only hosts a hidden
/// first responder so we can intercept key events without drawing custom keys.
struct KeyboardView: View {
    let onKeyTap: (UInt32) -> Void
    let onVirtualKeyTap: (UInt16) -> Void
    let onBackspaceStart: () -> Void
    let onBackspaceEnd: () -> Void

    var body: some View {
        SystemKeyboardHost(
            onText: { text in
                for scalar in text.unicodeScalars {
                    onKeyTap(scalar.value)
                }
            },
            onBackspace: {
                onVirtualKeyTap(VirtualKey.delete)
            },
            onBackspaceStart: onBackspaceStart,
            onBackspaceEnd: onBackspaceEnd,
            onReturn: {
                onVirtualKeyTap(VirtualKey.returnKey)
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 1)
    }
}

private struct SystemKeyboardHost: UIViewRepresentable {
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onBackspaceStart: () -> Void
    let onBackspaceEnd: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onText: onText,
            onBackspace: onBackspace,
            onBackspaceStart: onBackspaceStart,
            onBackspaceEnd: onBackspaceEnd,
            onReturn: onReturn
        )
    }

    func makeUIView(context: Context) -> KeyboardInputContainer {
        let view = KeyboardInputContainer()
        view.configure(with: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: KeyboardInputContainer, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onBackspace = onBackspace
        context.coordinator.onBackspaceStart = onBackspaceStart
        context.coordinator.onBackspaceEnd = onBackspaceEnd
        context.coordinator.onReturn = onReturn
        uiView.configure(with: context.coordinator)
        uiView.activateKeyboard()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onBackspace: () -> Void
        var onBackspaceStart: () -> Void
        var onBackspaceEnd: () -> Void
        var onReturn: () -> Void

        init(
            onText: @escaping (String) -> Void,
            onBackspace: @escaping () -> Void,
            onBackspaceStart: @escaping () -> Void,
            onBackspaceEnd: @escaping () -> Void,
            onReturn: @escaping () -> Void
        ) {
            self.onText = onText
            self.onBackspace = onBackspace
            self.onBackspaceStart = onBackspaceStart
            self.onBackspaceEnd = onBackspaceEnd
            self.onReturn = onReturn
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                return true
            }

            if string == "\n" {
                onReturn()
            } else {
                onText(string)
            }

            (textField as? InterceptingTextField)?.restoreBackingText()
            return false
        }
    }
}

private final class KeyboardInputContainer: UIView {
    private let textField = InterceptingTextField(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        alpha = 0.015

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.textContentType = .none
        textField.keyboardType = .default
        textField.returnKeyType = .default
        textField.enablesReturnKeyAutomatically = false
        if #available(iOS 17.0, *) {
            textField.inlinePredictionType = .no
        }
        textField.restoreBackingText()

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 1)
    }

    func configure(with coordinator: SystemKeyboardHost.Coordinator) {
        textField.delegate = coordinator
        textField.onBackspace = coordinator.onBackspace
        textField.onBackspaceStart = coordinator.onBackspaceStart
        textField.onBackspaceEnd = coordinator.onBackspaceEnd
        textField.restoreBackingText()
    }

    func activateKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.textField.restoreBackingText()
            self.textField.becomeFirstResponder()
        }
    }
}

private final class InterceptingTextField: UITextField {
    private static let backingText = "\u{200B}"
    private static let wordDeleteDelay: TimeInterval = 0.5
    private static let holdRecognitionFloor: TimeInterval = 0.28
    private static let holdContinuationTimeout: TimeInterval = 0.8

    var onBackspace: (() -> Void)?
    var onBackspaceStart: (() -> Void)?
    var onBackspaceEnd: (() -> Void)?

    private var backspaceBurstStartedAt: TimeInterval?
    private var lastBackspaceEventAt: TimeInterval?
    private var isHoldSequence = false
    private var didTriggerWordDelete = false
    private var releaseWorkItem: DispatchWorkItem?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.restoreBackingText()
            self?.becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func deleteBackward() {
        super.deleteBackward()

        let now = ProcessInfo.processInfo.systemUptime
        guard let lastBackspaceEventAt else {
            beginBackspaceBurst(at: now)
            onBackspace?()
            self.lastBackspaceEventAt = now
            scheduleBackspaceRelease()
            restoreBackingText()
            return
        }

        let gap = now - lastBackspaceEventAt
        guard gap <= Self.holdContinuationTimeout else {
            beginBackspaceBurst(at: now)
            onBackspace?()
            self.lastBackspaceEventAt = now
            scheduleBackspaceRelease()
            restoreBackingText()
            return
        }

        if !isHoldSequence {
            if gap >= Self.holdRecognitionFloor {
                isHoldSequence = true
            } else {
                beginBackspaceBurst(at: now)
                onBackspace?()
                self.lastBackspaceEventAt = now
                scheduleBackspaceRelease()
                restoreBackingText()
                return
            }
        }

        if !didTriggerWordDelete, let backspaceBurstStartedAt,
           now - backspaceBurstStartedAt >= Self.wordDeleteDelay {
            didTriggerWordDelete = true
            onBackspaceStart?()
        }

        self.lastBackspaceEventAt = now
        scheduleBackspaceRelease()
        restoreBackingText()
    }

    private func beginBackspaceBurst(at now: TimeInterval) {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        backspaceBurstStartedAt = now
        lastBackspaceEventAt = nil
        isHoldSequence = false
        didTriggerWordDelete = false
    }

    private func scheduleBackspaceRelease() {
        releaseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishBackspaceBurst()
        }
        releaseWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.holdContinuationTimeout,
            execute: workItem
        )
    }

    private func finishBackspaceBurst() {
        if didTriggerWordDelete {
            onBackspaceEnd?()
        }

        backspaceBurstStartedAt = nil
        lastBackspaceEventAt = nil
        isHoldSequence = false
        didTriggerWordDelete = false
        releaseWorkItem = nil
    }

    func restoreBackingText() {
        if text != Self.backingText {
            text = Self.backingText
        }

        let end = endOfDocument
        selectedTextRange = textRange(from: end, to: end)
    }
}
