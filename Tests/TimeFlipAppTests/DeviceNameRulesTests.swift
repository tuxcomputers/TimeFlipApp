@testable import TimeFlipApp
import XCTest

/// The device's limits on its own name, checked without a device.
///
/// These matter more than a normal field's validation because the failure they guard against is
/// nearly invisible: `setDeviceName` refuses an over-long or non-ASCII name by returning false, so
/// getting this wrong means a rename that appears to work, logs one line, and leaves the cube
/// called what it was called.
final class DeviceNameRulesTests: XCTestCase {

    // MARK: - what the field may hold while typing

    func testInputIsHeldToTheDeviceLimit() {
        let typed = String(repeating: "a", count: 25)
        XCTAssertEqual(DeviceNameRules.truncatedInput(typed).count, DeviceNameRules.maximumLength)
    }

    func testInputExactlyAtTheLimitIsUntouched() {
        let typed = String(repeating: "a", count: DeviceNameRules.maximumLength)
        XCTAssertEqual(DeviceNameRules.truncatedInput(typed), typed)
    }

    func testTypingIsNotCharacterFiltered() {
        // Deliberate: an emoji that vanished as it was typed would look like a broken keyboard.
        // It is left visible and refused at submit, where there is somewhere to say why.
        XCTAssertEqual(DeviceNameRules.truncatedInput("Cube 🎲"), "Cube 🎲")
        XCTAssertEqual(DeviceNameRules.truncatedInput("Café"), "Café")
    }

    // MARK: - what a submitted name does

