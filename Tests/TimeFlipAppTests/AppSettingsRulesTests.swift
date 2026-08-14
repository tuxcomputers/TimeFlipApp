@testable import TimeFlipApp
import XCTest

/// Covers `AppSettingsRules`: the bounds each App tab row is held to, and the two conversions between what the
/// `setting` table stores and what a row shows.
///
/// The bounds are the previous app's, so what these assert is that they came across intact -- each one was a
/// measurement or a decision with a reason, and re-picking them would throw the reason away.
final class AppSettingsRulesTests: XCTestCase {
    // MARK: - the daily reset

    func testTheResetHourIsATwelveHourFace() {
        XCTAssertEqual(AppSettingsRules.resetHours, 1 ... 12)
        // AM is a fixed word: PM was only ever a way to pick a wrong value, a reset in the afternoon cutting a
        // working day's accounting in half.
        XCTAssertEqual(AppSettingsRules.resetSuffix, "AM")
    }

    func testMidnightReadsAsTwelve() {
        XCTAssertEqual(AppSettingsRules.hour12(from: 0), 12)
    }

    func testAnAfternoonHourStillDrawsAsItsClockFace() {
        // A stored PM hour has to draw as something on an AM-only face, and it draws as the hour it is on the face.
        // Correcting the stored value would be a write, and this is a reading.
        XCTAssertEqual(AppSettingsRules.hour12(from: 15), 3)
        XCTAssertEqual(AppSettingsRules.hour12(from: 12), 12)
    }

    func testTheSeededResetIsThreeInTheMorning() {
        // Not midnight, so a session spanning midnight is not split in two.
        XCTAssertEqual(AppSettingsRules.defaultResetHour24, 3)
        XCTAssertEqual(AppSettingsRules.hour12(from: AppSettingsRules.defaultResetHour24), 3)
    }

    // MARK: - the battery warning

    func testTheBatteryWarningIsCappedAtTwentyPercent() {
        // The archive's cap and its reasoning: the cube runs on AA cells, so the warning has to leave time to choose
        // when to swap them, not time to find one. A threshold much above this keeps the warning lit for most of the
        // cells' life, which teaches somebody to ignore it.
        XCTAssertEqual(AppSettingsRules.batteryWarningPercent, 1 ... 20)
        XCTAssertEqual(AppSettingsRules.defaultBatteryWarningPercent, 10)
    }

    func testTheWarningCannotBeSetToNothing() {
        // A warning at 0% arrives once the device is already dead.
        XCTAssertEqual(AppSettingsRules.batteryWarningPercent.lowerBound, 1)
    }

    // MARK: - the history fetch

    func testTheIntervalIsBoundedByTheMinuteAndTheHour() {
        XCTAssertEqual(AppSettingsRules.fetchIntervalMinutes, 1 ... 60)
    }

    func testSecondsBecomeWholeMinutes() {
        XCTAssertEqual(AppSettingsRules.minutes(fromSeconds: 600), 10)
        XCTAssertEqual(AppSettingsRules.minutes(fromSeconds: 90), 1, "rounded down, not up")
    }

    func testTheSeededIntervalIsBelowTheFloorAndReadsAsTheFloor() {
        // 10 seconds, deliberately: sub-minute polling makes history arrive quickly while testing. The row cannot
        // hold it, and drawing "0 mins" would report a number the control could not even take.
        XCTAssertEqual(AppSettingsRules.defaultFetchIntervalSeconds, 10)
        XCTAssertEqual(AppSettingsRules.minutes(fromSeconds: AppSettingsRules.defaultFetchIntervalSeconds), 1)
    }

    // MARK: - the blip filter

