import Foundation
import UIKit

/// iPad side of pointer and keyboard input (tla/InputPath.tla design, wire format in
/// Shared/protocol.h). Main thread only.
///
/// - Every message carries <<session, seq>>: session is random per app launch, seq counts up.
/// - Held keys/buttons are tracked here. HELD (release-only on the Mac) goes first on every new
///   connection (`connectionEstablished`) and whenever the link used for input changes.
/// - Losing held state without key-ups (resign active, cancelled touches) sends HELD = {}.
/// - While anything is held a keepalive goes out every KEYDRD_INPUT_HEARTBEAT_MS, so the Mac's
///   silence deadline only fires when every link is dead.
/// - Events are sent immediately, one per message (no batching): latency first.
final class InputSender {

    enum Link: String { case usb, wifi }

    /// Sends one framed message on the current input link; returns that link, or nil if no link.
    var send: ((Data) -> Link?)?

    /// Mac display size from the session handshake (for the aspect-fit video rect).
    var macDisplaySize: CGSize = .zero

    let session: UInt64 = UInt64.random(in: 1...UInt64.max)
    private var seq: UInt64 = 0
    private(set) var heldKeys = Set<UInt16>()
    private(set) var buttons: UInt8 = 0
    private var lastLink: Link?
    private var heartbeat: DispatchSourceTimer?
    private(set) var sentCount: UInt64 = 0
    private var resignObserver: NSObjectProtocol?

    // Mirrors of Shared/protocol.h (kept as literals: the macros use shifts and suffixes).
    static let buttonLeft: UInt8 = 1 << 0      // KEYDRD_BUTTON_LEFT
    static let buttonRight: UInt8 = 1 << 1     // KEYDRD_BUTTON_RIGHT
    static let buttonOther: UInt8 = 1 << 2     // KEYDRD_BUTTON_OTHER
    static let tMove: UInt8 = 0x01             // KEYDRD_INPUT_MOUSE_MOVE
    static let tClick: UInt8 = 0x02            // KEYDRD_INPUT_CLICK
    static let tScroll: UInt8 = 0x03           // KEYDRD_INPUT_SCROLL
    static let tKey: UInt8 = 0x10              // KEYDRD_INPUT_KEY
    static let tHeld: UInt8 = 0x11             // KEYDRD_INPUT_HELD
    static let tText: UInt8 = 0x12             // KEYDRD_INPUT_TEXT
    static let heartbeatMs = 250               // KEYDRD_INPUT_HEARTBEAT_MS
    static let heldMaxKeys = 32                // KEYDRD_HELD_MAX_KEYS
    static let phaseNone: UInt8 = 0, phaseBegan: UInt8 = 1, phaseChanged: UInt8 = 2
    static let phaseEnded: UInt8 = 3, phaseCancelled: UInt8 = 4

