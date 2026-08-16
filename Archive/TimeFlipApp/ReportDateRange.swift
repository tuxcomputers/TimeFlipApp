import Foundation

/// The instant range a Report tab date selection covers.
///
/// Days here are the app's own days, not calendar midnights: a day begins at the configured
/// `daily_reset_time` (seeded 03:00, see `database/011_setting.sql`) and runs to the same time the
/// next day, which is the window `DailyCategoryTotals` measures the menu bar's figure over. A
/// one-day report therefore shows exactly what the menu bar showed on that day. Cutting at midnight
/// here while everything else in the app cuts at the reset time would put the small hours of a
/// working night on the wrong side of the boundary, and only in this one screen.
enum ReportDateRange {
    /// The half-open range `start ..< end` covering every app-day from `start`'s date to `end`'s,
    /// both included.
    ///
    /// - Parameters:
    ///   - start: the day picked on the left. Only its calendar date is read, so the time of day it
    ///     happens to carry (whatever `Date()` seeded it with) doesn't shift the boundary.
    ///   - end: the day picked on the right, or `nil` when the right picker hasn't been touched --
    ///     a start with no end reports that single day.
    ///   - resetHour: local hour the day rolls over at (`AppState.dailyResetHour`).
    ///   - resetMinute: local minute the day rolls over at (`AppState.dailyResetMinute`).
    ///
    /// The returned end is the reset boundary *after* the last day, so the whole of that final day
    /// sits inside the range rather than the range stopping as it begins.
    static func bounds(
        start: Date,
        end: Date?,
        resetHour: Int,
        resetMinute: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let first = dayStart(of: start, resetHour: resetHour, resetMinute: resetMinute, calendar: calendar)
        let lastDay = dayStart(of: end ?? start, resetHour: resetHour, resetMinute: resetMinute, calendar: calendar)
        // An end before the start would invert the range and report nothing. The right picker's own
        // lower bound stops that being reachable; this makes the single day the answer rather than
        // the empty range if it ever gets past, since a start date on its own already means one day.
        let last = max(first, lastDay)
        let endInstant = calendar.date(byAdding: .day, value: 1, to: last)
            ?? last.addingTimeInterval(TimeConstants.secondsPerHour * 24)
        return (first, endInstant)
    }

    /// The upper bound for both pickers: the last instant of today, so today is selectable and every
    /// later date is drawn greyed out.
    ///
    /// This is a time recorder, not a time planner: a future date is not a report anyone can ask
    /// for. Allowing one would only ever answer "nothing tracked", which is indistinguishable from a
    /// real day on which nothing was.
    ///
    /// The end of today rather than the start of it: a day cell carries whatever time of day the
    /// picker's binding holds, so a bound at today's 00:00 would put today itself out of range for
    /// any binding carrying an afternoon time, greying out the one day most reports want.
    static func latestSelectableDay(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(TimeConstants.secondsPerHour * 24)
        return startOfTomorrow.addingTimeInterval(-1)
    }

    /// The instant the app-day containing `date`'s calendar date begins.
    static func dayStart(
        of date: Date,
        resetHour: Int,
        resetMinute: Int,
        calendar: Calendar = .current
    ) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = resetHour
        components.minute = resetMinute
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components) ?? date
    }
}
