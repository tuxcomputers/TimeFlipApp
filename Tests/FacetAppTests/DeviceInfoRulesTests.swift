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

    func testNothingPairedIsAnAppTimingByHand() {
        // The archive's reasoning, kept: "Disconnected" is true of the cube and no answer at all to why the app is
        // plainly still recording time. Nothing paired is the whole of what timing by hand means now, so this is the
        // only state that says it.
        XCTAssertEqual(
            DeviceInfoRules.connection(isCubePaired: false, isCubeConnected: false),
            "Manual mode, no device"
        )
    }

    func testAPairedDeviceReportsWhetherItCanBeHeard() {
        XCTAssertEqual(DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: true), "Connected")
        XCTAssertEqual(DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: false), "Disconnected")
    }

    func testPairingACubeIsAllItTakesToBeFollowingOne() {
        // **The three lines that went, and why they cannot come back.** A manual launch that had since paired a cube
        // read "Connected, not used until restart", and a device launch whose cube had been forgotten read "Device
        // gone, restart to time by hand". Both were the app admitting that a mode decided at startup had come apart
        // from the row underneath it. Timing by hand is read from the pairing now, so the only thing between a cube
        // being paired and being followed is the row this reads.
        XCTAssertEqual(DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: true), "Connected")
        XCTAssertNotEqual(
            DeviceInfoRules.connection(isCubePaired: true, isCubeConnected: true), "Connected, not used until restart"
        )
        XCTAssertNotEqual(
            DeviceInfoRules.connection(isCubePaired: false, isCubeConnected: false),
            "Device gone, restart to time by hand"
        )
    }

    // MARK: - the battery

    func testNoDeviceAtAllIsADifferentAnswerFromOneThatCannotBeHeard() {
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: false, isCubeConnected: false, batteryPercent: nil), "Not paired")
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: false, batteryPercent: nil), "Unknown")
    }

    func testAPercentageOnlyComesFromALiveReading() {
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: true, batteryPercent: 34), "34%")
        // A level with no connection behind it is a number that was true at some moment nobody can name, so it is
        // not shown as though it were now. Nothing stores one today, and this is what keeps that true if anything
        // ever does.
        XCTAssertEqual(DeviceInfoRules.battery(isCubePaired: true, isCubeConnected: false, batteryPercent: 34), "Unknown")
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
}
