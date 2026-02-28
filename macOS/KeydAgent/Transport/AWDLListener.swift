import Network
import Foundation

/// Advertises a Bonjour service (_keyd._tcp) and accepts peer connections over AWDL.
/// AWDL is an Apple proprietary peer-to-peer protocol active when Bonjour services
/// are discovered between nearby Apple devices. Pre-warmed while USB is active.
actor AWDLListener {
    private var listener: NWListener?
    var onConnection: (@Sendable (NWConnection) -> Void)?

    func start() throws {
        // applicationService parameters enable AWDL-capable peer connections via Bonjour
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let l = try NWListener(using: params)
        // Advertise _keyd._tcp Bonjour service — iOS NWBrowser discovers this
        l.service = NWListener.Service(type: "_keyd._tcp")
        l.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.onConnection?(connection)
            }
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[AWDLListener] Advertising _keyd._tcp Bonjour service")
            case .failed(let error):
                print("[AWDLListener] Failed: \(error)")
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
