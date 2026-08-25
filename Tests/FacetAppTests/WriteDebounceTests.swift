@testable import FacetApp
import XCTest

/// Covers holding a write back until the value stops moving.
///
/// **Driven on a tiny interval rather than the real half-second**, so the suite does not sit through the wait to find
/// out whether one call or three arrived. What is being checked is the coalescing and the cancelling, neither of which
/// is a fact about the duration.
@MainActor
final class WriteDebounceTests: XCTestCase {
    private let quick: TimeInterval = 0.02

    /// Waits for the write to **have happened**, rather than for a length of time somebody guessed would cover it.
    ///
    /// **A fixed wait is a claim about how busy the machine is, and CI is busier than this one.** These tests drive a
    /// 20ms timer and waited 80ms for it, which is generous here and thin on a loaded runner: on 2026-08-25 the
    /// `Timer` behind `testAWriteAfterOneHasGoneOutIsItsOwn` had not fired inside that window, the second `schedule`
    /// cancelled it as it is meant to, one write arrived where two were expected, and CI failed on a debounce that
    /// was working perfectly. The same commit passed in the job beside it, which is what a timing flake looks like.
    ///
    /// So the deadline is only a give-up point: this returns the moment the condition holds. The run loop is spun
    /// rather than slept through, because that is what lets the timer fire at all -- it is scheduled in `.common`,
    /// which `.default` belongs to.
    private func waitUntil(
        _ what: String,
        within timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// Waits a fixed span, which is only ever right for asserting that something **did not** happen: an absence has
    /// no effect to wait on, so the only question is whether it was given long enough to show up.
    private func waitABit(_ multiple: Double = 4) {
        let done = expectation(description: "the timer had its chance")
        DispatchQueue.main.asyncAfter(deadline: .now() + quick * multiple) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testTheRealIntervalClearsTheStepper() {
        // Not a preference: the fastest a held arrow moves is one tick per `singleStepInterval` and the slowest is
        // one per `fiveStepInterval`, so the wait has to outlast the slower of them or a hold writes part way
        // through itself.
        XCTAssertGreaterThan(WriteDebounce.interval, StepperHoldRules.fiveStepInterval)
        XCTAssertGreaterThan(WriteDebounce.interval, StepperHoldRules.singleStepInterval)
    }

    func testOneWriteGoesOutAfterTheValueStopsMoving() {
        let debounce = WriteDebounce(interval: quick)
        var writes = 0

        debounce.schedule { writes += 1 }

        XCTAssertEqual(writes, 0, "nothing goes out while the value could still move")

        waitUntil("the write goes out once the value has stopped moving") { writes == 1 }
    }

    func testAHoldOfManyTicksIsOneWrite() {
        // What the whole type is for. Each tick displaces the last, so the command carries the number the arrow was
        // let go on rather than one command per tick -- and `DeviceLogin.send` refuses a second command while the
        // first is out, so most of them would have been dropped anyway, unpredictably.
        let debounce = WriteDebounce(interval: quick)
        var written: [Int] = []

        for tick in 1...10 { debounce.schedule { written.append(tick) } }

        waitUntil("the last tick is written") { written == [10] }
        XCTAssertEqual(written, [10], "only the last one, and only once")
    }

    func testACancelStopsTheWriteThatWasComing() {
        // **The archive's measured trap.** A control that writes immediately -- the Disable box -- has to take the
        // pending one out of the way first, because it carries values worked out before the flag flipped and would
        // undo the toggle by landing after it.
        let debounce = WriteDebounce(interval: quick)
        var writes = 0
        debounce.schedule { writes += 1 }

        debounce.cancel()

        waitABit()
        XCTAssertEqual(writes, 0)
    }

    func testCancellingWhenNothingIsPendingIsHarmless() {
        let debounce = WriteDebounce(interval: quick)

        debounce.cancel()
        debounce.cancel()

        XCTAssertFalse(debounce.isPending)
    }

    func testItSaysWhetherOneIsWaiting() {
        let debounce = WriteDebounce(interval: quick)
        XCTAssertFalse(debounce.isPending)

        debounce.schedule {}
        XCTAssertTrue(debounce.isPending)

        waitUntil("it stops saying so once the write has gone out") { !debounce.isPending }
    }

    func testAWriteAfterOneHasGoneOutIsItsOwn() {
        // Somebody moving a field, waiting, and moving it again is two writes rather than one: the second is not a
        // continuation of the first, and the value stood still in between.
        let debounce = WriteDebounce(interval: quick)
        var writes = 0

        debounce.schedule { writes += 1 }
        // **Waited for, not slept through, and that is the whole of this test.** `schedule` cancels whatever is
        // pending, so a second one arriving before the first has fired is one write rather than two -- which is the
        // right behaviour and not what is being checked here. The wait is what makes the two separate.
        waitUntil("the first write goes out") { writes == 1 }

        debounce.schedule { writes += 1 }
        waitUntil("and the second is its own rather than a continuation") { writes == 2 }

        XCTAssertEqual(writes, 2)
    }
}
