@testable import FacetApp
import XCTest

/// Which advertisements the Device tab lists, and what it calls them.
///
/// **Every one of these runs with no radio**, which is why the decisions are here and not in `BluetoothScanner`: a
/// `CBPeripheral` cannot be built outside CoreBluetooth, so a filter that read one directly could only be checked by
/// holding a cube in the room.
///
/// The cases are the archive's, because they are measurements rather than opinions
/// (`docs/timeflip2-firmware-observations.md`): this hardware carries two names, a rename moves only one of them, and
/// the one macOS reports is a connection stale.
final class DeviceScanRulesTests: XCTestCase {
    private func device(
        peripheral: String? = nil,
        advertised: String? = nil,
        service: Bool = false,
        id: UUID = UUID()
    ) -> ScannedDevice {
        ScannedDevice(
            id: id, peripheralName: peripheral, advertisedName: advertised, advertisesTimeFlipService: service
        )
    }

    // MARK: - what is eligible

    func testTheVendorNameIsMatchedAsASubstring() {
        // The hardware ships as "TimeFlip v2.0" and the family's names all contain the word, so an exact test would
        // miss most of them.
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(peripheral: "TimeFlip v2.0"), remembered: nil, previouslyKnown: nil
        ))
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(advertised: "timeflip"), remembered: nil, previouslyKnown: nil
        ))
    }

    func testARenamedCubeIsStillFoundByItsAdvertisedName() {
        // **The bug this rule exists for**, measured 2026-08-01: a cube whose `CBPeripheral.name` read "Hazza cuber"
        // was still advertising "TimeFlip v2.0". The archive's discovery scan checked only the peripheral name, so a
        // renamed cube connected fine and could not be found.
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(peripheral: "Hazza cuber", advertised: "TimeFlip v2.0"),
            remembered: nil,
            previouslyKnown: nil
        ))
    }

    func testARememberedNameIsMatchedExactly() {
        // Exact, unlike the vendor test: a short chosen name used as a substring would start claiming other people's
        // hardware.
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(peripheral: "Dibby"), remembered: "Dibby", previouslyKnown: nil
        ))
        XCTAssertFalse(
            DeviceScanRules.isEligible(
                device(peripheral: "Dibby's headphones"), remembered: "Dibby", previouslyKnown: nil
            ),
            "a remembered name must not match as a substring"
        )
    }

    func testThePreviousNameIsMatchedBecauseTheReportedOneIsAConnectionStale() {
        // The scan straight after a rename still sees the old name, which is exactly when somebody is watching for
        // the new one. `device_name.previous_name` is stored for this.
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(peripheral: "Dibby"), remembered: "Plopper", previouslyKnown: "Dibby"
        ))
    }

    func testTheServiceUuidIsEnoughOnItsOwn() {
        // Rarely present on this hardware, which is why the names carry the work, but when it is there it settles it.
        XCTAssertTrue(DeviceScanRules.isEligible(
            device(peripheral: "Anything at all", service: true), remembered: nil, previouslyKnown: nil
        ))
    }

    func testAStrangersDeviceIsNotEligible() {
        XCTAssertFalse(DeviceScanRules.isEligible(
            device(peripheral: "Magic Keyboard", advertised: "Magic Keyboard"),
            remembered: "Dibby",
            previouslyKnown: nil
        ))
        XCTAssertFalse(
            DeviceScanRules.isEligible(device(), remembered: "Dibby", previouslyKnown: nil),
            "an advertisement carrying no name at all matches nothing"
        )
    }

    func testAnEmptyRememberedNameMatchesNothing() {
        // The seeded state: `device_name` is empty until the first connection. An empty string matching an empty
        // peripheral name would make every unnamed device in the room eligible.
        XCTAssertFalse(DeviceScanRules.isEligible(
            device(peripheral: ""), remembered: "", previouslyKnown: ""
        ))
    }

    // MARK: - what it is called

    func testTheLabelPrefersTheNameTheUserChose() {
        // The opposite priority to the filter, deliberately: the advertised name never changes, so preferring it
        // would list every renamed cube as "TimeFlip v2.0" and the user would never see their own name.
        XCTAssertEqual(
            DeviceScanRules.label(for: device(peripheral: "Hazza cuber", advertised: "TimeFlip v2.0")),
            "Hazza cuber"
        )
    }

    func testTheAdvertisedNameIsTheFallback() {
        XCTAssertEqual(DeviceScanRules.label(for: device(advertised: "TimeFlip v2.0")), "TimeFlip v2.0")
        XCTAssertEqual(
            DeviceScanRules.label(for: device(peripheral: "   ", advertised: "TimeFlip v2.0")),
            "TimeFlip v2.0",
            "a name that is only whitespace is not a name"
        )
    }

    func testSomethingWithNoNameIsStillListed() {
        // What somebody scanning with All Devices ticked is looking at. Dropping it would make the escape hatch out
        // of the filter narrower than the filter.
        XCTAssertEqual(DeviceScanRules.label(for: device()), "Unnamed device")
    }

    // MARK: - the order

    func testEligibleDevicesComeFirst() {
        // The point of All Devices is to show a cube the filter cannot see, which is useless if it sits below a
        // room's worth of headphones.
        let cube = device(peripheral: "TimeFlip v2.0")
        let keyboard = device(peripheral: "Apple Keyboard")
        let ordered = DeviceScanRules.ordered([keyboard, cube], remembered: nil, previouslyKnown: nil)

        XCTAssertEqual(ordered.first?.id, cube.id)
    }

    func testTheRestAreSortedByNameSoTwoScansAgree() {
        let zed = device(peripheral: "Zed")
        let alpha = device(peripheral: "alpha")
        let ordered = DeviceScanRules.ordered([zed, alpha], remembered: nil, previouslyKnown: nil)

        XCTAssertEqual(ordered.map { DeviceScanRules.label(for: $0) }, ["alpha", "Zed"], "case does not decide it")
    }

    func testTwoDevicesSharingANameDoNotSwapPlaces() {
        // A dictionary's iteration order is not stable, and these are drawn from one. Without the tiebreak the list
        // would reshuffle between redraws of the same two devices.
        let first = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            peripheralName: "TimeFlip v2.0", advertisedName: nil, advertisesTimeFlipService: false
        )
        let second = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            peripheralName: "TimeFlip v2.0", advertisedName: nil, advertisesTimeFlipService: false
        )

        XCTAssertEqual(
            DeviceScanRules.ordered([second, first], remembered: nil, previouslyKnown: nil).map(\.id),
            [first.id, second.id]
        )
    }
}
