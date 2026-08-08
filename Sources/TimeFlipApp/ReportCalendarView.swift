import SwiftUI

/// A month calendar for the Report tab, drawn here rather than taken from the system.
///
/// **Why not `DatePicker(.graphical)`.** Two things this screen needs are not expressible on the
/// native control, and both were established by measurement rather than assumed:
/// - The days between the start and the end are drawn **bold**, so the selected span reads as a span
///   in both calendars instead of two unrelated highlighted days. Neither SwiftUI's `DatePicker` nor
///   AppKit's `NSDatePicker` offers any hook for styling an individual day cell.
/// - The month arrows stop at the last month holding a selectable day. A date range bound governs
///   which days can be *selected*, not which month is *displayed*: measured 2026-08-08 by setting
///   `minDate`/`maxDate` on a bare `NSDatePicker`, whose forward arrow paged into a fully greyed-out
///   month exactly as the SwiftUI one did.
///
/// The arithmetic lives in `ReportCalendarGrid`, under test; this is the drawing.
struct ReportCalendarView: View {
    let title: String
    /// Shown beside the title in a lighter style, for saying something about the selection itself
    /// (the Report tab uses it for "not set, reporting one day").
    let subtitle: String?
    @Binding var selection: Date
    /// Days outside this are drawn dimmed and cannot be clicked, and months holding none of it
    /// cannot be reached.
    let allowed: ClosedRange<Date>
    /// Days in this span are drawn bold: the whole selected range, passed to **both** calendars so
    /// each shows the same span rather than only its own end of it.
    let emphasised: ClosedRange<Date>
    /// Every size inside the calendar, derived from the width the tab has to spend.
    let metrics: ReportCalendarMetrics

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @State private var displayedMonth: Date?

