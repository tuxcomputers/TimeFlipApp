@testable import TimeFlipApp
import XCTest

/// Why the manual-mode offer says it gave up.
///
/// Only a log line, and worth a type anyway: it is the single place "nothing was in range" can be
/// told apart from "it was right there and refused this app's PIN", and those send whoever reads it
/// looking in completely different places. It has now been got wrong twice, the second time on
/// hardware with the cube on the desk and the log blaming its absence.
final class ManualModeOfferReasonTests: XCTestCase {
    private func reason(found: Int, refused: Int) -> String {
        ManualModeOfferReason.describe(eligibleFound: found, refusedPIN: refused)
    }

    func testNothingInRange() {
        XCTAssertEqual(reason(found: 0, refused: 0), "nothing eligible found in the scan")
    }

    func testOneDeviceRefusingThePIN() {
        // The case measured on hardware 2026-08-09, which reported itself as the one above.
        XCTAssertEqual(reason(found: 1, refused: 1), "the one device found refused this app's PIN")
    }

    func testSeveralDevicesAllRefusing() {
        // An office with several cubes advertising: all eligible by name, only one of them this
        // user's, and none of them accepting this app's PIN.
        XCTAssertEqual(reason(found: 3, refused: 3), "all 3 devices found refused this app's PIN")
    }

    func testFoundButUnreachableIsItsOwnAnswer() {
        // Neither of the two the caller used to choose between. Folding it into "not in range"
        // blames the range for something that answered; folding it into "refused" blames the
        // password. It was found, and it could not be reached.
        XCTAssertEqual(reason(found: 1, refused: 0), "1 device found, none of them reachable")
        XCTAssertEqual(reason(found: 2, refused: 0), "2 devices found, none of them reachable")
    }

    func testAMixOfRefusedAndUnreachableReadsAsUnreachable() {
        // Two cubes, one refusing and one that dropped: the refusal is not the whole story, so the
        // wording that says every one of them refused would be false.
        XCTAssertEqual(reason(found: 2, refused: 1), "2 devices found, none of them reachable")
    }

    func testMoreRefusalsThanDevicesStillReadsAsAllRefused() {
        // Defensive: mid-factory-reset two passwords are tried per candidate, and a counter that
        // ever double-counted must not fall through to the unreachable wording.
        XCTAssertEqual(reason(found: 1, refused: 2), "the one device found refused this app's PIN")
    }

    func testNoDeviceOutranksAnyRefusalCount() {
        // A refusal with nothing found is not a state the attempt can produce, and if it ever were,
        // the honest answer is still that the scan listed nothing.
        XCTAssertEqual(reason(found: 0, refused: 2), "nothing eligible found in the scan")
    }
}
