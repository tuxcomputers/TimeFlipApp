@testable import FacetApp
import AppKit
import XCTest

/// Covers what the Device tab's Name row does when a name is committed: what reaches the cube, what does not, and what
/// the `device_name` row is allowed to say afterwards.
///
/// **On a real database rather than on doubles**, for the reason `AutoPauseSettlesBeforeItIsSentTests` is on one: the
/// claim is that the row did or did not move, and only the table can say. The log is real for the same reason -- a
/// refusal that says which kind it was is half of what is being asserted.
///
/// **What cannot be here is a cube that takes the write.** `swift test` never touches a radio, so every rename below
/// ends in a refusal of one kind or another, which is exactly the half worth pinning hermetically: it is the half
/// that must leave the table alone. That a cube takes `0x15`, that the row follows it, and that the cube is still
/// found on the next launch is `Tests/Scripted/66-device-rename.sh`, against real hardware.
///
/// **Committed through `onCommit`, which is what Return produces.** `EditableNameCellTests` is where that link is
/// pinned -- Return commits, a click elsewhere does not -- so driving a real key event here would be testing that
/// cell a second time rather than testing the window it is wired to.
@MainActor
final class RenamingTheCubeReachesItFirstTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    private var debugLog: DebugLog!
    /// The cube this app is paired to, as far as the table is concerned.
    private let cube = UUID(uuidString: "0BE1F1CE-0000-4000-8000-000000000001")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            _ = try database.bootstrapDebug()
            settings = SettingStore(connection: database.connection())
            debugLog = DebugLog(databaseURL: database.debugURL)
            // **The state the Name row opens in**, which is the only one where renaming is offered at all: a cube
            // paired, reachable, and having said what it is called (`DeviceNameRules.renameRefusal`). The radio still
            // has no cube on it, and that pairing of rows saying connected with a radio holding nothing is not
            // artificial -- it is the state between a link going down and the drop being recorded, and what the
            // window does in it is what these tests are about.
            XCTAssertTrue(settings.write("paired", field: "paired", true))
            XCTAssertTrue(settings.write("device_uuid", field: "uuid", cube.uuidString))
            XCTAssertTrue(settings.write("connection", field: "connected", true))
            XCTAssertTrue(settings.write("device_name", field: "name", "Dibby"))
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller = nil
            debugLog = nil
            settings = nil
            database.remove()
        }
        super.tearDown()
    }

    /// A window with a radio that has no cube on it, which is the ordinary way a rename fails: the cube is out of
    /// range or flat, and `BluetoothRadio.send` refuses at once rather than reaching for anything. The central
    /// manager is not built until something scans, so this touches no hardware and provokes no permission prompt.
    ///
    /// **Kept in a property, and that is not tidiness.** The callbacks the controller installs on the radio capture
    /// it weakly, exactly as the app needs them to, so a controller nobody holds is deallocated where it stands and
    /// the radio then reports names to nothing -- which reads as the wiring being absent. The app holds one for the
    /// life of the launch; this holds one for the life of the test.
    private var controller: SettingsWindowController!

    @discardableResult
    private func window(with radio: BluetoothRadio = BluetoothRadio(debugLog: nil)) -> SettingsWindowController {
        controller = SettingsWindowController(
            debugLog: debugLog, categories: nil, faces: nil, settings: settings, radio: radio
        )
        return controller
    }

    /// The Device tab's pane, found the way the controller finds it. Every pane is built when `panes` is first asked
    /// for, so this needs no tab to be selected.
    private func devicePane(in controller: SettingsWindowController) throws -> DevicePane {
        try XCTUnwrap(controller.panes.tabViewItems.compactMap { $0.view as? DevicePane }.first)
    }

    /// Commits a name into the Name row, which is what Return does to it.
    private func rename(to typed: String, in controller: SettingsWindowController) throws {
        try devicePane(in: controller).nameCell.onCommit?(typed)
    }

    /// What the table says the cube is called, asked of the table every time.
    private func storedName() -> String? { settings.string("device_name", field: "name") }

    private func storedPreviousName() -> String? { settings.string("device_name", field: "previous_name") }

    /// How many log rows match, which is a SQL `LIKE`. Read as a number, so a query that cannot run answers zero
    /// rather than something that reads as a match.
    private func rows(matching pattern: String) -> Int {
        Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0
    }

    private func waitUntil(
        _ what: String,
        within timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    // MARK: - what the row opens on

    func testTheRowOpensOnWhatTheTableHolds() throws {
        // The precondition the rest of this file leans on, and worth stating rather than assuming: a row that opened
        // on anything else would make every name below mean something different.
        let window = window()

        let cell = try devicePane(in: window).nameCell
        XCTAssertEqual(cell?.name, "Dibby")
        XCTAssertEqual(cell?.isEnabled, true, "a cube is paired, connected, and has said what it is called")
    }

    // MARK: - names that never reach the radio

    func testANameTheCubeCannotHoldIsRefusedInFrontOfTheRadio() throws {
        // **Refused before anything is sent**, which is the point of deciding in `DeviceNameRules`: the name cannot
        // be encoded for `0x15` at all, so reaching for the radio would spend a round trip to learn what the rules
        // already know.
        let window = window()

        try rename(to: "Cube 🎲", in: window)

        XCTAssertEqual(rows(matching: "The device cannot be called Cube%"), 1, "and it says which name and why")
        XCTAssertEqual(rows(matching: "Renaming the cube to%"), 0, "nothing was sent")
        XCTAssertEqual(storedName(), "Dibby", "and the table still holds what the cube answers to")
    }

    func testAnOverLongNameIsRefusedRatherThanCutDown() throws {
        // The field holds itself to 18 as it is typed, so this is the paste that outran the truncation. Writing its
        // first 18 characters would name the cube something nobody asked for.
        let window = window()

        try rename(to: String(repeating: "a", count: DeviceNameRules.maximumLength + 4), in: window)

        XCTAssertEqual(rows(matching: "Renaming the cube to%"), 0)
        XCTAssertEqual(storedName(), "Dibby")
    }

    func testTheNameItAlreadyHasSpendsNothing() throws {
        // A field opened and closed again is not a rename, and a BLE write for it would be a command that changes
        // nothing followed by a row that says nothing.
        let window = window()

        try rename(to: "  Dibby  ", in: window)

        XCTAssertEqual(rows(matching: "The device name was left as it was"), 1)
        XCTAssertEqual(rows(matching: "Renaming the cube to%"), 0)
    }

    // MARK: - a name the cube never took

    func testANameNoCubeTookIsNotWrittenDown() throws {
        // **The claim this file exists for.** `device_name` is the app's record of what the cube is carrying *and*
        // what the filtered scan matches it on (`DeviceScanRules.isEligible`), so a row written on the strength of a
        // command no cube took would be a name nothing could be found by.
        let window = window()

        try rename(to: "Plopper", in: window)

        waitUntil("the attempt is made and refused") { self.rows(matching: "The cube did not take the name Plopper%") == 1 }
        XCTAssertEqual(rows(matching: "Renaming the cube to Plopper"), 1, "the attempt was real")
        XCTAssertEqual(storedName(), "Dibby", "and the table still holds what it held")
        XCTAssertEqual(rows(matching: "The cube is called Plopper%"), 0, "and nothing claims otherwise")
    }

    func testTheRowGoesBackToWhatIsStoredAfterARefusal() throws {
        // Read back rather than remembered: a row left showing a name that reached neither the cube nor the table is
        // the two-answers problem with a scan filter downstream of it.
        let window = window()

        try rename(to: "Plopper", in: window)

        waitUntil("the row is put back") { (try? self.devicePane(in: window).nameCell.name) == "Dibby" }
    }

    func testNothingIsSaidAboutTheLagForARenameThatDidNotHappen() throws {
        // The notice exists to stop a scan list showing the old name reading as a failure. Said after a rename that
        // failed, it would be the app claiming the opposite of what happened.
        let window = window()

        try rename(to: "Plopper", in: window)

        waitUntil("the refusal has landed") { self.rows(matching: "The cube did not take the name%") == 1 }
        XCTAssertEqual(rows(matching: "The cube is now called%"), 0)
    }

    // MARK: - what the cube says it is called

    /// A cube reporting its own name, which is what `peripheralDidUpdateName(_:)` produces a second or two into a
    /// connection and the only confirmation a rename ever gets.
    private func reportName(_ name: String, from id: UUID, on radio: BluetoothRadio) {
        radio.onDeviceName?(id, name)
    }

    func testANameTheCubeReportsIsWrittenDown() throws {
        // The path that catches a cube renamed in the vendor's app, and the one that confirms a rename made here.
        let radio = BluetoothRadio(debugLog: nil)
        window(with: radio)

        reportName("Wobble", from: cube, on: radio)

        XCTAssertEqual(storedName(), "Wobble")
        XCTAssertEqual(storedPreviousName(), "Dibby", "and the name before it stays in the scan filter")
    }

    func testTheNameARenameReplacedIsRefusedAsAStaleRead() throws {
        // **The reason `DevicePairingRules.adoption` exists.** macOS re-reads the GAP name only on connecting, so the
        // connection after a rename can still hand out the name the cube was renamed away from. Adopting it would
        // undo the rename on the tab and in the row the scan filter is built from, and put it back a connection later.
        XCTAssertTrue(settings.write("device_name", field: "name", "Plopper"))
        XCTAssertTrue(settings.write("device_name", field: "previous_name", "Dibby"))
        let radio = BluetoothRadio(debugLog: nil)
        window(with: radio)

        reportName("Dibby", from: cube, on: radio)

        XCTAssertEqual(storedName(), "Plopper", "the rename stands")
        XCTAssertEqual(storedPreviousName(), "Dibby")
        XCTAssertEqual(rows(matching: "The cube reports the name it had before the rename%"), 1, "and it says so")
    }

    func testTheNameAlreadyOnRecordWritesNothingAndSaysNothing() throws {
        // Every connection reports a name, so a row per connection saying the name has not changed would be the loop
        // of the app burying what the cube actually did.
        let radio = BluetoothRadio(debugLog: nil)
        window(with: radio)

        reportName("Dibby", from: cube, on: radio)

        XCTAssertEqual(storedName(), "Dibby")
        XCTAssertNil(storedPreviousName(), "nothing was displaced")
        XCTAssertEqual(rows(matching: "The cube is called Dibby%"), 0)
    }

    func testANameFromSomeOtherDeviceIsNotThisCubesName() throws {
        // Every connection reports a name, including the one that proves a factory reset and any made to a device
        // that turns out to be somebody else's. Writing one of those into `device_name` would rename the pairing
        // after a cube it is not to.
        let radio = BluetoothRadio(debugLog: nil)
        window(with: radio)

        reportName("Somebody elses cube", from: UUID(), on: radio)

        XCTAssertEqual(storedName(), "Dibby")
        XCTAssertEqual(rows(matching: "Ignoring the name Somebody elses cube%"), 1)
    }

    func testTheTabFollowsTheNameTheCubeReports() throws {
        // The tab is redrawn from the table rather than from what arrived, which is the rule every write on it keeps.
        let radio = BluetoothRadio(debugLog: nil)
        let window = window(with: radio)
        _ = try devicePane(in: window)

        reportName("Wobble", from: cube, on: radio)

        XCTAssertEqual(try devicePane(in: window).nameCell.name, "Wobble")
    }
}
