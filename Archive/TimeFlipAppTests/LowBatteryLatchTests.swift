@testable import TimeFlipApp
import XCTest

/// Covers the menu bar's low-battery hysteresis (`LowBatteryLatch`), extracted from
/// `MenuBarController.updatedLowBatteryLatch`. Uses the app's real thresholds: latch at/below 5%,
/// clear only once strictly above 5 + 5 = 10%.
final class LowBatteryLatchTests: XCTestCase {
    private let threshold = 5
    private let recoveryMargin = 5

    private func updated(latched: Bool, level: UInt8?) -> Bool {
        LowBatteryLatch.updated(latched: latched, currentLevel: level, threshold: threshold, recoveryMargin: recoveryMargin)
    }

    func testLatchesOnAtThreshold() {
        XCTAssertTrue(updated(latched: false, level: 5))
    }

    func testLatchesOnBelowThreshold() {
        XCTAssertTrue(updated(latched: false, level: 1))
    }

    func testDoesNotLatchJustAboveThreshold() {
        XCTAssertFalse(updated(latched: false, level: 6))
    }

    func testStaysLatchedInsideTheHysteresisBand() {
        // Between the threshold (5) and the recovery level (10) an already-latched state holds --
        // a reading wobbling in this band must not clear the warning.
        XCTAssertTrue(updated(latched: true, level: 6))
        XCTAssertTrue(updated(latched: true, level: 10))
    }

    func testClearsOnlyStrictlyAboveRecoveryLevel() {
        // Recovery level is threshold + margin = 10; clearing requires > 10, so 10 holds and 11
        // clears.
        XCTAssertTrue(updated(latched: true, level: 10))
        XCTAssertFalse(updated(latched: true, level: 11))
    }

    func testNilReadingLeavesLatchUnchanged() {
        XCTAssertTrue(updated(latched: true, level: nil))
        XCTAssertFalse(updated(latched: false, level: nil))
    }

    func testFullNoisyCycleAroundTheThreshold() {
        // Drop into low battery, wobble around 5-10 without ever clearing, then genuinely recover.
        var latched = false
        latched = updated(latched: latched, level: 4)   // drop below -> on
        XCTAssertTrue(latched)
        latched = updated(latched: latched, level: 7)   // bounce up, still in band -> stays on
        XCTAssertTrue(latched)
        latched = updated(latched: latched, level: 5)   // back at threshold -> stays on
        XCTAssertTrue(latched)
        latched = updated(latched: latched, level: 10)  // top of band, not yet recovered -> on
        XCTAssertTrue(latched)
        latched = updated(latched: latched, level: 12)  // genuine recovery -> off
        XCTAssertFalse(latched)
        latched = updated(latched: latched, level: 6)   // back in band but not latched -> stays off
        XCTAssertFalse(latched)
    }
}
