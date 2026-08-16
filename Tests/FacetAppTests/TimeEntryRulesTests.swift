@testable import FacetApp
import Foundation
import XCTest

/// Covers `TimeEntryRules`: whether a finished segment counts as tracked time, and the threshold that decides
/// the one interesting case.
///
/// Numbers in, decision out, no database. `TimeEntryRecorderTests` is where they meet real rows.
final class TimeEntryRulesTests: XCTestCase {
    private func decision(
        duration: Double,
        paused: Bool = false,
        finalised: Bool = true,
        blip: Int = 5
    ) -> TimeEntryRules.Decision {
        TimeEntryRules.decision(
            durationSeconds: duration,
            isPaused: paused,
            isFinalised: finalised,
            blipSeconds: blip
        )
    }

    // MARK: - what counts

    func testAnOrdinaryFinishedSegmentCounts() {
        XCTAssertEqual(decision(duration: 300), .create)
    }

    func testAnOpenSegmentIsTooEarlyToAsk() {
        XCTAssertEqual(
            decision(duration: 300, finalised: false), .ignore(.stillRunning),
            "the question belongs to the moment it closes"
        )
    }

    func testAPausedStretchIsTimeNotSpent() {
        XCTAssertEqual(decision(duration: 3_600, paused: true), .ignore(.paused))
    }

    func testStillRunningIsAnsweredBeforePaused() {
        // Both are true of a paused segment that has not closed yet, and only one of them is final: marking it
        // answered would be wrong, so the open case has to win.
        XCTAssertEqual(decision(duration: 60, paused: true, finalised: false), .ignore(.stillRunning))
    }

    // MARK: - the blip threshold

    func testAnythingShorterThanTheThresholdIsAFlipPastAFace() {
        XCTAssertEqual(decision(duration: 4, blip: 5), .ignore(.blip(shorterThan: 5)))
        XCTAssertEqual(decision(duration: 0, blip: 5), .ignore(.blip(shorterThan: 5)))
    }

    func testASegmentExactlyAsLongAsTheThresholdIsKept() {
        // "Ignore flips under five": five is not under five.
        XCTAssertEqual(decision(duration: 5, blip: 5), .create)
    }

    func testZeroSwitchesTheFilterOff() {
        // A request to count everything, including a segment that ran no time at all.
        XCTAssertEqual(decision(duration: 0, blip: 0), .create)
        XCTAssertEqual(decision(duration: 0.4, blip: 0), .create)
    }

    // MARK: - the threshold itself

    func testAMissingThresholdFallsBackToTheSeededValue() {
        // `database/011_setting.sql` seeds 5, which comes from the vendor spec.
        XCTAssertEqual(TimeEntryRules.blipSeconds(from: nil), 5)
        XCTAssertEqual(TimeEntryRules.blipSeconds(from: nil), TimeEntryRules.defaultBlipSeconds)
    }

    func testAHandEditedThresholdIsHeldToTheBoundsTheAppWouldSet() {
        XCTAssertEqual(TimeEntryRules.blipSeconds(from: 12), 12)
        XCTAssertEqual(TimeEntryRules.blipSeconds(from: 0), 0, "zero is a real value: the filter off")
        XCTAssertEqual(TimeEntryRules.blipSeconds(from: -1), 0)
        XCTAssertEqual(
            TimeEntryRules.blipSeconds(from: 600), 30,
            "a row nobody could have set from the app cannot discard ten minutes of work"
        )
    }
}
