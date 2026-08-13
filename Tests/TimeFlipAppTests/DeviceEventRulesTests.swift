@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers `DeviceEventRules`: what an incoming segment means for what is already recorded.
///
/// The decisions are here rather than beside the sqlite because this is the part that was wrong in the
/// previous app and wrong invisibly -- a segment left claiming to be live is never converted, so the time in
/// it is lost with nothing failing. Numbers in, decision out, no database.
final class DeviceEventRulesTests: XCTestCase {
    /// A moment with no fractional part, so `startEpoch` is exactly this and the tests are about the
    /// comparisons rather than about rounding.
    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    private func segment(
        eventNumber: Int = 10,
        face: Int = 4,
        at offset: TimeInterval = 0,
        duration: TimeInterval = 30,
        isPaused: Bool = false
    ) -> DeviceEventSegment {
        DeviceEventSegment(
            eventNumber: eventNumber,
            face: face,
            startedAt: moment.addingTimeInterval(offset),
            durationSeconds: duration,
            isPaused: isPaused
        )
    }

    private func mark(_ startEpoch: Int, _ eventNumber: Int) -> DeviceEventMark {
        DeviceEventMark(startEpoch: startEpoch, eventNumber: eventNumber)
    }

    // MARK: - the epoch a segment carries

    func testTheEpochIsWholeSeconds() {
        // What the device reports, and so what the table stores: two segments inside one second share it,
        // which is why the event number is carried alongside.
        XCTAssertEqual(segment(at: 0.9).startEpoch, segment().startEpoch)
        XCTAssertEqual(segment(at: 1).startEpoch, segment().startEpoch + 1)
    }

    // MARK: - a segment never seen before

    func testTheFirstSegmentEverRecordedIsTheOpenOne() {
        XCTAssertEqual(
            DeviceEventRules.decision(for: segment(), existingRowID: nil, mark: .none),
            .insertAsOpen,
            "an empty table needs no special case: every real epoch is newer than the sentinel"
        )
    }

    func testASegmentNewerThanAnythingRecordedTakesOverAsTheOpenOne() {
        let decision = DeviceEventRules.decision(
            for: segment(eventNumber: 11, at: 60),
            existingRowID: nil,
            mark: mark(segment().startEpoch, 10)
        )

        XCTAssertEqual(decision, .insertAsOpen, "the last frame of a history dump is the segment in progress")
    }

    func testASegmentArrivingOutOfOrderGoesInAlreadyClosed() {
        let decision = DeviceEventRules.decision(
            for: segment(eventNumber: 9, at: -60),
            existingRowID: nil,
            mark: mark(segment().startEpoch, 10)
        )

        XCTAssertEqual(decision, .insertClosed, "it cannot be what is happening now, so it is not left open")
    }

    func testASecondSegmentInsideTheSameSecondStillTakesOver() {
        // Measured on the device 2026-08-12: a daily limit's pause produced events 72 through 76 inside one
        // second. With the epoch as the only test, the close-out stopped firing after 72 and 72 was left
        // claiming to be live for good, beside the row that really was.
        let decision = DeviceEventRules.decision(
            for: segment(eventNumber: 73),
            existingRowID: nil,
            mark: mark(segment().startEpoch, 72)
        )

        XCTAssertEqual(decision, .insertAsOpen)
    }

    func testALowerEventNumberInTheSameSecondDoesNotTakeOver() {
        let decision = DeviceEventRules.decision(
            for: segment(eventNumber: 72),
            existingRowID: nil,
            mark: mark(segment().startEpoch, 73)
        )

        XCTAssertEqual(decision, .insertClosed)
    }

    func testADeviceResetIsDecidedOnTheEpochAndNeverOnItsCounter() {
        // A reset restarts the device's counter low while the table still holds high numbers from before it.
        // The epoch dominates, so the new segment is correctly the newest despite counting from 1.
        let decision = DeviceEventRules.decision(
            for: segment(eventNumber: 1, at: 3_600),
            existingRowID: nil,
            mark: mark(segment().startEpoch, 5_000)
        )

        XCTAssertEqual(decision, .insertAsOpen)
    }

    // MARK: - a segment already on record

    func testTheOpenSegmentGrowingIsUpdatedInPlaceAndStaysOpen() {
        // The normal case by volume: the live frame is re-sent with a larger duration on every refresh.
        let live = segment(eventNumber: 10, duration: 90)

        let decision = DeviceEventRules.decision(
            for: live,
            existingRowID: 42,
            mark: mark(live.startEpoch, 10)
        )

        XCTAssertEqual(decision, .update(rowID: 42, finalised: false))
    }

    func testAFinishedSegmentBeingResentIsUpdatedAndStaysClosed() {
        let old = segment(eventNumber: 10)

        let decision = DeviceEventRules.decision(
            for: old,
            existingRowID: 42,
            mark: mark(old.startEpoch + 60, 11)
        )

        XCTAssertEqual(decision, .update(rowID: 42, finalised: true))
    }

    func testAResentRowFromTheSameSecondAsTheLiveOneIsNotReopened() {
        // The other half of the 2026-08-12 measurement. Matching the mark is an equality on the pair, not
        // "is it newer": testing the epoch alone here re-opened an earlier row from the same second every
        // time the device re-sent it.
        let earlier = segment(eventNumber: 72)

        let decision = DeviceEventRules.decision(
            for: earlier,
            existingRowID: 42,
            mark: mark(earlier.startEpoch, 76)
        )

        XCTAssertEqual(decision, .update(rowID: 42, finalised: true))
    }

    // MARK: - ordering on its own

    func testNewerIsThePairWithTheEpochDominating() {
        let base = mark(segment().startEpoch, 10)

        XCTAssertTrue(DeviceEventRules.isNewer(segment(eventNumber: 11), than: base))
        XCTAssertFalse(DeviceEventRules.isNewer(segment(eventNumber: 10), than: base), "the mark is not newer than itself")
        XCTAssertFalse(DeviceEventRules.isNewer(segment(eventNumber: 9), than: base))
        XCTAssertTrue(DeviceEventRules.isNewer(segment(eventNumber: 1, at: 1), than: base))
        XCTAssertFalse(DeviceEventRules.isNewer(segment(eventNumber: 9_999, at: -1), than: base))
    }

    // MARK: - which event type

    func testASegmentIsAFlipOrAPauseAndNothingElse() {
        XCTAssertEqual(DeviceEventRules.eventTypeName(isPaused: false), "face_flip")
        XCTAssertEqual(DeviceEventRules.eventTypeName(isPaused: true), "pause")
    }
}
