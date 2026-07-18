@testable import TimeFlipApp
import XCTest

final class AutoPauseStepperTests: XCTestCase {
    /// Walks the full sequence of `nextValue` calls a real held-arrow loop would produce,
    /// starting from `start`, and returns the values reached in order (not including `start`
    /// itself).
    private func simulateHold(from start: Int, direction: Int, ticks: Int) -> [Int] {
        var current = start
        var reached: [Int] = []
        for _ in 0..<ticks {
            current = AutoPauseStepper.nextValue(current: current, holdStartValue: start, direction: direction)
            reached.append(current)
        }
        return reached
    }

    func testUpHoldFromNonMultipleOfFiveMatchesSpecExample() {
        // Starting at 4 and holding up: 5, 6, 7, 8, 9, 10 (single digits, crossing the 5 and 10
        // gridlines), then 15, 20, 25, 30 (by 5) -- the exact example from the feature request.
        let reached = simulateHold(from: 4, direction: 1, ticks: 10)
        XCTAssertEqual(reached, [5, 6, 7, 8, 9, 10, 15, 20, 25, 30])
    }

    func testDownHoldMirrorsUpHold() {
        let reached = simulateHold(from: 26, direction: -1, ticks: 10)
        XCTAssertEqual(reached, [25, 24, 23, 22, 21, 20, 15, 10, 5, 0])
    }

    func testUpHoldFromAMultipleOfFiveCountsGridlinesBeyondIt() {
        // Starting exactly on a gridline (10): the two counted gridlines are the *next* ones
        // beyond it (15, 20), not itself -- so the single-digit phase runs all the way to 20.
        let reached = simulateHold(from: 10, direction: 1, ticks: 12)
        XCTAssertEqual(reached, [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 25, 30])
    }

    func testDownHoldFromAMultipleOfFiveCountsGridlinesBeyondIt() {
        let reached = simulateHold(from: 20, direction: -1, ticks: 12)
        XCTAssertEqual(reached, [19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 5, 0])
    }

    func testTickIntervalIsSlowerOncePastTheSecondBoundary() {
        XCTAssertEqual(AutoPauseStepper.tickInterval(current: 4, holdStartValue: 4, direction: 1), AutoPauseStepper.singleStepInterval)
        XCTAssertEqual(AutoPauseStepper.tickInterval(current: 9, holdStartValue: 4, direction: 1), AutoPauseStepper.singleStepInterval)
        XCTAssertEqual(AutoPauseStepper.tickInterval(current: 10, holdStartValue: 4, direction: 1), AutoPauseStepper.fiveStepInterval)
        XCTAssertGreaterThan(AutoPauseStepper.fiveStepInterval, AutoPauseStepper.singleStepInterval)
    }

    func testSecondBoundaryUpAndDown() {
        XCTAssertEqual(AutoPauseStepper.secondBoundary(from: 4, direction: 1), 10)
        XCTAssertEqual(AutoPauseStepper.secondBoundary(from: 26, direction: -1), 20)
    }
}
