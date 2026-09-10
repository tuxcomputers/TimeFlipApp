@testable import FacetCore
import Foundation
import Testing

/// The watch that turns a spent `daily_limit` into a stopped clock, and the refusal that keeps it stopped.
///
/// `DailyLimitEnforcement` is where the decisions are tested; this is about what the app does with them, and about
/// the thing that makes the limit testable at all with no cube on the desk: **in manual mode the app is the clock**,
/// so stopping the device is the app's own pause path.
///
/// **Every reading here says `isCounting` as well as `timingState`, and that is not boilerplate.** `timingState` is about *this
/// app's* clock and answers `.idle` for a cube however busy it is; `isCounting` is whether the figure is moving, which
/// is the question the watch actually has to ask. These fixtures said only the first until run 116 found a cube five
/// seconds from its limit sitting there for 68 seconds with the tick never started.
@Suite @MainActor
final class DailyLimitWatchTests {
    private let clock = HandDrivenScheduler()
    private let window = Date(timeIntervalSince1970: 1_700_000_000)

    private func category(_ id: Int, limit: Int) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: "Break",
            iconName: nil,
            colourID: 0,
            colour: nil,
            usesWhiteLines: false,
            dailyLimitMinutes: limit,
            isCategoryActive: true
        )
    }

    /// A watch reading a reading the test controls, and counting the stops it asks for.
    private func watch(
        reading: @escaping () -> TimingReadout.Reading,
        stopped: @escaping () -> Void = {}
    ) -> DailyLimitWatch {
        DailyLimitWatch(
            timing: reading,
            windowStart: { _ in self.window },
            debugLog: nil,
            scheduler: clock,
            stopTiming: stopped
        )
    }

    private func reading(counting: Bool, limit: Int = 5, seconds: TimeInterval = 300) -> TimingReadout.Reading {
        TimingReadout.Reading(
            category: category(7, limit: limit),
            timingState: counting ? .running : .idle,
            seconds: seconds,
            isCounting: counting
        )
    }

    // MARK: - the tick itself
    //
    // **None of this could be asserted before the clock became a port.** `start`, `stop` and `resumeIfStopped`
    // built a `Timer` on `RunLoop.main` and there was nothing to look at, so the whole of what this section covers
    // was carried by the scripted suite and by run 116 finding it the hard way.

    @Test func testStartingArmsTheTick() {
        let watch = watch(reading: { self.reading(counting: true) })

        watch.start()

        #expect(clock.wakes.count == 1)
        #expect(clock.wakes.first?.seconds == DailyLimitWatch.intervalSeconds)
        #expect(clock.wakes.first?.repeating == true, "a heartbeat, not one wake that re-arms itself")
        #expect(clock.wakes.first?.mayGroup == false, "a limit is a deadline and must not be shuffled")
    }

    @Test func testNothingIsArmedWhileTheFigureIsNotMoving() {
        // **Run 116, 2026-08-27.** A cube sat five seconds from its limit for 68 seconds and nothing happened,
        // because the guard here asked `timingState == .running` and a cube leaves that `.idle` however busy it
        // is. `isCounting` is the question that is true for both sources.
        let watch = watch(reading: { self.reading(counting: false) })

        watch.start()

        #expect(clock.isEmpty)
    }

    @Test func testACubeArmsTheTickEvenThoughTheAppsOwnClockIsIdle() {
        // **The exact shape of run 116.** A cube is `.idle` as far as `TimingReadout` is concerned, because the app
        // is running no session of its own while it follows one, and yet the figure is moving. A guard asking
        // `timingState == .running` refuses this and the limit never lands; `isCounting` accepts it.
        let cube = TimingReadout.Reading(
            category: category(7, limit: 5), timingState: .idle, seconds: 300, isCounting: true
        )
        let watch = watch(reading: { cube })

        watch.start()

        #expect(clock.wakes.count == 1)
    }

    @Test func testStartingTwiceIsOneTick() {
        let watch = watch(reading: { self.reading(counting: true) })

        watch.start()
        watch.start()

        #expect(clock.arranged == 1, "the second start finds one already running and leaves it alone")
    }

    @Test func testStoppingTakesTheTickAway() {
        let watch = watch(reading: { self.reading(counting: true) })
        watch.start()

        watch.stop()

        #expect(clock.isEmpty)
    }

    @Test func testResumingAfterAStopArmsItAgain() {
        // What `onTimingChanged` calls, being the funnel every path that starts timing already goes through.
        let watch = watch(reading: { self.reading(counting: true) })
        watch.start()
        watch.stop()

        watch.resumeIfStopped()

        #expect(clock.wakes.count == 1)
    }

    @Test func testTheArmedTickIsTheOneThatSpendsTheBudget() throws {
        // The wire between the two halves: that the wake actually reaches `check`, rather than the tick being
        // armed and evaluating nothing.
        var stops = 0
        let watch = watch(reading: { self.reading(counting: true) }, stopped: { stops += 1 })
        watch.start()
        #expect(stops == 0)

        try clock.tick()

        #expect(stops == 1, "five minutes recorded against a five minute limit, so the clock is stopped")
    }

    @Test func testTheClockIsStoppedWhenTheBudgetIsSpent() {
        // The whole feature in one check: 5 minutes of limit, 5 minutes recorded, and the app stops itself.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 5), timingState: .running, seconds: 300, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 1)
        #expect(watch.isLimitReached)
    }

    @Test func testAClockShortOfTheLimitIsLeftRunning() {
        // 20 seconds short, which is where the archive's checklist staged its crossing and where this app's
        // scripted check stages it too.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 5), timingState: .running, seconds: 280, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 0)
        #expect(!(watch.isLimitReached))
    }

    @Test func testACategoryWithNoLimitIsNeverStopped() {
        // `daily_limit = 0` is no limit at all, so a whole day against it is not a crossing.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 0), timingState: .running, seconds: 86_400, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 0)
        #expect(!(watch.isLimitReached))
    }

    @Test func testItDoesNotStopTheSameSessionTwice() {
        // Once stopped, the reading comes back paused, and a second stop would start it again -- `togglePause` being
        // a toggle. This is the case that makes the latch matter here rather than only in the rules.
        var stops = 0
        var timingState = TimingState.running
        let watch = watch(
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), timingState: timingState, seconds: 300, isCounting: timingState == .running) },
            stopped: {
                stops += 1
                timingState = .paused
            }
        )

        watch.check(at: window)
        watch.check(at: window)
        watch.check(at: window)

        #expect(stops == 1, "the clock is stopped once, not on every tick after it")
    }

    @Test func testStartingItAgainOverTheLimitStopsItAgain() {
        // The limit is hard: picking the category back up does not buy more time, it is stopped on the next tick.
        var stops = 0
        var timingState = TimingState.running
        let watch = watch(
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), timingState: timingState, seconds: 300, isCounting: timingState == .running) },
            stopped: {
                stops += 1
                timingState = .paused
            }
        )

        watch.check(at: window)
        timingState = .running
        watch.check(at: window)

        #expect(stops == 2)
    }

    @Test func testACubeIsStoppedEvenThoughTheAppsOwnClockIsIdle() {
        // **The shape run 116 found, and the one every fixture above is the wrong shape for.** A cube produces a
        // reading that is `.idle` and counting at the same time: the app runs no session of its own while it follows
        // one, so `timingState` says idle however busy the cube is, and `isCounting` is the only thing that says the figure
        // is moving. Asking `timingState == .running` meant the tick never started, and a cube five seconds from its limit
        // sat on it for 68 seconds with nothing sent.
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            timingState: .idle,
            seconds: 300,
            isCounting: true,
            cubeFace: 1,
            cubePauseState: .running
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 1, "a cube over its limit is stopped, whatever the app's own clock is doing")
        #expect(watch.isLimitReached)
    }

    @Test func testACubeShortOfTheLimitIsLeftRunning() {
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            timingState: .idle,
            seconds: 280,
            isCounting: true,
            cubeFace: 1,
            cubePauseState: .running
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 0)
    }

    @Test func testAPausedCubeIsNotStoppedAgain() {
        // A stopped cube is not counting, which is the same answer the app's own paused clock gives -- so the one
        // question covers both and there is no mode to tell apart.
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            timingState: .idle,
            seconds: 300,
            isCounting: false,
            cubeFace: 1,
            cubePauseState: .paused
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 0, "nothing counting means nothing that can cross a limit")
    }

    @Test func testNothingBeingTimedIsNotACrossing() {
        var stops = 0
        let watch = watch(reading: { .idle }, stopped: { stops += 1 })

        watch.check(at: window)

        #expect(stops == 0)
        #expect(!(watch.isLimitReached))
    }

    @Test func testARaisedLimitLiftsTheRefusalWithoutStartingTheClock() {
        // Raising the limit on the Categories tab is answered immediately -- but in manual mode nothing starts
        // timing on its own. The user gets their Resume back; they do not get time recorded while they were away.
        var stops = 0
        var limit = 5
        var timingState = TimingState.running
        let watch = DailyLimitWatch(
            timing: { TimingReadout.Reading(category: self.category(7, limit: limit), timingState: timingState, seconds: 300, isCounting: timingState == .running) },
            windowStart: { _ in self.window },
            debugLog: nil,
            scheduler: clock,
            stopTiming: {
                stops += 1
                timingState = .paused
            }
        )

        watch.check(at: window)
        #expect(watch.isLimitReached)
        #expect(timingState == .paused)

        limit = 10

        // **No second `check` here, deliberately, and this test used to have one.** With it, this passed while the
        // app was broken: stopping the clock stands the tick down, so the real app never gets another `check` and the
        // refusal it asks about was answered from the last one for the rest of the launch (run 15, 2026-08-16). The
        // raised limit has to be answered by the ask itself.
        #expect(!(watch.isLimitReached), "the refusal is lifted")
        // The clock is the user's to start. `stopTiming` is the only thing this watch can call, so the proof that
        // nothing resumed on their behalf is that the session is still stopped and was stopped exactly once.
        #expect(timingState == .paused, "nothing started the clock on the user's behalf")
        #expect(stops == 1)
    }

    // MARK: - the refusal every path asks

    @Test func testAResumeIsRefusedWhileTheLimitIsSpent() {
        // Paused and over the limit: the one combination that cannot be clicked out of.
        #expect(!(ManualTimerRules.isClickable(.paused, isLimitReached: true)))
    }

    @Test func testPausingIsNeverRefused() {
        // Stopping stays available throughout. A limit that trapped somebody into recording time would be the
        // opposite of what it is for.
        #expect(ManualTimerRules.isClickable(.running, isLimitReached: true))
    }

    @Test func testTheOrdinaryCasesAreUnchanged() {
        #expect(ManualTimerRules.isClickable(.paused, isLimitReached: false))
        #expect(ManualTimerRules.isClickable(.running, isLimitReached: false))
        #expect(!(ManualTimerRules.isClickable(.idle, isLimitReached: false)))
        #expect(!(ManualTimerRules.isClickable(.idle, isLimitReached: true)))
    }

    @Test func testTheStatusItemsRightHalfBecomesANoOp() {
        // The archive exercised the refusal through this half rather than the menu item, precisely because the menu
        // item is disabled and clicking it proves nothing.
        #expect(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .paused, isLimitReached: true) == .ignore
        )
        #expect(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .paused, isLimitReached: false) == .togglePause
        )
    }

    @Test func testTheLeftHalfStillOpensTheMenu() {
        // Quit is only reachable through the menu, so no timingState may take the left half away.
        #expect(
            StatusItemClickRouter.action(isLeftSide: true, timingState: .paused, isLimitReached: true) == .showMenu
        )
    }

    @Test func testTheDropdownItemStillReadsResumeWhileItIsRefused() {
        // It says what clicking would do, and it will not do it. A dead item claiming something else is on offer
        // would be worse than a dead one telling the truth.
        #expect(ManualTimerRules.pauseMenuTitle(for: .paused) == "Resume")
    }
}
