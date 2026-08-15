@testable import FacetApp
import XCTest

/// Covers `ManualMode`: that a launch with no paired device starts timing by hand, and one with a paired
/// device does not.
@MainActor
final class ManualModeTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    override func tearDown() {
        settings = nil
        database.remove()
        super.tearDown()
    }

    private func setPaired(_ paired: Bool) {
        XCTAssertTrue(
            database.execute(
                "UPDATE setting SET setting_value = '{\"paired\":\(paired)}' WHERE setting_name = 'paired';"
            )
        )
    }

    func testItStartsOff() {
        XCTAssertFalse(ManualMode(debugLog: nil).isOn, "nothing is in manual mode until something says so")
    }

    func testAnUnpairedLaunchStartsInManualMode() {
        // The seeded state, and the state of an app that has never been paired.
        let manualMode = ManualMode(debugLog: nil)

        manualMode.startIfNoDeviceIsPaired(settings)

        XCTAssertTrue(manualMode.isOn)
    }

    func testAPairedLaunchDoesNot() {
        setPaired(true)
        let manualMode = ManualMode(debugLog: nil)

        manualMode.startIfNoDeviceIsPaired(settings)

        XCTAssertFalse(manualMode.isOn)
    }

    func testAnUnreadablePairedSettingStartsInManualMode() {
        // Of the two ways to be wrong, sitting in manual mode with a good cube on the desk is visible and
        // recoverable; waiting forever for a device that was never paired looks like a broken app.
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))
        let manualMode = ManualMode(debugLog: nil)

        manualMode.startIfNoDeviceIsPaired(settings)

        XCTAssertTrue(manualMode.isOn)
    }

    func testTheFlagIsNotWrittenToTheDatabase() {
        let manualMode = ManualMode(debugLog: nil)
        manualMode.startIfNoDeviceIsPaired(settings)
        XCTAssertTrue(manualMode.isOn, "precondition")

        // In memory only, by design: the mode describes what this launch is doing, and nothing about it
        // belongs in a table whose job is what is durably true.
        XCTAssertEqual(
            settings.flag("paired", field: "paired"), false,
            "turning manual mode on must not have written anything back"
        )
        XCTAssertNil(settings.json("manual_mode"), "there is no such setting, and there should not be")
    }
}
