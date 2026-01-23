@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length number_separator
@MainActor
final class DailyFacetTotalsTests: XCTestCase {
    private var dataStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        dataStoreURL = AppDataStore.testDatabaseURL()
        AppDataStore.resetForTests(at: dataStoreURL)
    }

    func testSeedsAndClipsToWindowStart() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0, second: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)

        // Event fully after window start (3:00).
        let morningStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 8, minute: 0)))
        store.append(
            DeviceEventRecord(
                id: nil,
                eventNumber: 1,
                facetID: 1,
                startedAt: morningStart,
                duration: 1_200,
                isPaused: false,
                activityName: "A"
            )
        )

        // Event crossing window start (2:00-3:30); expect only 30m (1800s) counted.
        let crossStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 2, minute: 0)))
        store.append(
            DeviceEventRecord(
                id: nil,
                eventNumber: 2,
                facetID: 1,
                startedAt: crossStart,
                duration: 5_400,
                isPaused: false,
                activityName: "A"
            )
        )

        let totals = DailyFacetTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromLogbook(now: now)

        let counted = totals.totals[1] ?? 0
        // 1200s + 1800s = 3000s
        XCTAssertEqual(counted, 3_000, accuracy: 0.5)
        let expectedWindowStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 3)))
        XCTAssertEqual(totals.windowStart, expectedWindowStart)
    }

    func testAccumulateAddsLiveSegmentWithinWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0, second: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        let totals = DailyFacetTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromLogbook(now: now)

        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 30)))
        let added = totals.accumulate(start: start, duration: 600, facetID: 4, now: now)

        XCTAssertEqual(added, 600, accuracy: 0.1)
        XCTAssertEqual(totals.totals[4] ?? 0, 600, accuracy: 0.1)
    }

    func testNextResetDateIsNextDayAtResetHour() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 4, minute: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        let totals = DailyFacetTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)

        let expectedNext = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 3)))
        XCTAssertEqual(totals.nextResetDate, expectedNext)
    }
}
// swiftlint:enable line_length number_separator
