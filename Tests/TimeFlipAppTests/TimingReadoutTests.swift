@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers the one answer both views draw from: which category is being timed, whether its clock is running, and
/// how much time it has today.
///
/// Against a real database, because that is the whole claim -- every field is read when it is asked for, so a row
/// changed behind the app's back shows up on the next read with nothing being told.
@MainActor
final class TimingReadoutTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var connection: DatabaseConnection!
    private var session: TimingSession!
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
        session = TimingSession()
        faces = FaceStore(connection: connection)
        // Wired to the time entry recorder as `main.swift` wires it, so closing a segment records it. The figure is
        // summed from `time_entry`, so a recorder with nowhere to hand a finished stretch would show none of it.
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: TimeEntryRecorder(
                connection: connection,
                settings: SettingReader(connection: connection),
                faces: faces,
                debugLog: nil
            ),
            debugLog: nil
        )
        readout = TimingReadout(
            session: session,
            categories: CategoryStore(connection: connection),
            faces: faces,
            events: events,
            dayTotal: DayTotal(
                settings: SettingReader(connection: connection),
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
        session = nil
        connection = nil
        database.remove()
        super.tearDown()
    }

    /// What the window does when a category is picked: the next face takes it, a segment opens on it, the clock
    /// starts.
    private func startTiming(_ categoryID: Int, at moment: Date) {
        let face = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        events.closeOpenSegment(at: moment)
        XCTAssertTrue(faces.assign(categoryID: categoryID, toFace: face))
        events.startSegment(face: face, at: moment)
        session.start(categoryID: categoryID)
    }

    // MARK: - nothing being timed

    func testAFreshDatabaseIsIdle() {
        // Face 13 has never been used and holds no category, so there is nothing to name and nothing to total.
        XCTAssertEqual(readout.read(at: noon), .idle)
    }

    func testAFaceHoldingNoCategoryIsIdleEvenWithTheClockRunning() {
        // The clock says it is running and the face says there is nothing to run: the face wins, because a session
        // drawn against no category would have no name, no icon and no total.
        events.startSegment(face: ManualFace.first, at: noon.addingTimeInterval(-60))
        session.start(categoryID: breakID)

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

    func testPausingStopsTheFigureWithoutLosingIt() {
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        events.closeOpenSegment(at: noon.addingTimeInterval(-180))
        session.togglePause()

        let reading = readout.read(at: noon)

        XCTAssertEqual(reading.state, .paused)
        // The two minutes since the pause are not counted, and the two before it are not thrown away. Neither takes
        // a special case here: pausing closed the segment, so there is no live part left to add.
        XCTAssertEqual(reading.seconds, 120)
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
