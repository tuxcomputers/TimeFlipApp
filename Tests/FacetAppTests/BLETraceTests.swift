@testable import FacetApp
import CoreBluetooth
import Foundation
import XCTest

/// How BLE traffic is written down.
///
/// Worth pinning rather than left to eye, because the trace is the evidence every later measurement rests on:
/// `docs/timeflip2-firmware-observations.md` is three findings nobody set out to look for, all of them read out of
/// rows like these afterwards. A format that quietly dropped a byte would not fail anything until somebody tried to
/// answer a question with it a month later.
final class BLETraceTests: XCTestCase {
    func testBytesAreHexUppercaseAndPadded() {
        // Two characters per byte, always: `0F` and not `F`, so a frame can be read as a frame rather than counted.
        XCTAssertEqual(BLETrace.describe(Data([0x00, 0x0F, 0xFF])), "00 0F FF")
    }

    func testReadableBytesGetTheirTextToo() {
        // Finding 3: the cube narrates every command in plain ASCII on the events characteristic. The archive
        // decoded those by hand from hex; this is that work done once.
        XCTAssertEqual(
            BLETrace.describe(Data("password set".utf8)),
            "70 61 73 73 77 6F 72 64 20 73 65 74 \"password set\""
        )
    }

    func testABinaryFrameIsNotDressedUpAsText() {
        // All the bytes printable, not most. A frame that is half readable is a binary frame that happens to contain
        // letters, and rendering it as a string invites reading meaning into a coincidence.
        XCTAssertEqual(BLETrace.describe(Data([0x02, 0x41])), "02 41")
    }

    func testNothingIsSaidAboutNoBytes() {
        XCTAssertEqual(BLETrace.describe(Data()), "")
    }

    func testTheHexIsNeverReplacedByTheText() {
        // The text is a convenience; the hex is the record. A rendering that dropped it would lose exactly the bytes
        // a surprise is made of.
        let described = BLETrace.describe(Data("AB".utf8))
        XCTAssertTrue(described.hasPrefix("41 42"), described)
    }

    func testTheCharacteristicsALoginTouchesAreNamed() {
        // A named characteristic is what makes a trace readable at a glance; an unnamed one falls back to the full
        // UUID rather than to "unknown", because a UUID appearing here unnamed is a finding and has to be lookup-able
        // in the vendor spec.
        XCTAssertEqual(TimeFlipUUIDs.name(for: TimeFlipUUIDs.password), "password")
        XCTAssertEqual(TimeFlipUUIDs.name(for: TimeFlipUUIDs.commandResult), "commandResult")

        let unhandled = CBUUID(string: "F1196F55-71A4-11E6-BDF4-0800200C9A66")
        XCTAssertEqual(TimeFlipUUIDs.name(for: unhandled), unhandled.uuidString)
    }
}