    /// The month on show. Derived rather than stored so it can never be left pointing at a month the
    /// bounds have since moved out of reach -- the To calendar's lower bound follows the start date,
    /// which changes under it.
    private var month: Date {
        ReportCalendarGrid.displayableMonth(
            for: displayedMonth ?? selection,
            within: allowed,
            calendar: calendar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutConstants.Report.titleSpacing) {
            HStack(spacing: SettingsLayoutConstants.Report.titleSpacing) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: SettingsLayoutConstants.Report.calendarRowSpacing) {
                header
                weekdayHeadings
                grid
            }
            // Pinned to exactly the grid's width. Without this the header's Spacer makes the whole
            // calendar greedy, and the row holding the two of them stretches both to share the
            // window rather than sizing each to its own content.
            .frame(width: metrics.gridWidth)
            .padding(SettingsLayoutConstants.Report.calendarPadding)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.FaceList.cornerRadius)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.FaceList.cornerRadius)
                    .stroke(Color(NSColor.separatorColor))
            )
        }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 0) {
            // A long month name in a wordier locale shrinks rather than pushing the arrows out of
            // the fixed-width calendar.
            Text(monthTitle)
                .font(.system(size: metrics.monthTitleFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(SettingsLayoutConstants.Report.monthTitleMinimumScale)
            Spacer(minLength: SettingsLayoutConstants.Report.titleSpacing)
            monthButton(months: -1, systemName: "chevron.left", label: "Previous month")
            monthButton(months: 1, systemName: "chevron.right", label: "Next month")
        }
    }

    /// One month arrow. Absent a reachable month in that direction the button is disabled rather
    /// than hidden, so the header doesn't reflow as you reach either end of the range.
    @ViewBuilder private func monthButton(months: Int, systemName: String, label: String) -> some View {
        let target = ReportCalendarGrid.month(movedFrom: month, by: months, within: allowed, calendar: calendar)
        Button {
            guard let target else { return }
            DeveloperMode.debugPrint(.report, "\(title) calendar moved to \(Self.debugMonth(target, calendar: calendar))")
            displayedMonth = target
        } label: {
            Image(systemName: systemName)
                .font(.system(size: metrics.arrowFontSize, weight: .semibold))
                .frame(
                    width: metrics.arrowSize,
                    height: metrics.arrowSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .foregroundStyle(target == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .accessibilityLabel(label)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month)
    }

    // MARK: - Grid

    @ViewBuilder private var weekdayHeadings: some View {
        HStack(spacing: 0) {
            ForEach(Array(ReportCalendarGrid.weekdaySymbols(calendar: calendar, locale: locale).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: metrics.weekdayFontSize))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.cellSize)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var grid: some View {
        let days = ReportCalendarGrid.days(forMonthContaining: month, calendar: calendar)
        VStack(spacing: 0) {
            ForEach(0..<ReportCalendarGrid.weeksShown, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<ReportCalendarGrid.daysPerWeek, id: \.self) { weekday in
                        let day = days[week * ReportCalendarGrid.daysPerWeek + weekday]
                        dayCell(day)
                    }
                }
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: Date) -> some View {
        let selectable = allowed.contains(day) || isSelectableEdgeDay(day)
        let isSelected = ReportCalendarGrid.isSameDay(day, selection, calendar: calendar)
        let inMonth = ReportCalendarGrid.isSameMonth(day, month, calendar: calendar)
        Button {
            DeveloperMode.debugPrint(.report, "\(title) calendar picked \(Self.debugDay(day, calendar: calendar))")
            selection = day
        } label: {
            Text(dayNumber(day))
                .font(.system(size: metrics.dayFontSize))
                // The whole selected span reads bold, in both calendars.
                .fontWeight(isEmphasised(day) ? .bold : .regular)
                .foregroundStyle(foreground(selectable: selectable, inMonth: inMonth, isSelected: isSelected))
                .frame(
                    width: metrics.cellSize,
                    height: metrics.cellSize
                )
                .background {
                    ZStack {
                        // The span first, the picked day on top of it: a tint for "inside the
                        // range", solid for "the date this calendar sets", so the two ends stay
                        // distinguishable from the days between them.
                        if isEmphasised(day) {
                            rangeFill(day)
                        }
                        if isSelected {
                            RoundedRectangle(cornerRadius: metrics.dayCornerRadius)
                                .fill(Color.accentColor)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        // Every row of the grid would otherwise take a focus ring as the tab gains focus, reading as
        // a selection rather than as keyboard focus -- the same treatment the Faces tab's list gets.
        .focusEffectDisabled()
        // NOTE: this label does not currently reach the accessibility layer, and neither does the
        // month arrows' one. Measured 2026-08-08 against the running app: every cell arrives with
        // no AXTitle, AXDescription or AXValue at all, so a date announces as a bare "button" --
        // worse than the system picker this replaced, which named its dates. The common factor is
        // `.buttonStyle(.plain)`; `.accessibilityElement(children: .ignore)` was tried and is worse
        // still, replacing the button role with AXUnknown while the name stays absent. Left in
        // place because it is correct as written and costs nothing, but it is not working. See the
        // Report section of docs/TODO-features-under-development.md.
        .accessibilityLabel(Self.accessibleDay(day, calendar: calendar, locale: locale))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The selected span's background: one continuous fill, rounded **only** at the range's own two
    /// ends and square everywhere else.
    ///
    /// It deliberately does not round where a row ends. Doing that put a corner on the right of one
    /// week and on the left of the next, and since the weeks stack directly on top of each other
    /// those corners met as a notch running down both edges of a multi-week range -- the fill read
    /// as a stack of separate pills rather than one span. Squaring every internal edge is what lets
    /// the rows meet flush.
    ///
    /// `leading`/`trailing` rather than left/right, so a right-to-left layout -- where the grid
    /// itself flips -- rounds the visually-correct ends.
    ///
    /// Tinted from the accent colour rather than a literal blue: macOS lets the accent colour be
    /// changed system-wide, and an opacity composites over whatever is behind it, so this follows
    /// that choice and adapts to light and dark without a second palette.
    @ViewBuilder private func rangeFill(_ day: Date) -> some View {
        let radius = metrics.dayCornerRadius
        let isRangeStart = ReportCalendarGrid.isSameDay(day, emphasised.lowerBound, calendar: calendar)
        let isRangeEnd = ReportCalendarGrid.isSameDay(day, emphasised.upperBound, calendar: calendar)
        UnevenRoundedRectangle(
            topLeadingRadius: isRangeStart ? radius : 0,
            bottomLeadingRadius: isRangeStart ? radius : 0,
            bottomTrailingRadius: isRangeEnd ? radius : 0,
            topTrailingRadius: isRangeEnd ? radius : 0
        )
        .fill(Color.accentColor.opacity(SettingsLayoutConstants.Report.rangeTintOpacity))
    }

    /// A day sitting exactly on a bound counts as selectable even when the bound's time of day puts
    /// the cell's own instant outside the range: the bounds are day-granular questions ("not before
    /// the start", "not after today") carried on instants that hold a time.
    private func isSelectableEdgeDay(_ day: Date) -> Bool {
        ReportCalendarGrid.isSameDay(day, allowed.lowerBound, calendar: calendar)
            || ReportCalendarGrid.isSameDay(day, allowed.upperBound, calendar: calendar)
    }

    private func isEmphasised(_ day: Date) -> Bool {
        if ReportCalendarGrid.isSameDay(day, emphasised.lowerBound, calendar: calendar) { return true }
        if ReportCalendarGrid.isSameDay(day, emphasised.upperBound, calendar: calendar) { return true }
        return emphasised.contains(day)
    }

    private func foreground(selectable: Bool, inMonth: Bool, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white) }
        if !selectable { return AnyShapeStyle(.tertiary) }
        // A selectable day from the month either side is real, just not the month being read.
        return inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private func dayNumber(_ day: Date) -> String {
        String(calendar.component(.day, from: day))
    }

    private static func accessibleDay(_ day: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    private static func debugMonth(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func debugDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
