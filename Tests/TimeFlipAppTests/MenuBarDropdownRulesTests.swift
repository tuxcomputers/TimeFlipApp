@testable import TimeFlipApp
import XCTest

/// The dropdown's Pause and Lock: whether each can be chosen, and what Pause is called.
///
/// These were expressions inside `rebuildMenu()`, which builds real `NSMenuItem`s, so nothing could
/// reach them. That is how the two ways into the same gesture came to disagree: the status item's
/// right half was taught to pause in manual mode and the menu item above it was left dead, and no
/// test noticed because none could.
final class MenuBarDropdownRulesTests: XCTestCase {
    private func allowsPause(
        _ status: ConnectionStatus,
        paired: Bool = true,
        locked: Bool = false,
        paused: Bool = false,
        limitReached: Bool = false
    ) -> Bool {
        MenuBarDropdownRules.allowsPause(
            connectionStatus: status,
            isPaired: paired,
            isLocked: locked,
            isPaused: paused,
            isDailyLimitReached: limitReached
        )
    }

    private func allowsLock(_ status: ConnectionStatus, paired: Bool = true) -> Bool {
        MenuBarDropdownRules.allowsLock(connectionStatus: status, isPaired: paired)
    }

    private func title(_ status: ConnectionStatus, paired: Bool = true, paused: Bool) -> String {
        MenuBarDropdownRules.pauseTitle(connectionStatus: status, isPaired: paired, isPaused: paused)
    }

    // MARK: - Manual mode

    func testManualModeCanPauseFromTheMenu() {
        // The requirement, and the agreement it restores: the status item's right half pauses a
        // manual session, so the item sitting above it must not be dead.
        XCTAssertTrue(allowsPause(.manual))
    }

    func testManualModeCannotLockFromTheMenu() {
        // Pause survived because the thing it acts on moved into the app. Lock has no such half:
        // it is a device command, and there is no device.
        XCTAssertFalse(allowsLock(.manual))
    }

    func testAStaleLockDoesNotDisableTheManualPause() {
        // `isLocked` belongs to a cube, and in manual mode this launch never reached one. Letting a
        // left-over true from anywhere disable the manual timer's only menu control would strand it
        // wherever it happened to be.
        XCTAssertTrue(allowsPause(.manual, locked: true))
    }

    func testTheManualPauseDoesNotDependOnThePairing() {
        // Manual mode is reached from a paired app, but the pairing has no bearing on a timer this
        // app is running itself.
        XCTAssertTrue(allowsPause(.manual, paired: false))
    }

    func testManualModeNamesTheTimersRealState() {
        // It is live, so it has something to say. A live item reading "Pause" over a stopped timer
        // would be the same lie the dead-item case exists to avoid.
        XCTAssertEqual(title(.manual, paused: true), "Resume")
        XCTAssertEqual(title(.manual, paused: false), "Pause")
    }

    // MARK: - A connected cube, the pre-existing rules

    func testAConnectedDeviceCanPauseAndLock() {
        XCTAssertTrue(allowsPause(.connected))
        XCTAssertTrue(allowsLock(.connected))
    }

    func testALockedDeviceRefusesPauseFromTheMenu() {
        // While locked the only valid action is the unlock gesture, so pause must not be reachable
        // here either.
        XCTAssertFalse(allowsPause(.connected, locked: true))
        XCTAssertTrue(allowsLock(.connected), "unlocking is the one thing still on offer")
    }

    func testALockedDeviceStillNamesItsRealState() {
        // Dead for the lock's sake, not for want of anything to say. This is what it did before
        // manual mode existed and the title rule must not quietly change it.
        XCTAssertEqual(title(.connected, paused: true), "Resume")
    }

    func testAStatusWithoutAPairingSendsNothing() {
        // Not a state the app can be in, and the belt-and-braces that says so.
        XCTAssertFalse(allowsPause(.connected, paired: false))
        XCTAssertFalse(allowsLock(.connected, paired: false))
    }

    // MARK: - No timing source at all

    func testEveryOtherStatusLeavesBothDead() {
        for status in [ConnectionStatus.disconnected, .pairing, .reconnecting, .resetting, .failed(nil)] {
            XCTAssertFalse(allowsPause(status), "\(status)")
            XCTAssertFalse(allowsLock(status), "\(status)")
        }
    }

    func testADeadItemNeverOffersToResume() {
        // Whatever `isPaused` is left holding. A dropped device keeps its last reading on screen, so
        // the flag can easily say paused while there is nothing there to resume.
        for status in [ConnectionStatus.disconnected, .pairing, .reconnecting, .resetting, .failed(nil)] {
            XCTAssertEqual(title(status, paused: true), "Pause", "\(status)")
        }
    }

    // MARK: - A spent daily limit

    func testASpentLimitTakesResumeAway() {
        // The visible half of the hard limit. `togglePause` refuses the unpause whether or not the
        // item is live, so this is what stops the refusal being a click that appears to work.
        XCTAssertFalse(allowsPause(.connected, paused: true, limitReached: true))
    }

    func testASpentLimitStillAllowsPausing() {
        // One direction only. A limit is reached with the cube still running -- the pause takes a
        // write and a history frame to come back -- and a double tap can start it again at any
        // moment, so the item has to stay live for the gesture that agrees with the limit.
        XCTAssertTrue(allowsPause(.connected, paused: false, limitReached: true))
    }

    func testAPausedCubeUnderItsLimitCanStillResume() {
        // The ordinary pause, which the limit must not touch: nothing is spent, so nothing is held.
        XCTAssertTrue(allowsPause(.connected, paused: true, limitReached: false))
    }

    func testAManualSessionIsNeverHeldByALimit() {
        // The limit is enforced by pausing a cube and manual mode has none, so blocking Resume here
        // would refuse to restart a timer that nothing ever stopped.
        XCTAssertTrue(allowsPause(.manual, paused: true, limitReached: true))
    }

    func testALockedCubeStaysDeadWhateverTheLimitSays() {
        // Two separate reasons to be dead, and the lock's is not weakened by the limit agreeing
        // with it: the unlock gesture is still the only thing on offer.
        XCTAssertFalse(allowsPause(.connected, locked: true, paused: true, limitReached: true))
        XCTAssertFalse(allowsPause(.connected, locked: true, paused: false, limitReached: true))
    }
}
