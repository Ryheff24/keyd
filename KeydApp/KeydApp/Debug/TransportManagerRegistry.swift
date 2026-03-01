import Foundation

// MARK: - TransportManager Registry (main app only, test support)

/// Shared registry that allows integration tests to obtain the running TransportManager
/// and PairingManager without going through AppDelegate (which doesn't exist — the app
/// uses @main struct KeydApp: App).
///
/// KeydApp registers both managers on startup so that KeydIntegrationTests can
/// access them via @testable import KeydApp → TransportManagerRegistry.shared.
///
/// Production code never reads from this registry.
@MainActor
public final class TransportManagerRegistry {
    public static let shared = TransportManagerRegistry()
    private init() {}

    // Internal (not public) so they're accessible within the module but not declared
    // public (which would require TransportManager/PairingManager to also be public).
    weak var transportManager: TransportManager?
    weak var pairingManager: PairingManager?
}
