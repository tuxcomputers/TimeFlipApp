@testable import FacetApp
import XCTest

/// Covers `DeviceInfoRules`: the words the Device tab's Info panel puts against each row.
///
/// The point of these is the distinctions. Every row here is a sentence about a thing that is not there, and "no
/// device" has three meanings that must not collapse into one: nothing is paired, something is paired and cannot be
/// heard from, and the app is not reaching for one at all.
final class DeviceInfoRulesTests: XCTestCase {
    // MARK: - the name

    func testAnUnpairedAppShowsNoNameEvenWhenItRemembersOne() {
        // The name deliberately outlives Forget Device -- forgetting does not un-rename a cube, and the remembered
        // string is what a filtered scan matches on. Showing it here would read as a device the app has.
        XCTAssertEqual(DeviceInfoRules.name(isPaired: false, deviceName: "Dibby"), "Not paired")
    }

    func testAPairedDeviceShowsTheNameItIsCarrying() {
        XCTAssertEqual(DeviceInfoRules.name(isPaired: true, deviceName: "Dibby"), "Dibby")
    }

    func testAPairedDeviceWithNoNameYetSaysUnknown() {
        // A real state rather than a fault: the name is read off the cube on connect and never guessed, so a pairing
        // that has not connected since has nothing to show.
        XCTAssertEqual(DeviceInfoRules.name(isPaired: true, deviceName: nil), "Unknown")
        XCTAssertEqual(DeviceInfoRules.name(isPaired: true, deviceName: "   "), "Unknown")
    }

    // MARK: - the connection

    func testManualModeSaysSoRatherThanDisconnected() {
        // The archive's reasoning, kept: "Disconnected" is true of the cube and no answer at all to why the app is
        // plainly still recording time.
        XCTAssertEqual(
            DeviceInfoRules.connection(isPaired: false, isConnected: false, isManualMode: true),
            "Manual mode, no device"
        )
    }

    func testManualModeOutranksPairing() {
        // It answers a different question from the other two: they describe a cube, this describes what the app is
        // doing instead of using one. A paired cube the app has stopped reaching for is still manual mode.
        XCTAssertEqual(
            DeviceInfoRules.connection(isPaired: true, isConnected: false, isManualMode: true),
            "Manual mode, no device"
        )
    }

    func testNothingPairedSaysNotPaired() {
        XCTAssertEqual(
            DeviceInfoRules.connection(isPaired: false, isConnected: false, isManualMode: false),
            "Not paired"
        )
    }

    func testAPairedDeviceReportsWhetherItCanBeHeard() {
        XCTAssertEqual(
            DeviceInfoRules.connection(isPaired: true, isConnected: true, isManualMode: false), "Connected"
        )
        XCTAssertEqual(
            DeviceInfoRules.connection(isPaired: true, isConnected: false, isManualMode: false), "Disconnected"
        )
    }

    // MARK: - the battery

    func testNoDeviceAtAllIsADifferentAnswerFromOneThatCannotBeHeard() {
        XCTAssertEqual(DeviceInfoRules.battery(isPaired: false, isConnected: false, percent: nil), "Not paired")
        XCTAssertEqual(DeviceInfoRules.battery(isPaired: true, isConnected: false, percent: nil), "Unknown")
    }

    func testAPercentageOnlyComesFromALiveReading() {
        XCTAssertEqual(DeviceInfoRules.battery(isPaired: true, isConnected: true, percent: 34), "34%")
        // A level with no connection behind it is a number that was true at some moment nobody can name, so it is
        // not shown as though it were now. Nothing stores one today, and this is what keeps that true if anything
        // ever does.
        XCTAssertEqual(DeviceInfoRules.battery(isPaired: true, isConnected: false, percent: 34), "Unknown")
    }

    // MARK: - the More rows, and the greying

    func testADetailTheCubeHasNotReportedSaysUnknown() {
        XCTAssertEqual(DeviceInfoRules.detail(nil), "Unknown")
        XCTAssertEqual(DeviceInfoRules.detail(""), "Unknown")
        XCTAssertEqual(DeviceInfoRules.detail("DI_LABS 2.0"), "DI_LABS 2.0")
    }

    func testValuesAreOnlyLiveWhileSomethingCanBeHeard() {
        // What this drives is the colour: a greyed row is the difference between a value the app is standing behind
        // and a placeholder standing in for one.
        XCTAssertTrue(DeviceInfoRules.isLive(isConnected: true))
        XCTAssertFalse(DeviceInfoRules.isLive(isConnected: false))
    }
}
