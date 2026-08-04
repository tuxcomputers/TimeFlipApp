@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length number_separator
@MainActor
final class DailyCategoryTotalsTests: XCTestCase {
    private var dataStoreURL: URL!

    /// The categories the schema seeds and the faces they start on (`database/007_category.sql`,
    /// `database/008_face.sql`). Named rather than inlined, since which face carries which category is
    /// what several of these tests are about.
    private enum Seeded {
        static let unassignedCategory = 0
        static let breakCategory = 1
        static let meetingCategory = 2
        static let meetingFace: UInt8 = 2
        static let breakFace: UInt8 = 8
        /// Unlocked and `Unassigned` to begin with, so it is the face free to be reassigned.
        static let spareFace: UInt8 = 3
    }

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
        // whether a segment is the newest it has seen: each write closes out the one before it. Only a
        // closed segment becomes a `time_entry`, so the order is what makes these countable at all.

        // Event crossing window start (2:00-3:30); expect only 30m (1800s) counted.
        let crossStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 2, minute: 0)))
        store.recordDeviceEvent(eventNumber: 1, deviceFace: Seeded.meetingFace, startedAt: crossStart, durationSeconds: 5_400, isPaused: false)

        // Event fully after window start (8:00).
        let morningStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 8, minute: 0)))
        store.recordDeviceEvent(eventNumber: 2, deviceFace: Seeded.meetingFace, startedAt: morningStart, durationSeconds: 1_200, isPaused: false)

        // A third segment on another face, purely to close out the 8:00 one. Without it that row is
        // still the device's open interval, has no entry, and is rightly uncounted -- the menu bar adds
        // the live segment's elapsed time separately, so counting it here would count it twice.
        let laterStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 0)))
        store.recordDeviceEvent(eventNumber: 3, deviceFace: Seeded.breakFace, startedAt: laterStart, durationSeconds: 0, isPaused: false)

        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        // 1200s + 1800s = 3000s, against the category rather than the face it came in on.
        XCTAssertEqual(totals.totals[Seeded.meetingCategory] ?? 0, 3_000, accuracy: 0.5)
        let expectedWindowStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 3)))
        XCTAssertEqual(totals.windowStart, expectedWindowStart)
    }

    /// The reason these totals are keyed by category at all.
    ///
    /// Two faces assigned one category share its `daily_limit`, so their time has to add up to spend
    /// it. Keyed by face, each face counted alone: 40 minutes on one and 40 on another left a
    /// 60-minute limit unreached, and the menu bar drew 40 beside the category's own name.
    func testTwoFacesSharingACategoryAddUpToOneTotal() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        store.updateFaceCategory(faceID: Seeded.spareFace, categoryID: Seeded.meetingCategory)
        XCTAssertEqual(
            try XCTUnwrap(store.loadFaceCategories()[Seeded.spareFace]).id, Seeded.meetingCategory,
            "precondition: two faces now share Meeting"
        )

        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9)))
        store.recordDeviceEvent(eventNumber: 1, deviceFace: Seeded.meetingFace, startedAt: first, durationSeconds: 2_400, isPaused: false)
        let second = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10)))
        store.recordDeviceEvent(eventNumber: 2, deviceFace: Seeded.spareFace, startedAt: second, durationSeconds: 2_400, isPaused: false)
        // Closes the second one out. Zero length, so it is a blip and leaves no entry of its own.
        let closer = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 11)))
        store.recordDeviceEvent(eventNumber: 3, deviceFace: Seeded.breakFace, startedAt: closer, durationSeconds: 0, isPaused: false)

        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        XCTAssertEqual(
            totals.totals[Seeded.meetingCategory] ?? 0, 4_800, accuracy: 0.5,
            "both faces' 40 minutes belong to the one category, so a 60-minute limit is exceeded rather than each face sitting under it"
        )
        XCTAssertNil(
            totals.totals[Seeded.breakCategory],
            "the zero-length closer is under blip_time, so Break has no entry and no total"
        )
    }

    /// Why the totals read `time_entry` and not `device_event` joined to `face`.
    ///
    /// An entry records the category the face was mapped to when the segment happened. Reassigning the
    /// face afterwards must not move that time: derived from the mapping as it stands now, a day's work
    /// would follow the face to whatever it points at next.
    func testReassigningAFaceLeavesAlreadyCountedTimeWhereItWas() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        store.updateFaceCategory(faceID: Seeded.spareFace, categoryID: Seeded.meetingCategory)

        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9)))
        store.recordDeviceEvent(eventNumber: 1, deviceFace: Seeded.spareFace, startedAt: start, durationSeconds: 1_800, isPaused: false)
        let breakStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10)))
        store.recordDeviceEvent(eventNumber: 2, deviceFace: Seeded.breakFace, startedAt: breakStart, durationSeconds: 600, isPaused: false)
        let closer = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 11)))
        store.recordDeviceEvent(eventNumber: 3, deviceFace: Seeded.meetingFace, startedAt: closer, durationSeconds: 0, isPaused: false)

        // Now the face moves to Break, which is the edit that would rewrite history if the totals were
        // derived from the current mapping.
        store.updateFaceCategory(faceID: Seeded.spareFace, categoryID: Seeded.breakCategory)

        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        XCTAssertEqual(
            totals.totals[Seeded.meetingCategory] ?? 0, 1_800, accuracy: 0.5,
            "the half hour stays on Meeting, which is what the face was when it was spent"
        )
        XCTAssertEqual(
            totals.totals[Seeded.breakCategory] ?? 0, 600, accuracy: 0.5,
            "and Break holds only its own ten minutes, not the reassigned face's history"
        )
    }

    /// Blips and pauses have no entry, so they have no total. Both fall out of reading `time_entry`
    /// rather than being tested for: a segment under `blip_time` is never converted, and neither is a
    /// pause. The `device_event` seed this replaced counted blips, and had to skip pauses itself.
    func testBlipsAndPausesAreNotCounted() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12)))
        let store = AppDataStore(databaseURL: dataStoreURL)

        // Two seconds on Meeting: the cube turned past the face, under the seeded blip_time of 5.
        let blip = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9)))
        store.recordDeviceEvent(eventNumber: 1, deviceFace: Seeded.meetingFace, startedAt: blip, durationSeconds: 2, isPaused: false)
        // An hour of pause on Break.
        let pause = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 30)))
        store.recordDeviceEvent(eventNumber: 2, deviceFace: Seeded.breakFace, startedAt: pause, durationSeconds: 3_600, isPaused: true)
        // Real time on Meeting, then a closer so it finalises.
        let real = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 30)))
        store.recordDeviceEvent(eventNumber: 3, deviceFace: Seeded.meetingFace, startedAt: real, durationSeconds: 900, isPaused: false)
        let closer = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 11)))
        store.recordDeviceEvent(eventNumber: 4, deviceFace: Seeded.spareFace, startedAt: closer, durationSeconds: 60, isPaused: false)

        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        XCTAssertEqual(
            totals.totals[Seeded.meetingCategory] ?? 0, 900, accuracy: 0.5,
            "the 15 minutes counts and the 2-second pass-over does not"
        )
        XCTAssertNil(totals.totals[Seeded.breakCategory], "an hour of pause is not an hour of tracked time")
        XCTAssertNil(
            totals.totals[Seeded.unassignedCategory],
            "and the closer is itself the open segment now, so its own minute is not counted here either -- the menu bar adds the live one"
        )
    }

    func testAccumulateAddsLiveSegmentWithinWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 10, minute: 0, second: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)
        totals.seedFromHistory(now: now)

        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9, minute: 30)))
        let added = totals.accumulate(start: start, duration: 600, categoryID: Seeded.meetingCategory, now: now)

        XCTAssertEqual(added, 600, accuracy: 0.1)
        XCTAssertEqual(totals.totals[Seeded.meetingCategory] ?? 0, 600, accuracy: 0.1)
    }

    func testNextResetDateIsNextDayAtResetHour() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 4, minute: 0)))
        let store = AppDataStore(databaseURL: dataStoreURL)
        let totals = DailyCategoryTotals(dataStore: store, calendar: calendar, resetHour: 3, now: now)

        let expectedNext = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 3)))
        XCTAssertEqual(totals.nextResetDate, expectedNext)
    }
}
// swiftlint:enable line_length number_separator
