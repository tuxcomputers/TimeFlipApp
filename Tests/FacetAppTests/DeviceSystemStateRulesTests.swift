@testable import FacetApp
import Foundation
import XCTest

/// Covers `DeviceSystemStateRules`: the four bytes the cube uses to say what it wants and what is broken.
///
/// **The codes are the vendor's and nothing about them is derivable**, which is what makes them worth pinning: `0x0100`
/// for a factory reset and `0x0202` for a flash fault are numbers out of a table, and a test is the only thing that
/// notices if one of them is transcribed wrongly.
final class DeviceSystemStateRulesTests: XCTestCase {
    private func state(_ sync: UInt16, _ hardware: UInt16) -> DeviceSystemStateRules.State? {
        DeviceSystemStateRules.state(
            from: Data([
                UInt8(sync >> 8), UInt8(sync & 0xFF),
                UInt8(hardware >> 8), UInt8(hardware & 0xFF),
            ])
        )
    }

    // MARK: - what it wants

    func testAllZeroMeansThereIsNothingToDo() {
        let read = state(0x0000, 0x0000)

        XCTAssertEqual(read?.sync, .ok)
        XCTAssertEqual(read?.hardware, .ok)
        XCTAssertEqual(read?.isEverythingFine, true)
    }

    func testAFactoryResetIsReported() {
        // The one this app acts on: it goes and asks for history again.
        XCTAssertEqual(state(0x0100, 0x0000)?.sync, .factoryReset)
    }

    func testTheSixThingsACubeCanAskFor() {
        XCTAssertEqual(state(0x0201, 0)?.sync, .timeRequired)
        XCTAssertEqual(state(0x0202, 0)?.sync, .faceColoursRequired)
        XCTAssertEqual(state(0x0203, 0)?.sync, .ledBrightnessRequired)
        XCTAssertEqual(state(0x0204, 0)?.sync, .blinkIntervalRequired)
        XCTAssertEqual(state(0x0205, 0)?.sync, .taskParametersRequired)
        XCTAssertEqual(state(0x0206, 0)?.sync, .autoPauseRequired)
    }

    func testAnUnpublishedRequestKeepsItsCode() {
        // Not coerced to `ok`. A newer firmware asking for something this app has never heard of is a fact, and
        // reading it as "nothing to do" would hide it -- so the number survives into the log.
        XCTAssertEqual(state(0x0207, 0x0000)?.sync, .unknown(0x0207))
        XCTAssertEqual(state(0x0207, 0x0000)?.isEverythingFine, false)
    }

    // MARK: - what is broken

    func testAFlashFaultIsReported() {
        // **The one that matters most here.** History is stored in flash, so a cube reporting this records nothing --
        // and its history reads come back empty, which is indistinguishable from a cube that has simply been reset.
        let read = state(0x0000, 0x0202)

        XCTAssertEqual(read?.hardware, .flash)
        XCTAssertEqual(read?.isEverythingFine, false)
    }

    func testTheOtherHardwareFaults() {
        XCTAssertEqual(state(0, 0x0201)?.hardware, .accelerometer)
        XCTAssertEqual(state(0, 0x0203)?.hardware, .accelerometerAndFlash)
        XCTAssertEqual(state(0, 0x0299)?.hardware, .unknown(0x0299))
    }

    func testAFaultIsNotFineEvenWithNothingToSync() {
        XCTAssertEqual(state(0x0000, 0x0201)?.isEverythingFine, false)
    }

    // MARK: - reading the bytes at all

    func testTheHalvesAreBigEndianAndInThatOrder() {
        // Sync first, hardware second. Swapped, a healthy cube asking for its colours would read as a broken one.
        let read = DeviceSystemStateRules.state(from: Data([0x01, 0x00, 0x02, 0x02]))

        XCTAssertEqual(read?.rawSync, 0x0100)
        XCTAssertEqual(read?.rawHardware, 0x0202)
        XCTAssertEqual(read?.sync, .factoryReset)
        XCTAssertEqual(read?.hardware, .flash)
    }

    func testAShortPayloadIsNotAState() {
        XCTAssertNil(DeviceSystemStateRules.state(from: Data([0x00, 0x00, 0x00])))
        XCTAssertNil(DeviceSystemStateRules.state(from: nil))
    }

    func testALongerPayloadIsStillReadFromItsFirstFourBytes() {
        // The characteristic is 20 bytes wide, so the four that matter arrive padded.
        var padded = Data([0x01, 0x00, 0x00, 0x00])
        padded.append(Data(repeating: 0, count: 16))

        XCTAssertEqual(DeviceSystemStateRules.state(from: padded)?.sync, .factoryReset)
    }

    // MARK: - saying it out loud

    func testAFlashFaultSaysWhatItMeansRatherThanItsCode() {
        // The codes mean nothing to whoever reads the log, and this one is the difference between "the cube was reset"
        // and "the cube is broken".
        let described = DeviceSystemStateRules.describe(try! XCTUnwrap(state(0x0000, 0x0202)))

        XCTAssertTrue(described.contains("FLASH MEMORY FAULT"), described)
        XCTAssertTrue(described.contains("cannot record history"), described)
    }

    func testAnUnpublishedCodeCarriesItsNumberIntoTheLog() {
        let described = DeviceSystemStateRules.describe(try! XCTUnwrap(state(0x0207, 0x0000)))

        XCTAssertTrue(described.contains("0x0207"), described)
    }
}
