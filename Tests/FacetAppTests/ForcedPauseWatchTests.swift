@testable import FacetApp
import XCTest

/// Putting `ForcedPause`'s decision on the wire: what is sent, when it is claimed, and the window in which the tables
/// have not caught up with the command yet.
///
/// **The re-entrancy is the reason this file exists.** It is not a theoretical race. `device_event` goes on saying the
/// cube is running until the fetch that follows the pause lands, and that fetch is itself what calls `check` again --
/// so without the guard the driver asks for a second pause off the back of its own first one. Finding 9 in
/// `docs/timeflip2-firmware-observations.md` is what makes the fetch unavoidable: the cube files the record and
/// announces nothing, so there is no notification the app could have waited on instead.
@MainActor
final class ForcedPauseWatchTests: XCTestCase {
    /// A bench whose every answer is a variable, so a test names only what it is about.
    @MainActor
    private final class Bench {
        var face: Int? = 5
        var facesWithCategory: Set<Int> = []
        var isPaused: Bool? = false
        var isLocked: Bool? = false
        var isCubeConnected = true
        var limitIsHolding = false

        /// Every `setPause` the watch asked for, in order.
        private(set) var sent: [Bool] = []
        /// Whether the cube confirms what it is sent. `false` is a command that went out and did not take.
        var confirms = true
        /// Whether `CubeLock` accepts the command at all. `false` is a cube that is locked or unreachable, where the
        /// completion is never called.
        var accepts = true

        /// The fetch the watch asked for, held so a test can decide when it lands.
        private(set) var pendingFetch: (() -> Void)?
        private(set) var fetches: [String] = []

        func landTheFetch() {
            let fetch = pendingFetch
            pendingFetch = nil
            fetch?()
        }

        func make() -> ForcedPauseWatch {
            ForcedPauseWatch(
                cubeFace: { self.face },
                hasCategory: { self.facesWithCategory.contains($0) },
                isPaused: { self.isPaused },
                isLocked: { self.isLocked },
                isCubeConnected: { self.isCubeConnected },
                limitIsHolding: { self.limitIsHolding },
                setPause: { wanted, then in
                    guard self.accepts else { return false }
                    self.sent.append(wanted)
                    then(self.confirms)
                    return true
                },
                refreshHistory: { reason, done in
                    self.fetches.append(reason)
                    self.pendingFetch = done
                },
                debugLog: nil
            )
        }
    }

    // MARK: - the pause

    func testAnEventOnAFaceWithNoCategoryStopsTheCube() {
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        XCTAssertEqual(bench.sent, [true])
        XCTAssertEqual(bench.fetches.count, 1, "the cube announces nothing, so the app has to go and ask")
    }

    func testAnEventOnAFaceWithACategoryStopsNothing() {
        let bench = Bench()
        bench.facesWithCategory = [5]
        let watch = bench.make()
        watch.check()
        XCTAssertTrue(bench.sent.isEmpty)
        XCTAssertTrue(bench.fetches.isEmpty)
    }

    // MARK: - the window the guard exists for

    func testTheFetchItAsksForCannotMakeItSendASecondPause() {
        // The exact sequence: pause sent, cube confirms, app asks for history, and that fetch's own `onChanged` calls
        // `check` again -- while `device_event` still says the cube is running on a face with no category.
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        XCTAssertEqual(bench.sent, [true])

        watch.check()
        watch.check()
        XCTAssertEqual(bench.sent, [true], "a command is in flight, so nothing else is decided from a stale table")
    }

    func testItLooksAgainOnceTheFetchHasWritten() {
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        // The fetch lands and writes what the cube says: stopped, on the same face.
        bench.isPaused = true
        bench.landTheFetch()

        watch.check()
        XCTAssertEqual(bench.sent, [true], "the cube is stopped now, so there is nothing left to ask for")
    }

    func testACommandThatWasNeverSentLeavesNothingInFlight() {
        // `CubeLock` answers false for a cube that is locked or unreachable, and then never calls the completion. A
        // flag left set there would wedge the watch for the rest of the launch.
        let bench = Bench()
        bench.accepts = false
        let watch = bench.make()
        watch.check()
        XCTAssertTrue(bench.sent.isEmpty)

        bench.accepts = true
        watch.check()
        XCTAssertEqual(bench.sent, [true], "the watch is not wedged by a command that never went out")
    }

    // MARK: - claiming

    func testAPauseTheCubeRefusedIsNotClaimed() {
        // The command went out and did not take, so there is no pause of this app's to lift later.
        let bench = Bench()
        bench.confirms = false
        let watch = bench.make()
        watch.check()
        bench.landTheFetch()

        // The cube turns out to be stopped anyway, and the face is given a category. That pause is not this app's.
        bench.isPaused = true
        bench.facesWithCategory = [5]
        watch.check()
        XCTAssertEqual(bench.sent, [true], "nothing was claimed, so nothing is lifted")
    }

    func testGivingTheFaceACategoryStartsTheCubeAgain() {
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        bench.isPaused = true
        bench.landTheFetch()

        // Nothing physical happens: the table changes under a cube sitting still.
        bench.facesWithCategory = [5]
        watch.check()
        XCTAssertEqual(bench.sent, [true, false])
    }

    func testAFlipOntoAnAssignedFaceNeedsNoCommand() {
        // The firmware lifts the pause on the turn, so the frame reports the cube already running.
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        bench.isPaused = true
        bench.landTheFetch()

        bench.face = 2
        bench.facesWithCategory = [2]
        bench.isPaused = false
        watch.check()
        XCTAssertEqual(bench.sent, [true], "nothing to send: the cube is already running")
    }

    // MARK: - what it will not touch

    func testALockedCubeIsLeftAlone() {
        let bench = Bench()
        bench.isLocked = true
        let watch = bench.make()
        watch.check()
        XCTAssertTrue(bench.sent.isEmpty)
    }

    func testAPauseTheDailyLimitIsHoldingIsNotLifted() {
        let bench = Bench()
        let watch = bench.make()
        watch.check()
        bench.isPaused = true
        bench.landTheFetch()

        bench.facesWithCategory = [5]
        bench.limitIsHolding = true
        watch.check()
        XCTAssertEqual(bench.sent, [true], "a hard limit has to win, or assigning a category is a way round it")
    }

    func testTheAppsOwnFacesAreNotTheCubes() {
        // `main.swift` filters 13 and 14 out before the watch sees them, which is this answering nil.
        let bench = Bench()
        bench.face = nil
        let watch = bench.make()
        watch.check()
        XCTAssertTrue(bench.sent.isEmpty)
    }
}
