@testable import TimeFlipApp
import XCTest

/// Whether the Device tab's two destructive buttons, Forget Device and Reset Device, are live.
///
/// Unlike every other control on that tab they are deliberately *not* gated on being connected:
/// forgetting a cube that is out of range is an ordinary thing to want, and refusing it until the
/// device came back would strand the user. They stopped sharing one rule on 2026-08-11, and the
/// difference is the whole subject of these tests -- see `DeviceTabRules`.
final class DeviceTabRulesTests: XCTestCase {
    private func allowsForget(_ status: ConnectionStatus) -> Bool {
        DeviceTabRules.allowsForget(connectionStatus: status)
    }

    private func allowsReset(_ status: ConnectionStatus) -> Bool {
        DeviceTabRules.allowsReset(connectionStatus: status)
    }

    // MARK: - Forget Device

    func testForgetIsLiveInManualMode() {
        // The requirement, and the sequence behind it: change the cube's batteries and it comes back on
        // the vendor default, a paired connect presents the stored PIN and is refused, and the app
        // offers manual mode. From there, forgetting and re-pairing is the only route back -- so a dead
        // Forget in manual mode is a dead end. It was dead until 2026-08-11, while forgetting still
        // reset the cube's password; now it sends nothing at all, so there is nothing to go wrong.
        XCTAssertTrue(allowsForget(.manual))
    }

    func testForgetIsLiveWhereverTheDeviceIsNot() {
        // The states a user reaches by losing the cube, flattening it, or having its PIN change
        // underneath the app. Forgetting is local, so none of them is a reason to refuse.
        for status in [ConnectionStatus.disconnected, .connected, .reconnecting, .failed(nil), .resetting, .manual] {
            XCTAssertTrue(allowsForget(status), "\(status)")
        }
    }

    func testForgetIsHeldOffOnlyMidPairing() {
        // The attempt owns the pairing state until it resolves; dropping it from underneath would leave
        // the two disagreeing about whether there is a device. It has its own cancel gesture.
        XCTAssertFalse(allowsForget(.pairing))
    }

    // MARK: - Reset Device

    func testResetIsRefusedInManualMode() {
        // Because something *does* answer. `0xFF` is routed against the protocol rather than the BLE
        // type, so it lands on the virtual device and is accepted; confirming it discards the real
        // cube's stored name and uuid, which is what the scan uses to find it again.
        XCTAssertFalse(allowsReset(.manual))
    }

    func testResetIsLiveWhereverThereIsNoStandIn() {
        for status in [ConnectionStatus.disconnected, .connected, .reconnecting, .failed(nil), .resetting] {
            XCTAssertTrue(allowsReset(status), "\(status)")
        }
    }

    func testResetIsHeldOffMidPairing() {
        XCTAssertFalse(allowsReset(.pairing))
    }

    // MARK: - The split itself

    func testManualModeIsTheOnlyStateWhereTheTwoDisagree() {
        // Pinned as a set rather than one at a time, because the failure mode is a new case being added
        // and quietly defaulting to enabled on the wrong one of the two.
        for status in [ConnectionStatus.disconnected, .connected, .reconnecting, .failed(nil), .resetting, .pairing] {
            XCTAssertEqual(allowsForget(status), allowsReset(status), "\(status)")
        }
        XCTAssertTrue(allowsForget(.manual))
        XCTAssertFalse(allowsReset(.manual))
    }
}
