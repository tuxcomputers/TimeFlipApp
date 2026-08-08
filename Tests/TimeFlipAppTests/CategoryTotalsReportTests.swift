@testable import TimeFlipApp
import XCTest

/// Covers `AppDataStore.loadCategoryTotals(from:to:)`, the Report tab's whole content.
///
/// Written against the real database rather than a stub, for the same reason as
/// `TimeEntryCreationTests`: what is being tested is SQL -- a grouped sum with each span clipped to
/// the range -- and a fake store would only test the fake.
///
/// Faces are seeded (`database/008_face.sql`): face 2 is `Meeting`, face 8 is `Break`, and face 1 is
/// the `Unassigned` sentinel. Segments are laid down through `recordDeviceEvent`, so they become
/// `time_entry` rows by the same path the app uses. The newest segment always stays open (it has no
/// end yet), so each test records one more event than the entries it means to assert on.
@MainActor
final class CategoryTotalsReportTests: XCTestCase {
    private var databaseURL: URL!
    /// An arbitrary fixed epoch; every time in these tests is an offset from it, so the numbers in
    /// the assertions are durations rather than dates.
    private let base: TimeInterval = 1_700_000_000

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = AppDataStore.testDatabaseURL()
        AppDataStore.resetForTests(at: databaseURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func record(
        _ store: AppDataStore,
        event: UInt32,
        face: UInt8,
        offset: TimeInterval,
        duration: TimeInterval,
        paused: Bool = false
    ) {
        store.recordDeviceEvent(
            eventNumber: event,
            deviceFace: face,
            startedAt: Date(timeIntervalSince1970: base + offset),
            durationSeconds: duration,
            isPaused: paused
        )
    }

    private func totals(_ store: AppDataStore, from: TimeInterval, to: TimeInterval) -> [CategoryTotalRecord] {
        store.loadCategoryTotals(
            from: Date(timeIntervalSince1970: base + from),
            to: Date(timeIntervalSince1970: base + to)
        )
    }

    // MARK: - the sum

    func testEachCategoryGetsItsOwnTotal() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 300)
        record(store, event: 3, face: 2, offset: 900, duration: 60)

        let rows = totals(store, from: -1, to: 1_000)

        XCTAssertEqual(rows.map(\.name), ["Meeting", "Break"], "longest first")
        XCTAssertEqual(rows.first?.seconds, 600)
        XCTAssertEqual(rows.last?.seconds, 300)
    }

    func testTwoSpellsOnTheSameCategoryAddUp() {
        // The report's unit is the category, not the segment: two separate spells on one category
        // are one row carrying their sum.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 300)
        record(store, event: 3, face: 2, offset: 900, duration: 400)
        record(store, event: 4, face: 8, offset: 1_300, duration: 60)

        let rows = totals(store, from: -1, to: 2_000)

        XCTAssertEqual(rows.first?.name, "Meeting")
        XCTAssertEqual(rows.first?.seconds, 1_000, "600 + 400, as one row")
    }

    func testTimeOnAFaceWithNoCategoryIsReportedAsUnassigned() {
        // Face 1 is the Unassigned sentinel (category_id 0), which loadCategories() deliberately
        // skips. It cannot be skipped here: that time was still spent, and dropping it would leave a
        // report that quietly fails to add up to the day.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 1, offset: 0, duration: 600)
        record(store, event: 2, face: 2, offset: 600, duration: 60)

        let rows = totals(store, from: -1, to: 1_000)

        XCTAssertEqual(rows.first?.name, "Unassigned")
        XCTAssertEqual(rows.first?.id, 0)
        XCTAssertEqual(rows.first?.seconds, 600)
    }

    // MARK: - clipping to the range

    func testASpanStartingBeforeTheRangeCountsOnlyItsOverlap() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        let rows = totals(store, from: 300, to: 1_000)

        XCTAssertEqual(rows.first?.name, "Meeting")
        XCTAssertEqual(rows.first?.seconds, 300, "only the half of the span inside the range")
    }

    func testASpanRunningPastTheRangeCountsOnlyItsOverlap() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        let rows = totals(store, from: -100, to: 200)

        XCTAssertEqual(rows.first?.seconds, 200)
    }

    func testTwoAdjacentRangesAddUpToTheRangeOverBoth() {
        // The property clipping exists for: an overnight span must not appear in full on both of the
        // days it touches. Report(A) + Report(B) == Report(A+B) is what makes the numbers trustworthy.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        let firstHalf = totals(store, from: 0, to: 250).first?.seconds ?? 0
        let secondHalf = totals(store, from: 250, to: 600).first?.seconds ?? 0
        let whole = totals(store, from: 0, to: 600).first?.seconds ?? 0

        XCTAssertEqual(firstHalf + secondHalf, whole)
        XCTAssertEqual(whole, 600)
    }

    // MARK: - what is left out

    func testASpanEntirelyOutsideTheRangeIsNotListed() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        XCTAssertTrue(totals(store, from: 5_000, to: 6_000).isEmpty)
    }

    func testATouchingButNonOverlappingSpanIsNotListedAsZero() {
        // A span ending exactly where the range begins contributes nothing, and a zero row would
        // read as "this category was used and took no time".
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        XCTAssertTrue(totals(store, from: 600, to: 1_000).isEmpty)
    }

    func testAPausedSegmentIsNotCounted() {
        // A pause never becomes a time_entry at all, so the report inherits that for free -- the
        // same rule the menu bar's daily figure follows.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600, paused: true)
        record(store, event: 2, face: 8, offset: 600, duration: 300)
        record(store, event: 3, face: 2, offset: 900, duration: 60)

        let rows = totals(store, from: -1, to: 2_000)

        XCTAssertEqual(rows.map(\.name), ["Break"], "the pause is not tracked time")
    }

    func testTheStillOpenSegmentIsNotCounted() {
        // The newest segment has no time_entry until something closes it out, so it is absent here
        // -- matching DailyCategoryTotals, where the menu bar adds the live segment on top instead.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)

        XCTAssertTrue(totals(store, from: -1, to: 2_000).isEmpty)
    }

    func testAnEmptyDatabaseReportsNothing() {
        let store = AppDataStore(databaseURL: databaseURL)

        XCTAssertTrue(totals(store, from: -1, to: 10_000).isEmpty)
    }

    // MARK: - a category's history outlives its current state

    func testARetiredCategorysHistoricalTimeStillTotals() throws {
        // The report shows time, not current categories: retiring a category is a promise its
        // history still counts (see ReportView's own documentation). loadCategoryTotals's join on
        // `time_entry` skips the `active` flag entirely to keep that promise -- this pins the SQL
        // shape directly, rather than relying only on the device checklist (11b) to notice a
        // regression here.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, offset: 0, duration: 600)
        record(store, event: 2, face: 8, offset: 600, duration: 60)

        let meetingID = try XCTUnwrap(store.loadCategories().first { $0.name == "Meeting" }?.id)
        // Face 2 is seeded locked (database/008_face.sql), and the app refuses to retire a category
        // a locked face still holds -- unlock it first, the route the app's own error prescribes.
        store.updateFaceLocked(faceID: 2, locked: false)
        XCTAssertTrue(store.updateCategoryActive(categoryID: meetingID, isActive: false))

        let rows = totals(store, from: -1, to: 1_000)

        XCTAssertEqual(rows.first { $0.name == "Meeting" }?.seconds, 600, "retiring must not drop its history")
    }
}
