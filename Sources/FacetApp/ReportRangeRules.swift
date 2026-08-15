import Foundation

/// What the Report tab's pair of calendars is allowed to say: which days can be picked in each of them, which days
/// read as the selected span, and what one calendar does to the other.
///
/// **The archive's rules, taken whole** (`Archive/TimeFlipApp/ReportView.swift`, `ReportDateRange.swift`), because
/// what they decide is a shape rather than an implementation: an end that starts unset, an end calendar that cannot
/// reach a day before the start, and therefore no inverted range and no error state to report for one. The reasons
/// are on each of them below.
///
/// Decisions only, no view and no database. The range itself is nothing the table holds -- it is a question being
/// asked, not a setting -- so the source-of-truth rule has nothing to say about where it lives.
enum ReportRangeRules {
    /// The upper bound for both calendars: the last instant of today, so today is selectable and every later date is
    /// drawn greyed out.
    ///
    /// **This is a time recorder, not a time planner**, so a future date is not a report anyone can ask for.
    /// Allowing one would only ever answer "nothing tracked", which is indistinguishable from a real day on which
    /// nothing was.
    ///
    /// The *end* of today rather than the start of it: a day cell carries whatever time of day the selection holds,
    /// so a bound at today's 00:00 would put today itself out of range for any selection carrying an afternoon time,
    /// greying out the one day most reports want.
    static func latestSelectableDay(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(24 * 60 * 60)
        return startOfTomorrow.addingTimeInterval(-1)
    }

    /// What the From calendar may offer: anything up to today. Unbounded below, history going back as far as it goes
    /// back.
    static func allowedStarts(latest: Date) -> ClosedRange<Date> {
        Date.distantPast ... latest
    }

    /// What the To calendar may offer: from the start day to today.
    ///
    /// **Bounded below at the start**, which is what makes an inverted range unreachable rather than rejected: every
    /// earlier day is drawn dimmed and refuses the click, so there is no way to be told off for a selection the
    /// screen allowed.
    ///
    /// Clamped at `latest` as well, and not for a case the screen can produce: a `ClosedRange` whose upper bound sits
    /// under its lower one traps at runtime, so a start that arrived from somewhere else -- a clock that moved
    /// backwards -- would crash the tab rather than draw oddly.
    static func allowedEnds(start: Date, latest: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        min(calendar.startOfDay(for: start), latest) ... latest
    }

    /// The span both calendars draw bold, which is **passed to each of them** rather than only to the one owning that
    /// end of it: the point is that the selection reads as one range across the pair instead of as two separately
    /// highlighted days.
    static func emphasised(start: Date, end: Date?) -> ClosedRange<Date> {
        let other = end ?? start
        return min(start, other) ... max(start, other)
    }

    /// The end after the start has moved to `start`.
    ///
    /// The To calendar's lower bound stops a *new* end landing before the start, but a start moving forward past an
    /// end already chosen would strand it behind, so it is carried along. An end that was never set stays unset:
    /// dropping back to a single day would be the screen changing the question.
    static func endCarriedForward(start: Date, end: Date?) -> Date? {
        guard let end else { return nil }
        return max(end, start)
    }

    /// The end after a day is picked in the To calendar. Never before the start, for the same reason its bound is.
    static func endChosen(_ picked: Date, start: Date) -> Date {
        max(picked, start)
    }

    /// The instants a picked range actually covers: from the daily reset on the first day to the daily reset on the
    /// day *after* the last one, so the whole of that final day is inside it.
    ///
    /// **Days here are the app's own days, not calendar midnights.** A day begins at `daily_reset_time` (seeded 03:00,
    /// `database/011_setting.sql`) and runs to the same time the next day, which is the window the menu bar's figure
    /// is measured over (`DayWindow`). So 5 August to 7 August is 5 August at 03:00 up to 8 August at 03:00, and a
    /// one-day report shows exactly what the menu bar showed on that day. Cutting at midnight here while everything
    /// else in the app cuts at the reset time would put the small hours of a working night on the wrong side of the
    /// boundary, and only on this one screen.
    ///
    /// Half-open, `start ..< end`: a stretch beginning exactly at the closing boundary belongs to the next day, not
    /// to both.
    static func bounds(
        start: Date,
        end: Date?,
        resetHour: Int,
        resetMinute: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let first = dayStart(of: start, resetHour: resetHour, resetMinute: resetMinute, calendar: calendar)
        let lastDay = dayStart(of: end ?? start, resetHour: resetHour, resetMinute: resetMinute, calendar: calendar)
        // An end before the start would invert the range and report nothing. The To calendar's own bound makes that
        // unreachable; this makes a single day the answer rather than an empty range if one ever gets past, since a
        // start on its own already means one day.
        let last = max(first, lastDay)
        let closing = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(24 * 60 * 60)
        return (first, closing)
    }

    /// The instant the app-day **named by** `date`'s calendar date begins.
    ///
    /// Named by, not containing, and the difference is the whole of why this is not `DayWindow.start`: a calendar cell
    /// carries midnight, which with a 03:00 reset sits inside the *previous* app-day. Asking which day contains it
    /// would report the day before the one that was clicked. Here the date picks the day and the reset time is
    /// stamped onto it.
    ///
    /// Through `Calendar` rather than arithmetic on seconds, so the two daylight-saving days -- 23 and 25 hours long
    /// -- still start and end at the right wall-clock time.
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

    /// What the To calendar says about itself while nothing has been picked in it.
    ///
    /// The archive's wording, and the archive's point: an unset end is not a missing value to be filled in, it is the
    /// common case said in one click. Pick a day on the left and get that day.
    static let unsetEndSubtitle = "not set, reporting one day"
}
