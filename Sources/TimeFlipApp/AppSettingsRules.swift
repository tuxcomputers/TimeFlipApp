import Foundation

/// The App tab's settings as values rather than views: what each row is bounded by, and the two conversions between
/// what the table stores and what the row shows.
///
/// **The bounds are the previous app's, and every one of them was a measurement or a decision with a reason**
/// (`Archive/TimeFlipApp/TimeFlipConstants.swift`), so they are carried over with the reasons attached rather than
/// re-picked. Where a value has a seeded default, the default here is that seed -- `database/011_setting.sql` -- and
/// the two must not drift: the fallback exists because `SettingReader` answers `nil` for a missing or malformed row
/// and refuses to guess what absence means, which is right, and this is where the guess belongs.
enum AppSettingsRules {
    // MARK: - the daily reset

    /// The hour the day's accounting rolls over, on a 12-hour face.
    ///
    /// **AM only, which is why the suffix is a fixed word rather than a second thing to set.** A reset in the middle
    /// of the afternoon would cut a working day's accounting in half, so every useful value sits in the small hours
    /// and PM was only ever a way to pick a wrong one. The archive found that out and reduced the row to one field,
    /// one suffix, one pair of arrows -- which also retired the twelve arrow clicks it used to take to cross from AM
    /// to PM.
    static let resetHours = 1 ... 12
    static let resetSuffix = "AM"
    /// The seeded `daily_reset_time`: 3 AM rather than midnight, so a session spanning midnight is not split.
    static let defaultResetHour24 = 3

    /// A 24-hour hour as it reads on a 12-hour face: 0 becomes 12, 13 becomes 1.
    ///
    /// A stored PM hour still has to draw as *something* on an AM-only face, and it draws as its clock-face hour --
    /// the same 3 for 15:00 -- rather than being silently corrected here. Correcting the stored value is a write, and
    /// this is a reading.
    static func hour12(from hour24: Int) -> Int {
        let onTheFace = ((hour24 % 12) + 12) % 12
        return onTheFace == 0 ? 12 : onTheFace
    }

    // MARK: - the battery warning

    /// The battery level at or below which the app says the cells are going.
    ///
    /// **Capped at 20%**, which is the archive's decision and its reasoning: the device runs on AA cells, so the
    /// warning does not have to leave time to source an unusual battery -- it has to leave time to choose *when* to
    /// swap them, because taking them out resets every device setting to its default. A threshold much above this
    /// would keep the warning lit for most of the cells' usable life, which only teaches somebody to ignore it.
    ///
    /// The floor is 1 rather than 0: a warning at 0% is a warning that arrives once the device is already dead.
    static let batteryWarningPercent = 1 ... 20
    static let batterySuffix = "%"
    /// The seeded `low_battery_level`.
    static let defaultBatteryWarningPercent = 10

    // MARK: - the history fetch

    /// How often the app asks the cube for history it has not seen, **in minutes**, which is the only place this
    /// value is expressed that way: the setting stores seconds and the rest of the app works in seconds.
    ///
    /// An hour is the far end of useful, the periodic fetch being a safety net behind the live face and pause events
    /// rather than the main path.
    static let fetchIntervalMinutes = 1 ... 60
    /// The seeded `fetch_history_interval_seconds`, which is **below the floor on purpose**: sub-minute polling makes
    /// history arrive quickly while testing, so the seed is a developer's value and this row floors it.
    static let defaultFetchIntervalSeconds = 10

    // MARK: - the blip filter

    /// How short a stretch has to be before it counts as the cube being turned *past* a face rather than time spent
    /// on it. `0` turns the filter off, so everything the device reports is counted.
    ///
    /// **The ceiling is deliberately low.** Measured blips are 0 to 3 seconds, so anything much beyond the default is
    /// discarding real work, and a mistyped 90 silently throwing away a minute and a half of tracked time would be a
    /// bad thing to have to notice later.
    static let blipSeconds = 0 ... 30
    /// The seeded `blip_time`, which is the vendor's own number: the `0x02` history stream carries "all intervals
    /// that lasted for at least 5 sec", so matching it discards exactly what a bulk read would never have shown.
    static let defaultBlipSeconds = 5

    // MARK: - saying it in words

    /// Seconds as whole minutes, rounded down, and never below the row's own floor: the seeded interval is smaller
    /// than a minute, and a row showing `0 mins` would be reporting a number the control cannot even hold.
    static func minutes(fromSeconds seconds: Int) -> Int {
        max(fetchIntervalMinutes.lowerBound, seconds / 60)
    }

    /// The unit beside a number, singular for exactly one. "1 min" and "2 mins", which is the archive's own wording
    /// and worth the branch: "1 mins" is the kind of thing that makes an app look unfinished.
    static func unit(_ singular: String, _ plural: String, for value: Int) -> String {
        value == 1 ? singular : plural
    }
}
