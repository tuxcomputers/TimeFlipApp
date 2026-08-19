@testable import FacetApp
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

    // MARK: - following a cube

    func testACubesFaceIsWhatTheReadingIsAbout() {
        // **The single answer the menu bar and the Faces tab both draw from.** They asked separately once, and a
        // launch with a cube connected then drew the face's category on the tab and the app's name in the menu bar.
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.deviceFace = { 5 }

        let reading = readout.read()

        XCTAssertEqual(reading.deviceFace, 5)
        XCTAssertEqual(reading.category?.id, 2)
    }

    func testACubeWinsOverWhatTheAppWasTimingByHand() {
        // A manual session is a stand-in for exactly the device that has turned up, so a reading taken while a cube is
        // connected is about the cube.
        startTiming(1, at: noon)
        XCTAssertEqual(readout.read(at: noon).category?.id, 1, "precondition: timing by hand")
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))

        readout.deviceFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).category?.id, 2)
    }

    func testTheLinkDroppingPutsTheManualSessionBack() {
        // Nothing has to be told: the face is asked for per reading, so a cube going away simply stops being the
        // answer and what the app is timing by hand is what is left.
        startTiming(1, at: noon)
        var face: Int? = 5
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.deviceFace = { face }
        XCTAssertEqual(readout.read(at: noon).category?.id, 2, "precondition: following the cube")

        face = nil

        XCTAssertEqual(readout.read(at: noon).category?.id, 1)
        XCTAssertNil(readout.read(at: noon).deviceFace)
    }

    func testACubesReadingIsNeverRunning() {
        // The app does not read the cube's history, so there is no segment of its own to call running -- whatever the
        // cube is doing, this app is not the thing measuring it.
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.deviceFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).state, .idle)
    }

    func testACubesReadingCarriesTheCategorysTotalForTheDay() {
        // The same figure a manual session shows, read the same way. Recorded here by hand, which is the only source
        // there is until the cube's history is ingested -- and exactly what makes the figure real rather than invented.
        startTiming(meetingID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).seconds, 300)
    }

    func testAFaceWhoseCategoryHasRecordedNothingReadsZero() {
        // Which is what every cube face reads today, the cube's own history not being ingested. It is a true answer,
        // not a missing one.
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 5))
        readout.deviceFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).seconds, 0)
    }

    func testAnUnassignedCubeFaceHasNothingToTotal() {
        readout.deviceFace = { 1 }

        XCTAssertEqual(readout.read(at: noon).seconds, 0)
    }

    func testTheTotalIsTheCategorysRatherThanTheFaces() {
        // Two faces, one category: the figure follows the category, so turning the cube between them shows the same
        // total rather than splitting it.
        startTiming(meetingID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 6))

        readout.deviceFace = { 5 }
        let first = readout.read(at: noon).seconds
        readout.deviceFace = { 6 }

        XCTAssertEqual(readout.read(at: noon).seconds, first)
    }

    func testAnUnassignedFaceReadsAsACubeWithNothingOnIt() {
        // Face 1 is seeded Unassigned. Still a cube, still a face -- there is simply no category to name.
        readout.deviceFace = { 1 }

        let reading = readout.read(at: noon)

        XCTAssertEqual(reading.deviceFace, 1)
        XCTAssertNil(reading.category)
    }

    // MARK: - timing by hand ignores the cube

    func testTimingByHandIgnoresACubeEntirely() {
        // Somebody offered manual mode and took it has said to get on without the device. A cube drifting into range
        // must not then appear in the menu bar and on the Faces tab, and must not take the click with it.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }
        XCTAssertEqual(readout.read(at: noon).category?.id, meetingID, "precondition: following the cube")

        readout.isTimingByHand = { true }

        let reading = readout.read(at: noon)
        XCTAssertNil(reading.deviceFace)
        XCTAssertEqual(reading.category?.id, breakID, "what the app is timing by hand")
        XCTAssertEqual(reading.state, .running, "and its clock, which the cube reading has none of")
    }

    func testItIsAskedPerReadingRatherThanOnce() {
        // The way back out of manual mode is a restart or forgetting the device, and pairing turns the mode off. That
        // has to reach the reading with nothing being told, which is only true if the question is asked every time.
        var byHand = true
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }
        readout.isTimingByHand = { byHand }
        XCTAssertNil(readout.read(at: noon).deviceFace, "precondition")

        byHand = false

        XCTAssertEqual(readout.read(at: noon).deviceFace, 5)
    }

    func testTimingByHandWithNoCubeIsTheOrdinaryReading() {
        // The commonest case of all -- nothing ever paired -- and it must be untouched by the gate.
        startTiming(meetingID, at: noon.addingTimeInterval(-60))
        readout.isTimingByHand = { true }

        XCTAssertEqual(readout.read(at: noon).category?.id, meetingID)
        XCTAssertEqual(readout.read(at: noon).state, .running)
    }

    /// A segment the cube reported, left open, which is what a history fetch writes for the interval it is on.
    private func cubeIsOn(face: Int, paused: Bool, at moment: Date) {
        events.record(
            DeviceEventSegment(
                eventNumber: 40,
                face: face,
                startedAt: moment,
                durationSeconds: 0,
                isPaused: paused
            )
        )
    }

    func testWhetherTheCubeIsPausedComesOutOfItsOwnOpenSegment() {
        // Every history frame carries the pause in its face byte, so the interval the cube reported is the answer --
        // no status read, and nothing to go stale between one fetch and the next.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))
        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, false, "precondition")

        // The next fetch brings the same interval back marked paused, which is what a double tap looks like.
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true)
    }

    func testACubeWithNoHistoryYetSaysNothingEitherWay() {
        // Nothing has been fetched, so there is no interval to read a pause off. Drawn as no glyph rather than as
        // running, which would be a claim about hardware on no evidence.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }

        XCTAssertNil(readout.read(at: noon).deviceIsPaused)
    }

    func testAnOpenSegmentOnAnotherFaceIsNotThisCubesPause() {
        // A manual segment left open when a cube arrives is still the newest open row, and its pause is the app's own.
        // Matching on the face is what keeps one from answering for the other.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }

        XCTAssertNil(readout.read(at: noon).deviceIsPaused)
    }

    func testAManualReadingCarriesNoDeviceState() {
        // There is no cube to be paused, so the field is empty rather than false -- "not paused" would be an answer
        // about hardware that is not there.
        startTiming(meetingID, at: noon.addingTimeInterval(-60))

        XCTAssertNil(readout.read(at: noon).deviceIsPaused)
    }

    func testTheCubesPauseIsNotTheAppsClock() {
        // A paused cube is still an idle *app*: nothing here is being measured by this process, so the status item's
        // tick must not start and the reading must not read as a session somebody could pause.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.deviceFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))

        let reading = readout.read(at: noon)
        XCTAssertEqual(reading.state, .idle)
        XCTAssertFalse(reading.isTiming(meetingID))
    }

    func testAReassignedFaceShowsUpOnTheNextRead() {
        readout.deviceFace = { 5 }
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        XCTAssertEqual(readout.read(at: noon).category?.id, 2, "precondition")

        XCTAssertTrue(faces.assign(categoryID: 1, toFace: 5))

        XCTAssertEqual(readout.read(at: noon).category?.id, 1)
    }
}
