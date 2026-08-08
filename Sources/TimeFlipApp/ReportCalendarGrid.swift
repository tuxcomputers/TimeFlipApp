import Foundation

/// The month-grid arithmetic behind `ReportCalendarView`, kept apart from the drawing so the parts
/// that are easy to get wrong -- where a month's first day sits in the week, which months can still
/// be reached -- are plain functions with tests rather than something only observable by looking at
/// a rendered calendar.
///
/// Everything here takes its `Calendar`, so the locale's first weekday is honoured rather than a
/// Monday or Sunday being assumed, and tests can pin a calendar instead of inheriting the machine's.
enum ReportCalendarGrid {
    /// Six weeks, always. A month needs five or six depending on where it starts, and a grid that
    /// changed height between months would move the list of totals underneath it as you page.
    static let weeksShown = 6
    static let daysPerWeek = 7

    /// The first instant of the month containing `date`.
    static func startOfMonth(containing date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    /// Every cell of the grid for the month containing `date`, in order, reading left to right and
    /// top to bottom.
    ///
    /// The days that pad the first and last weeks are the **real** adjacent-month dates rather than
    /// blanks, so every cell has a date to name -- which is what lets the range emphasis run
    /// continuously across a month boundary instead of stopping at the edge of the grid, and gives
    /// VoiceOver something to read for a padding cell.
    static func days(forMonthContaining date: Date, calendar: Calendar) -> [Date] {
        let firstOfMonth = startOfMonth(containing: date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        // How far the 1st sits from the start of its week, given where this locale's week begins.
        let offset = (weekday - calendar.firstWeekday + daysPerWeek) % daysPerWeek
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth
        return (0..<(weeksShown * daysPerWeek)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    /// The column headings, ordered from the locale's first weekday.
    ///
    /// The short symbols cut to two characters, which is what the system calendar shows and what
    /// keeps the row even. The obvious alternatives are both worse: `veryShortWeekdaySymbols` gives
    /// the ambiguous S/M/T/W/T/F/S in English, and the `EEEEEE` "short narrow" format is ragged in
    /// en_GB, which returns a mix of two- and three-letter forms (measured: `Mon Tu Wed Th Fri Sat
    /// Su`). Cutting is safe for locales whose symbols are already shorter -- Japanese weekdays are
    /// a single character and pass through untouched.
    static func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        var source = calendar
        source.locale = locale
        let symbols = source.shortWeekdaySymbols
        guard symbols.count == daysPerWeek else { return symbols }
        // shortWeekdaySymbols is Sunday-first regardless of the locale's own first weekday, so
        // rotate it to match the columns the grid actually draws.
        let offset = calendar.firstWeekday - 1
        return (0..<daysPerWeek).map { String(symbols[($0 + offset) % daysPerWeek].prefix(2)) }
    }

    /// Whether two instants fall in the same month of the same year.
    static func isSameMonth(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    /// Whether two instants fall on the same day. What the emphasis and selection tests compare on,
    /// since both sides carry a time of day that has nothing to do with the question.
    static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    /// Whether `day` sits in the grid's first column -- the locale's first weekday.
    ///
    /// The selected range is filled as a continuous bar, so it has to be rounded off where a run
    /// ends and left square where it carries on into the next cell. A row's edges are two of those
    /// places: a range crossing a week boundary stops at the edge of the grid and resumes on the
    /// line below, and squaring it there would leave the fill running into nothing.
    static func isFirstColumn(_ day: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: day) == calendar.firstWeekday
    }

    /// Whether `day` sits in the grid's last column. The other end of `isFirstColumn`.
    static func isLastColumn(_ day: Date, calendar: Calendar) -> Bool {
        let lastWeekday = ((calendar.firstWeekday - 1 + daysPerWeek - 1) % daysPerWeek) + 1
        return calendar.component(.weekday, from: day) == lastWeekday
    }

    /// The month `months` away from the one shown, or `nil` when that month holds no selectable day.
    ///
    /// This is what stops the calendar paging into a month where everything is greyed out: a month
    /// is reachable only if some part of it lies inside `allowed`. Comparing whole months rather
    /// than instants is deliberate -- the month containing the last selectable day is reachable even
    /// though most of it sits beyond that day.
    static func month(
        movedFrom displayed: Date,
        by months: Int,
        within allowed: ClosedRange<Date>,
        calendar: Calendar
    ) -> Date? {
        guard let moved = calendar.date(byAdding: .month, value: months, to: startOfMonth(containing: displayed, calendar: calendar)) else {
            return nil
        }
        let earliest = startOfMonth(containing: allowed.lowerBound, calendar: calendar)
        let latest = startOfMonth(containing: allowed.upperBound, calendar: calendar)
        guard moved >= earliest, moved <= latest else { return nil }
        return moved
    }

    /// The month to show for a given selection, pulled inside `allowed` if the selection sits outside
    /// it. Used when the calendar first appears and whenever the bounds move under it -- the To
    /// calendar's lower bound follows the start date, and it must not be left displaying a month it
    /// can no longer reach.
    static func displayableMonth(
        for selection: Date,
        within allowed: ClosedRange<Date>,
        calendar: Calendar
    ) -> Date {
        let wanted = startOfMonth(containing: selection, calendar: calendar)
        let earliest = startOfMonth(containing: allowed.lowerBound, calendar: calendar)
        let latest = startOfMonth(containing: allowed.upperBound, calendar: calendar)
        return min(max(wanted, earliest), latest)
    }
}
