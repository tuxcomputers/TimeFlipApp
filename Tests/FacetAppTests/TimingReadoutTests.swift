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
final class TimingReadoutTests: XCTestCase, @unchecked Sendable {
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
        try MainActor.assumeIsolated {
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
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            readout = nil
            events = nil
            faces = nil
            connection = nil
            database.remove()
        }
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

    func testAFollowedCubeIsReachable() {
        // The other side of the pair, so the flag cannot quietly default the wrong way and refuse every click.
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertTrue(readout.read(at: noon).isCubeConnected)
    }

    func testAManualReadingHasNothingToReach() {
        // No face, so nothing to reach and nothing for the flag to be about.
        startTiming(1, at: noon)

        XCTAssertFalse(readout.read(at: noon).isCubeConnected)
    }

    func testACubesFaceIsWhatTheReadingIsAbout() {
        // **The single answer the menu bar and the Faces tab both draw from.** They asked separately once, and a
        // launch with a cube connected then drew the face's category on the tab and the app's name in the menu bar.
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.cubeFace = { 5 }

        let reading = readout.read()

        XCTAssertEqual(reading.cubeFace, 5)
        XCTAssertEqual(reading.category?.id, 2)
    }

    func testACubeWinsOverWhatTheAppWasTimingByHand() {
        // A manual session is a stand-in for exactly the device that has turned up, so a reading taken while a cube is
        // connected is about the cube.
        startTiming(1, at: noon)
        XCTAssertEqual(readout.read(at: noon).category?.id, 1, "precondition: timing by hand")
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))

        readout.cubeFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).category?.id, 2)
    }

    func testTheLinkDroppingPutsTheManualSessionBackWhenNothingIsPaired() {
        // **With no cube on record**, which is the case this describes and the only one it is true of. The face is
        // asked for per reading, so a cube going away simply stops being the answer and what the app is timing by
        // hand is what is left. A *paired* cube going away is the test below, and is a different situation.
        startTiming(1, at: noon)
        var face: Int? = 5
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.cubeFace = { face }
        XCTAssertEqual(readout.read(at: noon).category?.id, 2, "precondition: following the cube")

        face = nil

        XCTAssertEqual(readout.read(at: noon).category?.id, 1)
        XCTAssertNil(readout.read(at: noon).cubeFace)
    }

    // MARK: - a paired cube that has gone quiet

    func testAPairedCubeGoingAwayDoesNotBecomeAManualSession() {
        // **The bug this exists for.** A link drops, `cubeFace` goes with it, and the reading fell through to the
        // app's own faces -- so the menu bar drew a category on face 13 that nobody had picked, ticking, while the
        // Device tab said the cube was unreachable and the launch was not a manual one throughout. Two pictures of one
        // question. The archive kept them apart with a `reconnecting` case, "so the menu bar keeps showing the last
        // known activity/icon instead of tearing down to an unpaired look".
        startTiming(1, at: noon)
        var face: Int? = 5
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        // The cube's own record of what it is on, which is what `HistoryIngestor` puts here on every fetch. It is
        // what the reading falls back to once the link cannot be asked any more.
        _ = events.record(
            DeviceEventSegment(eventNumber: 7, face: 5, startedAt: noon, durationSeconds: 30, isPaused: false)
        )
        readout.cubeFace = { face }
        readout.isCubePaired = { true }
        XCTAssertEqual(readout.read(at: noon).category?.id, 2, "precondition: following the cube")

        face = nil

        // Still the cube's face and the cube's category, out of its own record, rather than the manual one.
        let reading = readout.read(at: noon)
        XCTAssertEqual(reading.cubeFace, 5)
        XCTAssertEqual(reading.category?.id, 2)
        XCTAssertNotEqual(reading.category?.id, 1, "the app's own session must not take the picture over")
        // **Drawn is not reachable.** The face is worth showing and the cube is not there to be sent anything, which
        // is what keeps a click refused rather than assigning a category to a device nobody can hear.
        XCTAssertFalse(reading.isCubeConnected)
    }

    func testACubeOutOfRangeGoesOnCounting() {
        // **The cube keeps timing whether this app can hear it or not**, and the figure here is worked out from its
        // open row and this machine's clock rather than from anything the link would have carried -- so freezing it
        // while the cube is out of range would show a number the very next read disagrees with. The archive kept its
        // clock running through a reconnect for the same reason ("keeps showing the last known activity/icon instead
        // of tearing down").
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))
        readout.isCubePaired = { true }
        readout.cubeFace = { nil }

        let reading = readout.read(at: noon)

        XCTAssertTrue(reading.isCounting)
        XCTAssertFalse(reading.isCubeConnected, "counting, and still nothing anybody may send a command to")
        XCTAssertEqual(reading.seconds, 60)
    }

    func testACubeOutOfRangeAndPausedIsNotCounting() {
        // Its last word was that it had stopped, and that is as true out of range as in it.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-60))
        readout.isCubePaired = { true }
        readout.cubeFace = { nil }

        XCTAssertFalse(readout.read(at: noon).isCounting)
    }

    func testAPairedCubeThatHasReportedNothingShowsNothing() {
        // A cube on record that has never reported a face this launch. There is nothing of its to show, and the app's
        // own faces are not its stand-in: the item falls back to the app's name rather than to a session.
        readout.isCubePaired = { true }
        readout.cubeFace = { nil }

        let reading = readout.read(at: noon)

        XCTAssertNil(reading.cubeFace)
        XCTAssertNil(reading.category)
        XCTAssertEqual(reading.state, .idle)
    }

    func testTakingManualModeStillWinsOverAPairedCube() {
        // Somebody answered the offer, so the cube is not consulted at all for the rest of the launch -- pairing on
        // record or not. Without this the fix above would strand them: the cube they said to get on without would go
        // on owning the picture.
        startTiming(1, at: noon)
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.isCubePaired = { true }
        readout.isManualMode = { true }

        XCTAssertEqual(readout.read(at: noon).category?.id, 1)
        XCTAssertNil(readout.read(at: noon).cubeFace)
    }

    func testACubesReadingIsNeverRunning() {
        // The app does not read the cube's history, so there is no segment of its own to call running -- whatever the
        // cube is doing, this app is not the thing measuring it.
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).state, .idle)
    }

    func testAConnectedCubeTimingIsCounting() {
        // **The fix this exists for.** A followed cube leaves `state` idle for the whole session, and both surfaces
        // started their tick on `state` -- so with a cube connected the menu bar and the Faces tab never ticked at
        // all, and the figure they drew was repainted only when a history fetch happened to redraw them. It was
        // growing on every read the whole time.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))

        let reading = readout.read(at: noon)

        XCTAssertTrue(reading.isCounting)
        XCTAssertEqual(reading.state, .idle, "and still no clock of this app's own")
    }

    func testTheFigureFollowsThisMachinesClockBetweenFetches() {
        // The elapsed part comes from the open row's `start_epoch` and the clock, so it moves second by second
        // rather than in the steps a history fetch would leave. What the cube itself measured lands in
        // `duration_seconds` on the next fetch and is not what either surface draws in between.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(readout.read(at: noon).seconds, 60)
        XCTAssertEqual(readout.read(at: noon.addingTimeInterval(45)).seconds, 105, "no row written in between")
    }

    func testAPausedCubeIsNotCounting() {
        // Nothing is being recorded, so there is nothing for a tick to keep up with -- and a figure counting up
        // beside a paused cube would be the app inventing time the cube says was not spent.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-60))

        XCTAssertFalse(readout.read(at: noon).isCounting)
    }

    func testACubeThatHasNotBeenHeardFromYetIsNotCounting() {
        // Connected, on a face, and no history fetched: there is no open row behind the figure, so the figure is
        // standing still and saying otherwise would start a tick over nothing.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertFalse(readout.read(at: noon).isCounting)
    }

    func testAManualSessionIsCountingWhileItRuns() {
        // The same field, for the app's own clock, so whoever draws has one thing to tick on whichever picture the
        // reading turns out to be.
        startTiming(meetingID, at: noon.addingTimeInterval(-60))
        XCTAssertTrue(readout.read(at: noon).isCounting)

        events.closeOpenSegment(at: noon)

        XCTAssertFalse(readout.read(at: noon).isCounting)
    }

    func testACubesReadingCarriesTheCategorysTotalForTheDay() {
        // The same figure a manual session shows, read the same way. Recorded here by hand, which is the only source
        // there is until the cube's history is ingested -- and exactly what makes the figure real rather than invented.
        startTiming(meetingID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).seconds, 300)
    }

    func testAFaceWhoseCategoryHasRecordedNothingReadsZero() {
        // Which is what every cube face reads today, the cube's own history not being ingested. It is a true answer,
        // not a missing one.
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).seconds, 0)
    }

    func testAnUnassignedCubeFaceHasNothingToTotal() {
        readout.cubeFace = { 1 }

        XCTAssertEqual(readout.read(at: noon).seconds, 0)
    }

    func testTheTotalIsTheCategorysRatherThanTheFaces() {
        // Two faces, one category: the figure follows the category, so turning the cube between them shows the same
        // total rather than splitting it.
        startTiming(meetingID, at: noon.addingTimeInterval(-600))
        events.closeOpenSegment(at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 6))

        readout.cubeFace = { 5 }
        let first = readout.read(at: noon).seconds
        readout.cubeFace = { 6 }

        XCTAssertEqual(readout.read(at: noon).seconds, first)
    }

    func testAnUnassignedFaceReadsAsACubeWithNothingOnIt() {
        // Face 1 is seeded Unassigned. Still a cube, still a face -- there is simply no category to name.
        readout.cubeFace = { 1 }

        let reading = readout.read(at: noon)

        XCTAssertEqual(reading.cubeFace, 1)
        XCTAssertNil(reading.category)
    }

    // MARK: - timing by hand ignores the cube

    func testTimingByHandIgnoresACubeEntirely() {
        // Somebody offered manual mode and took it has said to get on without the device. A cube drifting into range
        // must not then appear in the menu bar and on the Faces tab, and must not take the click with it.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        XCTAssertEqual(readout.read(at: noon).category?.id, meetingID, "precondition: following the cube")

        readout.isManualMode = { true }

        let reading = readout.read(at: noon)
        XCTAssertNil(reading.cubeFace)
        XCTAssertEqual(reading.category?.id, breakID, "what the app is timing by hand")
        XCTAssertEqual(reading.state, .running, "and its clock, which the cube reading has none of")
    }

    func testItIsAskedPerReadingRatherThanOnce() {
        // The way back out of manual mode is a restart or forgetting the device, and pairing turns the mode off. That
        // has to reach the reading with nothing being told, which is only true if the question is asked every time.
        var byHand = true
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        readout.isManualMode = { byHand }
        XCTAssertNil(readout.read(at: noon).cubeFace, "precondition")

        byHand = false

        XCTAssertEqual(readout.read(at: noon).cubeFace, 5)
    }

    func testTimingByHandWithNoCubeIsTheOrdinaryReading() {
        // The commonest case of all -- nothing ever paired -- and it must be untouched by the gate.
        startTiming(meetingID, at: noon.addingTimeInterval(-60))
        readout.isManualMode = { true }

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
        readout.cubeFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))
        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, false, "precondition")

        // The next fetch brings the same interval back marked paused, which is what a double tap looks like.
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true)
    }

    func testACubeWithNoHistoryAndNothingAskedSaysNothingEitherWay() {
        // Nothing fetched and the cube not asked, so there is nothing to read a pause off at all. Drawn as no glyph
        // rather than as running, which would be a claim about hardware on no evidence.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertNil(readout.read(at: noon).deviceIsPaused)
    }

    func testBeforeAnyHistoryTheCubesOwnAnswerDrawsTheGlyph() {
        // **The first seconds of a launch.** The app asks the cube how it is well before the first history fetch
        // lands, so without this the glyph is missing for exactly the moment somebody is watching the app start.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        readout.cubeSaysPaused = { true }

        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true)
    }

    func testOnceThereIsHistoryTheRowWinsOverWhatTheCubeSaid() {
        // The row is an interval the cube recorded; the answer to `0x10` is a snapshot of the moment it was asked,
        // and a locked cube reports itself paused whatever its pause byte says. So the row takes over the moment
        // there is one, and goes on winning.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }
        readout.cubeSaysPaused = { true }
        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true, "precondition: nothing but the cube's answer yet")

        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, false)
    }

    func testAnOpenSegmentOnAnotherFaceIsNotThisCubesPause() {
        // A manual segment left open when a cube arrives is still the newest open row, and its pause is the app's own.
        // Matching on the face is what keeps one from answering for the other.
        startTiming(breakID, at: noon.addingTimeInterval(-300))
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        readout.cubeFace = { 5 }

        XCTAssertNil(readout.read(at: noon).deviceIsPaused)
    }

    func testAManualSegmentOpenOnTopDoesNotHideTheCubesPause() {
        // **The hole this closes.** The pause was read off `openSegment()`, and a manual segment carries the epoch as
        // its event number, so it is very often the newest open row -- which meant the glyph vanished under a
        // perfectly connected cube as soon as both clocks had been used in one launch. Asking by face cannot be
        // answered by a manual row at all.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-120))
        startTiming(breakID, at: noon.addingTimeInterval(-60))
        readout.cubeFace = { 5 }

        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true)
    }

    func testAQuietCubeGoesOnSayingWhatTheColumnSays() {
        // **Connected or not, the glyph is the `paused` column.** It is the cube's own account of what it was doing,
        // out of its own history, so a link going down does not change the answer -- it only stops it being
        // refreshed. Drawing no glyph instead would tear down exactly the "last known activity" the archive kept.
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 5))
        cubeIsOn(face: 5, paused: true, at: noon.addingTimeInterval(-120))
        readout.isCubePaired = { true }
        readout.cubeFace = { 5 }
        XCTAssertEqual(readout.read(at: noon).deviceIsPaused, true, "precondition: paused while connected")

        readout.cubeFace = { nil }

        let reading = readout.read(at: noon)
        XCTAssertEqual(reading.cubeFace, 5, "still the cube's face")
        XCTAssertEqual(reading.deviceIsPaused, true, "and still the cube's pause")
        XCTAssertFalse(reading.isCubeConnected, "but not a cube anything may be sent to")
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
        readout.cubeFace = { 5 }
        cubeIsOn(face: 5, paused: false, at: noon.addingTimeInterval(-60))

        let reading = readout.read(at: noon)
        XCTAssertEqual(reading.state, .idle)
        XCTAssertFalse(reading.isTiming(meetingID))
    }

    func testAReassignedFaceShowsUpOnTheNextRead() {
        readout.cubeFace = { 5 }
        XCTAssertTrue(faces.assign(categoryID: 2, toFace: 5))
        XCTAssertEqual(readout.read(at: noon).category?.id, 2, "precondition")

        XCTAssertTrue(faces.assign(categoryID: 1, toFace: 5))

        XCTAssertEqual(readout.read(at: noon).category?.id, 1)
    }
}
