import XCTest
@testable import SharedProtocol

final class TransportEventLogTests: XCTestCase {

    // MARK: - Basic append and export

    func testAppendAndExportSingleEntry() {
        let log = TransportEventLog(capacity: 10)
        let entry = TransportEventEntry(
            previousState: "disconnected",
            event: "usbConnectionArrived",
            newState: "pendingUSBIdentity",
            sideEffects: ["startUSBIdentityTimer"]
        )
        log.append(entry)
        let exported = log.export()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].previousState, "disconnected")
        XCTAssertEqual(exported[0].event, "usbConnectionArrived")
        XCTAssertEqual(exported[0].newState, "pendingUSBIdentity")
        XCTAssertEqual(exported[0].sideEffects, ["startUSBIdentityTimer"])
    }

    func testExportEmptyLog() {
        let log = TransportEventLog(capacity: 10)
        XCTAssertEqual(log.export().count, 0)
    }

    func testEntryCountTracksAppends() {
        let log = TransportEventLog(capacity: 10)
        XCTAssertEqual(log.entryCount, 0)
        for i in 0..<5 {
            log.append(makeEntry(index: i))
        }
        XCTAssertEqual(log.entryCount, 5)
    }

    // MARK: - Circular buffer behaviour

    func testCircularBufferWrapsAtCapacity() {
        let cap = 5
        let log = TransportEventLog(capacity: cap)
        // Fill past capacity
        for i in 0..<8 {
            log.append(makeEntry(index: i))
        }
        XCTAssertEqual(log.entryCount, cap, "Should only hold `capacity` entries")
        let exported = log.export()
        XCTAssertEqual(exported.count, cap)
        // The oldest 3 (0,1,2) should have been evicted; entries 3..7 survive in order
        XCTAssertEqual(exported[0].event, "event-3")
        XCTAssertEqual(exported[4].event, "event-7")
    }

    func testExportOrderIsChronological() {
        let log = TransportEventLog(capacity: 10)
        for i in 0..<7 {
            log.append(makeEntry(index: i))
        }
        let exported = log.export()
        for (idx, entry) in exported.enumerated() {
            XCTAssertEqual(entry.event, "event-\(idx)")
        }
    }

    func testExportOrderAfterWrap() {
        let log = TransportEventLog(capacity: 4)
        // Write 6 entries — wraps twice
        for i in 0..<6 {
            log.append(makeEntry(index: i))
        }
        let exported = log.export()
        // Newest 4: entries 2,3,4,5 in insertion order
        XCTAssertEqual(exported.count, 4)
        XCTAssertEqual(exported[0].event, "event-2")
        XCTAssertEqual(exported[3].event, "event-5")
    }

    // MARK: - Clear

    func testClearEmptiesLog() {
        let log = TransportEventLog(capacity: 10)
        for i in 0..<5 { log.append(makeEntry(index: i)) }
        log.clear()
        XCTAssertEqual(log.entryCount, 0)
        XCTAssertEqual(log.export().count, 0)
    }

    func testAppendAfterClearWorks() {
        let log = TransportEventLog(capacity: 5)
        for i in 0..<5 { log.append(makeEntry(index: i)) }
        log.clear()
        log.append(makeEntry(index: 99))
        XCTAssertEqual(log.entryCount, 1)
        XCTAssertEqual(log.export()[0].event, "event-99")
    }

    // MARK: - JSON round-trip

    func testExportJSONProducesValidJSON() {
        let log = TransportEventLog(capacity: 10)
        log.append(makeEntry(index: 0))
        log.append(makeEntry(index: 1))

        let data = log.exportJSON()
        XCTAssertFalse(data.isEmpty, "exportJSON should produce non-empty data")

        // Must be valid JSON (use iso8601 decoder to match iso8601 encoder used by exportJSON)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([TransportEventEntry].self, from: data)
        XCTAssertNotNil(decoded, "JSON should decode back to [TransportEventEntry]")
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?[0].event, "event-0")
        XCTAssertEqual(decoded?[1].event, "event-1")
    }

    func testExportJSONRoundTripPreservesSideEffects() {
        let log = TransportEventLog(capacity: 5)
        let entry = TransportEventEntry(
            previousState: "disconnected",
            event: "awdlCandidateArrived",
            newState: "pendingAWDLPool",
            sideEffects: ["logEvent(AWDL candidate arrived)"]
        )
        log.append(entry)

        let data = log.exportJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([TransportEventEntry].self, from: data)
        XCTAssertEqual(decoded?.first?.sideEffects, ["logEvent(AWDL candidate arrived)"])
    }

    func testExportJSONEmptyLogProducesEmptyArray() {
        let log = TransportEventLog(capacity: 10)
        let data = log.exportJSON()
        let decoded = try? JSONDecoder().decode([TransportEventEntry].self, from: data)
        XCTAssertEqual(decoded?.count, 0)
    }

    // MARK: - Helpers

    private func makeEntry(index: Int) -> TransportEventEntry {
        TransportEventEntry(
            previousState: "state-\(index)",
            event: "event-\(index)",
            newState: "state-\(index + 1)",
            sideEffects: []
        )
    }
}
