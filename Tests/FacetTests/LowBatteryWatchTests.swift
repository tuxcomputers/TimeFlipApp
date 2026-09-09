@testable import FacetCore
import Foundation
import Testing

/// Covers the low-battery warning: when it arms, when it lets go, and when it flashes.
///
/// **Against a real database built from the real DDL**, because half the claim is that the threshold comes out of the
/// `setting` table at the moment it is asked rather than from a copy taken earlier. A fake store would prove the
/// class agrees with itself and say nothing about `low_battery_level`.
///
/// The charge is handed in through a closure the test moves, which is exactly how the app wires it: the watch asks
/// `BluetoothRadio` for the live figure and holds none of it.
@Suite @MainActor
final class LowBatteryWatchTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var built: LowBatteryWatch?
    /// What the "radio" is currently reporting. `nil` stands for no live connection.
    private var level: Int?
    private var changes = 0

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated**, so unlike the `tearDown` it replaces it
        // cannot call `built?.stop()`. `database` is a `let` for the same reason: a non-isolated `deinit` may read
        // that where it could not read a `@MainActor var`.
        //
        // **What that gives up is the blink timer being invalidated**, and it is worth naming rather than leaving
        // to be found. A watch released while flashing leaves its repeating `Timer` retained by `RunLoop.main`,
        // firing against a `[weak self]` that is now nil -- so it does nothing, but it is never invalidated
        // either. Harmless here because no run loop in a `swift test` process is being serviced anyway, which is
        // the same fact that made this suite need `fire()` in the first place. `HistoryTimer` solves it properly
        // with a `TimerHolder` whose own `deinit` invalidates the timer, and that is the answer if this ever
        // stops being harmless; it was left alone deliberately, to keep this change to the `fire()` extraction.
        database.remove()
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

    @Test func testAHealthyChargeIsNoWarning() {
        report(80)

        #expect(watch.alert == .none)
    }

    @Test func testTheSeededThresholdIsWhatDecides() {
        // `database/011_setting.sql` seeds `{"percent":10}`, so 10 is low and 11 is not. Read from the table rather
        // than from a constant here, which is the point of the test.
        report(11)
        #expect(!watch.alert.isBatteryLow)

        report(10)
        #expect(watch.alert.isBatteryLow)
    }

    @Test func testTheWarningFlashesFromTheMomentItArms() {
        // On its coloured phase to begin with, so it arrives as a colour rather than as half a second of nothing.
        report(5)

        #expect(watch.alert.isBatteryLow)
        #expect(watch.alert.isBlinkOn)
        #expect(changes == 1, "the surfaces that draw the warning were not told about it")
    }

    @Test func testTheWarningHoldsThroughAFlapAcrossTheThreshold() {
        report(10)
        let armed = changes

        for percent in [11, 10, 11, 12, 11] { report(percent) }

        #expect(watch.alert.isBatteryLow)
        #expect(changes == armed, "the warning was redrawn while nothing about it had changed")
    }

    @Test func testTheWarningLetsGoOnceTheChargeIsWellClearOfTheThreshold() {
        report(10)

        report(15)
        #expect(watch.alert.isBatteryLow, "15 is inside the recovery margin, so the warning still stands")

        report(16)
        #expect(watch.alert == .none)
    }

    // MARK: - the link going

    @Test func testTheFlashStopsWithTheLinkAndTheWarningDoesNot() {
        report(4)

        report(nil)

        #expect(watch.alert.isBatteryLow, "a link that has gone is not evidence that the cells recovered")
        #expect(!watch.alert.isBlinkOn, "there is nothing on screen to flash about with no reading behind it")
    }

    @Test func testACubeThatComesBackStillFlatIsStillFlashing() {
        report(4)
        report(nil)

        report(4)

        #expect(watch.alert.isBatteryLow)
        #expect(watch.alert.isBlinkOn)
    }

    // MARK: - the threshold moving underneath it

    @Test func testRaisingTheWarningLevelArmsItWithoutWaitingForAReading() {
        // The case a reading-driven watch misses: a cube sitting steady at 15 reports nothing for as long as it stays
        // there, so without this the control would appear to do nothing at all.
        report(15)
        #expect(!watch.alert.isBatteryLow)

        #expect(settings.write("low_battery_level", field: "percent", 20))
        watch.reconsider(because: "the warning level changed")

        #expect(watch.alert.isBatteryLow)
    }

    @Test func testLoweringTheWarningLevelLetsGoOfIt() {
        report(10)
        #expect(watch.alert.isBatteryLow)

        // Low at 10, and not low at all once the level somebody cares about is 4: the charge has to clear the *new*
        // threshold plus its margin, which 10 does.
        #expect(settings.write("low_battery_level", field: "percent", 4))
        watch.reconsider(because: "the warning level changed")

        #expect(watch.alert == .none)
    }

    // MARK: - the flash itself

    @Test func testTheFlashAlternatesAndKeepsSayingSo() {
        // The timer is the claim -- half a second on, half a second off, and whoever draws told each time -- and the
        // phase is now turned over by calling `fire()` rather than by waiting for a run loop to do it. That is what
        // lets this suite run here at all: a `@MainActor` swift-testing test is not on the main thread on Linux, so
        // the `RunLoop.main` timer never fires and the wait this replaces timed out rather than passing.
        //
        // It also asks more than the wait did. `XCTestExpectation` could only be fulfilled by the *first* change of
        // phase, so alternating was asserted in one direction; two calls assert it turns over and back.
        report(3)
        let armed = changes
        #expect(watch.alert.isBlinkOn, "it arrives on its coloured phase rather than on half a second of nothing")

        watch.fire()

        #expect(!watch.alert.isBlinkOn, "the first change of phase should be the colour going off")
        #expect(watch.alert.isBatteryLow, "the warning itself does not blink, only its colour does")
        #expect(changes == armed + 1, "and whoever draws is told about it")

        watch.fire()

        #expect(watch.alert.isBlinkOn, "and back on, which is what alternating means")
        #expect(changes == armed + 2)
    }
}
