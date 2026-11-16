import UIKit

/// The Metal host view that also captures input and sends it to the Mac (InputSender).
///
/// Mapping:
///  - Trackpad / mouse (indirect pointer): hover moves the Mac cursor, clicks are clicks
///    (secondary = right), drags are drags, two-finger trackpad scroll and mouse wheel scroll.
///    The iPad pointer is hidden over the video; the Mac cursor in the stream is the cursor.
///  - Finger (direct touch): the cursor jumps to the finger; tap = click; drag past a small slop
///    = left drag; two fingers = scroll (content follows fingers); two-finger tap = right click;
///    three-finger tap = show/hide the on-screen keyboard.
///  - Hardware keyboard: every key by HID usage (pressesBegan/Ended), modifiers included.
///  - On-screen keyboard: typed text goes as text; delete and return as keys.
final class InputCaptureView: MetalHostView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {

    var input: InputSender?

    // Finger state machine.
    private enum TouchMode { case idle, pending, dragging, twoFinger, threeFinger, ignoring }
    private var mode: TouchMode = .idle
    private var startPoint: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var lastCentroid: CGPoint = .zero
    private var twoFingerMoved = false
    private var maxFingers = 0
    private static let dragSlop: CGFloat = 6
    private static let tapMaxDuration: TimeInterval = 0.35

    // Indirect pointer (trackpad/mouse) buttons currently down via touches.
    private var pointerTouchButtons: [ObjectIdentifier: UInt8] = [:]

