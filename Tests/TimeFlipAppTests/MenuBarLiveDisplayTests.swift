@testable import TimeFlipApp
import XCTest

/// Whether the menu bar has anything to draw, whether what it draws is current, and whether a
/// `.disconnected` status should clear it.
///
/// All three were read straight off `isPaired` and `connectionStatus`, which held while a cube was
/// the only thing that could be timing. Manual mode reports `.disconnected` for its whole launch --
/// truthfully, there is no cube -- while running a session with a category and a duration, so each
/// of these answered "nothing is happening" for a session that was.
final class MenuBarLiveDisplayTests: XCTestCase {

    // MARK: - Is there anything to draw

    func testAManualSessionAlwaysHasSomethingToDraw() {
        // Even with no pairing and no device ever reached, which is the state manual mode leaves
        // behind it. Its reading comes from a source this app drives itself.
        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(isPaired: false, hasReachedDeviceThisSession: false, isManualMode: true)
        )
    }

    func testNothingToDrawBeforeADeviceHasBeenReached() {
        // The placeholder case: an "Idle 0:00" here would look like a reading from a device that has
        // never answered.
        XCTAssertFalse(
            MenuBarLiveDisplay.showsActivity(isPaired: true, hasReachedDeviceThisSession: false, isManualMode: false)
        )
        XCTAssertFalse(
            MenuBarLiveDisplay.showsActivity(isPaired: false, hasReachedDeviceThisSession: false, isManualMode: false)
        )
    }

    func testADroppedDeviceKeepsDrawingItsLastActivity() {
        // Deliberately not the placeholder: once a device has been reached, an outage keeps the last
        // known activity on screen. That is the whole point of the reconnecting state.
        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(isPaired: true, hasReachedDeviceThisSession: true, isManualMode: false)
        )
    }

    // MARK: - Is what it draws current

    func testAManualSessionRendersAsLive() {
        // The requirement in as many words: the display is the same in device or manual mode. The
        // app is generating the reading, so there is no window in which it could be out of date.
        XCTAssertTrue(MenuBarLiveDisplay.rendersAsLive(isPaired: false, isConnected: false, isManualMode: true))
    }

    func testAConnectedDeviceRendersAsLive() {
        XCTAssertTrue(MenuBarLiveDisplay.rendersAsLive(isPaired: true, isConnected: true, isManualMode: false))
    }

    func testADroppedDeviceDoesNotRenderAsLive() {
        // It still draws (above), but in the flat yellow that says this is the last reading rather
        // than the current one.
        XCTAssertFalse(MenuBarLiveDisplay.rendersAsLive(isPaired: true, isConnected: false, isManualMode: false))
    }

    func testConnectedButUnpairedIsNotLive() {
        XCTAssertFalse(MenuBarLiveDisplay.rendersAsLive(isPaired: false, isConnected: true, isManualMode: false))
    }

    // MARK: - Tearing down

    func testManualModeDoesNotTearDownOnDisconnect() {
        // `enterManualMode` sets `.disconnected` and it stays there for the launch. Tearing down on
        // it would clear the very session that status is describing -- which is what emptied the
        // menu bar to a bare app name in manual mode.
        XCTAssertFalse(MenuBarLiveDisplay.tearsDownOnDisconnect(isManualMode: true))
    }

    func testAnOrdinaryDisconnectStillTearsDown() {
        XCTAssertTrue(MenuBarLiveDisplay.tearsDownOnDisconnect(isManualMode: false))
    }
}
