@testable import TimeFlipApp
import XCTest

/// What each half of the status item does, in each state the app can be in.
///
/// These rules lived inside an `@objc` AppKit handler until manual mode added a fourth to them, so
/// reaching any of them needed a real status item, a real click and a window server. In practice
/// that meant they were only ever checked by hand, one at a time, which is how a rule gets changed
/// for one state and quietly broken in another.
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

    func testInManualModeBothHalvesOpenTheMenu() {
        // Quit matters more here than anywhere else: it is the only way *out* of manual mode, the
        // work is done in the Settings window, which has no Quit of its own, and the menu is the
        // only thing that carries one. Sending either half to Settings would put that single exit
        // behind knowing which half of the status item to click.
        XCTAssertEqual(action(manual: true, left: true), .showMenu)
        XCTAssertEqual(action(manual: true, left: false), .showMenu)
    }

    func testManualModeNeverPausesOrLocks() {
        // Whatever the click count, and even if a stale "connected" somehow survived alongside it:
        // there is no device, and firing a lock at one that isn't there is worse than doing nothing.
        for clicks in 1...3 {
            XCTAssertEqual(action(connected: true, manual: true, left: false, clicks: clicks), .showMenu)
        }
    }

    func testManualModeOutranksALowBatteryBlink() {
        // A blink can only be left over from before the device went away, manual mode never reading
        // a battery. If it won, the left half would go to Settings and take the menu, and with it
        // the only Quit, out of reach -- which is the whole reason this rule is ordered first.
        XCTAssertEqual(action(manual: true, lowBattery: true, left: true), .showMenu)
        XCTAssertEqual(action(manual: true, lowBattery: true, left: false), .showMenu)
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

    // MARK: - Neither connected nor manual

    func testDisconnectedGivesTheMenuFromEitherSide() {
        // Nothing to pause, nothing to lock, and no manual session to configure.
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
