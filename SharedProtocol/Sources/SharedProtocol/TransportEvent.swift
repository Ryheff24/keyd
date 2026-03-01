import Foundation

/// A single recorded transport state transition.
///
/// Every call to a transport transition function produces one of these entries,
/// capturing the full before/after context for debugging and testing.
public struct TransportEventEntry: Codable, Sendable {
    public let timestamp: Date
    public let previousState: String
    public let event: String
    public let newState: String
    public let sideEffects: [String]

    public init(
        timestamp: Date = Date(),
        previousState: String,
        event: String,
        newState: String,
        sideEffects: [String]
    ) {
        self.timestamp = timestamp
        self.previousState = previousState
        self.event = event
        self.newState = newState
        self.sideEffects = sideEffects
    }
}
