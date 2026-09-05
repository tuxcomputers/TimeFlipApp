import Foundation

/// The App tab's settings as values rather than views: what each row is bounded by, and the two conversions between
/// what the table stores and what the row shows.
///
/// **The bounds are the previous app's, and every one of them was a measurement or a decision with a reason**
/// (`TimeFlipConstants.swift`), so they are carried over with the reasons attached rather than
/// re-picked. Where a value has a seeded default, the default here is that seed -- `database/011_setting.sql` -- and
/// the two must not drift: the fallback exists because `SettingStore` answers `nil` for a missing or malformed row
/// and refuses to guess what absence means, which is right, and this is where the guess belongs.
///
/// **What is *not* here is what is not on that tab.** The battery warning's bounds moved to `BatteryRules` on
/// 2026-09-03 with the row itself, which is now the Device tab's, and they sit beside the other numbers the
/// threshold is judged by rather than beside settings it no longer shares a tab with.
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

    // MARK: - back the other way

    /// An hour picked on the AM-only face, as the 24-hour hour the table stores. 12 becomes 0, the rest stay as they
    /// are.
    ///
    /// **Always AM**, which is what the row offers, so a value stored as a PM hour is normalised to its AM equivalent
    /// the first time somebody touches the row. The archive did the same, deliberately: the face cannot express the
    /// old value, so leaving it alone would mean a row that reads 3 and stores 15.
    static func hour24(fromFace hour12: Int) -> Int {
        hour12 % 12
    }

    /// Whole minutes as the seconds the table stores.
    static func seconds(fromMinutes minutes: Int) -> Int {
        minutes * 60
    }

    /// Where a changed row lands: which `setting` row, which field of its JSON, and the value in the unit that row
    /// stores.
    ///
    /// **One place decides this.** The row knows what somebody typed and the table knows nothing about rows, so the
    /// mapping between them is a rule rather than something each end half-knows -- which is how a control comes to
    /// write the right number into the wrong column.
    /// `nil` for a change that is not one field being set to one value. Signing out empties two fields at once, so
    /// it has no single destination and is written by its own path rather than squeezed through this one.
    static func destination(for change: AppSettingsPane.Change) -> (setting: String, field: String, value: Stored)? {
        switch change {
        case let .showsSeconds(on):
            return ("display_seconds", "enabled", .flag(on))
        case let .dailyResetHour12(hour):
            return ("daily_reset_time", "hour", .number(hour24(fromFace: hour)))
        case let .fetchIntervalMinutes(minutes):
            return ("fetch_history_interval_seconds", "seconds", .number(seconds(fromMinutes: minutes)))
        case let .blipSeconds(seconds):
            return ("blip_time", "seconds", .number(seconds))
        case let .debugEnabled(on):
            return (DebugTraceRules.setting, DebugTraceRules.enabledField, .flag(on))
        case let .debugDirectory(path):
            return (DebugTraceRules.setting, DebugTraceRules.directoryField, .text(path))
        case .googleDisconnected, .googleSignInRequested, .googleConnected,
             .googleCalendarNamed, .googleCalendarCreateRequested, .googleCalendarChanged,
             .googleCalendarDeleteRequested,
             // Neither of these is a row being set: one is what the Keychain says and the other is what Google
             // says, and no `setting` field holds either.
             .googleCredentialChanged, .googleVerified,
             // A panel to run, not a value to store. What comes back out of it is `debugDirectory`.
             .debugDirectoryRequested,
             // These act on the file rather than on a row: a Finder window, a copy, and emptying it.
             .debugRevealRequested, .debugCopyRequested, .debugClearRequested:
            return nil
        }
    }

    /// What goes into the column: the three shapes a setting's field takes.
    enum Stored: Equatable {
        case flag(Bool)
        case number(Int)
        case text(String)
    }

    /// What a row is called when something has to be said about it out loud, which is the label beside it rather than
    /// the column it writes: nobody reading an alert knows what `low_battery_level` is.
    static func title(for change: AppSettingsPane.Change) -> String {
        switch change {
        case .showsSeconds: return "Show seconds"
        case .dailyResetHour12: return "Daily reset at"
        case .fetchIntervalMinutes: return "Fetch history every"
        case .blipSeconds: return "Ignore flips under"
        case .googleDisconnected, .googleSignInRequested, .googleConnected,
             .googleCredentialChanged, .googleVerified: return "Google account"
        case .googleCalendarNamed, .googleCalendarCreateRequested, .googleCalendarChanged,
             .googleCalendarDeleteRequested: return "Calendar"
        case .debugEnabled: return "Debug logging"
        case .debugDirectory, .debugDirectoryRequested: return "Directory"
        case .debugRevealRequested, .debugCopyRequested, .debugClearRequested: return "Trace file"
        }
    }
}
