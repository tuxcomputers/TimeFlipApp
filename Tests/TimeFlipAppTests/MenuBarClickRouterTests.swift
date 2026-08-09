@testable import TimeFlipApp
import XCTest

/// What each half of the status item does, in each state the app can be in.
///
/// These rules lived inside an `@objc` AppKit handler until manual mode made them worth pinning, so
/// reaching any of them needed a real status item, a real click and a window server. In practice
/// that meant they were only ever checked by hand, one at a time, which is how a rule gets changed
/// for one state and quietly broken in another.
///
/// Manual mode is its own case: it draws as live and has a timer to stop, but nothing to lock, so it
/// can neither borrow the connected answers nor the no-device ones.
final class MenuBarClickRouterTests: XCTestCase {
    private func action(
        connected: Bool = false,
        manual: Bool = false,
        lowBattery: Bool = false,
        left: Bool,
        clicks: Int = 1
    ) -> StatusItemClick {
        MenuBarClickRouter.action(
            isConnected: connected,
            isManualMode: manual,
            isLowBatteryBlinking: lowBattery,
            isLeftSide: left,
            clickCount: clicks
        )
    }

    // MARK: - Manual mode

    func testInManualModeTheRightHalfStillPauses() {
        // There is a timer to stop, so the right half keeps its meaning even though the device the
        // ordinary pause talks to is not there.
        XCTAssertEqual(action(manual: true, left: false), .togglePauseImmediately)
    }

    func testTheManualPauseDoesNotWaitForADoubleClick() {
        // The wait exists to let a second click upgrade to lock. Manual mode has no lock, so there
        // is no second gesture the first click could turn out to be part of, and holding it back
        // would only make the control feel slow.
        XCTAssertNotEqual(action(manual: true, left: false), .togglePause)
    }

    func testManualModeNeverLocks() {
        // Nothing to lock. A double-click is two toggles, which lands back where it started -- the
        // ordinary result of double-clicking any toggle, and harmless.
        for clicks in 1...3 {
            XCTAssertEqual(action(manual: true, left: false, clicks: clicks), .togglePauseImmediately)
        }
    }

    func testInManualModeTheLeftHalfKeepsTheMenu() {
        // Where Quit lives, which matters more here than anywhere else: quitting is the only way
        // *out* of manual mode.
        XCTAssertEqual(action(manual: true, left: true), .showMenu)
        XCTAssertEqual(action(manual: true, lowBattery: true, left: true), .showMenu)
    }

    // MARK: - Connected, the pre-existing rules

    func testConnectedRightSideSingleClickTogglesPause() {
        XCTAssertEqual(action(connected: true, left: false, clicks: 1), .togglePause)
    }

    func testConnectedRightSideDoubleClickLocks() {
        XCTAssertEqual(action(connected: true, left: false, clicks: 2), .lockDevice)
        XCTAssertEqual(action(connected: true, left: false, clicks: 3), .lockDevice)
    }

    func testConnectedLeftSideOpensTheMenu() {
        XCTAssertEqual(action(connected: true, left: true), .showMenu)
    }

    func testConnectedLeftSideOpensSettingsWhileTheBatteryWarningBlinks() {
        XCTAssertEqual(action(connected: true, lowBattery: true, left: true), .openSettings)
    }

    // MARK: - No device, which is also what manual mode gets

    func testDisconnectedGivesTheMenuFromEitherSide() {
        // Nothing to pause and nothing to lock. Also the manual-mode answer: its stop control is
        // the play/pause on the Faces tab, and the menu is where Quit lives, which matters there
        // more than anywhere else since quitting is the only way out of the mode.
        XCTAssertEqual(action(left: true), .showMenu)
        XCTAssertEqual(action(left: false), .showMenu)
        XCTAssertEqual(action(left: false, clicks: 2), .showMenu, "a double-click must not lock a device that isn't there")
    }

    func testALowBatteryBlinkAloneDoesNotOpenSettingsWhileDisconnected() {
        // The low-battery route is a connected-state rule; a blink still fading after a drop
        // shouldn't start diverting clicks away from the menu.
        XCTAssertEqual(action(lowBattery: true, left: true), .showMenu)
    }
}
