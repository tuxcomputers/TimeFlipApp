@testable import FacetApp
import AppKit
import XCTest

/// Creating a category on the Faces tab starts it; creating one on the Categories tab does not.
///
/// **The two tabs are asking different things**, which is why one control behaves differently from the other despite
/// being the same control. Typing a name on the Categories tab is maintaining a list. Typing one on the Faces tab is
/// saying what you are doing now, and making somebody create a category and then click the row they just made is
/// asking them to say it twice.
///
/// Built on a real database rather than on doubles, because what is being checked is not that a method was called: it
/// is that a face now holds the category and a segment is open against it. Those are rows, and only the tables can
/// say whether they are there.
@MainActor
final class CreateStartsTimingTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var categories: CategoryStore!
    private var faces: FaceStore!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!
    private var controller: SettingsWindowController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        _ = try database.bootstrap()
        let connection = database.connection()
        categories = CategoryStore(connection: connection)
        faces = FaceStore(connection: connection)
        let settings = SettingStore(connection: connection)
        let entries = TimeEntryStore(connection: connection)
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: nil,
            debugLog: nil
        )
        let dayTotal = DayTotal(settings: settings, entries: entries, events: events, faces: faces)
        readout = TimingReadout(categories: categories, faces: faces, events: events, dayTotal: dayTotal)
        // **Decided the way a launch decides it**, from a table with nothing paired, rather than set by hand. The
        // clock only starts by hand while the app is its own clock, so a controller with no `LaunchMode` refuses every
        // start -- and a test that skipped this would be describing a state no launch reaches.
        controller = SettingsWindowController(
            debugLog: nil,
            categories: categories,
            faces: faces,
            deviceEvents: events,
            timing: readout,
            entries: entries,
            settings: settings,
            launchMode: LaunchMode.decided(from: settings, debugLog: nil)
        )
    }

    override func tearDown() {
        controller = nil
        database.remove()
        super.tearDown()
    }

    /// The name typed into a pane's create control, committed the way the button commits it.
    private func create(_ name: String, on pane: SettingsTab) {
        controller.select(pane)
        let control: CategoryCreateControl?
        switch controller.panes.selectedTabViewItem?.view {
        case let faces as FacesPane: control = faces.createControl
        case let categories as CategoriesPane: control = categories.createControl
        default: control = nil
        }
        control?.onSave?(name)
    }

    private var openSegments: Int {
        Int(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;") ?? "0") ?? 0
    }

    private func categoryID(named name: String) -> Int? {
        categories.matching(name: name).first?.id
    }

    // MARK: - the Faces tab

    func testCreatingOnFacesAssignsItToAFaceAndStartsIt() {
        create("Drafting", on: .faces)

        let id = try? XCTUnwrap(categoryID(named: "Drafting"))
        XCTAssertNotNil(id, "the category was not created at all")
        guard let id else { return }

        XCTAssertTrue(
            ManualFace.all.contains { faces.categoryID(forFace: $0) == id },
            "no manual face holds the category that was just created"
        )
        XCTAssertEqual(openSegments, 1, "creating it on the Faces tab did not start the clock")
        XCTAssertEqual(readout.read().category?.id, id)
    }

    func testCreatingASecondOneMovesTheClockToIt() {
        // The same thing clicking a row does: the stretch that was running ends and the new one begins, so a create
        // cannot leave two segments open or leave the clock on the category before it.
        create("Drafting", on: .faces)
        create("Reviewing", on: .faces)

        XCTAssertEqual(openSegments, 1, "the first segment was left open")
        XCTAssertEqual(readout.read().category?.name, "Reviewing")
    }

    func testTheTwoCategoriesAreOnDifferentFaces() {
        // `startTiming` rotates the manual face precisely so a finished segment's category cannot be reassigned
        // underneath it. A create that started the clock without rotating would undo that.
        create("Drafting", on: .faces)
        let first = try? XCTUnwrap(categoryID(named: "Drafting"))
        create("Reviewing", on: .faces)
        let second = try? XCTUnwrap(categoryID(named: "Reviewing"))

        let firstFace = ManualFace.all.first { faces.categoryID(forFace: $0) == first }
        let secondFace = ManualFace.all.first { faces.categoryID(forFace: $0) == second }
        XCTAssertNotNil(firstFace)
        XCTAssertNotNil(secondFace)
        XCTAssertNotEqual(firstFace, secondFace, "the second category took the face the first one is on")
    }

    // MARK: - the Categories tab

    func testCreatingOnCategoriesLeavesTheClockAlone() {
        // The list is being maintained, not the day. A category made here starting the clock would record time
        // against something nobody said they had started doing.
        create("Filing", on: .categories)

        XCTAssertNotNil(categoryID(named: "Filing"), "the category was not created")
        XCTAssertEqual(openSegments, 0, "creating it on the Categories tab started the clock")
    }

    func testCreatingOnCategoriesDoesNotDisturbAClockAlreadyRunning() {
        create("Drafting", on: .faces)
        let running = readout.read().category?.id

        create("Filing", on: .categories)

        XCTAssertEqual(openSegments, 1, "the running segment was closed or a second was opened")
        XCTAssertEqual(readout.read().category?.id, running, "the clock moved to the new category")
    }
}
