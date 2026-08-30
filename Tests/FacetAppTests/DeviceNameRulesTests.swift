@testable import FacetApp
import XCTest

/// Covers `DeviceNameRules`: what a typed device name does, when the row will open at all, and what the refusals say.
///
/// **The point of testing this without a radio is that the limits are the device's.** A name over 18 characters or
/// carrying an emoji cannot reach the cube at all, and a rename that fails at the BLE call fails almost silently --
/// so what is worth pinning is that the decision is taken before anything is sent, and that a refusal says whose rule
/// it is and what would work instead.
///
/// The scan-matching half of the archive's rules is not here: it arrived in the rebuild as `DeviceScanRules` and is
/// covered by `DeviceScanRulesTests`.
final class DeviceNameRulesTests: XCTestCase {
    // MARK: - the limit is the spec's

    func testTheLimitIsTheSpecs18() {
        // `docs/TimeFlip2 BLE Protocol v4.3.md`, the `0x15` entry: "name (18 symbols MAX. ASCII coding)". Not a
        // display choice, and not this app's to relax.
        XCTAssertEqual(DeviceNameRules.maximumLength, 18)
    }

    // MARK: - nothing to do

    func testAnEmptyNameWritesNothing() {
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "   ", current: "Dibby"), .ignore)
    }

    func testTheNameItAlreadyHasWritesNothing() {
        // A field opened and closed again is not a rename, and spending a BLE write on it would be one.
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "Dibby", current: "Dibby"), .ignore)
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "  Dibby  ", current: "Dibby"), .ignore)
    }

    // MARK: - a name that goes

    func testAPlainNameIsWritten() {
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "Plopper", current: "Dibby"), .write("Plopper"))
    }

    func testInteriorSpacesSurviveButSurroundingOnesDoNot() {
        // "Solid cube" is a reasonable name; a trailing space is invisible everywhere it would be shown.
        XCTAssertEqual(DeviceNameRules.renameDecision(typed: "  Solid cube ", current: nil), .write("Solid cube"))
    }

    func testANameExactlyAtTheLimitIsAccepted() {
        let name = String(repeating: "a", count: DeviceNameRules.maximumLength)

        XCTAssertEqual(DeviceNameRules.renameDecision(typed: name, current: nil), .write(name))
    }

    // MARK: - a name that does not

    func testAnOverLongNameIsRefusedRatherThanTruncated() {
        // **Refused, not shortened.** The field holds itself to 18 as it is typed, so this is what a paste that
        // outran the truncation meets -- and writing its first 18 characters would name the cube something nobody
        // asked for.
        let name = String(repeating: "a", count: DeviceNameRules.maximumLength + 3)

        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: name, current: nil),
            .refuse(.tooLong(count: DeviceNameRules.maximumLength + 3))
        )
    }

    func testNonASCIIIsRefusedRatherThanStripped() {
        // The character is left visible as it is typed and refused here with a reason, because one that vanished on
        // the keystroke reads as a broken keyboard.
        for name in ["Cube 🎲", "Café", "Ångström"] {
            XCTAssertEqual(
                DeviceNameRules.renameDecision(typed: name, current: nil),
                .refuse(.unwritableCharacters),
                name
            )
        }
    }

    func testControlCharactersAreRefusedThoughTheSpecOnlySaysASCII() {
        // This app's own addition: a tab or a NUL in a name is a rendering problem in every app that lists the
        // device, for no use anybody has.
        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: "Two\tnames", current: nil),
            .refuse(.unwritableCharacters)
        )
    }

    func testAnOverLongNameIsJudgedOnItsCharactersNotItsSpacing() {
        // Trimmed first, so a name that only fits once its surrounding spaces go is not refused for their length.
        let name = "  " + String(repeating: "a", count: DeviceNameRules.maximumLength) + "  "

        XCTAssertEqual(
            DeviceNameRules.renameDecision(typed: name, current: nil),
            .write(String(repeating: "a", count: DeviceNameRules.maximumLength))
        )
    }

    // MARK: - whether the row opens at all

    func testTheNameOnlyOpensWithACubeOnTheOtherEnd() {
        // Renaming is a command that has to arrive somewhere: with nothing connected the app could only write down a
        // name the hardware has never heard, and `device_name` is what the scan filter matches on.
        XCTAssertEqual(
            DeviceNameRules.renameRefusal(isCubePaired: false, isCubeConnected: false, deviceName: nil),
            .notPaired
        )
        XCTAssertEqual(
            DeviceNameRules.renameRefusal(isCubePaired: true, isCubeConnected: false, deviceName: "Dibby"),
            .notConnected
        )
        XCTAssertNil(
            DeviceNameRules.renameRefusal(isCubePaired: true, isCubeConnected: true, deviceName: "Dibby")
        )
    }

    func testACubeThatHasNotSaidWhatItIsCalledCannotBeRenamedFromThePlaceholder() {
        // The row reads `Unknown` in that state (`DeviceInfoRules.name`), and a field opened on it would offer the
        // app's own way of saying it does not know as the name to keep.
        for name in [nil, "", "   "] {
            XCTAssertEqual(
                DeviceNameRules.renameRefusal(isCubePaired: true, isCubeConnected: true, deviceName: name),
                .nameUnknown,
                name ?? "nil"
            )
        }
    }

    // MARK: - what the refusals say

    func testARefusalNamesTheLimitTheAllowanceAndWhoseRuleItIs() {
        // All three parts are required rather than stylistic: a limit with no owner reads as the app being fussy,
        // and a name refused without saying what would work leaves somebody guessing at a rule they cannot see.
        for problem in [DeviceNameProblem.tooLong(count: 21), .unwritableCharacters] {
            let message = problem.message
            XCTAssertTrue(message.contains("TimeFlip"), "names the device: \(problem)")
            XCTAssertTrue(message.contains("not something this app has decided"), "whose rule it is: \(problem)")
            XCTAssertTrue(message.contains("18 characters"), "what will work: \(problem)")
            XCTAssertTrue(message.contains("letters, numbers, spaces"), "in the user's terms: \(problem)")
        }
    }

    func testTooLongSaysHowLongTheNameActuallyWas() {
        XCTAssertTrue(DeviceNameProblem.tooLong(count: 21).message.contains("21"))
    }

    func testAFailedWriteIsNotDressedUpAsARefusedName() {
        // A cube that did not answer is a different problem from a name it cannot hold, and quoting the character
        // rules at a connection fault sends somebody looking in the wrong place.
        let message = DeviceNameProblem.writeFailed.message

        XCTAssertFalse(message.contains("18"), "the character rules have nothing to do with a write that failed")
        XCTAssertFalse(message.contains("not something this app has decided"))
        XCTAssertTrue(message.contains("still called what it was called before"))
        XCTAssertNotEqual(DeviceNameProblem.writeFailed.title, DeviceNameProblem.unwritableCharacters.title)
    }

    // MARK: - the lag the firmware imposes

    func testTheNoticeLeadsWithTheRenameHavingWorked() {
        // Somebody who renames the cube, looks for the new name in a scan and finds the old one will otherwise
        // conclude the rename failed and that this app broke it.
        let notice = DeviceNameRules.renameLagNotice(newName: "Plopper", previousName: "Dibby")

        XCTAssertTrue(notice.contains("now called \"Plopper\""))
        XCTAssertTrue(notice.contains("Dibby"), "and says which name will keep turning up")
        XCTAssertTrue(notice.contains("advertising"), "the scan list is the half that never changes")
    }

    func testTheNoticeDoesNotOfferAWayToHurryTheAppItself() {
        // The archive told people to Forget the device and pair again, which is how *its* Device tab caught up. This
        // app keeps the name it wrote, so that sequence would spend a re-pair to change nothing.
        let notice = DeviceNameRules.renameLagNotice(newName: "Plopper", previousName: "Dibby")

        XCTAssertFalse(notice.contains("Forget Device"))
        XCTAssertTrue(notice.contains("this app will go on calling it that"))
    }

    func testTheNoticeAttributesTheLagRatherThanApologisingForIt() {
        let notice = DeviceNameRules.renameLagNotice(newName: "Plopper", previousName: nil)

        XCTAssertTrue(notice.contains("the old name"), "with nothing to name, it still says what will show")
        XCTAssertTrue(notice.contains("neither half of that is something this app can change"))
    }
}
