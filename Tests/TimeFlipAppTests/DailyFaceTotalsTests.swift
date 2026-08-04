@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length number_separator
@MainActor
final class DailyFaceTotalsTests: XCTestCase {
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

        // Written in device order, oldest first, because recordDeviceEvent decides `finalised` from
        // whether a segment is the newest it has seen: each write closes out the one before it. The
        // seed reads finalised rows only, so the order is what makes both of these visible to it.

        // Event crossing window start (2:00-3:30); expect only 30m (1800s) counted.
        let crossStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 2, minute: 0)))
        store.recordDeviceEvent(eventNumber: 1, deviceFace: 1, startedAt: crossStart, durationSeconds: 5_400, isPaused: false)

        // Event fully after window start (3:00).
        let morningStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 8, minute: 0)))
        store.recordDeviceEvent(eventNumber: 2, deviceFace: 1, startedAt: morningStart, durationSeconds: 1_200, isPaused: false)

        // A third segment on another face, purely to close out the 8:00 one. Without it that row is
        // still the device's open interval and the seed rightly skips it -- the menu bar adds the
        // live segment's elapsed time separately, so counting it here would count it twice.
        let laterStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 0)))
        store.recordDeviceEvent(eventNumber: 3, deviceFace: 9, startedAt: laterStart, durationSeconds: 0, isPaused: false)

        let totals = DailyFaceTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

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
        let totals = DailyFaceTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 30)))
        let added = totals.accumulate(start: start, duration: 600, faceID: 4, now: now)

        XCTAssertEqual(added, 600, accuracy: 0.1)
        XCTAssertEqual(totals.totals[4] ?? 0, 600, accuracy: 0.1)
    }

    func testNextResetDateIsNextDayAtResetHour() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 4, minute: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        let totals = DailyFaceTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)

        let expectedNext = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 3)))
        XCTAssertEqual(totals.nextResetDate, expectedNext)
    }
}
// swiftlint:enable line_length number_separator
