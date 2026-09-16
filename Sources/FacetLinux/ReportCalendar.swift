import CGtk
import FacetCore
import Foundation

/// One month of days, drawn as a grid, with arrows to page between months.
///
/// **Hand-drawn rather than `GtkCalendar`, which is the same decision the Mac made against `NSDatePicker`** and for
/// the same reason: what this has to do is refuse days. Every day after today, and -- in the To calendar -- every
/// day before the picked start, is drawn dimmed and declines the click, so an inverted range is unreachable rather
/// than rejected after the fact. A stock calendar can mark a day but cannot say no to one.
///
/// **What it may offer is `ReportRangeRules`' and what it lays out is `ReportCalendarGrid`'s.** Six weeks of seven,
/// always, so the grid does not change height as months change; which of those days belong to the month, and which
/// month an arrow may reach, are the core's answers. This draws them.
///
/// **Every size comes from `ReportCalendarMetrics`**, derived from the width the tab has to spend. The window is one
/// width, so that is one number here -- but it is still derived rather than written down, because the ratios inside
/// it are the archive's and the two platforms have to keep the same proportions.
@MainActor
final class ReportCalendar {
    let widget: UnsafeMutablePointer<GtkWidget>

    /// Called with the day picked.
    var onPick: ((Date) -> Void)?

    /// Called when the month on show changes, so it can be logged.
    var onShowMonth: ((Date) -> Void)?

    private let identifier: String
    private let metrics: ReportCalendarMetrics
    private let calendar = Calendar.current
    private let locale = Locale.current

    /// The month on show. **Not the selection**: paging looks at another month without choosing anything in it.
    private var month: Date

    /// The day this calendar has chosen, or `nil` for the To calendar before anybody has picked an end.
    private var selection: Date?

    /// Which days may be picked at all, from `ReportRangeRules`. The To calendar's lower bound follows the start
    /// date, so this moves under it and the month on show is pulled back inside when it does.
    private var allowed: ClosedRange<Date>

    /// Which days are drawn as part of the picked range, so a range reads as a block rather than as two ends.
    private var emphasised: ClosedRange<Date>

    private let header: UnsafeMutablePointer<GtkWidget>
    private let grid: UnsafeMutablePointer<GtkWidget>
    private var signals = GtkSignals()
    private var monthLabel: UnsafeMutablePointer<GtkWidget>?

