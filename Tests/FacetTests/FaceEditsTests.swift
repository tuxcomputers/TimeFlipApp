@testable import FacetCore
import Foundation
import Testing

/// What the Faces tab does when one of its controls is used, against a real database and no window.
///
/// **The three gestures, and the interesting one is a click on a category**, which means three different things
/// depending on what the app is doing. Every one of those branches lived in `SettingsWindowController`, so reaching
/// them needed AppKit and a built controller -- which is why the two that refuse have never had a test, and why one
/// of them was found on hardware rather than here: with the cube on a locked face, clicking a category produced a
/// log row and nothing else at all.
///
/// **Seeded faces are what most of these turn on.** `database/008_face.sql` puts Meeting on face 2 and Break on
/// face 8 and locks both, which makes the locked case the ordinary one on a fresh database rather than an edge of
/// it.
@Suite @MainActor
final class FaceEditsTests {
    private let database: TemporaryDatabase
    private var connection: DatabaseConnection!
    private var faces: FaceStore!
    private var categories: CategoryStore!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!
    private var edits: FaceEdits!

    /// What the app is doing, which the two refusals turn on. Written by each test rather than derived, these being
    /// the closures a composition root supplies.
    private var isManualMode = true
    private var isLimitReached = false
    private var redraws = 0
    private var timingRedraws = 0

    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        faces = FaceStore(connection: connection)
        categories = CategoryStore(connection: connection)
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
            categories: categories,
            faces: faces,
            events: events,
            dayTotal: DayTotal(
                settings: SettingStore(connection: connection),
                entries: TimeEntryStore(connection: connection),
                events: events,
                faces: faces
            )
        )
        readout.isManualMode = { [self] in isManualMode }
        edits = FaceEdits(
            faces: faces,
            timing: readout,
            events: events,
            isManualMode: { [self] in isManualMode },
            isLimitReached: { [self] in isLimitReached },
            debugLog: nil
        )
        edits.changed = { [self] in redraws += 1 }
        edits.timingChanged = { [self] in timingRedraws += 1 }
    }

    deinit {
        database.remove()
    }

    private func category(_ name: String) throws -> CategoryRecord {
        let id = try #require(categories.insert(name: name))
        return try #require(categories.category(id: id))
    }

    /// A cube resting on `face`, as the app sees one.
    ///
    /// **Which face is a closure on `TimingReadout`, not a row**, and that is the point of it: the radio answers it
    /// live, so a reading taken a second later is about where the cube is now. `isManualMode` goes with it, being
    /// the one thing that stops the cube being asked about at all -- and both halves of the app read the same
    /// closure, which is why the test moves one variable.
    private func cubeRestingOn(_ face: Int) {
        isManualMode = false
        readout.isManualMode = { [self] in isManualMode }
        readout.cubeFace = { face }
    }

    // MARK: - clicking a category with no cube

    @Test func testAClickStartsTheClockAndRotatesOntoAManualFace() throws {
        let admin = try category("Admin")

        edits.start(admin, at: moment)

        let reading = readout.read()
        #expect(reading.timingState == .running)
        #expect(reading.category?.id == admin.id)
        #expect(ManualFace.all.contains(events.currentManualFace()), "the app's own faces, never a cube's")
        #expect(redraws == 1)
        #expect(timingRedraws == 1)
    }

    @Test func testASecondCategoryGoesOnTheNextManualFaceRatherThanTheOneJustFinished() throws {
        let admin = try category("Admin")
        let study = try category("Study")
        edits.start(admin, at: moment)
        let firstFace = events.currentManualFace()

        edits.start(study, at: moment.addingTimeInterval(60))

        // **What makes the outgoing segment's category safe whenever anything reads it.** Reusing the face would
        // leave the finished stretch pointing at a face now holding something else.
        #expect(events.currentManualFace() != firstFace)
        #expect(faces.categoryID(forFace: firstFace) == admin.id, "the closed segment still names what it timed")
        #expect(readout.read().category?.id == study.id)
    }

    @Test func testClickingTheCategoryAlreadyBeingTimedChangesNothing() throws {
        let admin = try category("Admin")
        edits.start(admin, at: moment)
        let face = events.currentManualFace()
        let before = redraws

        edits.start(admin, at: moment.addingTimeInterval(60))

        // Not a refusal and not a restart: the clock is where it should be. Restarting would rotate the face and
        // close a segment for a gesture that asked for no change.
        #expect(events.currentManualFace() == face)
        #expect(readout.read().timingState == .running)
        #expect(redraws == before, "nothing changed, so nothing is redrawn")
    }

    // MARK: - clicking a category with a cube

    @Test func testAClickWithACubeConnectedGivesItsFaceTheCategoryAndStartsNoClock() throws {
        let admin = try category("Admin")
        cubeRestingOn(3)

        edits.start(admin, at: moment.addingTimeInterval(60))

        #expect(faces.categoryID(forFace: 3) == admin.id)
        // **No segment, no clock.** The cube is doing the timing, so opening one here would be the app recording a
        // stretch it did not measure.
        #expect(events.currentManualFace() == ManualFace.first, "no manual face was taken")
        #expect(timingRedraws == 1, "the status item draws this reading too")
    }

    @Test func testALockedFaceKeepsWhatItHas() throws {
        let admin = try category("Admin")
        // Face 2 is seeded locked, holding Meeting.
        let before = faces.categoryID(forFace: 2)
        cubeRestingOn(2)

        edits.start(admin, at: moment.addingTimeInterval(60))

        #expect(faces.categoryID(forFace: 2) == before)
        #expect(redraws == 0, "nothing was written, so there is nothing to read back")
    }

    @Test func testALockedFaceIsWhatTheDrawingAsksToo() throws {
        cubeRestingOn(2)

        // **One answer read twice.** A row that looks live has to be one that does something, and this is the
        // question the list is drawn from.
        #expect(edits.click(for: readout.read()) == .faceIsLocked(2))
        #expect(!edits.click(for: readout.read()).doesAnything)
    }

    @Test func testClickingTheCategoryAFaceAlreadyHoldsChangesNothing() throws {
        let admin = try category("Admin")
        cubeRestingOn(3)
        edits.start(admin, at: moment.addingTimeInterval(60))
        let before = redraws

        edits.start(admin, at: moment.addingTimeInterval(120))

        #expect(redraws == before, "a deliberate no-op, and the log is what tells it from a list that has stopped")
    }

    @Test func testAPairedAppThatIsNotTimingByHandRefusesTheClick() throws {
        let admin = try category("Admin")
        // No cube reading and not manual: a device is on record and the app is neither following it nor timing by
        // hand. It is looking.
        isManualMode = false
        readout.isCubePaired = { true }

        edits.start(admin, at: moment)

        #expect(readout.read().timingState == .idle)
        #expect(faces.facesHolding(categoryID: admin.id).isEmpty)
        #expect(edits.click(for: readout.read()) == .waitingForTheDevice)
    }

    // MARK: - the clock

    @Test func testPausingClosesTheSegmentAndResumingOpensAnother() throws {
        let admin = try category("Admin")
        edits.start(admin, at: moment)

        let paused = edits.togglePause(at: moment.addingTimeInterval(60))

        #expect(paused?.timingState == .paused)
        #expect(readout.read().timingState == .paused, "and the table says so, not just the answer")

        let resumed = edits.togglePause(at: moment.addingTimeInterval(120))

        #expect(resumed?.timingState == .running)
    }

    @Test func testASpentLimitRefusesAResumeAndRedrawsNothing() throws {
        let admin = try category("Admin")
        edits.start(admin, at: moment)
        _ = edits.togglePause(at: moment.addingTimeInterval(60))
        let before = redraws
        isLimitReached = true

        let after = edits.togglePause(at: moment.addingTimeInterval(120))

        #expect(after == nil, "a refusal and nothing being timed are the same thing to a caller: do not repaint")
        #expect(readout.read().timingState == .paused)
        #expect(redraws == before)
    }

    @Test func testPausingWithNothingRunningDoesNothingAtAll() {
        let after = edits.togglePause(at: moment)

        #expect(after == nil)
        #expect(redraws == 0)
        #expect(timingRedraws == 0)
    }

    // MARK: - the lock

    @Test func testTheLockIsReadFromTheTableAndInverted() throws {
        cubeRestingOn(3)
        #expect(faces.isFaceLocked(face: 3) == false)

        edits.toggleLock()

        #expect(faces.isFaceLocked(face: 3) == true)
        #expect(redraws == 1)

        edits.toggleLock()

        #expect(faces.isFaceLocked(face: 3) == false)
    }

    @Test func testTheLockUsesTheFaceTheCubeIsOnNowRatherThanTheOneLastDrawn() throws {
        cubeRestingOn(3)
        // The cube is turned between the tab being drawn and the click landing, which is the case this reads the
        // face for rather than taking it from the control.
        cubeRestingOn(5)

        edits.toggleLock()

        #expect(faces.isFaceLocked(face: 5) == true)
        #expect(faces.isFaceLocked(face: 3) == false)
    }

    @Test func testTheLockWithNoCubeFaceWritesNothing() {
        edits.toggleLock()

        // Not reachable through the control, which is not drawn without a cube -- but a click landing as the link
        // drops would otherwise write to whatever face was last on screen.
        for face in 1 ... 12 {
            #expect(faces.isFaceLocked(face: face) == (face == 2 || face == 8), "only the seeded pair")
        }
        #expect(redraws == 0)
    }
}
