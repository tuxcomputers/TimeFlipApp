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

    /// What the To calendar says about itself while nothing has been picked in it.
    ///
    /// The archive's wording, and the archive's point: an unset end is not a missing value to be filled in, it is the
    /// common case said in one click. Pick a day on the left and get that day.
    static let unsetEndSubtitle = "not set, reporting one day"
}
