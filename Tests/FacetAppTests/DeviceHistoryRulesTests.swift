@testable import FacetApp
import Foundation
import XCTest

/// Reading the cube's history: the bytes it sends, and where the next stream starts.
///
/// **Every frame here is built to the vendor's layout rather than captured**, which is the point of testing the rule
/// rather than the radio: a frame is a fixed shape, and what is worth pinning is that this app reads the shape the
/// spec describes -- byte order included, since one field in the middle of it runs the other way.
final class DeviceHistoryRulesTests: XCTestCase {
    /// A frame, built field by field so each test can bend one part of it.
    private func frame(
        event: UInt32 = 7,
        face: UInt8 = 3,
        start: UInt64 = 1_786_600_000,
        duration: UInt64 = 90,
        trailing: [UInt8] = [0, 0]
    ) -> Data {
        var bytes: [UInt8] = []
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: event >> (8 * (3 - $0))) }
        bytes.append(face)
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: start >> (8 * (7 - $0))) }
        // Five bytes, little-endian: the one field that runs the other way.
        bytes += (0..<5).map { UInt8(truncatingIfNeeded: duration >> (8 * $0)) }
        bytes += trailing
        return Data(bytes)
    }

    // MARK: - asking

    func testAskingForOneEventNamesIt() {
        XCTAssertEqual(DeviceHistoryRules.readEvent(7), Data([0x01, 0x00, 0x00, 0x00, 0x07]))
    }

    func testAskingForTheLastEventIsAllOnes() {
        // The vendor's own "give me the latest", which is why the argument is optional rather than a magic number
        // written out at the call site.
        XCTAssertEqual(DeviceHistoryRules.readEvent(), Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testAskingForAStreamNamesWhereItStarts() {
        XCTAssertEqual(DeviceHistoryRules.readHistory(from: 300), Data([0x02, 0x00, 0x00, 0x01, 0x2C]))
    }

    func testTheEventNumberIsBigEndian() {
        // The frame's own order. A stream asked for in the wrong byte order would start somewhere arbitrary and look
        // like a cube with no history.
        XCTAssertEqual(DeviceHistoryRules.readHistory(from: 1), Data([0x02, 0x00, 0x00, 0x00, 0x01]))
    }

    // MARK: - reading a frame

    func testAFrameReadsAsASegment() {
        let segment = DeviceHistoryRules.segment(from: frame(event: 7, face: 3, start: 1_786_600_000, duration: 90))

        XCTAssertEqual(segment?.eventNumber, 7)
        XCTAssertEqual(segment?.face, 3)
        XCTAssertEqual(segment?.startedAt, Date(timeIntervalSince1970: 1_786_600_000))
        XCTAssertEqual(segment?.durationSeconds, 90)
        XCTAssertEqual(segment?.isPaused, false)
    }

    func testTheDurationIsLittleEndianWhileEverythingElseIsNot() {
        // The trap in the middle of the layout. Read the other way round, 90 seconds becomes 6,039,797,760.
        let bytes = [UInt8](frame(duration: 90))

        XCTAssertEqual(bytes[13], 90, "the low byte comes first")
        XCTAssertEqual(DeviceHistoryRules.segment(from: Data(bytes))?.durationSeconds, 90)
    }

    func testAPausedIntervalCarriesItsFaceAbove127() {
        // The vendor's own encoding: pausing adds an interval to the history "for the facet with Side + 128", so the
        // stretch is kept and marked rather than dropped.
        let segment = DeviceHistoryRules.segment(from: frame(face: 3 + 128))

        XCTAssertEqual(segment?.face, 3)
        XCTAssertEqual(segment?.isPaused, true)
    }

    func testAPausedIntervalIsStillASegment() {
        // It is time the cube accounted for. Discarding it would lose the fact that the stretch existed at all.
        XCTAssertNotNil(DeviceHistoryRules.segment(from: frame(face: 130)))
    }

    func testAnAccelerometerErrorIsNotAFace() {
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(face: DeviceHistoryRules.accelerometerError)))
    }

    func testFaceZeroIsNotAFace() {
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(face: 0)))
    }

    func testAFaceAboveTheCubesTwelveIsRefused() {
        // Nothing above 12 comes from a device, and 13 upwards are the app's own faces -- a frame claiming one would
        // put a cube's segment on a manual face.
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(face: 13)))
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(face: 13 + 128)))
    }

    func testAFrameWithNoTimeIsNotASegment() {
        // Zero is a frame that did not carry a time, not a segment from 1970.
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(start: 0)))
    }

    func testAShortFrameIsNotASegment() {
        XCTAssertNil(DeviceHistoryRules.segment(from: Data([0, 0, 0, 1, 3])))
    }

    // MARK: - the end of a stream

    func testAnAllZeroFrameEndsTheStream() {
        XCTAssertTrue(DeviceHistoryRules.isEndOfStream(Data(repeating: 0, count: 20)))
    }

    func testTheSentinelIsSeventeenZerosNotTwenty() {
        // Bytes 18 and 19 carry a previous-event pointer that some firmware fills in regardless, so a stricter check
        // reads a real terminator as a frame and waits for a stream that has already finished.
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[18] = 0x2A
        bytes[19] = 0x11

        XCTAssertTrue(DeviceHistoryRules.isEndOfStream(Data(bytes)))
        XCTAssertNil(DeviceHistoryRules.segment(from: Data(bytes)))
    }

    func testARealFrameIsNotTheEnd() {
        XCTAssertFalse(DeviceHistoryRules.isEndOfStream(frame()))
    }

    // MARK: - the same segment, or a different generation

    private func mark(_ event: Int, _ epoch: Int) -> DeviceEventMark {
        DeviceEventMark(startEpoch: epoch, eventNumber: event)
    }

    private func segment(_ event: Int, _ epoch: Int) -> DeviceEventSegment {
        DeviceEventSegment(
            eventNumber: event,
            face: 3,
            startedAt: Date(timeIntervalSince1970: TimeInterval(epoch)),
            durationSeconds: 0,
            isPaused: false
        )
    }

    func testTheSameNumberAndTheSameStartIsTheSameSegment() {
        XCTAssertTrue(DeviceHistoryRules.isSameSegment(mark(10, 1000), as: segment(10, 1000)))
    }

    func testTheSameNumberFromADifferentGenerationIsNot() {
        // The one that cost the previous app nine segments: a factory reset restarts the counter, so a post-reset
        // event 10 is not the event 10 on file, and calling them the same skips the stream bringing events 1 to 9 in.
        XCTAssertFalse(DeviceHistoryRules.isSameSegment(mark(10, 1000), as: segment(10, 2000)))
    }

    // MARK: - where the next stream starts

    func testAnEmptyDatabaseStartsFromTheBeginning() {
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(.none, deviceLast: segment(40, 5000)), 0)
    }

    func testAnUnansweredReadLeavesTheStoredPositionStanding() {
        // A timeout re-requests the same thing rather than re-streaming everything the cube holds.
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(10, 1000), deviceLast: nil), 10)
    }

    func testItResumesAtTheStoredPositionRatherThanPastIt() {
        // The newest row is normally the cube's still-open segment, and asking for it again is how its finished
        // duration comes back.
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(10, 1000), deviceLast: segment(12, 3000)), 10)
    }

    func testACubeSittingOnTheRecordedSegmentResumesThere() {
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(10, 1000), deviceLast: segment(10, 1000)), 10)
    }

    func testACounterThatWentBackwardsStartsFromTheBeginning() {
        // A factory reset. The stored position names a segment the cube cannot reach, so asking for it returns
        // nothing -- for ever, while everything the cube does hold is never fetched.
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(38, 5000), deviceLast: segment(2, 9000)), 0)
    }

    func testANewerNumberThatStartedEarlierStartsFromTheBeginning() {
        // The reset that has already counted back up past the stored number, where nothing about the numbers looks
        // wrong. Only the clock catches it.
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(10, 5000), deviceLast: segment(12, 1000)), 0)
    }

    func testASegmentSharingItsSecondWithTheNextStillResumes() {
        // `>=` rather than `>` on the epoch: a zero-length segment can share its second with the one that follows,
        // and the previous app's production database holds several.
        XCTAssertEqual(DeviceHistoryRules.resumeFrom(mark(10, 1000), deviceLast: segment(11, 1000)), 10)
    }

    // MARK: - splitting a stream

    func testTheLastFrameIsTheOpenOne() {
        // Measured behaviour rather than anything the spec says: the cube reuses that event number and refreshes its
        // duration, so the last frame of a complete dump is the interval still running.
        let (finished, open) = DeviceHistoryRules.split([segment(8, 100), segment(9, 200), segment(10, 300)])

        XCTAssertEqual(finished.map(\.eventNumber), [8, 9])
        XCTAssertEqual(open?.eventNumber, 10)
    }

    func testFramesAreOrderedByNumberRatherThanByArrival() {
        // Written in ascending order or not at all: the recorder decides update-versus-insert from the newest row it
        // has seen, so a later segment written first makes every earlier one look already superseded.
        let (finished, open) = DeviceHistoryRules.split([segment(10, 300), segment(8, 100), segment(9, 200)])

        XCTAssertEqual(finished.map(\.eventNumber), [8, 9])
        XCTAssertEqual(open?.eventNumber, 10)
    }

    func testARepeatedFrameKeepsTheLaterAccountOfIt() {
        let (finished, _) = DeviceHistoryRules.split([segment(8, 100), segment(8, 100), segment(9, 200)])

        XCTAssertEqual(finished.count, 1)
    }

    func testAnEmptyStreamHasNothingOpen() {
        let (finished, open) = DeviceHistoryRules.split([])

        XCTAssertTrue(finished.isEmpty)
        XCTAssertNil(open)
    }

    func testOneFrameIsTheOpenOneAndNothingIsFinished() {
        let (finished, open) = DeviceHistoryRules.split([segment(10, 300)])

        XCTAssertTrue(finished.isEmpty)
        XCTAssertEqual(open?.eventNumber, 10)
    }

    // MARK: - whether the stream really ended on the current segment

    func testAStreamReachingTheCubesLastEventEndsOnTheCurrentOne() {
        XCTAssertTrue(DeviceHistoryRules.isCurrent(segment(10, 300), deviceLast: segment(10, 300)))
    }

    func testAStreamCutShortDoesNot() {
        // A dropped stream also ends on a frame, and that frame is a closed segment with more history behind it.
        // Recording it as the open one would put a stale segment on screen as what is happening now.
        XCTAssertFalse(DeviceHistoryRules.isCurrent(segment(7, 100), deviceLast: segment(10, 300)))
    }

    func testWithNoAnswerToCheckAgainstTheStreamIsTakenAtItsWord() {
        XCTAssertTrue(DeviceHistoryRules.isCurrent(segment(7, 100), deviceLast: nil))
    }
}
