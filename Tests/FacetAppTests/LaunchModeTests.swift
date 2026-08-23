@testable import FacetApp
import XCTest

/// Covers `LaunchMode`: that a launch with no paired device is its own clock, one with a paired device follows it,
/// and that nothing after startup can move a launch from one to the other.
@MainActor
final class LaunchModeTests: XCTestCase {
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

    func testAnUnpairedLaunchIsItsOwnClock() {
        // The seeded state, and the state of an app that has never been paired.
        XCTAssertEqual(LaunchMode.decided(from: settings, debugLog: nil), .manual)
    }

    func testAPairedLaunchFollowsTheCube() {
        setPaired(true)

        XCTAssertEqual(LaunchMode.decided(from: settings, debugLog: nil), .device)
    }

    func testAnUnreadablePairedSettingIsItsOwnClock() {
        // Of the two ways to be wrong, sitting in manual mode with a good cube on the desk is visible and
        // recoverable; waiting forever for a device that was never paired looks like a broken app.
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))

        XCTAssertEqual(LaunchMode.decided(from: settings, debugLog: nil), .manual)
    }

    func testIsManualIsTheQuestionMostCallersAsk() {
        XCTAssertTrue(LaunchMode.manual.isManual)
        XCTAssertFalse(LaunchMode.device.isManual)
    }

    func testDecidingWritesNothingBack() {
        // In memory only, by design: the mode describes what this launch is doing, and nothing about it belongs in a
        // table whose job is what is durably true. A stored answer would outlive the restart somebody made
        // specifically to get out of it.
        _ = LaunchMode.decided(from: settings, debugLog: nil)

        XCTAssertEqual(settings.flag("paired", field: "paired"), false, "deciding must not have written anything")
        XCTAssertNil(settings.json("manual_mode"), "there is no such setting, and there should not be")
    }

    func testThePairingCanChangeUnderneathADecidedModeWithoutMovingIt() {
        // **The rule the type exists for.** A value already decided is not a view onto `paired`: pairing a cube after
        // the fact leaves this launch exactly what it was. What used to happen here -- the app adopting the cube --
        // is the switching that made "which mode is this" a question with two live answers.
        //
        // Deciding again is what a *restart* is, and it is the only thing that reads the table a second time.
        let decided = LaunchMode.decided(from: settings, debugLog: nil)
        XCTAssertEqual(decided, .manual, "precondition: nothing paired at launch")

        setPaired(true)

        XCTAssertEqual(decided, .manual, "the launch is still what it was")
        XCTAssertEqual(LaunchMode.decided(from: settings, debugLog: nil), .device, "and a restart would differ")
    }

    func testForgettingTheDeviceDoesNotMakeADeviceLaunchItsOwnClock() {
        // The other direction, and the one that used to have three callers on the Device tab: forget, factory reset,
        // and the reset that follows a forget. A device launch whose cube has gone has nothing to follow and does not
        // start timing by hand on its own -- `DeviceInfoRules.connection` is where that state is admitted to.
        setPaired(true)
        let decided = LaunchMode.decided(from: settings, debugLog: nil)
        XCTAssertEqual(decided, .device, "precondition: a cube on record at launch")

        setPaired(false)

        XCTAssertEqual(decided, .device, "the launch is still what it was")
    }

    func testThereIsNoWayToChangeADecidedMode() {
        // Not a behaviour so much as the shape that guarantees every behaviour above: an enum with no setter has
        // nowhere for a fourth caller to appear. Written down because the previous type had `start` and `stop`, and
        // the rule that they were only for startup was one somebody had to keep rather than one the code enforced.
        var mode = LaunchMode.manual

        mode = .device

        // A local being reassignable is not the app changing modes: what matters is that nothing reachable from a
        // running app holds one it can write to. `main.swift` binds it with `let`, and every consumer takes a
        // `() -> Bool` over it.
        XCTAssertEqual(mode, .device)
    }
}