    func testTheBlipFilterRunsFromOffToThirtySeconds() {
        // 0 turns it off, the way `auto_pause_minutes` does. The ceiling is low on purpose: measured blips are 0 to 3
        // seconds, so a mistyped 90 would silently throw away a minute and a half of tracked time.
        XCTAssertEqual(AppSettingsRules.blipSeconds, 0 ... 30)
        XCTAssertEqual(AppSettingsRules.defaultBlipSeconds, 5, "the vendor's own number")
    }

    // MARK: - saying it in words

    func testAUnitIsSingularForExactlyOne() {
        XCTAssertEqual(AppSettingsRules.unit("min", "mins", for: 1), "min")
        XCTAssertEqual(AppSettingsRules.unit("min", "mins", for: 2), "mins")
        XCTAssertEqual(AppSettingsRules.unit("sec", "secs", for: 0), "secs", "\"0 secs\", not \"0 sec\"")
    }

    // MARK: - back the other way

    func testAFaceHourBecomesTheHourTheTableStores() {
        XCTAssertEqual(AppSettingsRules.hour24(fromFace: 2), 2)
        XCTAssertEqual(AppSettingsRules.hour24(fromFace: 12), 0, "12 on an AM face is midnight")
    }

    func testTheHourSurvivesATripThroughBothConversions() {
        for hour in AppSettingsRules.resetHours {
            XCTAssertEqual(
                AppSettingsRules.hour12(from: AppSettingsRules.hour24(fromFace: hour)), hour,
                "the face reads back as itself, or a row would move every time it was touched"
            )
        }
    }

    func testAnAfternoonHourIsNormalisedToTheMorningWhenTheRowIsTouched() {
        // The face is AM only, so it cannot express 15:00. Storing what it *can* say is the archive's decision and
        // the honest one: the alternative is a row that reads 3 and stores 15.
        XCTAssertEqual(AppSettingsRules.hour24(fromFace: AppSettingsRules.hour12(from: 15)), 3)
    }

    func testMinutesBecomeSeconds() {
        XCTAssertEqual(AppSettingsRules.seconds(fromMinutes: 9), 540)
    }

    // MARK: - where a change lands

    func testEachRowWritesItsOwnColumn() {
        // One place decides this. The row knows what was typed and the table knows nothing about rows, so a mapping
        // each end half-knew is how a control comes to write the right number into the wrong column.
        let destinations = [
            AppSettingsPane.Change.showsSeconds(false),
            .pausesOnLock(false),
            .dailyResetHour12(2),
            .batteryWarningPercent(15),
            .fetchIntervalMinutes(9),
            .blipSeconds(3),
        ].map { AppSettingsRules.destination(for: $0) }

        XCTAssertEqual(destinations.map(\.setting), [
            "display_seconds",
            "pause_on_lock",
            "daily_reset_time",
            "low_battery_level",
            "fetch_history_interval_seconds",
            "blip_time",
        ])
        XCTAssertEqual(destinations.map(\.field), ["enabled", "enabled", "hour", "percent", "seconds", "seconds"])
    }

    func testAChangeIsConvertedToTheUnitItsColumnStores() {
        // The rows show a 12-hour face and whole minutes; the table stores 24-hour hours and seconds.
        XCTAssertEqual(AppSettingsRules.destination(for: .dailyResetHour12(12)).value, .number(0))
        XCTAssertEqual(AppSettingsRules.destination(for: .fetchIntervalMinutes(9)).value, .number(540))
        XCTAssertEqual(AppSettingsRules.destination(for: .blipSeconds(3)).value, .number(3), "already its own unit")
        XCTAssertEqual(AppSettingsRules.destination(for: .showsSeconds(true)).value, .flag(true))
    }

    func testARowIsNamedByItsLabelWhenSomethingHasToBeSaid() {
        // Nobody reading an alert knows what `low_battery_level` is.
        XCTAssertEqual(AppSettingsRules.title(for: .batteryWarningPercent(15)), "Battery warning at")
        XCTAssertEqual(AppSettingsRules.title(for: .showsSeconds(true)), "Show seconds")
    }
}
