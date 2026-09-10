@testable import FacetCore
import Foundation
import Testing

/// Covers holding a write back until the value stops moving.
///
/// **Driven through `HandDrivenScheduler`**, which is the third slot in the clock's square and the reason none of
/// this waits for anything. That helper carries the two measurements behind the choice: a `@MainActor`
/// swift-testing test does not run on the main thread on Linux, so a `RunLoop.main` timer never fires there, and a
/// polled wait failed CI on 2026-08-25 for a debounce that was working perfectly.
///
/// **The real half-second is now what is under test**, where a stand-in interval used to be. Nothing here sits
/// through it, so there is no longer a reason to pass a smaller one, and `testOneWriteGoesOutAfterTheValueStopsMoving`
/// asserts the wake was armed for `WriteDebounce.interval` itself.
///
/// **Nothing here says a real timer ever fires.** On the Mac the scripted suite covers the debounced setting writes
/// against a real cube.
@Suite @MainActor
final class WriteDebounceTests {

    @Test func testTheRealIntervalClearsTheStepper() {
        // Not a preference: the fastest a held arrow moves is one tick per `singleStepInterval` and the slowest is
        // one per `fiveStepInterval`, so the wait has to outlast the slower of them or a hold writes part way
        // through itself.
        #expect(WriteDebounce.interval > StepperHoldRules.fiveStepInterval)
        #expect(WriteDebounce.interval > StepperHoldRules.singleStepInterval)
    }

    @Test func testOneWriteGoesOutAfterTheValueStopsMoving() throws {
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)
        var writes = 0

        debounce.schedule { writes += 1 }
        #expect(writes == 0, "nothing goes out while the value could still move")
        #expect(clock.wakes.first?.seconds == WriteDebounce.interval, "armed for the real wait, not a stand-in")
        #expect(clock.wakes.first?.repeating == false, "a debounce is one wake, not a heartbeat")

        try clock.tick()

        #expect(writes == 1, "and exactly one once it has stopped")
    }

    @Test func testAHoldOfManyTicksIsOneWrite() throws {
        // What the whole type is for. Each tick displaces the last, so the command carries the number the arrow was
        // let go on rather than one command per tick -- and `DeviceLogin.send` refuses a second command while the
        // first is out, so most of them would have been dropped anyway, unpredictably.
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)
        var written: [Int] = []

        for tick in 1...10 { debounce.schedule { written.append(tick) } }
        try clock.tick()

        #expect(written == [10], "only the last one, and only once")
    }

    @Test func testACancelStopsTheWriteThatWasComing() throws {
        // **The archive's measured trap.** A control that writes immediately -- the Disable box -- has to take the
        // pending one out of the way first, because it carries values worked out before the flag flipped and would
        // undo the toggle by landing after it.
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)
        var writes = 0
        debounce.schedule { writes += 1 }
        // Kept before the cancel takes it off the clock, so the body can still be run below.
        let armed = try #require(clock.wakes.first)

        debounce.cancel()

        // **Run deliberately after the cancel**, which asks something stronger than a wait ever could. A wait only
        // sees whether an invalidated timer went off; this runs the body outright and says that even then, the
        // cancelled write is no longer there to make.
        armed.tick()

        #expect(writes == 0)
    }

    @Test func testCancellingWhenNothingIsPendingIsHarmless() throws {
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)

        debounce.cancel()
        debounce.cancel()

        #expect(!debounce.isPending)
    }

    @Test func testItSaysWhetherOneIsWaiting() throws {
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)
        #expect(!debounce.isPending)

        debounce.schedule {}
        #expect(debounce.isPending)

        try clock.tick()

        #expect(!debounce.isPending, "and it stops saying so once the write has gone out")
    }

    @Test func testAWriteAfterOneHasGoneOutIsItsOwn() throws {
        // Somebody moving a field, waiting, and moving it again is two writes rather than one: the second is not a
        // continuation of the first, and the value stood still in between.
        let clock = HandDrivenScheduler()
        let debounce = WriteDebounce(scheduler: clock)
        var writes = 0

        debounce.schedule { writes += 1 }
        // **The first one going out is what makes the two separate.** `schedule` cancels whatever is pending, so a
        // second arriving before the first has fired is one write rather than two -- which is the right behaviour,
        // and not what is being checked here.
        try clock.tick()
        #expect(writes == 1)

        debounce.schedule { writes += 1 }
        try clock.tick()

        #expect(writes == 2, "and the second is its own rather than a continuation")
    }
}