    init() {
        print("[CONSOLE] InputSender: session=\(String(session, radix: 16))")
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelAll(reason: "will-resign-active")
        }
    }

    deinit {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        heartbeat?.cancel()
    }

    // MARK: - Geometry

    /// The aspect-fit rect the Mac display occupies inside `bounds` (matches MetalRenderer).
    func videoRect(in bounds: CGRect) -> CGRect {
        guard macDisplaySize.width > 0, macDisplaySize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let mac = macDisplaySize.width / macDisplaySize.height
        let scr = bounds.width / bounds.height
        if mac > scr {
            let h = bounds.width / mac
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * mac
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        }
    }

    /// Normalized 0...65535 coordinates over the video rect (clamped to its edges).
    func normalized(_ p: CGPoint, in bounds: CGRect) -> (UInt16, UInt16) {
        let r = videoRect(in: bounds)
        let nx = min(max((p.x - r.minX) / max(r.width, 1), 0), 1)
        let ny = min(max((p.y - r.minY) / max(r.height, 1), 0), 1)
        return (UInt16((nx * 65535).rounded()), UInt16((ny * 65535).rounded()))
    }

    // MARK: - Events (main thread)

    func pointerMove(_ x: UInt16, _ y: UInt16, ts: TimeInterval) {
        var b = Data(); b.appendLE(x); b.appendLE(y)
        emit(Self.tMove, b, ts: ts)
    }

    func button(_ button: UInt8, down: Bool, _ x: UInt16, _ y: UInt16, ts: TimeInterval) {
        if down { if buttons & button != 0 { return }; buttons |= button }
        else { if buttons & button == 0 { return }; buttons &= ~button }
        var b = Data(); b.appendLE(x); b.appendLE(y); b.append(button); b.append(down ? 1 : 0)
        emit(Self.tClick, b, ts: ts)
        print("[CONSOLE] input button=\(button) down=\(down) at=(\(x),\(y)) buttons=\(buttons) seq=\(seq)")
        updateHeartbeat()
    }

    func scroll(dx: CGFloat, dy: CGFloat, phase: UInt8, _ x: UInt16, _ y: UInt16, ts: TimeInterval) {
        var b = Data(); b.appendLE(x); b.appendLE(y)
        b.appendLE(Int32((dx * 16).rounded())); b.appendLE(Int32((dy * 16).rounded())); b.append(phase)
        emit(Self.tScroll, b, ts: ts)
    }

    func key(_ usage: UInt16, down: Bool, ts: TimeInterval) {
        if down { if heldKeys.contains(usage) { return }; heldKeys.insert(usage) }
        else { if heldKeys.remove(usage) == nil { return } }
        var b = Data(); b.appendLE(usage); b.append(down ? 1 : 0)
        emit(Self.tKey, b, ts: ts)
        print("[CONSOLE] input key=0x\(String(usage, radix: 16)) down=\(down) held=\(heldKeys.count) seq=\(seq)")
        updateHeartbeat()
    }

    func text(_ s: String, ts: TimeInterval) {
        let units = Array(s.utf16)
        guard !units.isEmpty else { return }
        var b = Data(); b.appendLE(UInt16(units.count))
        for u in units { b.appendLE(u) }
        emit(Self.tText, b, ts: ts)
    }

    /// The iPad lost its held state with no key/button-ups (InputPath Cancel): tell the Mac.
    func cancelAll(reason: String) {
        guard !heldKeys.isEmpty || buttons != 0 else { return }
        print("[CONSOLE] input cancelAll reason=\(reason) keys=\(heldKeys.count) buttons=\(buttons)")
        heldKeys.removeAll(); buttons = 0
        sendHeld(ts: ProcessInfo.processInfo.systemUptime)
        updateHeartbeat()
    }

    /// A new connection carries input now (InputPath Connect): HELD first.
    func connectionEstablished(link: Link?) {
        lastLink = link
        print("[CONSOLE] input connectionEstablished link=\(link?.rawValue ?? "none") keys=\(heldKeys.count) buttons=\(buttons)")
        sendHeld(ts: ProcessInfo.processInfo.systemUptime)
    }

    /// E2E only: one message with an explicit seq (e.g. a stale one), bypassing state.
    func sendRawForTest(type: UInt8, body: Data, seq rawSeq: UInt64) {
        var d = InputEventHeader(type: type, tsUs: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)).serialize()
        d.appendLE(session); d.appendLE(rawSeq); d.append(body)
        _ = send?(d)
    }

    var lastSeq: UInt64 { seq }

    // MARK: - Wire

    private func sendHeld(ts: TimeInterval) {
        var b = Data(); b.append(buttons)
        let keys = Array(heldKeys.prefix(Self.heldMaxKeys))
        b.append(UInt8(keys.count))
        for k in keys { b.appendLE(k) }
        emit(Self.tHeld, b, ts: ts, isHeld: true)
    }

    private func message(_ type: UInt8, _ body: Data, ts: TimeInterval) -> Data {
        seq += 1
        var d = InputEventHeader(type: type, tsUs: UInt64(ts * 1_000_000)).serialize()
        d.appendLE(session); d.appendLE(seq); d.append(body)
        return d
    }

    private func emit(_ type: UInt8, _ body: Data, ts: TimeInterval, isHeld: Bool = false) {
        guard let send else { return }
        let msg = message(type, body, ts: ts)
        guard let link = send(msg) else {
            // No link: dropped. The Mac releases on loss/silence; HELD resyncs on reconnect.
            return
        }
        sentCount += 1
        if link != lastLink && !isHeld {
            // InputPath Switch: the previous link may still be alive and hold presses on the Mac.
            let prev = lastLink
            lastLink = link
            print("[CONSOLE] input link switch \(prev?.rawValue ?? "none") -> \(link.rawValue): HELD resync")
            sendHeld(ts: ts)
        } else if isHeld {
            lastLink = link
        }
    }

    private func updateHeartbeat() {
        let holding = !heldKeys.isEmpty || buttons != 0
        if holding && heartbeat == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(Self.heartbeatMs),
                       repeating: .milliseconds(Self.heartbeatMs), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in
                guard let self, let send = self.send else { return }
                let ka = InputEventHeader(type: InputEventType.keepalive.rawValue,
                                          tsUs: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)).serialize()
                _ = send(ka)
            }
            t.resume()
            heartbeat = t
        } else if !holding, let t = heartbeat {
            t.cancel()
            heartbeat = nil
        }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
