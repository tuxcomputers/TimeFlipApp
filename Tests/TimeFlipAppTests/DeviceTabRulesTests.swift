@testable import TimeFlipApp
import XCTest

/// Whether the Device tab's two destructive buttons, Forget Device and Reset Device, are live.
///
/// Unlike every other control on that tab they are deliberately *not* gated on being connected:
/// forgetting a cube that is out of range is an ordinary thing to want, and refusing it until the
/// device came back would strand the user. Manual mode is the one state where that reasoning fails,
/// and it fails quietly -- see `DeviceTabRules` for what each button actually does to a stand-in.
final class DeviceTabRulesTests: XCTestCase {
    private func allows(_ status: ConnectionStatus, manual: Bool = false) -> Bool {
        DeviceTabRules.allowsPairingActions(connectionStatus: status, isManualMode: manual)
    }

    func testManualModeSwitchesThemOff() {
        // Both reach the virtual device and both succeed against it. Reset confirms a wipe that
        // never happened and discards the real cube's stored name and uuid; Forget reports success
        // without sending anything and deletes the PIN this app rotated onto a cube that still
        // wants it. Neither is recoverable without the device in hand.
        XCTAssertFalse(allows(.disconnected, manual: true))
    }

    func testManualModeOutranksEveryConnectionStatus() {
        // The status manual mode reports is `.disconnected`, but nothing should depend on that: it
        // is the stand-in answering that makes these unsafe, not which status happens to be set.
        for status in [ConnectionStatus.disconnected, .connected, .reconnecting, .failed(nil), .resetting] {
            XCTAssertFalse(allows(status, manual: true), "\(status)")
        }
    }

    func testAnOutOfRangeDeviceCanStillBeForgotten() {
        // The case the connected-gate was deliberately not applied to. A user who has lost or sold
        // the cube has to be able to forget it, and it will never be connected again.
        XCTAssertTrue(allows(.disconnected))
        XCTAssertTrue(allows(.failed(nil)))
    }

    func testTheyAreLiveWhileConnected() {
        XCTAssertTrue(allows(.connected))
    }

    func testMidPairingTheyAreHeldOff() {
        // The attempt owns the connection until it resolves.
        XCTAssertFalse(allows(.pairing))
    }
}
