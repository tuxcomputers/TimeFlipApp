@testable import FacetApp
import XCTest

/// Covers `ManualTimerRules` and `DurationFormat`: what the timing control shows, and how a duration reads.
final class ManualTimerRulesTests: XCTestCase {
    // MARK: - what the control shows

    func testNothingPickedIsIdle() {
        XCTAssertEqual(ManualTimerRules.timingState(categoryID: nil, isRunning: false), .idle)
        XCTAssertEqual(
            ManualTimerRules.timingState(categoryID: nil, isRunning: true), .idle,
            "running against no category is not a state to draw"
        )
    }

    func testAPickedCategoryIsRunningOrPaused() {
        XCTAssertEqual(ManualTimerRules.timingState(categoryID: 7, isRunning: true), .running)
        XCTAssertEqual(ManualTimerRules.timingState(categoryID: 7, isRunning: false), .paused)
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

    func testTheMenuItemSaysWhatClickingDoes() {
        // Deliberately the opposite of the glyph: a glyph is a status readout, a menu item is an instruction.
        XCTAssertEqual(ManualTimerRules.pauseMenuTitle(for: .running), "Pause")
        XCTAssertEqual(ManualTimerRules.pauseMenuTitle(for: .paused), "Resume")
        XCTAssertEqual(
            ManualTimerRules.pauseMenuTitle(for: .idle), "Pause",
            "a dead item claiming there is something to resume is worse than one claiming there is something to pause"
        )
    }

    // MARK: - which face manual mode times on

    func testTheAppsFacesStartAboveTheCubes() {
        // Seeded in `database/008_face.sql` alongside the twelve physical faces. Nothing above 12 is ever
        // reported by a device, which is what leaves these numbers free.
        XCTAssertEqual(ManualFace.all, [13, 14])
        XCTAssertEqual(ManualFace.first, 13)
        XCTAssertTrue(ManualFace.all.allSatisfy { $0 > 12 })
    }

    func testConsecutiveSegmentsNeverShareAFace() {
        // The whole reason there is more than one. A finished segment's face keeps its category while the next
        // segment runs, so nothing can be filed under the category that replaced it.
        XCTAssertEqual(ManualFace.next(after: 13), 14)
        XCTAssertEqual(ManualFace.next(after: 14), 13)
        for face in ManualFace.all {
            XCTAssertNotEqual(ManualFace.next(after: face), face)
        }
    }

    func testTheFirstEverSegmentStartsAtTheFirstFace() {
        XCTAssertEqual(ManualFace.next(after: nil), ManualFace.first, "nothing has been timed yet")
    }

    func testARotationStartsOverWhenTheLastSegmentWasNotOneOfOurs() {
        // A cube's flip, not manual mode's. Continuing a rotation this app was not part of would mean reading
        // a position into a number that never had one.
        XCTAssertEqual(ManualFace.next(after: 4), ManualFace.first)
        XCTAssertEqual(ManualFace.next(after: 12), ManualFace.first)
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