    func testAPlainNameIsWritten() {
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: "Solid cube", current: "TimeFlip v2.0"),
            .write("Solid cube")
        )
    }

    func testInteriorSpacesSurviveButSurroundingOnesDoNot() {
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: "  Solid cube  ", current: nil),
            .write("Solid cube")
        )
    }

    func testTheNameItAlreadyHasWritesNothing() {
        // Every visit to the field would otherwise spend a BLE write to change nothing.
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "Solid cube", current: "Solid cube"), .ignore)
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: " Solid cube ", current: "Solid cube"), .ignore)
    }

    func testAnEmptyNameWritesNothing() {
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "", current: "Solid cube"), .ignore)
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "   ", current: "Solid cube"), .ignore)
    }

    func testNonASCIIIsRefusedRatherThanStripped() {
        // Stripping would write "Cube " -- a name the user did not ask for, and one they would
        // have no reason to expect.
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: "Cube 🎲", current: nil),
            .refuse(.unwritableCharacters)
        )
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: "Café", current: nil),
            .refuse(.unwritableCharacters)
        )
    }

    func testAnOverLongNameIsRefusedRatherThanTruncated() {
        // The field holds typing to 18, so this stands between the device and a paste path that
        // outruns it, or any caller that does not come through the field at all.
        let typed = String(repeating: "a", count: 19)
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: typed, current: nil),
            .refuse(.tooLong(count: 19))
        )
    }

    func testANameExactlyAtTheLimitIsAccepted() {
        let typed = String(repeating: "a", count: DeviceNameRules.maximumLength)
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: typed, current: nil), .write(typed))
    }

    // MARK: - finding the device again after a rename

    func testARenamedCubeIsFoundByItsRememberedName() {
        // The regression this exists for: renaming a cube "Hazza" made every reconnect scan time
        // out, on every launch, because the only name test was `contains("timeflip")`. Reconnecting
        // is a scan, not a uuid lookup, so a name that matches nothing loses the device outright.
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "Hazza", remembered: "Hazza"))
    }

    func testTheVendorNameStillMatchesWithNothingRemembered() {
        // A never-paired app has no remembered name, and must still find a cube out of the box.
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "TimeFlip v2.0", remembered: nil))
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "TimeFlip", remembered: nil))
    }

    func testTheVendorNameMatchesOnASubstringButARememberedNameDoesNot() {
        // "TimeFlip v2.0" has to match the family, so that one is a substring test. A remembered
        // name is exact: "Cube" as a substring would claim someone else's "Cube Companion".
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "My TimeFlip 2", remembered: nil))
        XCTAssertFalse(DeviceNameRules.matchesKnownDevice(peripheralName: "Cube Companion", remembered: "Cube"))
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "Cube", remembered: "Cube"))
    }

    func testAStaleCachedNameIsRescuedByTheAdvertisedOne() {
        // The exact state after a rename, reported 2026-08-01: CBPeripheral.name is a connection
        // behind, so it holds the name from *before* the rename and matches neither "timeflip" nor
        // the new remembered name. Only the advertised name, which this cube never changes, finds
        // it. The discovery scan checked one and not the other, so a renamed cube could be
        // connected to but not scanned for.
        XCTAssertFalse(
            DeviceNameRules.matchesKnownDevice(peripheralName: "Wobble", remembered: "Dibby"),
            "the stale cached name alone cannot match, which is what made this a bug"
        )
        XCTAssertTrue(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "Wobble",
                advertisedName: "TimeFlip v2.0",
                remembered: "Dibby"
            )
        )
    }

    func testEitherNameAloneIsEnough() {
        // Whichever half is current, the device is found.
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "Dibby", advertisedName: nil, remembered: "Dibby"))
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: nil, advertisedName: "TimeFlip v2.0", remembered: nil))
    }

    func testTwoNamesThatBothMissStillDoNotMatch() {
        // Checking a second name must widen the net for the paired cube, not start claiming others.
        XCTAssertFalse(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "Someone's Headphones",
                advertisedName: "Someone's Headphones",
                remembered: "Dibby"
            )
        )
    }

    func testMatchingIgnoresCase() {
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "HAZZA", remembered: "hazza"))
        XCTAssertTrue(DeviceNameRules.matchesKnownDevice(peripheralName: "timeflip v2.0", remembered: nil))
    }

    func testAnUnrelatedDeviceIsNotClaimed() {
        XCTAssertFalse(DeviceNameRules.matchesKnownDevice(peripheralName: "Someone's AirPods", remembered: "Hazza"))
        XCTAssertFalse(DeviceNameRules.matchesKnownDevice(peripheralName: nil, remembered: "Hazza"))
        XCTAssertFalse(DeviceNameRules.matchesKnownDevice(peripheralName: "", remembered: "Hazza"))
    }

    func testAnEmptyRememberedNameMatchesNothingExtra() {
        // An empty stored name must not degrade into "match everything".
        XCTAssertFalse(DeviceNameRules.matchesKnownDevice(peripheralName: "Someone's Speaker", remembered: ""))
    }

    // MARK: - what the refusals tell the user

    func testARefusalNamesTheLimitTheAllowanceAndWhoseRuleItIs() {
        // All three are requirements, not phrasing. A limit with no owner reads as the app being
        // fussy; a refusal with no allowance leaves the user guessing at a rule they cannot see.
        for problem in [DeviceNameProblem.tooLong(count: 21), .unwritableCharacters] {
            let message = problem.message
            XCTAssertTrue(
                message.contains("TimeFlip"),
                "\(problem.id) should put the limit on the device's makers: \(message)"
            )
            XCTAssertTrue(
                message.contains("not something this app has decided"),
                "\(problem.id) should say the limit is not the app's: \(message)"
            )
            XCTAssertTrue(
                message.contains("\(DeviceNameRules.maximumLength) characters"),
                "\(problem.id) should say what length is allowed: \(message)"
            )
            XCTAssertTrue(
                message.contains("letters, numbers"),
                "\(problem.id) should say what characters are allowed: \(message)"
            )
        }
    }

    func testTooLongSaysHowLongTheNameActuallyWas() {
        XCTAssertTrue(DeviceNameProblem.tooLong(count: 21).message.contains("21"))
    }

    func testAFailedWriteIsNotDressedUpAsARefusedName() {
        // The device not answering is a different problem from a name it cannot hold, and pointing
        // the user at the character rules when the real issue is the connection wastes their time.
        let message = DeviceNameProblem.writeFailed.message
        XCTAssertFalse(message.contains("letters, numbers"))
        XCTAssertTrue(message.contains("connected"))
        XCTAssertEqual(DeviceNameProblem.writeFailed.title, "The device didn't accept the new name")
    }

    func testTheLimitIsTheSpecs18() {
        // Pinned against the vendor spec's cap on 0x15 rather than left to drift: the driver takes
        // its own limit from this value, so a change here silently changes what the device is sent.
        XCTAssertEqual(DeviceNameRules.maximumLength, 18)
    }

    // MARK: - Finding a cube that was renamed a moment ago

    func testTheNameBeforeTheRenameStillMatches() {
        // The whole point of device_name.previous_name. Renamed "Dibby" -> "Wobble", the very next
        // scan still reports "Dibby" because macOS re-reads the GAP name only on the next connect.
        // Matching the new name alone loses the cube at the exact moment it was renamed.
        XCTAssertTrue(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "Dibby",
                remembered: "Wobble",
                previouslyKnown: "Dibby"
            )
        )
    }

    func testTheCurrentNameStillMatchesWithAPreviousOneKept() {
        XCTAssertTrue(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "Wobble",
                remembered: "Wobble",
                previouslyKnown: "Dibby"
            )
        )
    }

    func testAPreviousNameIsMatchedExactlyLikeTheCurrentOne() {
        // Same reasoning as the remembered name: a short former name used as a substring would
        // start claiming other people's hardware.
        XCTAssertFalse(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "Cube Companion",
                remembered: "Wobble",
                previouslyKnown: "Cube"
            )
        )
    }

    func testAnUnrelatedDeviceStillMatchesNothing() {
        XCTAssertFalse(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: "GlowDreaming",
                advertisedName: "GlowDreaming",
                remembered: "Wobble",
                previouslyKnown: "Dibby"
            )
        )
    }

    func testEitherNameCanArriveOnTheAdvertisementInstead() {
        XCTAssertTrue(
            DeviceNameRules.matchesKnownDevice(
                peripheralName: nil,
                advertisedName: "Dibby",
                remembered: "Wobble",
                previouslyKnown: "Dibby"
            )
        )
    }
}
