import Network
import Foundation

/// Listens on localhost:12345 for iOS connections forwarded through usbmuxd.
/// When the iOS device is connected via USB, usbmuxd forwards the device's TCP
/// connection to this local port transparently. No usbmuxd protocol parsing needed —
/// the forwarding is transparent at the TCP level.
actor USBListener {
    static let port: UInt16 = 12345
    private var listener: NWListener?
    var onConnection: (@Sendable (NWConnection) -> Void)?

    func start() throws {
        let params = NWParameters.tcp

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.onConnection?(connection)
            }
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[USBListener] Listening on port \(Self.port)")
            case .failed(let error):
                print("[USBListener] Failed: \(error)")
            default:
                break
            }
        }
        l.start(queue: .global(qos: .userInteractive))
        self.listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
