@testable import FacetApp
import Foundation
import XCTest

/// Covers `DayWindow`: what "today" means for tracked time, and how a stretch is clipped to it.
///
/// A fixed calendar and time zone, so these assert the rules rather than the machine they run on.
final class DayWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }()

    private func date(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try XCTUnwrap(formatter.date(from: text))
    }

    private func start(_ now: String, hour: Int = 3, minute: Int = 0) throws -> Date {
        DayWindow.start(at: try date(now), resetHour: hour, resetMinute: minute, calendar: calendar)
    }

    // MARK: - where the day starts

    func testTheDayStartsAtTheResetTimeNotMidnight() throws {
        // Seeded to 03:00 for a stated reason: a session running across midnight should not be cut in half by
        // the calendar.
        XCTAssertEqual(try start("2026-08-13 14:00:00"), try date("2026-08-13 03:00:00"))
    }

    func testBeforeTheResetTimeTheDayIsStillYesterdays() throws {
        XCTAssertEqual(try start("2026-08-13 01:30:00"), try date("2026-08-12 03:00:00"))
        XCTAssertEqual(try start("2026-08-13 00:00:00"), try date("2026-08-12 03:00:00"), "just after midnight")
    }

    func testTheBoundaryItselfBelongsToTheNewDay() throws {
        XCTAssertEqual(try start("2026-08-13 03:00:00"), try date("2026-08-13 03:00:00"))
        XCTAssertEqual(try start("2026-08-13 02:59:59"), try date("2026-08-12 03:00:00"))
    }

    func testTheMinuteIsHonoured() throws {
        // Stored as well as the hour so a finer time can be set while testing the rollover.
        XCTAssertEqual(try start("2026-08-13 03:20:00", hour: 3, minute: 30), try date("2026-08-12 03:30:00"))
        XCTAssertEqual(try start("2026-08-13 03:40:00", hour: 3, minute: 30), try date("2026-08-13 03:30:00"))
    }

    func testTheWindowStartsAtTheSameWallClockTimeAcrossADaylightSavingChange() throws {
        // Sydney's clocks go forward on 2026-10-04, so that day is 23 hours long. Through `Calendar` rather
        // than subtracting 86,400 seconds, the day still starts at 03:00 either side of it.
        //
        // 01:00 rather than 02:00 for the second one: 02:00 does not exist that morning, the clocks going
        // straight from 01:59:59 to 03:00:00.
        XCTAssertEqual(try start("2026-10-04 12:00:00"), try date("2026-10-04 03:00:00"))
        XCTAssertEqual(try start("2026-10-04 01:00:00"), try date("2026-10-03 03:00:00"))
    }

    // MARK: - the reset time in force

    func testAMissingResetTimeFallsBackToTheSeededThreeAM() {
        let reset = DayWindow.resetTime(hour: nil, minute: nil)

        XCTAssertEqual(reset.hour, 3)
        XCTAssertEqual(reset.minute, 0)
    }

    func testAHandEditedResetTimeIsHeldToARealClock() {
        XCTAssertEqual(DayWindow.resetTime(hour: 25, minute: 90).hour, 23)
        XCTAssertEqual(DayWindow.resetTime(hour: 25, minute: 90).minute, 59)
        XCTAssertEqual(DayWindow.resetTime(hour: -4, minute: -1).hour, 0)
        XCTAssertEqual(DayWindow.resetTime(hour: -4, minute: -1).minute, 0)
    }

    // MARK: - clipping a stretch to the window

    func testAStretchInsideTheWindowCountsWhole() throws {
        let windowStart = try date("2026-08-13 03:00:00")
        let began = try date("2026-08-13 09:00:00")

        XCTAssertEqual(
            DayWindow.overlap(
                startEpoch: began.timeIntervalSince1970,
                durationSeconds: 600,
                windowStart: windowStart,
                now: try date("2026-08-13 10:00:00")
            ),
            600
        )
    }

    func testAStretchStraddlingTheStartCountsOnlyThePartInside() throws {
        // An hour either side of the boundary: half of it belongs to yesterday.
        let windowStart = try date("2026-08-13 03:00:00")

        XCTAssertEqual(
            DayWindow.overlap(
                startEpoch: try date("2026-08-13 02:00:00").timeIntervalSince1970,
                durationSeconds: 7_200,
                windowStart: windowStart,
                now: try date("2026-08-13 10:00:00")
            ),
            3_600
        )
    }

    func testAStretchEntirelyBeforeTheWindowCountsNothing() throws {
        XCTAssertEqual(
            DayWindow.overlap(
                startEpoch: try date("2026-08-12 10:00:00").timeIntervalSince1970,
                durationSeconds: 600,
                windowStart: try date("2026-08-13 03:00:00"),
                now: try date("2026-08-13 10:00:00")
            ),
            0,
            "zero, not a negative number"
        )
    }

    func testARecordedEndInTheFutureIsClippedToNow() throws {
        // Only reachable from a clock that moved, or a hand-edited row. Counting it would report time that has
        // not happened.
        XCTAssertEqual(
            DayWindow.overlap(
                startEpoch: try date("2026-08-13 09:00:00").timeIntervalSince1970,
                durationSeconds: 7_200,
                windowStart: try date("2026-08-13 03:00:00"),
                now: try date("2026-08-13 09:30:00")
            ),
            1_800
        )
    }

    // MARK: - a stretch still running

    func testAStretchStillRunningCountsUpToNow() throws {
        XCTAssertEqual(
            DayWindow.elapsedInside(
                startEpoch: try date("2026-08-13 09:00:00").timeIntervalSince1970,
                windowStart: try date("2026-08-13 03:00:00"),
                now: try date("2026-08-13 09:05:00")
            ),
            300
        )
    }

    func testAStretchRunningSinceBeforeTheWindowCountsFromTheBoundary() throws {
        // Started last night and still going: today's total gets the part since the reset, not the whole thing.
        XCTAssertEqual(
            DayWindow.elapsedInside(
                startEpoch: try date("2026-08-13 01:00:00").timeIntervalSince1970,
                windowStart: try date("2026-08-13 03:00:00"),
                now: try date("2026-08-13 04:00:00")
            ),
            3_600
        )
    }
}
