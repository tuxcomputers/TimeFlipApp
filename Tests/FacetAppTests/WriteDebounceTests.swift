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
        waitABit()
        XCTAssertEqual(writes, 1)
    }

    func testAHoldOfManyTicksIsOneWrite() {
        // What the whole type is for. Each tick displaces the last, so the command carries the number the arrow was
        // let go on rather than one command per tick -- and `DeviceLogin.send` refuses a second command while the
        // first is out, so most of them would have been dropped anyway, unpredictably.
        let debounce = WriteDebounce(interval: quick)
        var written: [Int] = []

        for tick in 1...10 { debounce.schedule { written.append(tick) } }

        waitABit()
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

        waitABit()
        XCTAssertFalse(debounce.isPending, "and stops saying so once it has gone out")
    }

    func testAWriteAfterOneHasGoneOutIsItsOwn() {
        // Somebody moving a field, waiting, and moving it again is two writes rather than one: the second is not a
        // continuation of the first, and the value stood still in between.
        let debounce = WriteDebounce(interval: quick)
        var writes = 0

        debounce.schedule { writes += 1 }
        waitABit()
        debounce.schedule { writes += 1 }
        waitABit()

        XCTAssertEqual(writes, 2)
    }
}