    private let keyboardProxy = SoftKeyboardProxy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpInput()
    }

    private func setUpInput() {
        isMultipleTouchEnabled = true
        addInteraction(UIPointerInteraction(delegate: self))

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // Trackpad two-finger scroll and mouse wheel only (no touches).
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.delegate = self
        addGestureRecognizer(scroll)

        keyboardProxy.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboardProxy.alpha = 0.01
        keyboardProxy.onText = { [weak self] text, ts in self?.input?.text(text, ts: ts) }
        keyboardProxy.onKey = { [weak self] usage, ts in
            self?.input?.key(usage, down: true, ts: ts)
            self?.input?.key(usage, down: false, ts: ts)
        }
        addSubview(keyboardProxy)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let ok = becomeFirstResponder()
            print("[CONSOLE] InputCaptureView in window: firstResponder=\(ok)")
        }
    }

    private func norm(_ p: CGPoint) -> (UInt16, UInt16) {
        input?.normalized(p, in: bounds) ?? (0, 0)
    }

    // MARK: - Pointer (trackpad / mouse)

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let (x, y) = norm(g.location(in: self))
        input?.pointerMove(x, y, ts: ProcessInfo.processInfo.systemUptime)
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let phase: UInt8
        switch g.state {
        case .began: phase = InputSender.phaseBegan
        case .changed: phase = InputSender.phaseChanged
        case .ended: phase = InputSender.phaseEnded
        case .cancelled, .failed: phase = InputSender.phaseCancelled
        default: return
        }
        let (x, y) = norm(g.location(in: self))
        input?.scroll(dx: t.x, dy: t.y, phase: phase, x, y, ts: ProcessInfo.processInfo.systemUptime)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func buttonFor(_ event: UIEvent?) -> UInt8 {
        guard let mask = event?.buttonMask else { return InputSender.buttonLeft }
        if mask.contains(.secondary) { return InputSender.buttonRight }
        if mask.contains(.button(3)) { return InputSender.buttonOther }
        return InputSender.buttonLeft
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer {
            let b = buttonFor(event)
            pointerTouchButtons[ObjectIdentifier(t)] = b
            let (x, y) = norm(t.location(in: self))
            input?.button(b, down: true, x, y, ts: t.timestamp)
        }
        let direct = touches.filter { $0.type == .direct }
        guard !direct.isEmpty else { return }
        let all = (event?.allTouches ?? touches).filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }
        maxFingers = max(maxFingers, all.count)
        switch mode {
        case .idle:
            guard let t = direct.first else { return }
            if all.count == 1 {
                mode = .pending
                startPoint = t.location(in: self)
                startTime = t.timestamp
                let (x, y) = norm(startPoint)
                input?.pointerMove(x, y, ts: t.timestamp)   // cursor jumps to the finger at once
            } else {
                enterMulti(all)
            }
        case .pending:
            enterMulti(all)
        case .twoFinger where all.count >= 3:
            mode = .threeFinger
        default:
            break
        }
    }

    private func enterMulti(_ all: Set<UITouch>) {
        if all.count >= 3 { mode = .threeFinger; return }
        mode = .twoFinger
        twoFingerMoved = false
        lastCentroid = centroid(all)
    }

    private func centroid(_ ts: Set<UITouch>) -> CGPoint {
        guard !ts.isEmpty else { return .zero }
        let pts = ts.map { $0.location(in: self) }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                       y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer {
            let (x, y) = norm(t.location(in: self))
            input?.pointerMove(x, y, ts: t.timestamp)
        }
        guard let t = touches.first(where: { $0.type == .direct }) else { return }
        switch mode {
        case .pending:
            let p = t.location(in: self)
            if hypot(p.x - startPoint.x, p.y - startPoint.y) > Self.dragSlop {
                mode = .dragging
                let (sx, sy) = norm(startPoint)
                input?.button(InputSender.buttonLeft, down: true, sx, sy, ts: t.timestamp)
                let (x, y) = norm(p)
                input?.pointerMove(x, y, ts: t.timestamp)
            }
        case .dragging:
            let (x, y) = norm(t.location(in: self))
            input?.pointerMove(x, y, ts: t.timestamp)
        case .twoFinger:
            let all = (event?.allTouches ?? touches).filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }
            guard all.count == 2 else { return }
            let c = centroid(all)
            let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
            lastCentroid = c
            if dx == 0 && dy == 0 { return }
            let phase = twoFingerMoved ? InputSender.phaseChanged : InputSender.phaseBegan
            twoFingerMoved = true
            let (x, y) = norm(c)
            input?.scroll(dx: dx, dy: dy, phase: phase, x, y, ts: t.timestamp)
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer {
            let b = pointerTouchButtons.removeValue(forKey: ObjectIdentifier(t)) ?? InputSender.buttonLeft
            let (x, y) = norm(t.location(in: self))
            input?.button(b, down: false, x, y, ts: t.timestamp)
        }
        guard let t = touches.first(where: { $0.type == .direct }) else { return }
        let remaining = (event?.allTouches ?? []).filter {
            $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
        }
        switch mode {
        case .pending:
            // Tap: click where the finger was.
            let (x, y) = norm(startPoint)
            input?.button(InputSender.buttonLeft, down: true, x, y, ts: t.timestamp)
            input?.button(InputSender.buttonLeft, down: false, x, y, ts: t.timestamp)
        case .dragging:
            let (x, y) = norm(t.location(in: self))
            input?.button(InputSender.buttonLeft, down: false, x, y, ts: t.timestamp)
        case .twoFinger:
            if remaining.isEmpty {
                if twoFingerMoved {
                    let (x, y) = norm(lastCentroid)
                    input?.scroll(dx: 0, dy: 0, phase: InputSender.phaseEnded, x, y, ts: t.timestamp)
                } else if t.timestamp - startTime <= Self.tapMaxDuration || startTime == 0 {
                    let (x, y) = norm(lastCentroid)
                    input?.button(InputSender.buttonRight, down: true, x, y, ts: t.timestamp)
                    input?.button(InputSender.buttonRight, down: false, x, y, ts: t.timestamp)
                }
            }
        case .threeFinger:
            if remaining.isEmpty { toggleSoftKeyboard() }
        default:
            break
        }
        if remaining.isEmpty { resetTouchMode() }
        else if mode == .pending || mode == .dragging { mode = .ignoring }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The system took the touches (gesture, notification, app switch): no ups will come.
        for t in touches where t.type == .indirectPointer {
            pointerTouchButtons.removeValue(forKey: ObjectIdentifier(t))
        }
        if mode == .twoFinger && twoFingerMoved {
            let (x, y) = norm(lastCentroid)
            input?.scroll(dx: 0, dy: 0, phase: InputSender.phaseCancelled, x, y,
                          ts: ProcessInfo.processInfo.systemUptime)
        }
        input?.cancelAll(reason: "touches-cancelled")
        resetTouchMode()
    }

    private func resetTouchMode() {
        mode = .idle
        maxFingers = 0
        twoFingerMoved = false
        startTime = 0
    }

    private func toggleSoftKeyboard() {
        if keyboardProxy.isFirstResponder {
            _ = becomeFirstResponder()
        } else {
            _ = keyboardProxy.becomeFirstResponder()
        }
        print("[CONSOLE] soft keyboard \(keyboardProxy.isFirstResponder ? "shown" : "hidden")")
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            if let k = p.key { input?.key(UInt16(k.keyCode.rawValue), down: true, ts: p.timestamp) }
            else { unhandled.insert(p) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            if let k = p.key { input?.key(UInt16(k.keyCode.rawValue), down: false, ts: p.timestamp) }
            else { unhandled.insert(p) }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // The key-up will not arrive; release these keys on the Mac now.
        for p in presses {
            if let k = p.key { input?.key(UInt16(k.keyCode.rawValue), down: false, ts: p.timestamp) }
        }
    }
}

/// Invisible responder that brings up the on-screen keyboard (three-finger tap).
final class SoftKeyboardProxy: UIView, UIKeyInput {
    var onText: ((String, TimeInterval) -> Void)?
    var onKey: ((UInt16, TimeInterval) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        let ts = ProcessInfo.processInfo.systemUptime
        if text == "\n" { onKey?(0x28, ts); return }   // Return
        onText?(text, ts)
    }

    func deleteBackward() {
        onKey?(0x2A, ProcessInfo.processInfo.systemUptime)   // Delete (backspace)
    }
}
