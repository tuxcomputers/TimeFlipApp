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

    // MARK: - the seventeen-byte answer, which is what a single-event read returns

    func testASeventeenByteFrameIsASegment() {
        // **The vendor's own table for a single-event read is bytes 0 to 16.** Requiring eighteen threw away every
        // reply the cube gave to `0x01` and logged "a frame this app cannot read" while the cube was answering
        // perfectly well (measured 2026-08-21). `docs/timeflip.md` says the duration is five bytes at 13 to 17 and is
        // wrong; the spec, and `CLAUDE.md`, say the spec wins.
        let short = frame(event: 7, face: 3, start: 1_786_600_000, duration: 90).prefix(17)

        let segment = DeviceHistoryRules.segment(from: Data(short))

        XCTAssertEqual(segment?.eventNumber, 7)
        XCTAssertEqual(segment?.face, 3)
        XCTAssertEqual(segment?.durationSeconds, 90)
    }

    func testEventZeroIsNotASegment() {
        // How "there is no history" arrives: the cube answers a request for an event it does not have with a frame
        // numbered zero. The archive reads it the same way, calling such frames "sentinel-like".
        XCTAssertNil(DeviceHistoryRules.segment(from: frame(event: 0)))
    }

    func testTheAnswerAnEmptyCubeActuallyGaveIsReadAsNothing() {
        // Captured off the wire on 2026-08-21, in answer to `01 FF FF FF FF` from a cube holding no history. Event,
        // side and moment are all zero and the trailing four bytes carry the cube's clock, which is neither a duration
        // nor anything this app wants -- so the whole frame has to come back as "no answer" rather than as a segment
        // on face 0 in 1970.
        let measured = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x6A, 0x87, 0xF7, 0xA1,
        ])

        XCTAssertEqual(measured.count, 17)
        XCTAssertNil(DeviceHistoryRules.segment(from: measured))
    }

    func testAnEmptyAnswerIsToldApartFromAFrameThisAppCannotRead() {
        // Both come back as `nil` from `segment(from:)` and they mean entirely different things: one is a cube with no
        // history, the other is a fault. The measured empty answer, and a genuinely broken frame beside it.
        let empty = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x6A, 0x87, 0xF7, 0xA1,
        ])

        XCTAssertTrue(DeviceHistoryRules.isNoSuchEvent(empty))
        XCTAssertFalse(DeviceHistoryRules.isNoSuchEvent(frame(event: 7, face: 66)), "a real event with a bad side")
    }

    func testTheSentinelIsNotReportedAsAMissingEvent() {
        // It starts with four zero bytes too, and it already has its own answer: the stream is over.
        XCTAssertFalse(DeviceHistoryRules.isNoSuchEvent(Data(repeating: 0, count: 20)))
    }

    func testARealFrameFromTheEvidenceDatabaseReadsCorrectly() {
        // Captured from the previous app against this same cube (`docs/timeflip2-firmware-evidence.sqlite`), which
        // makes it the only frame in this suite that was not built by it. Event 8, side 6, and a duration of 20,285
        // seconds in four big-endian bytes -- so it pins the layout end to end against something real.
        let measured = Data([
            0x00, 0x00, 0x00, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x6A, 0x7D, 0x28, 0x59, 0x00, 0x00, 0x4F, 0x3D,
        ])

        let segment = DeviceHistoryRules.segment(from: measured)

        XCTAssertEqual(segment?.eventNumber, 8)
        XCTAssertEqual(segment?.face, 6)
        XCTAssertEqual(segment?.durationSeconds, 20_285)
        XCTAssertEqual(segment?.startedAt, Date(timeIntervalSince1970: 1_786_587_225))
        XCTAssertEqual(segment?.isPaused, false)
    }

    func testAPausedFrameFromTheEvidenceDatabaseReadsCorrectly() {
        // The same source, and the pause encoding on a real frame: side `0x88` is face 8 with the pause bit.
        let measured = Data([
            0x00, 0x00, 0x00, 0x02, 0x88, 0x00, 0x00, 0x00, 0x00,
            0x6A, 0x6E, 0x76, 0xCA, 0x00, 0x00, 0x00, 0x01,
        ])

        let segment = DeviceHistoryRules.segment(from: measured)

        XCTAssertEqual(segment?.eventNumber, 2)
        XCTAssertEqual(segment?.face, 8)
        XCTAssertEqual(segment?.isPaused, true)
        XCTAssertEqual(segment?.durationSeconds, 1)
    }

    // MARK: - the duration field, whose byte order firmware disagrees with the spec about

    func testABigEndianDurationIsRead() {
        // What the archive measured on firmware shipping 2026-01, and what the spec's table says.
        XCTAssertEqual(DeviceHistoryRules.duration(from: [0x00, 0x00, 0x00, 0x5A]), 90)
    }

    func testALittleEndianDurationIsReadToo() {
        // The same number the other way round. Both are tried because firmware disagrees with its own spec, and
        // taking the *smaller* non-zero reading is what picks the sane one: 90 seconds is 1,509,949,440 read
        // backwards, so the plausible duration is always the lesser of the two.
        XCTAssertEqual(DeviceHistoryRules.duration(from: [0x5A, 0x00, 0x00, 0x00]), 90)
    }

    func testADurationOfNothingIsZeroRatherThanAGuess() {
        XCTAssertEqual(DeviceHistoryRules.duration(from: [0x00, 0x00, 0x00, 0x00]), 0)
    }

    func testAJustStartedSegmentReadsAsZeroSeconds() {
        // The frame the cube reuses for the interval it is on: it exists before it has lasted any time at all, and a
        // zero duration must stay zero rather than being read as one of the two large mirror values.
        XCTAssertEqual(DeviceHistoryRules.segment(from: frame(duration: 0))?.durationSeconds, 0)
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
