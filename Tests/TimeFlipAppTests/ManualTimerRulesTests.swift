@testable import TimeFlipApp
import XCTest

/// Covers `ManualTimerRules` and `DurationFormat`: what the timing control shows, and how a duration reads.
final class ManualTimerRulesTests: XCTestCase {
    // MARK: - what the control shows

    func testNothingPickedIsIdle() {
        XCTAssertEqual(ManualTimerRules.state(categoryID: nil, isRunning: false), .idle)
        XCTAssertEqual(
            ManualTimerRules.state(categoryID: nil, isRunning: true), .idle,
            "running against no category is not a state to draw"
        )
    }

    func testAPickedCategoryIsRunningOrPaused() {
        XCTAssertEqual(ManualTimerRules.state(categoryID: 7, isRunning: true), .running)
        XCTAssertEqual(ManualTimerRules.state(categoryID: 7, isRunning: false), .paused)
    }

    func testTheIconSaysWhatIsHappeningNotWhatClickingDoes() {
        // The opposite of a media player, deliberately: this is a status readout, and the question it
        // answers is "am I still on the clock?"
        XCTAssertEqual(ManualTimerRules.symbolName(for: .running), "play.fill")
        XCTAssertEqual(ManualTimerRules.symbolName(for: .paused), "pause.fill")
        XCTAssertNil(ManualTimerRules.symbolName(for: .idle), "an empty space, which is also the invitation")
    }

    func testOnlyASessionCanBeClicked() {
        XCTAssertTrue(ManualTimerRules.isClickable(.running))
        XCTAssertTrue(ManualTimerRules.isClickable(.paused))
        XCTAssertFalse(
            ManualTimerRules.isClickable(.idle),
            "there is no clock to stop, and a click on a blank space names no category to start"
        )
    }

    func testTheManualFaceIsThirteen() {
        // Seeded in `database/008_face.sql` alongside the twelve physical faces.
        XCTAssertEqual(ManualFace.id, 13)
    }

    // MARK: - how a duration reads

    func testHoursAreNeverDropped() {
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(7, rounding: .truncate, showingSeconds: true), "0:00:07")
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(7, rounding: .truncate, showingSeconds: false), "0:00")
    }

    func testMinutesAndSecondsArePadded() {
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(3_723, rounding: .truncate, showingSeconds: true), "1:02:03")
    }

    func testHoursGrowPastTen() {
        XCTAssertEqual(
            DurationFormat.hoursMinutesSeconds(44_580, rounding: .truncate, showingSeconds: false), "12:23"
        )
    }

    func testALiveClockTruncatesAndAHistoricalSumRounds() {
        // A ticking value must never read ahead of the time actually recorded; a static total should not read
        // a second short of it.
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(59.6, rounding: .truncate, showingSeconds: true), "0:00:59")
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(59.6, rounding: .round, showingSeconds: true), "0:01:00")
    }

    func testANegativeDurationReadsAsZero() {
        // Only reachable from a clock that moved backwards, and "-0:-1" would be worse than wrong.
        XCTAssertEqual(DurationFormat.hoursMinutesSeconds(-5, rounding: .truncate, showingSeconds: true), "0:00:00")
    }
}
