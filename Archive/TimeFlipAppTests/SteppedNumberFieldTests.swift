@testable import TimeFlipApp
import XCTest

/// Covers `SteppedNumberField.stepBase`, the rule deciding what an arrow press counts from.
///
/// The control itself is a SwiftUI view and its focus behaviour can only really be judged by using
/// it, but the decision the bug came down to is arithmetic and belongs here: an arrow used to step
/// the stored value while the field displayed something else entirely.
final class SteppedNumberFieldTests: XCTestCase {
    private let range = 0...30

    private func base(_ draft: String, stored: Int) -> Int {
        SteppedNumberField.stepBase(draft: draft, storedValue: stored, range: range)
    }

    func testAnUntouchedFieldStepsFromItsStoredValue() {
        // A blurred field's draft is kept in step with the value, so the two agree and nothing about
        // the old behaviour changes for the common case: click an arrow without typing first.
        XCTAssertEqual(base("5", stored: 5), 5)
    }

    func testATypedButUncommittedNumberIsWhatTheArrowStepsFrom() {
        // The bug. Type 20 over a stored 5 and press up: 21 is what the screen implies, and 6 is
        // what the control used to do while continuing to display 20.
        XCTAssertEqual(base("20", stored: 5), 20)
    }

    func testATypedNumberAboveTheRangeClampsToTheTop() {
        // Without the clamp the arrows would be stuck: stepping down from 99 in a field capped at 30
        // would read 98, still out of range, and every press would look like it did nothing.
        XCTAssertEqual(base("99", stored: 5), 30)
    }

    func testATypedNumberBelowTheRangeClampsToTheBottom() {
        XCTAssertEqual(base("-4", stored: 5), 0)
    }

    func testAnUnparseableDraftFallsBackToTheStoredValue() {
        // Matching commitDraft, which reverts an unparseable entry rather than inventing a number.
        // Falling back to 0 instead would turn a typo into a silent reset of the setting.
        XCTAssertEqual(base("abc", stored: 12), 12)
        XCTAssertEqual(base("", stored: 12), 12)
        XCTAssertEqual(base("7.5", stored: 12), 12)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(base("  8 ", stored: 3), 8)
    }

    func testAHoldBegunAfterTypingAcceleratesFromTheTypedNumber() {
        // stepBase feeds AutoPauseStepper's holdStartValue, which measures the step-1-then-step-5
        // boundary from where the hold began. Typing 4 and holding up has to accelerate as though 4
        // were the starting point, not the 25 still sitting in storage.
        let holdStart = base("4", stored: 25)
        var current = holdStart
        var reached: [Int] = []
        for _ in 0..<10 {
            current = AutoPauseStepper.nextValue(current: current, holdStartValue: holdStart, direction: 1)
            reached.append(current)
        }
        XCTAssertEqual(reached, [5, 6, 7, 8, 9, 10, 15, 20, 25, 30])
    }
}
