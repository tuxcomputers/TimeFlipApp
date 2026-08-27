@testable import FacetApp
import AppKit
import XCTest

/// Clicking a category with a cube connected: the face the cube is resting on takes it, and no clock starts.
///
/// **Two gestures sharing one control**, which is why this is a file of its own rather than more cases in
/// `CreateStartsTimingTests`. With no cube, a click is "start timing this", and it rotates a manual face and opens a
/// segment. With a cube, the same click is "this face is that", and it writes one column of one row. The only thing
/// they share is where they start.
///
/// Against a real database, for the reason every test around this is: what is being checked is not that a method was
/// called, it is that `face` now names a different category and `device_event` does not. Those are rows.
@MainActor
final class ClickLandsOnTheCubesFaceTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var categories: CategoryStore!
    private var faces: FaceStore!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!
    private var settings: SettingStore!
    private var launchMode: LaunchMode = .manual
    private var controller: SettingsWindowController!

    /// Face 5, which `008_face.sql` seeds *Unassigned* and unlocked. A cube face that will take a category, unlike
    /// the two the DDL seeds with one.
    private let freeFace = 5
    /// Face 2, seeded with Meeting **and locked**. The ordinary case on a fresh database, not an edge of it.
    private let lockedFace = 2

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            let connection = database.connection()
            categories = CategoryStore(connection: connection)
            faces = FaceStore(connection: connection)
            settings = SettingStore(connection: connection)
            let entries = TimeEntryStore(connection: connection)
            events = DeviceEventRecorder(
                connection: connection,
                timezones: TimezoneStore(connection: connection),
                timeEntries: nil,
                debugLog: nil
            )
            readout = TimingReadout(
                categories: categories,
                faces: faces,
                events: events,
                dayTotal: DayTotal(settings: settings, entries: entries, events: events, faces: faces)
            )
            // Decided from a table with nothing paired, which is what a launch does. The tests that want the other mode
            // rebuild the controller through `pairADevice`, because a launch's mode is settled before it has a window and
            // cannot be moved afterwards -- see `LaunchMode`.
            // Built here rather than through `buildController`, which `setUpWithError` cannot reach: it overrides a
            // nonisolated method, so calling a `@MainActor` one on `self` from it is sending `self` across actors.
            launchMode = .manual
            controller = SettingsWindowController(
                debugLog: nil,
                categories: categories,
                faces: faces,
                deviceEvents: events,
                timing: readout,
                entries: entries,
                settings: settings,
                launchMode: launchMode
            )
        }
    }

    /// Builds the window's controller in the mode a launch would have decided on.
    ///
    /// **Rebuilt rather than reconfigured**, which is the whole shape of the rule: there is no way to hand a running
    /// controller a different mode, so a test that wants the other one is describing a different launch.
    private func buildController(mode: LaunchMode) {
        launchMode = mode
        controller = SettingsWindowController(
            debugLog: nil,
            categories: categories,
            faces: faces,
            deviceEvents: events,
            timing: readout,
            entries: entries,
            settings: settings,
            launchMode: mode
        )
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            // Put down rather than left on the run loop for the rest of the suite: the timer outlives the controller,
            // whose deallocation it does not notice.
            controller?.stopTicking()
            controller = nil
            settings = nil
            readout = nil
            events = nil
            faces = nil
            categories = nil
            database.remove()
        }
        super.tearDown()
    }

    /// A cube resting on `face`, answered per reading exactly as the radio answers it.
    private func cubeIsOn(_ face: Int) {
        readout.cubeFace = { face }
    }

    /// A row of the Faces tab's list being clicked, through the closure the row actually calls.
    private func click(_ name: String) {
        controller.select(.faces)
        guard let pane = controller.panes.selectedTabViewItem?.view as? FacesPane else {
            return XCTFail("the Faces tab is not on show")
        }
        guard let category = categories.matching(name: name).first else {
            return XCTFail("there is no category called \(name)")
        }
        pane.categoryList.onSelect?(category)
    }

    private func id(_ name: String) -> Int? {
        categories.matching(name: name).first?.id
    }

    private var openSegments: Int {
        Int(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;") ?? "0") ?? 0
    }

    /// A cube's own segment on `face`, which is what `HistoryIngestor` writes on every fetch: open, and as long as
    /// the cube has said it is.
    private func cubeHasBeenTiming(on face: Int, forSeconds seconds: Double, since: Date, paused: Bool = false) {
        events.record(
            DeviceEventSegment(
                eventNumber: 40,
                face: face,
                startedAt: since,
                durationSeconds: seconds,
                isPaused: paused
            )
        )
    }

    // MARK: - the Faces tab keeps up with a cube's clock

    func testTheTabTicksWhileACubeIsTiming() {
        // **The fix this exists for.** A followed cube leaves `state` idle for the whole session, and the tick was
        // started on `state` -- so the Timing column stood still while a cube timed and jumped a whole history
        // interval whenever a fetch redrew it. The figure was growing on every read the entire time.
        controller.isOnScreen = { true }
        controller.select(.faces)
        cubeIsOn(freeFace)
        XCTAssertTrue(faces.assign(categoryID: id("Break") ?? 0, toFace: freeFace))
        cubeHasBeenTiming(on: freeFace, forSeconds: 60, since: Date().addingTimeInterval(-60))

        controller.redrawTiming()

        XCTAssertTrue(controller.isRepaintTicking)
    }

    func testAPausedCubeStopsTheTick() {
        // A double tap on the cube arrives as a paused interval in the next fetch, and that fetch redraws this --
        // which is the moment the clock has to stop, not the next time somebody opens the window.
        controller.isOnScreen = { true }
        controller.select(.faces)
        cubeIsOn(freeFace)
        XCTAssertTrue(faces.assign(categoryID: id("Break") ?? 0, toFace: freeFace))
        cubeHasBeenTiming(on: freeFace, forSeconds: 60, since: Date().addingTimeInterval(-60))
        controller.redrawTiming()
        XCTAssertTrue(controller.isRepaintTicking, "precondition")

        cubeHasBeenTiming(on: freeFace, forSeconds: 60, since: Date().addingTimeInterval(-60), paused: true)
        controller.redrawTiming()

        XCTAssertFalse(controller.isRepaintTicking)
    }

    func testAWindowThatIsNotOnScreenDoesNotTick() {
        // A cube being turned redraws this whether or not anybody has the window open, and the figure is worked out
        // when it is drawn rather than counted up in here -- so a closed window misses nothing by standing still, and
        // a tick for it would be a wake-up a second for a view nobody can see.
        controller.isOnScreen = { false }
        controller.select(.faces)
        cubeIsOn(freeFace)
        XCTAssertTrue(faces.assign(categoryID: id("Break") ?? 0, toFace: freeFace))
        cubeHasBeenTiming(on: freeFace, forSeconds: 60, since: Date().addingTimeInterval(-60))

        controller.redrawTiming()

        XCTAssertFalse(controller.isRepaintTicking)
    }

    // MARK: - the face takes it

    func testTheFaceTheCubeIsOnTakesTheCategory() {
        cubeIsOn(freeFace)

        click("Break")

        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Break"))
    }

    func testTheReadingThenNamesIt() {
        // The whole point of writing the face rather than anything else: both surfaces draw the reading, and the
        // reading is the face's category, so the tab and the menu bar follow with nothing being told.
        cubeIsOn(freeFace)

        click("Break")

        XCTAssertEqual(readout.read().category?.id, id("Break"))
        XCTAssertEqual(readout.read().cubeFace, freeFace)
    }

    func testNoClockStarts() {
        // The cube is doing the timing and this app does not read its history yet, so a segment opened here would be
        // the app recording a stretch it never measured.
        cubeIsOn(freeFace)

        click("Break")

        XCTAssertEqual(openSegments, 0)
        XCTAssertEqual(readout.read().timingState, .idle)
        XCTAssertEqual(readout.read().seconds, 0)
    }

    func testTheManualFacesAreLeftAlone() {
        // The rotation exists so a finished manual segment cannot be reassigned underneath it. A click that landed on
        // the cube's face *and* on a manual face would put the category in two places at once.
        cubeIsOn(freeFace)

        click("Break")

        for face in ManualFace.all {
            XCTAssertNil(faces.categoryID(forFace: face), "manual face \(face) was written to")
        }
    }

    func testAnotherClickMovesTheSameFaceToTheNewCategory() {
        // One face is being said something about, repeatedly. It is not a rotation: there is one cube face in front of
        // the user and the second click is a correction of the first.
        cubeIsOn(freeFace)

        click("Break")
        click("Meeting")

        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Meeting"))
        XCTAssertEqual(openSegments, 0)
    }

    func testClickingWhatTheFaceAlreadyHoldsChangesNothing() {
        cubeIsOn(freeFace)
        click("Break")

        click("Break")

        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Break"))
        XCTAssertEqual(openSegments, 0)
    }

    // MARK: - a locked face keeps what it has

    func testALockedFaceRefusesTheCategory() {
        // Face 2 is seeded locked, holding Meeting. Locking is the user saying this face keeps what it has, and a
        // click is not an instruction strong enough to undo that.
        cubeIsOn(lockedFace)

        click("Break")

        XCTAssertEqual(faces.categoryID(forFace: lockedFace), id("Meeting"))
    }

    func testARefusedClickStartsNothingEither() {
        // The failure that would matter: falling through to the manual path and opening a segment, so a refused click
        // recorded time anyway.
        cubeIsOn(lockedFace)

        click("Break")

        XCTAssertEqual(openSegments, 0)
        for face in ManualFace.all {
            XCTAssertNil(faces.categoryID(forFace: face), "manual face \(face) was written to by a refused click")
        }
    }

    func testUnlockingTheFaceLetsTheSameClickThrough() {
        // Read at the point of use, so nothing has to be told the face was unlocked: the next click asks the table.
        cubeIsOn(lockedFace)
        click("Break")
        XCTAssertEqual(faces.categoryID(forFace: lockedFace), id("Meeting"), "precondition")

        XCTAssertTrue(database.execute("UPDATE face SET locked = 0 WHERE face_id = \(lockedFace);"))
        click("Break")

        XCTAssertEqual(faces.categoryID(forFace: lockedFace), id("Break"))
    }

    // MARK: - and without a cube, nothing changes

    func testWithNoCubeTheClickStillStartsTheClock() {
        // The manual path is untouched: this is a branch taken only when there is a face to take it, and the whole of
        // `CreateStartsTimingTests` still describes what happens otherwise.
        click("Break")

        XCTAssertEqual(openSegments, 1)
        XCTAssertEqual(readout.read().timingState, .running)
        XCTAssertTrue(ManualFace.all.contains { faces.categoryID(forFace: $0) == id("Break") })
    }

    // MARK: - a paired app does not start timing by hand

    /// A launch that found a device on record: the table says so, and the mode it decided on is `.device`.
    ///
    /// **Both, and set together at the start rather than flipped part way**, because the app reads both -- `paired`
    /// is what a launch decides the mode from, and the mode is what a click asks. Setting one without the other would
    /// be testing a state no launch reaches.
    ///
    /// The controller is rebuilt rather than told, since pairing a cube in front of a running window no longer
    /// changes what that window is (`LaunchMode`). What that case does instead is the test below it.
    private func pairADevice() {
        XCTAssertTrue(
            database.execute("UPDATE setting SET setting_value = '{\"paired\":true}' WHERE setting_name = 'paired';")
        )
        buildController(mode: .device)
    }

    func testAPairedAppDoesNotStartTimingByHand() {
        // The state this rule is about: a cube on record, out of reach at this moment, and nobody has said to get on
        // without it. A click that started the clock here would record against a category while the cube records
        // against whatever face it is sitting on, and whichever was read later would look like the answer.
        pairADevice()

        click("Break")

        XCTAssertEqual(openSegments, 0)
        for face in ManualFace.all {
            XCTAssertNil(faces.categoryID(forFace: face), "manual face \(face) was written to")
        }
    }

    func testADeviceLaunchThatGaveUpLookingStillDoesNotTimeByHand() {
        // **What the offer used to change, and no longer does.** Answering "Stop Looking" settles the reconnect loop
        // and nothing else: this is still a launch with a cube on record, so the click is still refused and the way
        // to the other answer is to forget the device and start the app again.
        //
        // The old version of this test pressed the offer's second button and expected the same click to go through.
        // That was the switching -- one launch being two things in turn -- and it is what `LaunchMode` removes.
        pairADevice()

        click("Break")

        XCTAssertEqual(openSegments, 0)
        for face in ManualFace.all {
            XCTAssertNil(faces.categoryID(forFace: face), "manual face \(face) was written to")
        }
    }

    func testPairingADeviceDoesNotStopAManualLaunchTimingByHand() {
        // The other direction, and the case the rule was stated for: a launch that started as its own clock goes on
        // being one, whatever appears on the Device tab while it runs. The Connection row is where that is admitted
        // to -- "Connected, not used until restart" (`DeviceInfoRules.connection`) -- rather than the app quietly
        // handing the clock over half way through a day.
        XCTAssertTrue(
            database.execute("UPDATE setting SET setting_value = '{\"paired\":true}' WHERE setting_name = 'paired';")
        )

        click("Break")

        XCTAssertEqual(openSegments, 1, "the launch is still its own clock")
        XCTAssertTrue(ManualFace.all.contains { faces.categoryID(forFace: $0) == id("Break") })
    }

    func testThePairingBeingRefusedIsNotACubeAssignmentEither() {
        // Neither branch: no face means nothing to assign to, and paired means nothing to start. The click does
        // nothing at all, which is the point -- there is no third thing for it to fall through to.
        pairADevice()

        click("Break")

        XCTAssertNil(readout.read().category)
        XCTAssertEqual(readout.read().timingState, .idle)
    }

    func testAPairedAppWithItsCubeInFrontOfItStillTakesTheClick() {
        // The ordinary paired case, and the reason the cube branch is ahead of this guard: there *is* somewhere for
        // the click to land, and it is the face on screen.
        pairADevice()
        cubeIsOn(freeFace)

        click("Break")

        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Break"))
        XCTAssertEqual(openSegments, 0)
    }

    func testTheLinkDroppingLeavesAPairedAppRefusing() {
        // Asked per click, so nothing has to be told: the cube going away stops being the answer, and what is left is
        // a paired app that has not been told to get on without one.
        pairADevice()
        var face: Int? = freeFace
        readout.cubeFace = { face }
        click("Break")
        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Break"), "precondition: the cube's face took it")

        face = nil
        click("Meeting")

        XCTAssertEqual(openSegments, 0, "the clock started by hand under a pairing")
        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Break"), "the cube's face kept what it was given")
    }

    func testCreatingOneOnTheFacesTabIsRefusedWhilePairedToo() {
        // The create shares the path, so it shares the rule. A category is still made -- the list is a list -- but
        // nothing is timed against it.
        pairADevice()
        controller.select(.faces)
        guard let pane = controller.panes.selectedTabViewItem?.view as? FacesPane else {
            return XCTFail("the Faces tab is not on show")
        }

        pane.createControl.onSave?("Drafting")

        XCTAssertNotNil(id("Drafting"), "the category was not created at all")
        XCTAssertEqual(openSegments, 0)
    }

    // MARK: - creating one lands the same way

    func testCreatingACategoryOnTheFacesTabLandsOnTheCubesFace() {
        // Creating on this tab is saying what you are doing now, so it goes where a click goes -- which the archive
        // gave as the reason the create lives on this tab at all rather than in the shared control.
        cubeIsOn(freeFace)
        controller.select(.faces)
        guard let pane = controller.panes.selectedTabViewItem?.view as? FacesPane else {
            return XCTFail("the Faces tab is not on show")
        }

        pane.createControl.onSave?("Drafting")

        XCTAssertEqual(faces.categoryID(forFace: freeFace), id("Drafting"))
        XCTAssertEqual(openSegments, 0, "a create with a cube connected started a clock")
    }

    // MARK: - the list says what the click will do

    /// Brings the Faces tab up **and makes it reload**.
    ///
    /// Away and back, deliberately. Faces is the tab a controller starts on, so selecting it changes nothing and the
    /// tab view's delegate never fires -- which is what fills the list and applies the rule to it. A real window gets
    /// there by being opened; a test has to ask for a switch that is actually a switch.
    private func showFacesTab() -> FacesPane? {
        controller.select(.categories)
        controller.select(.faces)
        return controller.panes.selectedTabViewItem?.view as? FacesPane
    }

    /// Every category row currently drawn on the Faces tab.
    private func rows() -> [CategoryRowView] {
        guard let pane = showFacesTab() else { return [] }
        func walk(_ view: NSView) -> [CategoryRowView] {
            (view as? CategoryRowView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(pane.categoryList)
    }

    private func timingView() -> TimingView? {
        showFacesTab()?.timingView
    }

    func testAnUnlockedFaceLeavesTheRowsLive() {
        cubeIsOn(freeFace)

        XCTAssertFalse(rows().isEmpty, "no rows to check")
        XCTAssertTrue(rows().allSatisfy(\.isEnabled))
    }

    func testALockedFaceDrawsTheRowsDead() {
        // The whole point of the rule being a value: the refusal was invisible, so a click that did nothing read as a
        // list that had stopped responding. Watched happening on hardware before this existed.
        cubeIsOn(lockedFace)

        XCTAssertFalse(rows().isEmpty, "no rows to check")
        XCTAssertTrue(rows().allSatisfy { !$0.isEnabled })
    }

    func testAPairedAppStillLookingDrawsThemDeadToo() {
        // The other refusal, and it has to look the same: in both cases a click does nothing, and the reason is
        // elsewhere on the screen rather than in the list.
        pairADevice()

        XCTAssertTrue(rows().allSatisfy { !$0.isEnabled })
    }

    func testTimingByHandLeavesThemLive() {
        XCTAssertTrue(rows().allSatisfy(\.isEnabled))
    }

    func testUnlockingTheFaceBringsTheRowsBack() {
        cubeIsOn(lockedFace)
        XCTAssertTrue(rows().allSatisfy { !$0.isEnabled }, "precondition")

        XCTAssertTrue(faces.setLocked(false, face: lockedFace))
        controller.redrawTiming()

        XCTAssertTrue(rows().allSatisfy(\.isEnabled))
    }

    // MARK: - the lock in the corner

    func testTheLockIsDrawnForTheFaceOnShow() {
        cubeIsOn(lockedFace)
        controller.redrawTiming()

        XCTAssertEqual(timingView()?.lockButton.isHidden, false)
        XCTAssertEqual(timingView()?.lockButton.contentTintColor, .systemRed)
    }

    func testThereIsNoLockWithoutACube() {
        controller.redrawTiming()

        XCTAssertEqual(timingView()?.lockButton.isHidden, true)
    }

    func testPressingTheLockLocksTheFaceTheCubeIsOn() {
        cubeIsOn(freeFace)
        controller.redrawTiming()
        XCTAssertEqual(faces.isLocked(face: freeFace), false, "precondition")

        timingView()?.onToggleLock?()

        XCTAssertEqual(faces.isLocked(face: freeFace), true)
    }

    func testPressingItAgainUnlocksIt() {
        cubeIsOn(lockedFace)
        controller.redrawTiming()

        timingView()?.onToggleLock?()

        XCTAssertEqual(faces.isLocked(face: lockedFace), false)
    }

    func testLockingImmediatelyRefusesTheNextClick() {
        // The two halves meeting: the lock is written, the tab is redrawn from the table, and the click that follows
        // reads the same answer. Nothing is told -- both ends ask.
        cubeIsOn(freeFace)
        controller.redrawTiming()

        timingView()?.onToggleLock?()
        click("Break")

        XCTAssertNil(faces.categoryID(forFace: freeFace), "a locked face took a category")
        XCTAssertTrue(rows().allSatisfy { !$0.isEnabled })
    }

    func testTheLockFollowsTheFaceRatherThanWhatWasDrawn() {
        // The cube can be turned between the tab being drawn and the click landing, so the toggle reads the face now
        // rather than acting on the one the button was drawn for.
        var face = freeFace
        readout.cubeFace = { face }
        controller.redrawTiming()

        face = 6
        timingView()?.onToggleLock?()

        XCTAssertEqual(faces.isLocked(face: 6), true, "the face the cube is on now")
        XCTAssertEqual(faces.isLocked(face: freeFace), false, "not the one the lock was drawn for")
    }
}
