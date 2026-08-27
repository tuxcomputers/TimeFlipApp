@testable import FacetApp
import Foundation
import XCTest

/// Covers `DeviceInfoRules`: the words the Device tab's TimeFlip section puts against each row.
///
/// The point of these is the distinctions. Every row here is a sentence about a thing that is not there, and "no
/// device" has three meanings that must not collapse into one: nothing is paired, something is paired and cannot be
/// heard from, and the app is not reaching for one at all.
final class DeviceInfoRulesTests: XCTestCase {
    // MARK: - the name

    func testAnUnpairedAppShowsNoNameEvenWhenItRemembersOne() {
        // The name deliberately outlives Forget Device -- forgetting does not un-rename a cube, and the remembered
        // string is what a filtered scan matches on. Showing it here would read as a device the app has.
        XCTAssertEqual(DeviceInfoRules.name(isCubePaired: false, deviceName: "Dibby"), "Not paired")
    }

    func testAPairedDeviceShowsTheNameItIsCarrying() {
        XCTAssertEqual(DeviceInfoRules.name(isCubePaired: true, deviceName: "Dibby"), "Dibby")
    }

    func testAPairedDeviceWithNoNameYetSaysUnknown() {
        // A real state rather than a fault: the name is read off the cube on connect and never guessed, so a pairing
        // that has not connected since has nothing to show.
        XCTAssertEqual(DeviceInfoRules.name(isCubePaired: true, deviceName: nil), "Unknown")
        XCTAssertEqual(DeviceInfoRules.name(isCubePaired: true, deviceName: "   "), "Unknown")
    }

    // MARK: - the connection

    func testManualModeSaysSoRatherThanDisconnected() {
        // The archive's reasoning, kept: "Disconnected" is true of the cube and no answer at all to why the app is
        // plainly still recording time.
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: false, isCubeConnected: false, isManualMode: true),
            "Manual mode, no device"
        )
    }

    func testManualModeOutranksPairing() {
        // It answers a different question from the other two: they describe a cube, this describes what the app is
        // doing instead of using one. A paired cube the app is not going to use is still manual mode -- and the row
        // names the restart, because the restart is the whole of what changes it (`LaunchMode`).
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: false, isManualMode: true),
            "Paired, not used until restart"
        )
    }

    func testAManualLaunchThatPairedACubeSaysItIsNotUsingIt() {
        // **Connected and ignored at the same time**, which is a state the app can now sit in for hours: pairing a
        // cube no longer hands it the clock. "Connected" on its own would be the more misleading half of the truth,
        // describing a link the app has and a job it is not doing with it.
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: true, isManualMode: true),
            "Connected, not used until restart"
        )
    }

    func testADeviceLaunchWhoseCubeHasGoneSaysToRestart() {
        // Only reachable by forgetting or resetting the cube from this very tab, a launch that decided `.device`
        // having had one on record. There is nothing left to follow and the app will not start timing by hand on its
        // own, so saying "Not paired" and stopping would read exactly like the app being broken.
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: false, isCubeConnected: false, isManualMode: false),
            "Device gone, restart to time by hand"
        )
    }

    func testAPairedDeviceReportsWhetherItCanBeHeard() {
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: true, isManualMode: false), "Connected"
        )
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: false, isManualMode: false), "Disconnected"
        )
    }

    // MARK: - the battery

    func testNoDeviceAtAllIsADifferentAnswerFromOneThatCannotBeHeard() {
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: false, isCubeConnected: false, percent: nil), "Not paired")
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: false, percent: nil), "Unknown")
    }

    func testAPercentageOnlyComesFromALiveReading() {
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: true, percent: 34), "34%")
        // A level with no connection behind it is a number that was true at some moment nobody can name, so it is
        // not shown as though it were now. Nothing stores one today, and this is what keeps that true if anything
        // ever does.
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: false, percent: 34), "Unknown")
    }

    // MARK: - the More rows, and the greying

    func testADetailTheCubeHasNotReportedSaysUnknown() {
        XCTAssertEqual(DeviceInfoRules.detail(isCubePaired: true, reported: nil), "Unknown")
        XCTAssertEqual(DeviceInfoRules.detail(isCubePaired: true, reported: ""), "Unknown")
        XCTAssertEqual(DeviceInfoRules.detail(isCubePaired: true, reported: "DI_LABS 2.0"), "DI_LABS 2.0")
    }

    func testAnUnpairedAppShowsNoDetailEvenWhenOneIsStored() {
        // These are stored now, so they outlive the connection that read them -- and a manufacturer reported against
        // no pairing would claim a device more strongly than the Name row above it is allowed to.
        XCTAssertEqual(DeviceInfoRules.detail(isCubePaired: false, reported: "DI_LABS"), "Not paired")
        XCTAssertEqual(DeviceInfoRules.detail(isCubePaired: false, reported: nil), "Not paired")
    }

    // MARK: - what comes off the wire

    func testACharacteristicDecodesToTheStringItHolds() {
        XCTAssertEqual(DeviceInfoRules.reported(Data("FW_v3.64".utf8)), "FW_v3.64")
    }

    func testAPaddedFieldLosesItsPadding() {
        // Each of these is a 20-byte field in the vendor spec, so a shorter string arrives padded. The NULs decode as
        // valid UTF-8, which is what makes them invisible rather than obviously wrong.
        let padded = Data("TFv4.1".utf8) + Data(repeating: 0, count: 14)

        XCTAssertEqual(DeviceInfoRules.reported(padded), "TFv4.1")
    }

    func testACubeThatSaidNothingIsNotTheSameAsOneThatSaidBlank() {
        // `nil` all the way down, so `DevicePairingRecorder` can tell "did not answer" from "answered" and leave a
        // stored value alone rather than blanking it.
        XCTAssertNil(DeviceInfoRules.reported(nil))
        XCTAssertNil(DeviceInfoRules.reported(Data()))
        XCTAssertNil(DeviceInfoRules.reported(Data(repeating: 0, count: 20)))
        XCTAssertNil(DeviceInfoRules.reported(Data("   ".utf8)))
    }

    func testBytesThatAreNotTextAreNotGuessedAt() {
        // System ID (0x2A23) is the reason this matters: it sits in the same service and is raw binary, so anything
        // reaching here that is not UTF-8 is a read this app should report as an absence rather than render.
        XCTAssertNil(DeviceInfoRules.reported(Data([0xFF, 0xFE, 0xFD])))
    }

    // MARK: - what a reading amounts to

    func testACubeThatAnsweredNothingReadsAsEmpty() {
        XCTAssertTrue(DeviceInfo().isEmpty)
    }

    func testOneAnswerIsEnoughToNotBeEmpty() {
        // Four independent reads: three failing does not make the fourth worthless.
        XCTAssertFalse(DeviceInfo(firmware: "FW_v3.64").isEmpty)
    }

    func testValuesAreOnlyLiveWhileSomethingCanBeHeard() {
        // What this drives is the colour: a greyed row is the difference between a value the app is standing behind
        // and a placeholder standing in for one.
        XCTAssertTrue(DeviceInfoRules.isLive(isCubeConnected: true))
        XCTAssertFalse(DeviceInfoRules.isLive(isCubeConnected: false))
    }
}
