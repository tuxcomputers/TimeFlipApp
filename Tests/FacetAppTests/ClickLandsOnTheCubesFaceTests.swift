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
final class ClickLandsOnTheCubesFaceTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var categories: CategoryStore!
    private var faces: FaceStore!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!
    private var settings: SettingStore!
    private var manualMode: ManualMode!
    private var controller: SettingsWindowController!

    /// Face 5, which `008_face.sql` seeds *Unassigned* and unlocked. A cube face that will take a category, unlike
    /// the two the DDL seeds with one.
    private let freeFace = 5
    /// Face 2, seeded with Meeting **and locked**. The ordinary case on a fresh database, not an edge of it.
    private let lockedFace = 2

    override func setUpWithError() throws {
        try super.setUpWithError()
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
        // Turned on from a table with nothing paired, which is what a launch does. The tests that pair a device turn
        // it off again through `pairADevice`, so every state below is one a launch actually reaches.
        manualMode = ManualMode(debugLog: nil)
        manualMode.startIfNoDeviceIsPaired(settings)
        controller = SettingsWindowController(
            debugLog: nil,
            categories: categories,
            faces: faces,
            deviceEvents: events,
            timing: readout,
            entries: entries,
            settings: settings,
            manualMode: manualMode
        )
    }

    override func tearDown() {
        controller = nil
        manualMode = nil
        settings = nil
        readout = nil
        events = nil
        faces = nil
        categories = nil
        database.remove()
        super.tearDown()
    }

    /// A cube resting on `face`, answered per reading exactly as the radio answers it.
    private func cubeIsOn(_ face: Int) {
        readout.deviceFace = { face }
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
        XCTAssertEqual(readout.read().deviceFace, freeFace)
    }

    func testNoClockStarts() {
        // The cube is doing the timing and this app does not read its history yet, so a segment opened here would be
        // the app recording a stretch it never measured.
        cubeIsOn(freeFace)

        click("Break")

        XCTAssertEqual(openSegments, 0)
        XCTAssertEqual(readout.read().state, .idle)
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
        XCTAssertEqual(readout.read().state, .running)
        XCTAssertTrue(ManualFace.all.contains { faces.categoryID(forFace: $0) == id("Break") })
    }

    // MARK: - a paired app does not start timing by hand

    /// A device on record, as pairing leaves things: the table says so, and manual mode goes off.
    ///
    /// Both, because the app reads both -- `paired` is what a launch works out the mode from, and the mode is what a
    /// click asks. Setting one and not the other would be testing a state the app cannot be in.
    private func pairADevice() {
        XCTAssertTrue(
            database.execute("UPDATE setting SET setting_value = '{\"paired\":true}' WHERE setting_name = 'paired';")
        )
        manualMode.stop(because: "a device is paired")
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

    func testChoosingManualModeLetsTheSameClickThrough() {
        // The button on the offer, which is the only thing that turns it on with a device paired. Same click, same
        // state of the table, and the answer changes because the user answered.
        pairADevice()
        click("Break")
        XCTAssertEqual(openSegments, 0, "precondition: refused while paired")

        manualMode.start(because: "the cube could not be found and manual mode was chosen")
        click("Break")

        XCTAssertEqual(openSegments, 1)
        XCTAssertTrue(ManualFace.all.contains { faces.categoryID(forFace: $0) == id("Break") })
    }

    func testThePairingBeingRefusedIsNotACubeAssignmentEither() {
        // Neither branch: no face means nothing to assign to, and paired means nothing to start. The click does
        // nothing at all, which is the point -- there is no third thing for it to fall through to.
        pairADevice()

        click("Break")

        XCTAssertNil(readout.read().category)
        XCTAssertEqual(readout.read().state, .idle)
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
        readout.deviceFace = { face }
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
}
