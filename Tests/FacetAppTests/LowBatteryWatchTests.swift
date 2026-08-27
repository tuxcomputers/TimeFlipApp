@testable import FacetApp
import Foundation
import XCTest

/// Covers the low-battery warning: when it arms, when it lets go, and when it flashes.
///
/// **Against a real database built from the real DDL**, because half the claim is that the threshold comes out of the
/// `setting` table at the moment it is asked rather than from a copy taken earlier. A fake store would prove the
/// class agrees with itself and say nothing about `low_battery_level`.
///
/// The charge is handed in through a closure the test moves, which is exactly how the app wires it: the watch asks
/// `BluetoothRadio` for the live figure and holds none of it.
@MainActor
final class LowBatteryWatchTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    private var built: LowBatteryWatch?
    /// What the "radio" is currently reporting. `nil` stands for no live connection.
    private var level: Int?
    private var changes = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            try database.bootstrap()
            settings = SettingStore(connection: database.connection())
            level = nil
            changes = 0
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            built?.stop()
            built = nil
            settings = nil
            database.remove()
        }
        super.tearDown()
    }

    /// Built on first use rather than in `setUpWithError`, which is not main-actor isolated: both closures capture
    /// this test case, and handing those to a `@MainActor` initialiser from there is a data race as far as the
    /// compiler is concerned. `HistoryTimerTests` does the same thing for the same reason.
    private var watch: LowBatteryWatch {
        if let built { return built }
        let created = LowBatteryWatch(level: { self.level }, settings: settings, debugLog: nil)
        created.onChanged = { self.changes += 1 }
        built = created
        return created
    }

    /// Reports a charge and lets the watch think about it, the way a notification arriving does.
    private func report(_ percent: Int?) {
        level = percent
        watch.reconsider(because: "a test said so")
    }

    // MARK: - arming and letting go

    func testAHealthyChargeIsNoWarning() {
        report(80)

        XCTAssertEqual(watch.alert, .none)
    }

    func testTheSeededThresholdIsWhatDecides() {
        // `database/011_setting.sql` seeds `{"percent":10}`, so 10 is low and 11 is not. Read from the table rather
        // than from a constant here, which is the point of the test.
        report(11)
        XCTAssertFalse(watch.alert.isBatteryLow)

        report(10)
        XCTAssertTrue(watch.alert.isBatteryLow)
    }

    func testTheWarningFlashesFromTheMomentItArms() {
        // On its coloured phase to begin with, so it arrives as a colour rather than as half a second of nothing.
        report(5)

        XCTAssertTrue(watch.alert.isBatteryLow)
        XCTAssertTrue(watch.alert.isBlinkOn)
        XCTAssertEqual(changes, 1, "the surfaces that draw the warning were not told about it")
    }

    func testTheWarningHoldsThroughAFlapAcrossTheThreshold() {
        report(10)
        let armed = changes

        for percent in [11, 10, 11, 12, 11] { report(percent) }

        XCTAssertTrue(watch.alert.isBatteryLow)
        XCTAssertEqual(changes, armed, "the warning was redrawn while nothing about it had changed")
    }

    func testTheWarningLetsGoOnceTheChargeIsWellClearOfTheThreshold() {
        report(10)

        report(15)
        XCTAssertTrue(watch.alert.isBatteryLow, "15 is inside the recovery margin, so the warning still stands")

        report(16)
        XCTAssertEqual(watch.alert, .none)
    }

    // MARK: - the link going

    func testTheFlashStopsWithTheLinkAndTheWarningDoesNot() {
        report(4)

        report(nil)

        XCTAssertTrue(watch.alert.isBatteryLow, "a link that has gone is not evidence that the cells recovered")
        XCTAssertFalse(watch.alert.isBlinkOn, "there is nothing on screen to flash about with no reading behind it")
    }

    func testACubeThatComesBackStillFlatIsStillFlashing() {
        report(4)
        report(nil)

        report(4)

        XCTAssertTrue(watch.alert.isBatteryLow)
        XCTAssertTrue(watch.alert.isBlinkOn)
    }

    // MARK: - the threshold moving underneath it

    func testRaisingTheWarningLevelArmsItWithoutWaitingForAReading() {
        // The case a reading-driven watch misses: a cube sitting steady at 15 reports nothing for as long as it stays
        // there, so without this the control would appear to do nothing at all.
        report(15)
        XCTAssertFalse(watch.alert.isBatteryLow)

        XCTAssertTrue(settings.write("low_battery_level", field: "percent", 20))
        watch.reconsider(because: "the warning level changed")

        XCTAssertTrue(watch.alert.isBatteryLow)
    }

    func testLoweringTheWarningLevelLetsGoOfIt() {
        report(10)
        XCTAssertTrue(watch.alert.isBatteryLow)

        // Low at 10, and not low at all once the level somebody cares about is 4: the charge has to clear the *new*
        // threshold plus its margin, which 10 does.
        XCTAssertTrue(settings.write("low_battery_level", field: "percent", 4))
        watch.reconsider(because: "the warning level changed")

        XCTAssertEqual(watch.alert, .none)
    }

    // MARK: - the flash itself

    func testTheFlashAlternatesAndKeepsSayingSo() {
        // The only test here that waits on the timer, because the timer is the claim: half a second on, half a
        // second off, and whoever draws is told each time.
        report(3)
        let told = changes
        let flipped = expectation(description: "the flash changed phase")
        watch.onChanged = { [weak self] in
            guard let self else { return }
            self.changes += 1
            if self.changes > told { flipped.fulfill() }
        }

        wait(for: [flipped], timeout: 2)

        XCTAssertFalse(watch.alert.isBlinkOn, "the first change of phase should be the colour going off")
        XCTAssertTrue(watch.alert.isBatteryLow, "the warning itself does not blink, only its colour does")
    }
}
