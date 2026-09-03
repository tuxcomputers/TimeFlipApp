@testable import FacetApp
import XCTest

/// Covers what a battery reading becomes on screen, and when it becomes a warning.
///
/// **Worth testing because the hardware's readings are noisy in a specific, measured way**, and both rules here exist
/// to absorb that rather than to be tidy: on real traffic the level flipped between two adjacent percentages roughly
/// every two seconds for a whole day, so a figure drawn straight off the wire would never sit still and a warning
/// judged straight off it would arm and disarm at the same rate. Neither of those can be caught by a test that only
/// feeds one reading, which is why most of these feed a run of them.
final class BatteryRulesTests: XCTestCase {
    /// The figure after a whole run of readings, which is how these actually arrive.
    private func shown(after readings: [Int], from start: Int? = nil) -> Int? {
        readings.reduce(start) { BatteryRules.shown($0, reading: $1) }
    }

    // MARK: - the figure to show

    func testTheFirstReadingIsSimplyTheAnswer() {
        // Nothing on show for it to flap against, so no judgement to make.
        XCTAssertEqual(BatteryRules.shown(nil, reading: 65), 65)
    }

    func testAOnePercentFlapNeverMovesTheFigure() {
        // The measured case, and the whole reason this rule exists: 65, 66, 65, 66, 65 shows 65 throughout.
        XCTAssertEqual(shown(after: [65, 66, 65, 66, 65]), 65)
    }

    func testAClimbOfTwoIsAdopted() {
        // The same run, ending two above where it started. That is the charge having actually moved rather than the
        // same charge being described twice, so the higher figure wins.
        XCTAssertEqual(shown(after: [65, 66, 65, 66, 67]), 67)
    }

    func testAClimbOfOneIsNotAdopted() {
        XCTAssertEqual(BatteryRules.shown(65, reading: 66), 65)
    }

    func testTheFigureKeepsClimbingOnceItHasMoved() {
        // Adopting 67 makes 67 the figure the next reading is judged against, so the flap either side of it is
        // absorbed exactly as the flap either side of 65 was.
        XCTAssertEqual(shown(after: [67, 68, 67, 68], from: 65), 67)
    }

    func testAFallIsTakenAtOnce() {
        // No margin on the way down, deliberately: a battery running down is what this figure is for, so the
        // pessimistic reading is never held back.
        XCTAssertEqual(BatteryRules.shown(65, reading: 64), 64)
    }

    func testTheFlapAfterAFallHoldsTheLowerFigure() {
        // Having dropped to 64, the cube wavering between 64 and 65 keeps showing 64 rather than climbing back.
        XCTAssertEqual(shown(after: [64, 65, 64, 65], from: 65), 64)
    }

    func testNewCellsAreAdoptedImmediately() {
        // The only way this hardware's charge really rises. It clears the two-point bar by a mile, which is the
        // point: the rule holds back a wobble, not a battery change.
        XCTAssertEqual(BatteryRules.shown(4, reading: 100), 100)
    }

    func testAReadingThatIsNotALevelIsDiscarded() {
        // `docs/TimeFlip2 BLE Protocol v4.3.md` gives 1 to 100. A byte outside that is not a charge, and drawing it
        // would be worse than having nothing to draw.
        XCTAssertEqual(BatteryRules.shown(65, reading: 0), 65)
        XCTAssertEqual(BatteryRules.shown(65, reading: 101), 65)
        XCTAssertEqual(BatteryRules.shown(65, reading: 255), 65)
        XCTAssertNil(BatteryRules.shown(nil, reading: 0))
    }

    // MARK: - the warning

    func testTheWarningArmsAtTheThreshold() {
        // At or below, not below: a threshold of 10 means 10 is low.
        XCTAssertTrue(BatteryRules.latched(false, level: 10, threshold: 10))
        XCTAssertTrue(BatteryRules.latched(false, level: 9, threshold: 10))
        XCTAssertFalse(BatteryRules.latched(false, level: 11, threshold: 10))
    }

    func testTheWarningHoldsUntilTheChargeIsWellClearOfIt() {
        // Armed at 10, it survives everything up to and including 15 (`recoveryMargin` of 5) and only lets go above.
        XCTAssertTrue(BatteryRules.latched(true, level: 11, threshold: 10))
        XCTAssertTrue(BatteryRules.latched(true, level: 15, threshold: 10))
        XCTAssertFalse(BatteryRules.latched(true, level: 16, threshold: 10))
    }

    func testTheWarningDoesNotFlapAroundTheThreshold() {
        // The reason the margin exists at all. Without it this run would arm and disarm five times.
        var latched = false
        for level in [10, 11, 10, 11, 12, 11] {
            latched = BatteryRules.latched(latched, level: level, threshold: 10)
            XCTAssertTrue(latched, "the warning let go at \(level)%, inside its own recovery margin")
        }
    }

    func testNoReadingLeavesTheWarningExactlyAsItWas() {
        // A link that has gone is not evidence that the cells recovered, so nothing about the verdict changes. What
        // stops while there is no reading is the flash, which is `LowBatteryWatch`'s to stop.
        XCTAssertTrue(BatteryRules.latched(true, level: nil, threshold: 10))
        XCTAssertFalse(BatteryRules.latched(false, level: nil, threshold: 10))
    }

    func testAThresholdOfItsOwnIsObeyed() {
        // The level is a setting (`low_battery_level`, 1 to 20 on the Device tab), so nothing here is tied to its seed.
        XCTAssertTrue(BatteryRules.latched(false, level: 20, threshold: 20))
        XCTAssertFalse(BatteryRules.latched(false, level: 20, threshold: 5))
        XCTAssertFalse(BatteryRules.latched(true, level: 26, threshold: 20))
    }

    // MARK: - what the threshold may be set to

    /// **These moved here with the row on 2026-09-03**, from `AppSettingsRulesTests`. The bounds belong beside the
    /// numbers the threshold is judged by rather than with the App tab, which no longer holds the control.
    func testTheWarningIsCappedAtTwentyPercent() {
        // The archive's cap and its reasoning: the device runs on AA cells, so the warning has to leave time to
        // choose when to swap them, not time to find one. A threshold much above this keeps the warning lit for most
        // of the cells' life, which teaches somebody to ignore it.
        XCTAssertEqual(BatteryRules.warningRange, 1 ... 20)
        XCTAssertEqual(BatteryRules.defaultWarningPercent, 10)
    }

    func testTheWarningCannotBeSetToNothing() {
        // A warning at 0% arrives once the device is already dead.
        XCTAssertEqual(BatteryRules.warningRange.lowerBound, 1)
    }

    func testTheSeededLevelIsInsideTheRangeTheFieldOffers() {
        // The seed and the bounds are two numbers in one file now, so this is cheap and it is the pairing that goes
        // wrong: a default outside the range would be clamped the first time somebody touched the row.
        XCTAssertTrue(BatteryRules.warningRange.contains(BatteryRules.defaultWarningPercent))
    }
}
