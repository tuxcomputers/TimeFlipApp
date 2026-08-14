import AppKit

/// The Report tab: a date range across the top, and what each category recorded over it underneath.
///
/// **A picked day or range is a question, and the totals are the answer to it.** The range covers the app's own days,
/// not calendar days: 5 August to 7 August means 5 August at the daily reset up to 8 August at the daily reset, so a
/// one-day report shows exactly what the menu bar showed on that day (`ReportRangeRules.bounds`).
///
/// Only the categories that recorded something appear, biggest first. The reset time and the entries are both read at
/// the moment the range changes, by the window -- this pane draws what it is handed.
///
/// The pair is the archive's, and so is the reason it is a pair of hand-drawn calendars rather than two date fields
/// (see [ReportCalendar]). What each one is allowed to offer is [ReportRangeRules]':
///
/// - **The end starts unset**, which is not a missing value to fill in but the common case said in one click: pick a
///   day on the left and the report covers that day. Clicking in the right calendar turns it into a range.
/// - **The right calendar cannot reach a day before the start.** Every earlier day is drawn dimmed and refuses the
///   click, so an inverted range is unreachable rather than rejected after the fact -- there is no error state for
///   one, and no way to be told off for a selection the screen allowed.
/// - **Both stop at today.** This is a time recorder, not a time planner.
///
/// The selection lives here rather than in the table, because it is not a setting: it is the question being asked,
/// and it lasts as long as the window is open. Nothing is written, so there is nothing for the source-of-truth rule
/// to arbitrate.
@MainActor
final class ReportPane: NSView {
    enum Identifier {
        static let range = "report-range"
        static let from = "from"
        static let to = "to"
    }

    enum Layout {
        static let padding = ReportLayout.tabPadding
        static let calendarSpacing = ReportLayout.calendarSpacing
        /// Above and below the hairline between the range and its answer.
        static let dividerSpacing: CGFloat = 12
    }

    /// The day picked on the left, and the day picked on the right if one has been.
    private(set) var start: Date
    private(set) var end: Date?

    /// Called whenever the range changes, so it can be logged. Nothing consumes the range itself yet.
    var onRangeChange: ((Date, Date?) -> Void)?
    /// Called when either calendar is paged to another month, for the same reason.
    var onShowMonth: ((String, Date) -> Void)?

    /// Exposed so the pair can be asserted without a window on screen.
    private(set) var fromCalendar: ReportCalendar!
    private(set) var toCalendar: ReportCalendar!

    /// What the range came to. Exposed for the same reason.
    let totalsList = ReportTotalsList()

    /// Called when the totals on show need re-reading: the range changed, or the tab was shown. **A request for a
    /// read**, not the answer -- the window owns the tables, and the reset time the range is measured against is read
    /// from `setting` at that moment rather than remembered here.
    var onNeedTotals: ((Date, Date?) -> Void)?

    private let calendar: Calendar
    /// What the clock says, asked rather than remembered. A Settings window can be left open across midnight, and a
    /// `latest` captured when the tab was built would go on refusing today for the rest of the night.
    private let now: () -> Date
    /// Today's end, which bounds both calendars. Derived at each use, from the clock above.
    private var latest: Date { ReportRangeRules.latestSelectableDay(now: now(), calendar: calendar) }
    private var metrics: ReportCalendarMetrics

