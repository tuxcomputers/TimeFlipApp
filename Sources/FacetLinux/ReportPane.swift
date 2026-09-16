import CGtk
import FacetCore
import Foundation

/// The Report tab: a date range across the top, and what each category recorded over it underneath.
///
/// **A picked day or range is a question, and the totals are the answer to it.** The range covers the app's own
/// days, not calendar days: 5 August to 7 August means 5 August at the daily reset up to 8 August at the daily
/// reset, so a one-day report shows exactly what the menu bar showed on that day. That is `ReportReadout`, which is
/// core and reads the reset out of the table at the moment it is asked.
///
/// **The selection lives here rather than in the table**, because it is not a setting: it is the question being
/// asked, and it lasts as long as the window is open. Nothing is written, so there is nothing for the
/// source-of-truth rule to arbitrate.
///
/// A pair of hand-drawn calendars rather than two date fields, and what each may offer is `ReportRangeRules`':
///
/// - **The end starts unset**, which is not a missing value to fill in but the common case said in one click: pick a
///   day on the left and the report covers that day. Clicking in the right calendar turns it into a range.
/// - **The right calendar cannot reach a day before the start.** Every earlier day is dimmed and refuses the click,
///   so an inverted range is unreachable rather than rejected after the fact.
/// - **Both stop at today.** This is a time recorder, not a time planner.
@MainActor
final class ReportPane {
    let widget: UnsafeMutablePointer<GtkWidget>

    /// The day picked on the left, and the day picked on the right if one has been.
    private(set) var start: Date
    private(set) var end: Date?

    private let readout: ReportReadout
    private let debugLog: DebugLog?
    private let metrics = ReportCalendarMetrics.fitting(tabWidth: SettingsMetrics.windowWidth)
    private let calendars: UnsafeMutablePointer<GtkWidget>
    private let totalsList = ReportTotalsList()
    private var fromCalendar: ReportCalendar!
    private var toCalendar: ReportCalendar!

    /// Today at the daily reset, held for as long as the window is open. **The one value here that is remembered**,
    /// and it is a bound rather than an answer: a window left open across midnight goes on offering yesterday as the
    /// latest day, which is the same thing the Mac does and is why the calendars are rebuilt on each open.
    private let latest = ReportRangeRules.latestSelectableDay()

    init(readout: ReportReadout, debugLog: DebugLog?) {
        self.readout = readout
        self.debugLog = debugLog
        start = latest
        end = nil

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.sectionSpacing))
        SettingsWidgets.identify(widget, SettingsTab.report.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(ReportLayout.tabPadding))
        }

        calendars = SettingsWidgets.row(spacing: Int(ReportLayout.calendarSpacing))
        SettingsWidgets.identify(calendars, "report-range")
        facet_box_pack_start(widget, calendars, 0, 1, 0)
        facet_box_pack_start(widget, totalsList.widget, 0, 1, 0)

        buildCalendars()
        totalsList.entries = { [weak self] total in
            guard let self else { return [] }
            return readout.entries(for: total.categoryID, start: start, end: end)
        }
        totalsList.onToggle = { [weak self] total, isExpanded in
            self?.debugLog?.record(.report, "Report category \(total.name) \(isExpanded ? "opened" : "closed")")
        }
        totalsList.onSort = { [weak self] order in
            self?.debugLog?.record(
                .report,
                "Report sorted by \(order.sortColumnState == .time ? "time" : "category"), "
                    + "\(order.isSortAscending ? "ascending" : "descending")"
            )
        }
    }

    /// Reads what the picked range came to, and draws it.
    func reload() {
        let totals = readout.totals(start: start, end: end)
        totalsList.show(totals, showingSeconds: readout.showsSeconds)
        let window = readout.bounds(start: start, end: end)
        debugLog?.record(
            .report,
            "Report totals \(Self.dayAndTime(window.start)) -> \(Self.dayAndTime(window.end)): \(totals.count) categories"
        )
    }

    private func buildCalendars() {
        for child in SettingsWidgets.children(of: calendars) {
            gtk_widget_destroy(child)
        }
        fromCalendar = ReportCalendar(
            identifier: "from",
            selection: start,
            allowed: ReportRangeRules.allowedStarts(latest: latest),
            emphasised: ReportRangeRules.emphasised(start: start, end: end),
            metrics: metrics
        )
        toCalendar = ReportCalendar(
            identifier: "to",
            selection: end,
            allowed: ReportRangeRules.allowedEnds(start: start, latest: latest),
            emphasised: ReportRangeRules.emphasised(start: start, end: end),
            metrics: metrics
        )
        fromCalendar.onPick = { [weak self] day in self?.pickStart(day) }
        toCalendar.onPick = { [weak self] day in self?.pickEnd(day) }
        for calendar in [fromCalendar, toCalendar] {
            calendar?.onShowMonth = { [weak self] month in
                self?.debugLog?.record(.report, "\(calendar === self?.fromCalendar ? "from" : "to") calendar showing \(Self.month(month))")
            }
        }
        facet_box_pack_start(calendars, fromCalendar.widget, 1, 1, 0)
        facet_box_pack_start(calendars, toCalendar.widget, 1, 1, 0)
        gtk_widget_show_all(calendars)
    }

    /// A day was picked on the left.
    ///
    /// **The end is carried forward or dropped**, which is `ReportRangeRules.endCarriedForward`: a start moved past
    /// the end would otherwise leave an inverted range, and clearing it is the answer that needs no error to explain
    /// it -- the report goes back to covering one day.
    private func pickStart(_ day: Date) {
        start = day
        end = ReportRangeRules.endCarriedForward(start: day, end: end)
        rangeChanged()
    }

    /// A day was picked on the right. `ReportRangeRules.endChosen` is what a day before the start means, and the
    /// calendar has already refused those -- this is the second half of the same answer rather than a check.
    private func pickEnd(_ day: Date) {
        end = ReportRangeRules.endChosen(day, start: start)
        rangeChanged()
    }

    private func rangeChanged() {
        debugLog?.record(
            .report,
            "Report range \(Self.day(start)) -> \(end.map(Self.day) ?? ReportRangeRules.unsetEndSubtitle)"
        )
        // **Both calendars, not only the one that was clicked.** The To calendar's bounds follow the From day, and
        // the emphasis spans them both, so a click in one changes what the other is allowed to offer.
        fromCalendar.update(
            selection: start,
            allowed: ReportRangeRules.allowedStarts(latest: latest),
            emphasised: ReportRangeRules.emphasised(start: start, end: end)
        )
        toCalendar.update(
            selection: end,
            allowed: ReportRangeRules.allowedEnds(start: start, latest: latest),
            emphasised: ReportRangeRules.emphasised(start: start, end: end)
        )
        reload()
    }

    private static func day(_ date: Date) -> String {
        ReportEntryText.date(date)
    }

    private static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    private static func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
