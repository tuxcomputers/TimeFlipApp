@testable import TimeFlipApp
import XCTest

/// What each half of the status item does, in each state the app can be in.
///
/// These rules lived inside an `@objc` AppKit handler until manual mode made them worth pinning, so
/// reaching any of them needed a real status item, a real click and a window server. In practice
/// that meant they were only ever checked by hand, one at a time, which is how a rule gets changed
/// for one state and quietly broken in another.
///
/// Manual mode is its own case, in the literal sense now: it draws as live and has a timer to stop,
/// but nothing to lock, so it can neither borrow the connected answers nor the no-device ones.
final class MenuBarClickRouterTests: XCTestCase {
    /// `paired` defaults to true so the interesting variable is the status: an unpaired app with a
    /// `.connected` status is not a state the app can be in, and is pinned separately below.
    private func action(
        status: ConnectionStatus = .disconnected,
        paired: Bool = true,
        lowBattery: Bool = false,
        left: Bool,
        clicks: Int = 1
    ) -> StatusItemClick {
        MenuBarClickRouter.action(
            connectionStatus: status,
            isPaired: paired,
            isLowBatteryBlinking: lowBattery,
            isLeftSide: left,
            clickCount: clicks
        )
    }

    // MARK: - Manual mode

    func testInManualModeTheRightHalfStillPauses() {
        // There is a timer to stop, so the right half keeps its meaning even though the device the
        // ordinary pause talks to is not there.
        XCTAssertEqual(action(status: .manual, left: false), .togglePauseImmediately)
    }

    func testTheManualPauseDoesNotWaitForADoubleClick() {
        // The wait exists to let a second click upgrade to lock. Manual mode has no lock, so there
        // is no second gesture the first click could turn out to be part of, and holding it back
        // would only make the control feel slow.
        XCTAssertNotEqual(action(status: .manual, left: false), .togglePause)
    }

    func testManualModeNeverLocks() {
        // Nothing to lock. A double-click is two toggles, which lands back where it started -- the
        // ordinary result of double-clicking any toggle, and harmless.
        for clicks in 1...3 {
            XCTAssertEqual(action(status: .manual, left: false, clicks: clicks), .togglePauseImmediately)
        }
    }

    func testInManualModeTheLeftHalfKeepsTheMenu() {
        // Where Quit lives, which matters more here than anywhere else: quitting is the only way
        // *out* of manual mode.
        XCTAssertEqual(action(status: .manual, left: true), .showMenu)
        XCTAssertEqual(action(status: .manual, lowBattery: true, left: true), .showMenu)
    }

    func testManualModeDoesNotDependOnThePairing() {
        // The pairing gate belongs to the device cases. Manual mode is reached from a paired app,
        // but nothing it does here is a command to that device, so it must not be conditional on
        // one still being remembered.
        XCTAssertEqual(action(status: .manual, paired: false, left: false), .togglePauseImmediately)
        XCTAssertEqual(action(status: .manual, paired: false, left: true), .showMenu)
    }

    // MARK: - Connected, the pre-existing rules

    func testConnectedRightSideSingleClickTogglesPause() {
        XCTAssertEqual(action(status: .connected, left: false, clicks: 1), .togglePause)
    }

    func testConnectedRightSideDoubleClickLocks() {
        XCTAssertEqual(action(status: .connected, left: false, clicks: 2), .lockDevice)
        XCTAssertEqual(action(status: .connected, left: false, clicks: 3), .lockDevice)
    }

    func testConnectedLeftSideOpensTheMenu() {
        XCTAssertEqual(action(status: .connected, left: true), .showMenu)
    }

    func testConnectedLeftSideOpensSettingsWhileTheBatteryWarningBlinks() {
        XCTAssertEqual(action(status: .connected, lowBattery: true, left: true), .openSettings)
    }

    func testConnectedWithoutAPairingSendsNothing() {
        // Not a state the app can be in, and the belt-and-braces that says so: a lock command is
        // not worth sending on the strength of a status that disagrees with the pairing.
        XCTAssertEqual(action(status: .connected, paired: false, left: false, clicks: 2), .showMenu)
    }

    // MARK: - No device, and no manual session either

    func testDisconnectedGivesTheMenuFromEitherSide() {
        // Nothing to pause and nothing to lock.
        XCTAssertEqual(action(left: true), .showMenu)
        XCTAssertEqual(action(left: false), .showMenu)
        XCTAssertEqual(action(left: false, clicks: 2), .showMenu, "a double-click must not lock a device that isn't there")
    }

    func testEveryStatusShortOfConnectedGivesTheMenu() {
        for status in [ConnectionStatus.disconnected, .pairing, .reconnecting, .resetting, .failed(nil)] {
            XCTAssertEqual(action(status: status, left: false, clicks: 1), .showMenu, "\(status)")
        }
    }

    func testALowBatteryBlinkAloneDoesNotOpenSettingsWhileDisconnected() {
        // The low-battery route is a connected-state rule; a blink still fading after a drop
        // shouldn't start diverting clicks away from the menu.
        XCTAssertEqual(action(lowBattery: true, left: true), .showMenu)
    }
}
