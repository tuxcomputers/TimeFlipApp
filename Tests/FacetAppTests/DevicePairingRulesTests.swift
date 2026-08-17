@testable import FacetApp
import Foundation
import XCTest

/// The two name decisions a pairing makes, both of which are invisible until a rename goes wrong months later.
final class DevicePairingRulesTests: XCTestCase {
    private func device(peripheralName: String?, advertisedName: String? = "TimeFlip v2.0") -> ScannedDevice {
        ScannedDevice(
            id: UUID(),
            peripheralName: peripheralName,
            advertisedName: advertisedName,
            advertisesTimeFlipService: true
        )
    }

    // MARK: - which name is recorded

    func testTheRecordedNameIsTheOneTheCubeCarries() {
        XCTAssertEqual(DevicePairingRules.gapName(of: device(peripheralName: "Dibby")), "Dibby")
    }

    func testTheAdvertisedNameIsNeverRecorded() {
        // Finding 1 in `docs/timeflip2-firmware-observations.md`: the advertised name never changes, so recording it
        // would put a name in `device_name` that no rename could ever move -- and that row is what the scan filter
        // compares against exactly.
        XCTAssertNil(DevicePairingRules.gapName(of: device(peripheralName: nil)))
        XCTAssertNil(DevicePairingRules.gapName(of: device(peripheralName: "   ")))
    }

    // MARK: - the name it displaced

    func testARealChangeKeepsTheNameBeingReplaced() {
        XCTAssertEqual(DevicePairingRules.previousName(replacing: "Dibby", with: "Wobble"), "Dibby")
    }

    func testTheSameNameAgainMovesNothing() {
        // The name is recorded on every connection. A rule that moved this each time would push the genuinely
        // previous name out of the row on the first reconnect after a rename, which is the one moment it is needed.
        XCTAssertNil(DevicePairingRules.previousName(replacing: "Dibby", with: "Dibby"))
    }

    func testAFirstPairingHasNothingToDisplace() {
        // Writing an empty string here would put a name in the scan filter that matches nothing.
        XCTAssertNil(DevicePairingRules.previousName(replacing: nil, with: "Dibby"))
        XCTAssertNil(DevicePairingRules.previousName(replacing: "", with: "Dibby"))
        XCTAssertNil(DevicePairingRules.previousName(replacing: "  ", with: "Dibby"))
    }

    // MARK: - which controls the TimeFlip section shows

    func testAnAppWithNoDeviceIsOfferedAScan() {
        XCTAssertTrue(DevicePairingRules.showsScanControls(isPaired: false))
        XCTAssertFalse(DevicePairingRules.showsPairedControls(isPaired: false))
    }

    func testAPairedAppIsOfferedForgetAndResetInstead() {
        XCTAssertFalse(DevicePairingRules.showsScanControls(isPaired: true))
        XCTAssertTrue(DevicePairingRules.showsPairedControls(isPaired: true))
    }

    func testExactlyOneSetOfControlsIsUp() {
        // The two are the section's two states rather than two independent switches, so a combination showing both or
        // neither is not a thing the tab can be in.
        for isPaired in [true, false] {
            XCTAssertNotEqual(
                DevicePairingRules.showsScanControls(isPaired: isPaired),
                DevicePairingRules.showsPairedControls(isPaired: isPaired)
            )
        }
    }

    // MARK: - whether Forget may be pressed

    func testForgetIsLiveWheneverThereIsSomethingToForget() {
        // It reaches no radio, so it stays available in exactly the state it is most needed: a cube that is missing,
        // flat, or on a PIN this app cannot present. After a battery change it is the only way back.
        XCTAssertTrue(DevicePairingRules.allowsForget(isPaired: true, isReaching: false))
    }

    func testForgetIsDeadWithNothingPaired() {
        XCTAssertFalse(DevicePairingRules.allowsForget(isPaired: false, isReaching: false))
    }

    func testForgetIsDeadWhileAnAttemptIsInFlight() {
        // A connect owns the pairing state until it resolves; dropping it from underneath one would leave the two
        // disagreeing about whether there is a device.
        XCTAssertFalse(DevicePairingRules.allowsForget(isPaired: true, isReaching: true))
    }

    func testTheScanControlsStayAwayWhileTheCubeIsMerelyOutOfRange() {
        // Gated on the pairing, not the connection: a cube in another room is still this app's cube, and offering a
        // scan the moment it went quiet would invite replacing a device that has not gone anywhere.
        XCTAssertFalse(DevicePairingRules.showsScanControls(isPaired: true))
    }

    // MARK: - whether Reset may be pressed

    func testResetNeedsTheCubeAndForgetDoesNot() {
        // The whole difference between the two buttons: one is a command that has to reach the hardware, the other is
        // this app's own rows. A live Reset with nothing connected would report a wipe that never left the Mac.
        XCTAssertFalse(DevicePairingRules.allowsReset(isPaired: true, isConnected: false, isReaching: false))
        XCTAssertTrue(DevicePairingRules.allowsReset(isPaired: true, isConnected: true, isReaching: false))
        XCTAssertTrue(DevicePairingRules.allowsForget(isPaired: true, isReaching: false))
    }

    func testResetIsDeadWithNothingPaired() {
        XCTAssertFalse(DevicePairingRules.allowsReset(isPaired: false, isConnected: true, isReaching: false))
    }

    func testResetIsDeadWhileAnAttemptIsInFlight() {
        XCTAssertFalse(DevicePairingRules.allowsReset(isPaired: true, isConnected: true, isReaching: true))
    }
}