    init(
        identifier: String,
        selection: Date?,
        allowed: ClosedRange<Date>,
        emphasised: ClosedRange<Date>,
        metrics: ReportCalendarMetrics
    ) {
        self.identifier = identifier
        self.selection = selection
        self.allowed = allowed
        self.emphasised = emphasised
        self.metrics = metrics
        month = ReportCalendarGrid.displayableMonth(
            for: selection ?? allowed.upperBound,
            within: allowed,
            calendar: calendar
        )

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.rowSpacing))
        SettingsWidgets.identify(widget, identifier)
        _ = SettingsWidgets.styled(widget, SettingsWidgets.panelClass)
        header = SettingsWidgets.row(spacing: 0)
        grid = SettingsWidgets.column(spacing: 0)
        facet_box_pack_start(widget, header, 0, 1, 0)
        facet_box_pack_start(widget, grid, 0, 1, 0)
        redraw()
    }

    /// Moves the bounds under the calendar, which is what the To calendar gets when the From day changes.
    ///
    /// **The month on show is pulled back inside**, or it would be left displaying a month it can no longer reach:
    /// `ReportCalendarGrid.displayableMonth` is that, and it is the core's answer rather than a clamp written here.
    func update(selection: Date?, allowed: ClosedRange<Date>, emphasised: ClosedRange<Date>) {
        self.selection = selection
        self.allowed = allowed
        self.emphasised = emphasised
        month = ReportCalendarGrid.displayableMonth(
            for: selection ?? month,
            within: allowed,
            calendar: calendar
        )
        redraw()
    }

    private func redraw() {
        for child in SettingsWidgets.children(of: header) + SettingsWidgets.children(of: grid) {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
        drawHeader()
        drawWeekdays()
        drawDays()
        gtk_widget_show_all(widget)
    }

    /// The month, with an arrow either side.
    ///
    /// **The arrows are disabled rather than hidden at either end of the range**, which is the Mac's decision: a
    /// header that reflows as it is reached is a control moving under the hand about to press it.
    private func drawHeader() {
        facet_box_pack_start(header, arrow("\u{25C0}", months: -1, named: "previous"), 0, 0, 0)
        let label = SettingsWidgets.plainLabel(monthTitle)
        facet_label_set_markup(label, "<b>\(monthTitle)</b>")
        facet_label_set_xalign(label, 0.5)
        SettingsWidgets.identify(label, "\(identifier)-month", saying: monthTitle)
        monthLabel = label
        facet_box_pack_start(header, label, 1, 1, 0)
        facet_box_pack_start(header, arrow("\u{25B6}", months: 1, named: "next"), 0, 0, 0)
    }

    private func arrow(_ glyph: String, months: Int, named name: String) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new_with_label(glyph)!
        facet_button_flatten(button)
        _ = SettingsWidgets.styled(button, SettingsWidgets.flatClass)
        SettingsWidgets.identify(button, "\(identifier)-\(name)-month")
        let reachable = ReportCalendarGrid.month(movedFrom: month, by: months, within: allowed, calendar: calendar)
        gtk_widget_set_sensitive(button, reachable == nil ? 0 : 1)
        signals.connect(button, "clicked") { [weak self] in
            guard let self, let moved = reachable else { return }
            month = moved
            onShowMonth?(moved)
            redraw()
        }
        return button
    }

    /// The initials, in the locale's own week order -- which is `ReportCalendarGrid`'s answer, since a week does not
    /// start on the same day everywhere.
    private func drawWeekdays() {
        let row = SettingsWidgets.row(spacing: 0)
        for symbol in ReportCalendarGrid.weekdaySymbols(calendar: calendar, locale: locale) {
            let label = SettingsWidgets.caption(symbol)
            facet_label_set_xalign(label, 0.5)
            gtk_widget_set_size_request(label, Int32(metrics.cellSize), -1)
            facet_box_pack_start(row, label, 0, 0, 0)
        }
        facet_box_pack_start(grid, row, 0, 0, 0)
    }

    /// Six weeks of seven, always: the grid does not change height as months change, so nothing under it moves when
    /// a month with an extra week is paged to.
    private func drawDays() {
        let days = ReportCalendarGrid.days(forMonthContaining: month, calendar: calendar)
        for week in stride(from: 0, to: days.count, by: ReportCalendarGrid.daysPerWeek) {
            let row = SettingsWidgets.row(spacing: 0)
            for day in days[week ..< min(week + ReportCalendarGrid.daysPerWeek, days.count)] {
                facet_box_pack_start(row, cell(day), 0, 0, 0)
            }
            facet_box_pack_start(grid, row, 0, 0, 0)
        }
    }

    /// One day.
    ///
    /// **Three states, and only one of them is a refusal.** A day outside this month is drawn faint but is still
    /// pickable, as the Mac's is -- the grid spills into the neighbouring months and clicking one of those days is a
    /// reasonable thing to do. A day outside `allowed` is what declines the click.
    private func cell(_ day: Date) -> UnsafeMutablePointer<GtkWidget> {
        let number = calendar.component(.day, from: day)
        let button = gtk_button_new_with_label("\(number)")!
        facet_button_flatten(button)
        // **Zero padding, or the cell is GTK's idea of a button rather than the size the metrics worked out.**
        // Measured 2026-09-16: with the theme's own padding each day demanded 46pt against the 39 asked for, and
        // the Report tab then needed a 728pt window -- which the window's own diagnostic is what said out loud.
        _ = SettingsWidgets.styled(button, SettingsWidgets.flatClass)
        gtk_widget_set_size_request(button, Int32(metrics.cellSize), Int32(metrics.cellSize))
        let isPickable = allowed.contains(day)
        gtk_widget_set_sensitive(button, isPickable ? 1 : 0)
        SettingsWidgets.identify(
            button,
            "\(identifier)-day-\(ReportEntryText.date(day, calendar: calendar))",
            saying: "\(number)"
        )
        if selection.map({ ReportCalendarGrid.isSameDay($0, day, calendar: calendar) }) == true {
            // The picked day itself, which the theme's own selected look is right for: a calendar somebody is
            // looking at has one day chosen, and every other list on this desktop marks that the same way.
            _ = SettingsWidgets.styled(button, "facet-day-picked")
        } else if emphasised.contains(day) {
            _ = SettingsWidgets.styled(button, "facet-day-in-range")
        } else if !ReportCalendarGrid.isSameMonth(day, month, calendar: calendar) {
            _ = SettingsWidgets.styled(button, SettingsWidgets.secondaryClass)
        }
        signals.connect(button, "clicked") { [weak self] in self?.onPick?(day) }
        return button
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month)
    }
}
