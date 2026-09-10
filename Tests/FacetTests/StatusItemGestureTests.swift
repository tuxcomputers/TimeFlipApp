@testable import FacetCore
import Foundation
import Testing

/// A press on the status item, from the two facts the platform reports to the thing it ends in.
///
/// **The hold-back had no unit coverage before this**, only `Tests/Scripted/57-cube-pause.sh`, which is set
/// aside for the duration of the Linux port. `StatusItemClickRouterTests` has fifteen tests on *which* action a
/// press means, and none of them could say what happened next, because what happened next was a
/// `DispatchWorkItem` on the main queue inside a Mac-only class. That is the shape the architecture review
/// calls a pure function extracted for testability while the bug hides in how it is called: the interesting
/// behaviour here is not the routing, it is that a second press has to reach the first one's pause and cancel
/// it before it goes.
@Suite @MainActor
final class StatusItemGestureTests {
    private let clock = HandDrivenScheduler()
    private let database: TemporaryDatabase
    private var debugLog: DebugLog!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        debugLog = DebugLog(databaseURL: database.debugURL, isRecording: true)
    }

    deinit {
        database.remove()
    }

    @MainActor
    final class World {
        var reading: TimingReadout.Reading = .idle
        var cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked, cubePauseState: .running)
        var isLimitReached = false
        var appPauses = 0
        var cubePauses = 0
        var cubeLocks = 0
        var menusShown = 0
    }

    /// A tenth of a second, standing in for the user's own double-click setting. Nothing waits for it: the
    /// number is asserted where it matters and the wake is driven by hand everywhere else.
    private static let doubleClick: TimeInterval = 0.1

    private func gesture(_ world: World) -> StatusItemGesture {
        StatusItemGesture(
            timing: { world.reading },
            cube: { world.cube },
            isLimitReached: { world.isLimitReached },
            togglePause: { world.appPauses += 1 },
            toggleCubePause: { world.cubePauses += 1 },
            toggleCubeLock: { world.cubeLocks += 1 },
            showMenu: { world.menusShown += 1 },
            scheduler: clock,
            doubleClickInterval: { Self.doubleClick },
            debugLog: debugLog
        )
    }

    private func rows(_ pattern: String) -> Int {
        Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0
    }

    // MARK: - the left half

    @Test func testTheLeftHalfOpensTheMenu() {
        let world = World()

        gesture(world).clicked(isLeftSide: true, clickCount: 1)

        #expect(world.menusShown == 1)
        #expect(clock.isEmpty, "nothing is held back: a menu is not half of a gesture")
    }

    @Test func testAPressWithNoSideOpensTheMenu() {
        // A synthetic `performClick` carries no event. The menu is the safe answer, being the one thing
        // reachable in every state and the only way out of the app.
        let world = World()

        gesture(world).clickedWithNoSide()

        #expect(world.menusShown == 1)
        #expect(rows("Status item clicked: no event%") == 1)
    }

    // MARK: - the right half, and the pause that waits

    @Test func testASinglePressArrangesTheCubePauseRatherThanSendingIt() {
        let world = World()

        gesture(world).clicked(isLeftSide: false, clickCount: 1)

        #expect(world.cubePauses == 0, "nothing has gone to the cube yet")
        #expect(clock.wakes.count == 1)
        #expect(clock.wakes.first?.seconds == Self.doubleClick, "the user's own double-click setting")
        #expect(clock.wakes.first?.mayGroup == false, "a gesture in progress must not be shuffled")
    }

    @Test func testThePauseGoesOnceTheDoubleClickWindowPasses() throws {
        let world = World()
        let gesture = gesture(world)
        gesture.clicked(isLeftSide: false, clickCount: 1)

        try clock.tick()

        #expect(world.cubePauses == 1)
        #expect(world.cubeLocks == 0)
    }

    @Test func testASecondPressLocksInsteadOfPausingAndLocking() {
        // **The whole reason the pause waits.** Without the cancel, a double click sends a pause *and* a lock,
        // which is two commands for one gesture and leaves the cube somewhere nobody asked for.
        let world = World()
        let gesture = gesture(world)
        gesture.clicked(isLeftSide: false, clickCount: 1)
        #expect(clock.wakes.count == 1, "precondition: a pause is waiting")

        gesture.clicked(isLeftSide: false, clickCount: 2)

        #expect(world.cubeLocks == 1)
        #expect(world.cubePauses == 0, "the waiting pause was dropped rather than also sent")
        #expect(clock.isEmpty, "and nothing is left armed to fire afterwards")
        #expect(rows("The waiting cube pause was dropped: a second click made it a lock") == 1)
    }

    @Test func testANewerPressReplacesTheOneWaiting() {
        let world = World()
        let gesture = gesture(world)
        gesture.clicked(isLeftSide: false, clickCount: 1)

        gesture.clicked(isLeftSide: false, clickCount: 1)

        #expect(clock.wakes.count == 1, "one waiting pause, not two")
        #expect(rows("The waiting cube pause was dropped: a newer click replaced it") == 1)
    }

    @Test func testAThirdPressDoesNotLandBackOnThePause() {
        // `>= 2` rather than `== 2` in the router, so a hand that clicks three times locks rather than pausing.
        let world = World()

        gesture(world).clicked(isLeftSide: false, clickCount: 3)

        #expect(world.cubeLocks == 1)
        #expect(world.cubePauses == 0)
        #expect(clock.isEmpty)
    }

    // MARK: - the app's own clock

    @Test func testTheAppsOwnClockIsStoppedAtOnce() {
        // No lock on a manual session, so there is no second gesture this might turn out to be half of.
        let world = World()
        world.reading = TimingReadout.Reading(category: nil, timingState: .running, seconds: 30, isCounting: true)

        gesture(world).clicked(isLeftSide: false, clickCount: 1)

        #expect(world.appPauses == 1)
        #expect(clock.isEmpty, "nothing waits")
    }

    // MARK: - the row every press writes

    @Test func testEveryPressLeavesARowIncludingOneThatDidNothing() {
        // **A press that deliberately did nothing and a press that never arrived look identical afterwards**
        // unless one of them left a row, and telling those two apart is the difference between a routing bug
        // and a missed hit.
        let world = World()
        world.cube = CubeReading(isCubeConnected: false, cubeLockState: .unknown)

        gesture(world).clicked(isLeftSide: false, clickCount: 1)

        #expect(world.cubePauses == 0)
        #expect(world.cubeLocks == 0)
        #expect(rows("Status item clicked: side=right clicks=1 state=idle -> ignore") == 1)
    }
}