    init(now: @escaping () -> Date = Date.init, calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.now = now
        // Today, which is the report somebody opening this tab is most likely to want, and the only one they can ask
        // for in no clicks at all.
        start = min(now(), ReportRangeRules.latestSelectableDay(now: now(), calendar: calendar))
        // Fitted properly on the first layout, when the tab view has handed this pane its width. A calendar has to be
        // built with *some* metrics, and the floor is the one size known to be legible.
        metrics = ReportCalendarMetrics(cellSize: ReportCalendarMetrics.minimumCellSize)
        super.init(frame: .zero)
        addCalendars(locale: locale)
        // Both calendars are built from the same three values and then drawn once, from one place, rather than each
        // being handed its own opening state: the subtitle saying what an unset end means is decided in `redraw`, and
        // building them without it left the To calendar opening blank.
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The cells are sized from the width this tab is actually given, so they are re-derived every time that width
    /// changes rather than being written down. Guarded on the metrics themselves changing, not on the width: a
    /// rounded-down cell size is the same across a range of widths, and rebuilding 84 buttons for a pixel of window
    /// drag would be work in service of nothing.
    override func layout() {
        super.layout()
        let fitted = ReportCalendarMetrics.fitting(tabWidth: bounds.width)
        guard fitted != metrics else { return }
        metrics = fitted
        redraw()
    }

    /// Re-derives what the calendars may offer and asks for the totals again. Called as the tab is shown: what is
    /// picked does not change, but today moves -- and today is what both calendars are bounded by -- and the entries
    /// may have grown since the tab was last looked at.
    func refresh() {
        redraw()
        onNeedTotals?(start, end)
    }

    /// Draws the answer to the range on show.
    func show(_ totals: [CategoryTotal], showingSeconds: Bool) {
        totalsList.show(totals, showingSeconds: showingSeconds)
    }

    /// A day picked in the From calendar.
    func selectStart(_ day: Date) {
        start = day
        // The To calendar's own bound stops a *new* end landing before the start; this is for a start that moves
        // forward past an end already chosen, which would otherwise strand it behind.
        end = ReportRangeRules.endCarriedForward(start: day, end: end)
        redraw()
        report()
    }

    /// A day picked in the To calendar. Picking one at all is what makes the range a range.
    func selectEnd(_ day: Date) {
        end = ReportRangeRules.endChosen(day, start: start)
        redraw()
        report()
    }

    /// Says the range changed, and asks for the totals over it. Both, always, from one place: a range on screen with
    /// last range's figures under it would be a worse answer than no figures at all.
    private func report() {
        onRangeChange?(start, end)
        onNeedTotals?(start, end)
    }

    private func addCalendars(locale: Locale) {
        let emphasised = ReportRangeRules.emphasised(start: start, end: end)
        fromCalendar = ReportCalendar(
            title: "From",
            name: Identifier.from,
            selection: start,
            allowed: ReportRangeRules.allowedStarts(latest: latest),
            emphasised: emphasised,
            metrics: metrics,
            calendar: calendar,
            locale: locale
        )
        toCalendar = ReportCalendar(
            title: "To",
            name: Identifier.to,
            selection: start,
            allowed: ReportRangeRules.allowedEnds(start: start, latest: latest, calendar: calendar),
            emphasised: emphasised,
            metrics: metrics,
            calendar: calendar,
            locale: locale
        )
        fromCalendar.onSelect = { [weak self] day in self?.selectStart(day) }
        toCalendar.onSelect = { [weak self] day in self?.selectEnd(day) }
        fromCalendar.onShowMonth = { [weak self] month in self?.onShowMonth?("From", month) }
        toCalendar.onShowMonth = { [weak self] month in self?.onShowMonth?("To", month) }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityIdentifier(Identifier.range)
        row.addSubview(fromCalendar)
        row.addSubview(toCalendar)
        addSubview(row)

        // A hairline between the question and its answer, which is how the archive divided this tab. Not a heading over
        // the totals: what they are is said by the range above them, and "Totals" would be a word explaining a column
        // of times that needs no explaining.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        addSubview(totalsList)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            // As tall as the calendars in it, so the totals begin under them rather than under the tab.
            row.bottomAnchor.constraint(equalTo: fromCalendar.bottomAnchor),

            // The hairline runs the full width of the tab's content, and the totals under it: a row of the list is a
            // line across the tab, with its figure at the right-hand end.
            divider.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Layout.dividerSpacing),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),

            totalsList.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Layout.dividerSpacing),
            totalsList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            totalsList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            // **All the way to the bottom of the tab**, which is what makes the list the thing that scrolls rather than
            // the tab: the calendars stay put and the times move under them.
            totalsList.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.padding),

            // **Half the tab each**, rather than each box sizing to the grid inside it. The cell size is rounded down
            // to fit, so grid-width boxes would leave a few points of slack at the right-hand edge and the pair would
            // stop short of the window (see `CLAUDE.md`). The slack goes either side of the grid inside its box
            // instead, where it reads as padding.
            // **Pinned by their tops only.** A calendar's height is decided from the inside -- six weeks of cells, the
            // weekday row, the month header -- and pinning the bottom as well made the whole chain stretchable: the
            // row then filled the tab, the box filled the row, and the stack inside spread its three rows 147pt
            // apart. Measured on the running app, which is the only place it showed: the constraints were satisfiable
            // either way, so nothing failed and no test noticed.
            fromCalendar.topAnchor.constraint(equalTo: row.topAnchor),
            fromCalendar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            toCalendar.topAnchor.constraint(equalTo: row.topAnchor),
            toCalendar.leadingAnchor.constraint(equalTo: fromCalendar.trailingAnchor, constant: Layout.calendarSpacing),
            toCalendar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toCalendar.widthAnchor.constraint(equalTo: fromCalendar.widthAnchor),
        ])
    }

    /// Both calendars, always, from one answer: the span is drawn bold in each of them, and the To calendar's bound
    /// follows the From calendar's day.
    private func redraw() {
        let emphasised = ReportRangeRules.emphasised(start: start, end: end)
        fromCalendar.show(
            selection: start,
            allowed: ReportRangeRules.allowedStarts(latest: latest),
            emphasised: emphasised,
            metrics: metrics
        )
        toCalendar.show(
            selection: end ?? start,
            allowed: ReportRangeRules.allowedEnds(start: start, latest: latest, calendar: calendar),
            emphasised: emphasised,
            metrics: metrics,
            // Says what an unset end means rather than leaving the calendar to look like a second date somebody
            // forgot to choose.
            subtitle: end == nil ? ReportRangeRules.unsetEndSubtitle : nil
        )
    }
}
