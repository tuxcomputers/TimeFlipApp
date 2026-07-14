@testable import TimeFlipApp
import XCTest

@MainActor
final class MockHistoryTests: XCTestCase {
    // Fixed base time to keep expectations deterministic.
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    func testFetchHistoryWithNilCursorReturnsAll() async {
        let mock = MockTimeFlipDevice()
        let entries = makeSequentialEntries(count: 3, spacing: 10)
        mock.seedHistory(entries)

        let fetched = await mock.fetchHistory(startingFrom: nil)

        XCTAssertEqual(fetched.count, entries.count)
        XCTAssertEqual(fetched, entries)
    }

    func testFetchHistoryInclusiveFromCursor() async {
        let mock = MockTimeFlipDevice()
        let entries = makeSequentialEntries(count: 4, spacing: 5)
        mock.seedHistory(entries)

        let cursor = entries[1].eventNumber
        let fetched = await mock.fetchHistory(startingFrom: cursor)

        XCTAssertEqual(fetched, Array(entries.suffix(3)))
    }

    func testFetchHistorySkipsEventsBeforeCursor() async {
        let mock = MockTimeFlipDevice()
        let entries = makeSequentialEntries(count: 5, spacing: 20)
        mock.seedHistory(entries)

        // Cursor between third and fourth event.
        let inBetween = UInt32(entries[2].startedAt.addingTimeInterval(10).timeIntervalSince1970)
        let fetched = await mock.fetchHistory(startingFrom: inBetween)

        XCTAssertEqual(fetched, Array(entries.suffix(2)))
    }

    func testFetchHistoryReturnsEmptyForFutureCursor() async {
        let mock = MockTimeFlipDevice()
        let entries = makeSequentialEntries(count: 2, spacing: 30)
        mock.seedHistory(entries)

        let futureCursor = UInt32(baseDate.addingTimeInterval(1_000).timeIntervalSince1970)
        let fetched = await mock.fetchHistory(startingFrom: futureCursor)

        XCTAssertTrue(fetched.isEmpty)
    }

    func testEventNumberMatchesStartSeconds() {
        let entries = makeSequentialEntries(count: 3, spacing: 7)
        for entry in entries {
            let expected = UInt32(entry.startedAt.timeIntervalSince1970)
            XCTAssertEqual(entry.eventNumber, expected)
        }
    }

    func testFacetFlipFinalizesPriorSessionWithMonotonicEventNumber() {
        let mock = MockTimeFlipDevice()
        mock.setDeviceTime(baseDate)
        // Start a fresh active session at the synchronized time.
        mock.flip(to: 2)

        // Advance device time to force a closing flip that finalizes the prior session.
        let endDate = baseDate.addingTimeInterval(12)
        mock.setDeviceTime(endDate)
        mock.flip(to: 3)

        let entries = mock.history
        XCTAssertGreaterThanOrEqual(entries.count, 3) // seeded entries + finalized sessions
        guard let finalized = entries.first(where: {
            $0.facetID == 2 && abs($0.startedAt.timeIntervalSince(baseDate)) < 0.5
        }) else {
            XCTFail("no finalized entry for facet 2 found")
            return
        }
        // Event numbers are a monotonic counter: unique and increasing in append order.
        let numbers = entries.compactMap { $0.eventNumber }
        XCTAssertEqual(numbers, numbers.sorted())
        XCTAssertEqual(Set(numbers).count, numbers.count)
        XCTAssertEqual(finalized.duration, 12, accuracy: 0.1)
    }

    // MARK: - Helpers

    private func makeSequentialEntries(count: Int, spacing: TimeInterval) -> [TimeFlipHistoryEntry] {
        (0..<count).map { index in
            let start = baseDate.addingTimeInterval(spacing * TimeInterval(index))
            return TimeFlipHistoryEntry(
                eventNumber: UInt32(start.timeIntervalSince1970),
                facetID: UInt8(1 + index),
                startedAt: start,
                duration: 6,
                isPaused: false
            )
        }
    }
}
