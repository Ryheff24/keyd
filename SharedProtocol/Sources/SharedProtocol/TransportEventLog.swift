import Foundation

/// Circular buffer event log for transport state transitions.
///
/// Records every FSM transition with timestamp, states, event, and side effects.
/// Thread-safe for concurrent reads; writes must happen on a single actor (Main or transport actor).
/// Used by both macOS and iOS transport layers for structured debug logging and test trace export.
public final class TransportEventLog: @unchecked Sendable {
    private var buffer: [TransportEventEntry]
    private let capacity: Int
    private var head: Int = 0     // Next write position
    private var count: Int = 0    // Number of valid entries

    public init(capacity: Int = 500) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.buffer = Array(repeating: TransportEventEntry(
            previousState: "", event: "", newState: "", sideEffects: []
        ), count: capacity)
    }

    /// Append a new transition entry to the log.
    public func append(_ entry: TransportEventEntry) {
        buffer[head] = entry
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Returns all entries in chronological order (oldest first).
    public func export() -> [TransportEventEntry] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(buffer[0..<count])
        }
        // Wrap-around: entries from head..end, then 0..head
        let tail = Array(buffer[head...])
        let front = Array(buffer[0..<head])
        return tail + front
    }

    /// Serialize all entries to JSON data for trace export.
    public func exportJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(export())) ?? Data()
    }

    /// Remove all entries from the log.
    public func clear() {
        head = 0
        count = 0
    }

    /// Number of entries currently stored.
    public var entryCount: Int { count }
}
