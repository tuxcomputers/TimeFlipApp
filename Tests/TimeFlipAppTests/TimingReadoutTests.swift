@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers the one answer both views draw from: which category is being timed, whether its clock is running, and
/// how much time it has today.
///
/// Against a real database, because that is the whole claim -- every field is read when it is asked for, so a row
/// changed behind the app's back shows up on the next read with nothing being told. Nothing here sets up a session
/// in memory, because there is no session in memory to set up: a test says "running" by leaving a segment open,
/// which is the same thing the app says it with.
@MainActor
final class TimingReadoutTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var connection: DatabaseConnection!
    private var faces: FaceStore!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!

    /// 2026-08-13 09:00:00 UTC. Whole seconds, so `start_epoch` is exact.
    private let noon = Date(timeIntervalSince1970: 1_786_600_000)

    /// Break, which face 8 is seeded with.
    private let breakID = 1
    /// Meeting, which face 2 is seeded with.
    private let meetingID = 2

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        faces = FaceStore(connection: connection)
        // Wired to the time entry recorder as `main.swift` wires it, so closing a segment records it. The figure is
        // summed from `time_entry`, so a recorder with nowhere to hand a finished stretch would show none of it.
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: TimeEntryRecorder(
                connection: connection,
                settings: SettingStore(connection: connection),
                faces: faces,
                debugLog: nil
            ),
            debugLog: nil
        )
        readout = TimingReadout(
            categories: CategoryStore(connection: connection),
            faces: faces,
            events: events,
            dayTotal: DayTotal(
                settings: SettingStore(connection: connection),
                entries: TimeEntryStore(connection: connection),
                events: events,
                faces: faces
            )
        )
    }

    override func tearDown() {
        readout = nil
        events = nil
        faces = nil
        connection = nil
        database.remove()
        super.tearDown()
    }

    /// What the window does when a category is picked: the next face takes it, a segment opens on it.
    private func startTiming(_ categoryID: Int, at moment: Date) {
        let face = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        events.closeOpenSegment(at: moment)
        XCTAssertTrue(faces.assign(categoryID: categoryID, toFace: face))
        events.startSegment(face: face, at: moment)
    }

    // MARK: - nothing being timed

    func testAFreshDatabaseIsIdle() {
        // Face 13 has never been used and holds no category, so there is nothing to name and nothing to total.
        XCTAssertEqual(readout.read(at: noon), .idle)
    }

    func testAFaceHoldingNoCategoryIsIdleEvenWithASegmentOpenOnIt() {
        // A face with nothing on it has no name, no icon and no total, so there is nothing to draw whatever the
        // table says about segments.
        events.startSegment(face: ManualFace.first, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(readout.read(at: noon).state, .idle)
        XCTAssertNil(readout.read(at: noon).category)
    }

    // MARK: - a session

    func testItNamesTheCategoryOnTheFaceTheLastSegmentUsed() {
        startTiming(meetingID, at: noon.addingTimeInterval(-120))

        let reading = readout.read(at: noon)

        XCTAssertEqual(reading.category?.id, meetingID)
        XCTAssertEqual(reading.category?.name, "Meeting")
        XCTAssertEqual(reading.state, .running)
    }

    func testItFollowsTheRotationRatherThanTheFirstFace() {
        // Two categories in a row, which is what puts the second on the *other* manual face. A readout keyed to
        // `ManualFace.first` would still be naming the first category.
        startTiming(meetingID, at: noon.addingTimeInterval(-600))
        startTiming(breakID, at: noon.addingTimeInterval(-300))

        XCTAssertEqual(readout.read(at: noon).category?.id, breakID)
    }

    func testTheFigureIsTheCategorysTimeTodayIncludingTheOpenStretch() {
        // Five minutes recorded on one face, then a stretch still running on the other: one category, so they add.
        startTiming(breakID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        startTiming(breakID, at: noon.addingTimeInterval(-120))

        XCTAssertEqual(readout.read(at: noon).seconds, 420)
    }

    // MARK: - running is an open row, and nothing else

    func testClosingTheSegmentIsWhatMakesItPaused() {
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertEqual(readout.read(at: noon).state, .running, "precondition")

        events.closeOpenSegment(at: noon.addingTimeInterval(-180))

        let reading = readout.read(at: noon)
        XCTAssertEqual(reading.state, .paused)
        // The two minutes since the close are not counted, and the two before it are not thrown away. Neither takes
        // a special case: there is no live part left to add.
        XCTAssertEqual(reading.seconds, 120)
        XCTAssertEqual(reading.category?.id, breakID, "the category is the face's, so it survives the pause")
    }

    func testAPausedRowIsNotRunning() {
        // A cube reports paused stretches of its own, as open rows with `paused` set.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertTrue(database.execute("UPDATE device_event SET paused = 1 WHERE finalised = 0;"))

        XCTAssertEqual(readout.read(at: noon).state, .paused)
    }

    func testASegmentOpenOnSomeOtherFaceIsNotThisSessionRunning() {
        // Face 8 is a device face, and a cube times whether or not the app is doing anything. That is not the app's
        // session running.
        startTiming(breakID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        events.startSegment(face: 8, at: noon.addingTimeInterval(-120))

        XCTAssertEqual(readout.read(at: noon).state, .paused)
    }

    // MARK: - a relaunch inherits the session

    func testAfterARelaunchTheLastCategoryIsStillOnShowAndPaused() {
        // The launch before: a stretch of Meeting, then quit, which closes the open segment.
        startTiming(meetingID, at: noon.addingTimeInterval(-900))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))

        // The launch after: a new readout over the same database, holding nothing at all.
        let relaunched = TimingReadout(
            categories: CategoryStore(connection: connection),
            faces: faces,
            events: events,
            dayTotal: DayTotal(
                settings: SettingStore(connection: connection),
                entries: TimeEntryStore(connection: connection),
                events: events,
                faces: faces
            )
        )

        let reading = relaunched.read(at: noon)
        XCTAssertEqual(reading.category?.id, meetingID, "the category the last launch was left on")
        XCTAssertEqual(reading.state, .paused, "stopped, since nothing is open")
        XCTAssertEqual(reading.seconds, 600, "the ten minutes it recorded today, not a stopwatch from zero")
    }

    func testARelaunchMidStretchIsStillRunning() {
        // A crash rather than a quit: the row is still open, so the new launch is timing. Startup recovery closes
        // rows like this one deliberately (see `DeviceEventRecorder.closeSegmentsStrandedOnAppFaces`); this is what
        // the readout says while one is there.
        startTiming(meetingID, at: noon.addingTimeInterval(-300))

        XCTAssertEqual(readout.read(at: noon).state, .running)
    }

    // MARK: - picking the same category again

    func testTheCategoryBeingTimedIsTheOneClickReadsAsNoChange() {
        startTiming(breakID, at: noon.addingTimeInterval(-60))

        let reading = readout.read(at: noon)
        XCTAssertTrue(reading.isTiming(breakID))
        XCTAssertFalse(reading.isTiming(meetingID))
    }

    func testAPausedCategoryIsNotBeingTimed() {
        // So clicking it starts it again rather than being ignored, which is what a relaunched app needs: the
        // category on show is exactly the one somebody is most likely to click.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        events.closeOpenSegment(at: noon.addingTimeInterval(-60))

        XCTAssertFalse(readout.read(at: noon).isTiming(breakID))
    }

    // MARK: - read, never remembered

    func testARenameShowsUpOnTheNextRead() {
        startTiming(meetingID, at: noon.addingTimeInterval(-60))
        XCTAssertEqual(readout.read(at: noon).category?.name, "Meeting", "precondition")

        XCTAssertTrue(database.execute("UPDATE category SET category_name = 'Standup' WHERE category_id = \(meetingID);"))

        XCTAssertEqual(readout.read(at: noon).category?.name, "Standup")
    }

    func testReassigningTheFaceChangesWhatIsBeingTimed() {
        startTiming(meetingID, at: noon.addingTimeInterval(-60))

        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: events.currentManualFace()))

        // The face is what says whose time this is, so moving it moves the reading -- which is exactly why manual
        // mode rotates rather than rewriting one face (see `ManualFace`).
        XCTAssertEqual(readout.read(at: noon).category?.id, breakID)
    }
}
