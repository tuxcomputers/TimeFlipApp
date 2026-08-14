import Foundation

/// How one recorded stretch is written out on the Report tab: the day it was on, the clock times it ran between, and
/// how long that was.
///
/// **`display_seconds` decides all three of them**, not just the duration. The setting is one question -- is a time
/// shown to the second, or to the minute -- and answering it differently in the same row is what would look like a
/// bug: a 19-second entry at minute precision reads "13:08 to 13:08", which is only honest if the duration beside it
/// reads `0:00` too. That is also why the setting is no longer called "Show seconds in the menu bar".
///
/// **The formats are fixed rather than localised**, which is a deliberate exception to how a date is usually drawn:
/// `dd/MM` and a 24-hour clock were asked for, and a machine set to en_US would otherwise render the day as `08/13`
/// and the time as `1:08 PM`. Fixed also keeps the columns the same width down the list, which is what lets the
/// figures be compared by eye.
enum ReportEntryText {
    /// The day, as `dd/MM`. No year: a report covers a range somebody has just picked on two calendars, so the year is
    /// on screen twice already.
    static func date(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(pattern: "dd/MM", calendar: calendar).string(from: date)
    }

    /// A clock time, to the minute or to the second.
    static func clock(_ date: Date, showingSeconds: Bool, calendar: Calendar = .current) -> String {
        formatter(pattern: showingSeconds ? "HH:mm:ss" : "HH:mm", calendar: calendar).string(from: date)
    }

    /// How long a stretch lasted, in the app's one duration format (`DurationFormat`), so a span cannot read one way
    /// here and another way in the menu bar.
    ///
    /// Rounded rather than truncated, as the totals are: this is a finished stretch, not a figure still counting up.
    static func duration(_ seconds: TimeInterval, showingSeconds: Bool) -> String {
        DurationFormat.hoursMinutesSeconds(seconds, rounding: .round, showingSeconds: showingSeconds)
    }

    /// What a screen reader is given for a row, which is the whole of it in words: a column of digits conveys nothing
    /// read out on its own.
    static func spoken(_ entry: TimeEntryRecord, showingSeconds: Bool, calendar: Calendar = .current) -> String {
        let day = formatter(pattern: "d MMMM", calendar: calendar).string(from: entry.start)
        let from = clock(entry.start, showingSeconds: showingSeconds, calendar: calendar)
        let to = clock(entry.end, showingSeconds: showingSeconds, calendar: calendar)
        return "\(day), \(from) to \(to), \(duration(entry.seconds, showingSeconds: showingSeconds))"
    }

    /// A formatter per call rather than a shared one: these run when a category is opened, which is a click, and a
    /// cached formatter would have to be invalidated when the calendar or the time zone under it changed.
    private static func formatter(pattern: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Fixed rather than the machine's, which is what `dateFormat` needs to mean what it says: a locale's own
        // preferences are allowed to reinterpret a pattern otherwise.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
}
