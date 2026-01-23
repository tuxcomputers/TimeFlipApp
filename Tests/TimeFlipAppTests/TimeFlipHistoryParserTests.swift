@testable import TimeFlipApp
import XCTest

@MainActor
final class TimeFlipHistoryParserTests: XCTestCase {
    func testParsesStandardHistoryFrame() {
        let eventNumber: UInt32 = 42
        let facet: UInt8 = 5
        let timestamp: UInt64 = 1_710_000_000
        let duration: UInt64 = 120

        var frame = Data(repeating: 0, count: 20)
        frame.replaceSubrange(0..<4, with: withUnsafeBytes(of: eventNumber.bigEndian, Array.init))
        frame[4] = facet
        frame.replaceSubrange(5..<13, with: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        frame.replaceSubrange(13..<18, with: littleEndianFiveBytes(from: duration))

        let entry = TimeFlipHistoryParser.parse(frame)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.eventNumber, eventNumber)
        XCTAssertEqual(entry?.facetID, facet)
        XCTAssertEqual(entry?.isPaused, false)
        XCTAssertEqual(entry?.duration, TimeInterval(duration))
        XCTAssertEqual(entry?.startedAt, Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    func testParsesPauseEvent() {
        let pauseFacet: UInt8 = 2
        var frame = Data(repeating: 0, count: 20)
        let eventNumber: UInt32 = 2
        frame.replaceSubrange(0..<4, with: withUnsafeBytes(of: eventNumber.bigEndian, Array.init))
        frame[4] = pauseFacet &+ 128
        frame.replaceSubrange(5..<13, with: withUnsafeBytes(of: UInt64(1_700_000_000).bigEndian, Array.init))
        frame.replaceSubrange(13..<18, with: littleEndianFiveBytes(from: 5))

        let entry = TimeFlipHistoryParser.parse(frame)
        XCTAssertEqual(entry?.eventNumber, eventNumber)
        XCTAssertEqual(entry?.facetID, pauseFacet)
        XCTAssertTrue(entry?.isPaused ?? false)
    }

    func testParsesBigEndianDurationFallback() {
        // Firmware variant encodes duration as 4-byte big-endian at bytes 13-16 (remaining bytes are padding).
        var frame = Data(repeating: 0, count: 20)
        frame.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(4).bigEndian, Array.init))
        frame[4] = 4
        frame.replaceSubrange(5..<13, with: withUnsafeBytes(of: UInt64(1_700_000_000).bigEndian, Array.init))
        frame[13] = 0x00
        frame[14] = 0x00
        frame[15] = 0x02
        frame[16] = 0x0A
        frame[17] = 0x00
        frame[18] = 0x00
        frame[19] = 0x04

        let entry = TimeFlipHistoryParser.parse(frame)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.duration, 522)
    }

    func testSkipsInvalidFacet() {
        var frame = Data(repeating: 0, count: 20)
        frame[4] = 66 // accelerometer error sentinel
        frame.replaceSubrange(5..<13, with: withUnsafeBytes(of: UInt64(1).bigEndian, Array.init))
        frame.replaceSubrange(13..<18, with: littleEndianFiveBytes(from: 1))

        XCTAssertNil(TimeFlipHistoryParser.parse(frame))
    }
}

private func littleEndianFiveBytes(from value: UInt64) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 32) & 0xFF)
    ]
}
