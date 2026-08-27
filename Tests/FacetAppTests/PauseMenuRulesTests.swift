@testable import FacetApp
import XCTest

/// The dropdown's Pause item: what it acts on, what it is called, and whether it can be chosen at all.
///
/// **The fault these were written for.** The item asked only about the app's own clock, so
/// `ManualTimerRules.isClickable` answered `false` for `.idle` and it sat greyed out with a cube connected -- while a
/// single click on the status item's right half, decided two lines away in `StatusItemClickRouter`, paused that same
/// cube. One surface was taught about the cube and the other was not, and nothing failed. `CubeLockRules` records the
/// archive dying of exactly that.
final class PauseMenuRulesTests: XCTestCase {
    // MARK: - what it acts on

    func testAConnectedUnlockedCubeIsPausableFromTheMenu() {
        // The whole of the report: connected and unlocked, so the item works. It used to be dead here.
        XCTAssertEqual(
            PauseMenuRules.target(timing: .idle, isCubeConnected: true, isCubeLocked: false),
            .cube
        )
        XCTAssertTrue(PauseMenuRules.isEnabled(.cube))
    }

    func testALockedCubeCannotBePausedSoTheItemIsDead() {
        // A locked cube is frozen on the face it is on and ignores everything but an unlock, so an item offering to
        // pause one is an offer that is going to be refused. `CubeLock.togglePause` refuses it in as many words; a
        // menu is the one surface that can say so *before* it is pressed.
        XCTAssertEqual(
            PauseMenuRules.target(timing: .idle, isCubeConnected: true, isCubeLocked: true),
            .nothing
        )
        XCTAssertFalse(PauseMenuRules.isEnabled(.nothing))
    }

    func testACubeNobodyHasAskedIsTreatedAsUnlocked() {
        // The same way round as `CubeLockRules.title`. A cube nobody has asked is far more often running than locked,
        // and of the two ways to be wrong, an enabled item that gets refused says why in the log, while one greyed
        // out for a lock that is not there offers no way to discover it was wrong.
        XCTAssertEqual(
            PauseMenuRules.target(timing: .idle, isCubeConnected: true, isCubeLocked: nil),
            .cube
        )
    }

    func testWithNoCubeConnectedThereIsNothingToActOn() {
        // The connection, not the pairing: it ends in a command and a command needs a live link.
        XCTAssertEqual(
            PauseMenuRules.target(timing: .idle, isCubeConnected: false, isCubeLocked: false),
            .nothing
        )
    }

    func testARunningManualSessionIsNeverTakenOverByAConnectedCube() {
        // `StatusItemClickRouter`'s precedence, kept in the same order so the two surfaces cannot come to disagree
        // about which clock the gesture belongs to.
        XCTAssertEqual(
            PauseMenuRules.target(timing: .running, isCubeConnected: true, isCubeLocked: false),
            .appClock
        )
        XCTAssertEqual(
            PauseMenuRules.target(timing: .paused, isCubeConnected: true, isCubeLocked: false),
            .appClock
        )
    }

    func testASpentDailyLimitStaysSpentRatherThanFallingThroughToTheCube() {
        // Otherwise the limit would be undone by reaching for the menu instead of the status item, which is the same
        // hole `StatusItemClickRouter` closes for the right half.
        XCTAssertEqual(
            PauseMenuRules.target(
                timing: .paused, isCubeConnected: true, isCubeLocked: false, isLimitReached: true
            ),
            .nothing
        )
    }

    // MARK: - what it is called

    func testTheCubesOwnPauseStateNamesTheItem() {
        XCTAssertEqual(PauseMenuRules.title(for: .cube, timing: .idle, isCubePaused: false), "Pause")
        XCTAssertEqual(PauseMenuRules.title(for: .cube, timing: .idle, isCubePaused: true), "Resume")
    }

    func testADeadItemReadsPauseRatherThanResume() {
        // Carried over from the previous app with its reasoning: a dead item claiming there is something to resume is
        // worse than one claiming there is something to pause. It matters most on a locked cube, which reports itself
        // paused whatever its pause byte says -- so "Resume" would be an offer the cube is certain to refuse.
        XCTAssertEqual(
            PauseMenuRules.title(for: .nothing, timing: .idle, isCubePaused: true),
            "Pause"
        )
    }

    func testTheAppsOwnClockStillNamesTheItemWhenItOwnsIt() {
        XCTAssertEqual(PauseMenuRules.title(for: .appClock, timing: .running), "Pause")
        XCTAssertEqual(PauseMenuRules.title(for: .appClock, timing: .paused), "Resume")
    }

    // MARK: - and it agrees with the surface beside it

    func testTheMenuAndTheRightHalfAgreeOnWhoOwnsTheGesture() {
        // The point of the whole type. Every state where the router sends a single right-half click somewhere is a
        // state where the menu must offer the same thing, or the two surfaces disagree again -- which is the failure
        // that has no symptom until somebody notices a greyed item above a working click.
        for locked in [false, true] {
            for connected in [false, true] {
                for state in [TimingState.idle, .running, .paused] {
                    let click = StatusItemClickRouter.action(
                        isLeftSide: false, timing: state, isCubeConnected: connected, clickCount: 1
                    )
                    let menu = PauseMenuRules.target(
                        timing: state, isCubeConnected: connected, isCubeLocked: locked
                    )
                    switch click {
                    case .togglePause:
                        XCTAssertEqual(menu, .appClock, "state \(state), connected \(connected)")
                    case .toggleCubePause:
                        // The one deliberate difference, and it is a difference in *affordance* rather than in
                        // outcome: the click is allowed through and refused by `CubeLock.togglePause` with a reason,
                        // because a click has no way to show it is unavailable. The menu can grey out instead, so it
                        // does. Both end with the cube unpaused and told why.
                        XCTAssertEqual(
                            menu, locked ? .nothing : .cube,
                            "state \(state), connected \(connected), locked \(locked)"
                        )
                    case .ignore:
                        XCTAssertEqual(menu, .nothing, "state \(state), connected \(connected)")
                    case .showMenu, .toggleCubeLock:
                        XCTFail("a single click on the right half is never \(click)")
                    }
                }
            }
        }
    }

    // MARK: - a spent limit, with a cube on the other end

    func testTheItemIsDeadForACubeThatWouldBeStartedOnASpentLimit() {
        // The limit was only ever asked about the app's own clock, and a cube leaves that `.idle`, so every cube click
        // fell past the one place it was consulted.
        let target = PauseMenuRules.target(
            timing: .idle,
            isCubeConnected: true,
            isCubeLocked: false,
            isCubePaused: true,
            isLimitReached: true
        )
        XCTAssertEqual(target, .nothing)
        XCTAssertFalse(PauseMenuRules.isEnabled(target))
    }

    func testTheItemStillStopsACubeOnASpentLimit() {
        let target = PauseMenuRules.target(
            timing: .idle,
            isCubeConnected: true,
            isCubeLocked: false,
            isCubePaused: false,
            isLimitReached: true
        )
        XCTAssertEqual(target, .cube)
        XCTAssertTrue(PauseMenuRules.isEnabled(target))
    }
}
