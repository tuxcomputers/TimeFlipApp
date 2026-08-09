@testable import TimeFlipApp
import XCTest

/// What each half of the status item does, in each state the app can be in.
///
/// These rules lived inside an `@objc` AppKit handler until manual mode made them worth pinning, so
/// reaching any of them needed a real status item, a real click and a window server. In practice
/// that meant they were only ever checked by hand, one at a time, which is how a rule gets changed
/// for one state and quietly broken in another.
///
/// Manual mode has no case of its own: it is not connected, so it takes the no-device answers in the
/// last section, which are also the answers it wants.
final class MenuBarClickRouterTests: XCTestCase {
    private func action(
        connected: Bool = false,
        lowBattery: Bool = false,
        left: Bool,
        clicks: Int = 1
    ) -> StatusItemClick {
        MenuBarClickRouter.action(
            isConnected: connected,
            isLowBatteryBlinking: lowBattery,
            isLeftSide: left,
            clickCount: clicks
        )
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
