@testable import TimeFlipApp
import XCTest

/// Whether the menu bar has anything to draw, and whether what it draws is current.
///
/// Both were read straight off `isPaired` and `connectionStatus`, which held while a cube was the
/// only thing that could be timing. A manual session runs with a category and a duration and no
/// device at all, so read literally each of these answered "nothing is happening" for a session
/// that was.
///
/// A third rule used to live here, asking whether a `.disconnected` should clear the display. It
/// existed only because manual mode reported `.disconnected` while running; `ConnectionStatus`
/// having a case of its own leaves nothing for it to answer.
final class MenuBarLiveDisplayTests: XCTestCase {

    // MARK: - Is there anything to draw

    func testAManualSessionAlwaysHasSomethingToDraw() {
        // Even with no pairing and no device ever reached. Its reading comes from a source this app
        // drives itself, so there is no such thing as not having reached it.
        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(
                isPaired: false,
                hasReachedDeviceThisSession: false,
                connectionStatus: .manual
            )
        )
    }

    func testNothingToDrawBeforeADeviceHasBeenReached() {
        // The placeholder case: an "Idle 0:00" here would look like a reading from a device that has
        // never answered.
        XCTAssertFalse(
            MenuBarLiveDisplay.showsActivity(
                isPaired: true,
                hasReachedDeviceThisSession: false,
                connectionStatus: .disconnected
            )
        )
        XCTAssertFalse(
            MenuBarLiveDisplay.showsActivity(
                isPaired: false,
                hasReachedDeviceThisSession: false,
                connectionStatus: .disconnected
            )
        )
    }

    func testADroppedDeviceKeepsDrawingItsLastActivity() {
        // Deliberately not the placeholder: once a device has been reached, an outage keeps the last
        // known activity on screen. That is the whole point of the reconnecting state.
        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(
                isPaired: true,
                hasReachedDeviceThisSession: true,
                connectionStatus: .reconnecting
            )
        )
    }

    /// The rule that replaced the teardown exception. Manual mode never used to be distinguishable
    /// here, so the display had to be told separately not to clear itself.
    func testManualModeIsNotAnOrdinaryDisconnect() {
        for status in [ConnectionStatus.disconnected, .failed(nil), .resetting] {
            XCTAssertFalse(
                MenuBarLiveDisplay.showsActivity(
                    isPaired: false,
                    hasReachedDeviceThisSession: false,
                    connectionStatus: status
                ),
                "\(status)"
            )
        }
    }

    // MARK: - Is what it draws current

    func testAManualSessionRendersAsLive() {
        // The requirement in as many words: the display is the same in device or manual mode. The
        // app is generating the reading, so there is no window in which it could be out of date.
        // Unpaired too, since the pairing has no bearing on a reading that never came from a cube.
        XCTAssertTrue(MenuBarLiveDisplay.rendersAsLive(isPaired: false, connectionStatus: .manual))
        XCTAssertTrue(MenuBarLiveDisplay.rendersAsLive(isPaired: true, connectionStatus: .manual))
    }

    func testAConnectedDeviceRendersAsLive() {
        XCTAssertTrue(MenuBarLiveDisplay.rendersAsLive(isPaired: true, connectionStatus: .connected))
    }

    func testADroppedDeviceDoesNotRenderAsLive() {
        // It still draws (above), but in the flat yellow that says this is the last reading rather
        // than the current one.
        XCTAssertFalse(MenuBarLiveDisplay.rendersAsLive(isPaired: true, connectionStatus: .reconnecting))
        XCTAssertFalse(MenuBarLiveDisplay.rendersAsLive(isPaired: true, connectionStatus: .disconnected))
    }

    func testConnectedButUnpairedIsNotLive() {
        XCTAssertFalse(MenuBarLiveDisplay.rendersAsLive(isPaired: false, connectionStatus: .connected))
    }
}
