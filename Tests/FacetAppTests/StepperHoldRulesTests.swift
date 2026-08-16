@testable import FacetApp
import XCTest

/// Covers `StepperHoldRules`: the tick sequence a held arrow runs through.
///
/// Copied from the previous app's `AutoPauseStepperTests` along with the rule itself, because the sequence is the
/// thing worth pinning and these already pin it. Testing it here rather than through the control is the whole reason
/// the rule is a separate type: the alternative is holding a real mouse button down for four seconds.
final class StepperHoldRulesTests: XCTestCase {
    /// Walks the sequence of `nextValue` calls a real held-arrow loop would produce, starting from `start`, and
    /// returns the values reached in order (not including `start` itself).
    private func simulateHold(from start: Int, direction: Int, ticks: Int) -> [Int] {
        var current = start
        var reached: [Int] = []
        for _ in 0 ..< ticks {
            current = StepperHoldRules.nextValue(current: current, holdStartValue: start, direction: direction)
            reached.append(current)
        }
        return reached
    }

    func testUpHoldFromNonMultipleOfFive() {
        // Starting at 4 and holding up: 5, 6, 7, 8, 9, 10 (single digits, crossing the 5 and 10 gridlines), then
        // 15, 20, 25, 30 (by 5).
        XCTAssertEqual(simulateHold(from: 4, direction: 1, ticks: 10), [5, 6, 7, 8, 9, 10, 15, 20, 25, 30])
    }

    func testDownHoldMirrorsUpHold() {
        XCTAssertEqual(simulateHold(from: 26, direction: -1, ticks: 10), [25, 24, 23, 22, 21, 20, 15, 10, 5, 0])
    }

    func testUpHoldFromAMultipleOfFiveCountsGridlinesBeyondIt() {
        // Starting exactly on a gridline (10): the two counted gridlines are the *next* ones beyond it (15, 20),
        // not itself, so the single-digit phase runs all the way to 20.
        XCTAssertEqual(
            simulateHold(from: 10, direction: 1, ticks: 12),
            [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 25, 30]
        )
    }

    func testDownHoldFromAMultipleOfFiveCountsGridlinesBeyondIt() {
        XCTAssertEqual(
            simulateHold(from: 20, direction: -1, ticks: 12),
            [19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 5, 0]
        )
    }

    func testTickIntervalIsSlowerOncePastTheSecondBoundary() {
        XCTAssertEqual(
            StepperHoldRules.tickInterval(current: 4, holdStartValue: 4, direction: 1),
            StepperHoldRules.singleStepInterval
        )
        XCTAssertEqual(
            StepperHoldRules.tickInterval(current: 9, holdStartValue: 4, direction: 1),
            StepperHoldRules.singleStepInterval
        )
        XCTAssertEqual(
            StepperHoldRules.tickInterval(current: 10, holdStartValue: 4, direction: 1),
            StepperHoldRules.fiveStepInterval
        )
        XCTAssertGreaterThan(StepperHoldRules.fiveStepInterval, StepperHoldRules.singleStepInterval)
    }

    func testSecondBoundaryUpAndDown() {
        XCTAssertEqual(StepperHoldRules.secondBoundary(from: 4, direction: 1), 10)
        XCTAssertEqual(StepperHoldRules.secondBoundary(from: 26, direction: -1), 20)
    }

    func testAClickIsOneStepBeforeAnythingRepeats() {
        // The delay is what keeps an ordinary click from becoming a run of them.
        XCTAssertGreaterThan(StepperHoldRules.initialHoldDelay, StepperHoldRules.singleStepInterval)
    }
}
