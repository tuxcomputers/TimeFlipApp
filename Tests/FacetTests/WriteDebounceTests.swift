@testable import FacetCore
import Foundation
import Testing

/// Covers holding a write back until the value stops moving.
///
/// **Driven on a tiny interval rather than the real half-second**, so the suite does not sit through the wait to find
/// out whether one call or three arrived. What is being checked is the coalescing and the cancelling, neither of which
/// is a fact about the duration.
///
/// **And driven by calling `fire()` rather than by waiting for a run loop at all**, which is what lets this suite run
/// on Linux. A `@MainActor` swift-testing test does not run on the main thread there, so the `RunLoop.main` timer
/// `schedule` arms never fires and every wait timed out (measured 2026-09-09, `docs/linux-port.md`). Calling the
/// timeout body is the bargain `HistoryTimer` has always made: what it skips is `Timer` itself, which is the part
/// with no decisions in it.
///
/// **So nothing here says a real timer ever fires**, and that is worth saying rather than implying. On the Mac the
/// scripted suite covers the debounced setting writes against a real cube.
///
/// The waiting this replaced is worth remembering rather than merely deleting, because it was not naive: it spun the
/// run loop and polled for the condition instead of sleeping a fixed span, precisely because a fixed wait is a claim
/// about how busy the machine is. On 2026-08-25 the timer behind `testAWriteAfterOneHasGoneOutIsItsOwn` had not fired
/// inside an 80ms window on a loaded CI runner, the second `schedule` cancelled it as it is meant to, one write
/// arrived where two were expected, and CI failed on a debounce that was working perfectly. Driving the body removes
/// that whole class of flake rather than widening the window again.
@Suite @MainActor
final class WriteDebounceTests {
    private let quick: TimeInterval = 0.02

    @Test func testTheRealIntervalClearsTheStepper() {
        // Not a preference: the fastest a held arrow moves is one tick per `singleStepInterval` and the slowest is
        // one per `fiveStepInterval`, so the wait has to outlast the slower of them or a hold writes part way
        // through itself.
        #expect(WriteDebounce.interval > StepperHoldRules.fiveStepInterval)
        #expect(WriteDebounce.interval > StepperHoldRules.singleStepInterval)
    }

    @Test func testOneWriteGoesOutAfterTheValueStopsMoving() {
        let debounce = WriteDebounce(interval: quick)
        var writes = 0

        debounce.schedule { writes += 1 }
        #expect(writes == 0, "nothing goes out while the value could still move")

        debounce.fire()

        #expect(writes == 1, "and exactly one once it has stopped")
    }

    @Test func testAHoldOfManyTicksIsOneWrite() {
        // What the whole type is for. Each tick displaces the last, so the command carries the number the arrow was
        // let go on rather than one command per tick -- and `DeviceLogin.send` refuses a second command while the
        // first is out, so most of them would have been dropped anyway, unpredictably.
        let debounce = WriteDebounce(interval: quick)
        var written: [Int] = []

        for tick in 1...10 { debounce.schedule { written.append(tick) } }
        debounce.fire()

        #expect(written == [10], "only the last one, and only once")
    }

    @Test func testACancelStopsTheWriteThatWasComing() {
        // **The archive's measured trap.** A control that writes immediately -- the Disable box -- has to take the
        // pending one out of the way first, because it carries values worked out before the flag flipped and would
        // undo the toggle by landing after it.
        let debounce = WriteDebounce(interval: quick)
        var writes = 0
        debounce.schedule { writes += 1 }

        debounce.cancel()

        // **Fired deliberately after the cancel**, which asks something stronger than the fixed wait this replaces.
        // That waited to see whether an invalidated timer went off; this says that even if the body did run, the
        // cancelled write is no longer there to make.
        debounce.fire()

        #expect(writes == 0)
    }

    @Test func testCancellingWhenNothingIsPendingIsHarmless() {
        let debounce = WriteDebounce(interval: quick)

        debounce.cancel()
        debounce.cancel()

        #expect(!debounce.isPending)
    }

    @Test func testItSaysWhetherOneIsWaiting() {
        let debounce = WriteDebounce(interval: quick)
        #expect(!debounce.isPending)

        debounce.schedule {}
        #expect(debounce.isPending)

        debounce.fire()

        #expect(!debounce.isPending, "and it stops saying so once the write has gone out")
    }

    @Test func testAWriteAfterOneHasGoneOutIsItsOwn() {
        // Somebody moving a field, waiting, and moving it again is two writes rather than one: the second is not a
        // continuation of the first, and the value stood still in between.
        let debounce = WriteDebounce(interval: quick)
        var writes = 0

        debounce.schedule { writes += 1 }
        // **The first one going out is what makes the two separate.** `schedule` cancels whatever is pending, so a
        // second arriving before the first has fired is one write rather than two -- which is the right behaviour,
        // and not what is being checked here.
        debounce.fire()
        #expect(writes == 1)

        debounce.schedule { writes += 1 }
        debounce.fire()

        #expect(writes == 2, "and the second is its own rather than a continuation")
    }
}
