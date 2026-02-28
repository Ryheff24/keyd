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
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onBackspace: onBackspace, onReturn: onReturn)
    }

    func makeUIView(context: Context) -> KeyboardInputContainer {
        let view = KeyboardInputContainer()
        view.configure(with: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: KeyboardInputContainer, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onBackspace = onBackspace
        context.coordinator.onReturn = onReturn
        uiView.configure(with: context.coordinator)
        uiView.activateKeyboard()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onBackspace: () -> Void
        var onReturn: () -> Void

        init(
            onText: @escaping (String) -> Void,
            onBackspace: @escaping () -> Void,
            onReturn: @escaping () -> Void
        ) {
            self.onText = onText
            self.onBackspace = onBackspace
            self.onReturn = onReturn
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            guard !string.isEmpty else { return false }

            if string == "\n" {
                onReturn()
            } else {
                onText(string)
            }

            textField.text = ""
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
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.keyboardType = .default
        textField.returnKeyType = .default
        textField.enablesReturnKeyAutomatically = false
        textField.text = ""

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
    }

    func activateKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.textField.becomeFirstResponder()
        }
    }
}

private final class InterceptingTextField: UITextField {
    var onBackspace: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func deleteBackward() {
        onBackspace?()
    }
}
