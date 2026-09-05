import AppKit

/// A month calendar for the Report tab, drawn here rather than taken from the system.
///
/// **Why not `NSDatePicker`.** Two things this screen needs are not expressible on the native control, and the
/// archive established both by measurement rather than by reasoning (`ReportCalendarView.swift`,
/// `docs/TODO-features-under-development.md`):
///
/// - The days between the start and the end are drawn **bold and tinted**, so the selected span reads as a span in
///   both calendars instead of as two unrelated highlighted days. Neither `NSDatePicker` nor SwiftUI's `DatePicker`
///   offers any hook for styling an individual day cell.
/// - The month arrows stop at the last month holding a selectable day. A date bound governs which days can be
///   *selected*, not which month is *displayed*: measured 2026-08-08 on a bare `NSDatePicker` with `minDate`/`maxDate`
///   set, whose forward arrow paged into a fully greyed-out month.
///
/// So the shape is the archive's and the drawing is new: that one was SwiftUI, and this is a view that rebuilds its
/// grid from `ReportCalendarGrid`, which holds the arithmetic and is under test on its own.
///
/// **It draws what it is given.** What the range means, and what the other calendar does about it, is the pane's
/// (`ReportPane`, `ReportRangeRules`). The one piece of state it keeps for itself is which month is on show, that
/// being a question about this view rather than about the report: it is derived from the selection until somebody
/// pages away from it.
@MainActor
final class ReportCalendar: NSView {
    enum Layout {
        /// Inside the box, around the whole calendar. Named in `ReportLayout` because the cell size is derived from
        /// what is left after it.
        static let padding = ReportLayout.calendarPadding
        /// Between the month header, the weekday row and the grid.
        static let rowSpacing: CGFloat = 4
        /// Between the title and the box under it, and between the title and its subtitle.
        static let titleSpacing: CGFloat = 4
        static let cornerRadius: CGFloat = 8
        /// The fill behind the days between the start and the end, as a fraction of the accent colour. Faint enough
        /// that the two solid endpoints still lead, strong enough to read on the white the calendar sits on -- the
        /// archive measured 0.12 as too faint at this cell size. Weight is kept on those days as well: a tint is the
        /// first thing lost to a colour-vision difference or a high-contrast setting, so bold is a second signal for
        /// the span rather than the only one.
        static let rangeTintOpacity: CGFloat = 0.15
    }

    /// The calendar's own name, which is what its parts are called in the accessibility tree: `report-from-month`,
    /// `report-to-2026-08-14`. A script presses a day by its date rather than by its position in the grid.
    enum Identifier {
        static func calendar(_ name: String) -> String { "report-calendar-\(name)" }
        static func month(_ name: String) -> String { "report-\(name)-month" }
        static func previousMonth(_ name: String) -> String { "report-\(name)-previous-month" }
        static func nextMonth(_ name: String) -> String { "report-\(name)-next-month" }
        static func day(_ name: String, _ date: Date, calendar: Calendar) -> String {
            "report-\(name)-\(ReportCalendar.identifierFormatter(calendar: calendar).string(from: date))"
        }
    }

    /// "From" or "To". The word over the box, and half of what every part of it is called.
    let title: String
    private let name: String
    private let calendar: Calendar
    private let locale: Locale

    /// The day this calendar sets, drawn solid.
    private(set) var selection: Date
    /// Days outside this are drawn dimmed and refuse the click, and months holding none of it cannot be reached.
    private(set) var allowed: ClosedRange<Date>
    /// Days in this span are drawn bold on a tint: the whole selected range, so both calendars show the same span.
    private(set) var emphasised: ClosedRange<Date>
    private(set) var metrics: ReportCalendarMetrics

    /// Called with the day clicked. A request: what a picked day does to the range is the pane's to say, and this
    /// redraws when it is told to.
    var onSelect: ((Date) -> Void)?
    /// Called when the month on show changes, so it can be logged. Nothing else depends on it.
    var onShowMonth: ((Date) -> Void)?

    /// The month somebody paged to, or `nil` while the calendar is still following its selection. Derived rather than
    /// stored on its own so it can never be left pointing at a month the bounds have since moved out of reach -- the
    /// To calendar's lower bound follows the start date, which changes under it.
    private var pagedMonth: Date?

    private var month: Date {
        ReportCalendarGrid.displayableMonth(for: pagedMonth ?? selection, within: allowed, calendar: calendar)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let panel = NSBox()
    private let monthLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let weekdayRow = NSStackView()
    private let grid = NSStackView()
    /// A plain view rather than a stack, and that is the fix for a fault worth not repeating: an `NSStackView` given
    /// more height than its views need distributes the slack between them, so the three rows of a calendar spread
    /// apart -- 147pt apart, measured on the running app -- whenever anything above could stretch it. Constants
    /// between three subviews cannot spread, so the calendar has exactly one possible height.
    private let content = NSView()
    private var contentWidth: NSLayoutConstraint!
    /// Six weeks of cells, stated rather than left to the rows inside: with this, nothing anywhere can stretch the
    /// calendar, and the space under it belongs to the totals.
    private var gridHeight: NSLayoutConstraint!

    init(
        title: String,
        name: String,
        selection: Date,
        allowed: ClosedRange<Date>,
        emphasised: ClosedRange<Date>,
        metrics: ReportCalendarMetrics,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.title = title
        self.name = name
        self.selection = selection
        self.allowed = allowed
        self.emphasised = emphasised
        self.metrics = metrics
        self.calendar = calendar
        self.locale = locale
        super.init(frame: .zero)
        addContent()
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Draws a new state. Everything arrives together, from the pane, because it is one answer: a start that moved
    /// changes what this calendar may offer *and* what it draws bold.
    func show(
        selection: Date,
        allowed: ClosedRange<Date>,
        emphasised: ClosedRange<Date>,
        metrics: ReportCalendarMetrics,
        subtitle: String? = nil
    ) {
        self.selection = selection
        self.allowed = allowed
        self.emphasised = emphasised
        self.metrics = metrics
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
        redraw()
    }

    // MARK: - drawing

    /// Rebuilt rather than patched, for the reason every list in this app is: the state arrives whole, so
    /// reconciling 42 cells against what is on screen would be work in service of nothing. It is also what keeps the
    /// cells honest through a resize -- every size in them comes from `metrics`, which changes with the window.
    private func redraw() {
        contentWidth.constant = metrics.gridWidth
        gridHeight.constant = CGFloat(ReportCalendarGrid.weeksShown) * metrics.cellSize
        monthLabel.stringValue = monthTitle
        monthLabel.font = .systemFont(ofSize: metrics.monthTitleFontSize, weight: .semibold)
        drawArrow(previousButton, months: -1)
        drawArrow(nextButton, months: 1)
        drawWeekdays()
        drawGrid()
    }

    private func drawArrow(_ button: NSButton, months: Int) {
        let target = ReportCalendarGrid.month(movedFrom: month, by: months, within: allowed, calendar: calendar)
        // Disabled rather than hidden at either end of the range, so the header does not reflow as it is reached.
        button.isEnabled = target != nil
        button.contentTintColor = target == nil ? .tertiaryLabelColor : .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: metrics.arrowFontSize,
            weight: .semibold
        )
        for constraint in button.constraints where constraint.firstAttribute == .width || constraint.firstAttribute == .height {
            constraint.constant = metrics.arrowSize
        }
    }

    private func drawWeekdays() {
        for view in weekdayRow.views {
            weekdayRow.removeView(view)
        }
        for symbol in ReportCalendarGrid.weekdaySymbols(calendar: calendar, locale: locale) {
            let label = NSTextField(labelWithString: symbol)
            label.font = .systemFont(ofSize: metrics.weekdayFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: metrics.cellSize).isActive = true
            // Seven letters read out before the grid tell a screen reader nothing: each cell carries its own full
            // date instead.
            label.setAccessibilityElement(false)
            weekdayRow.addView(label, in: .leading)
        }
    }

    private func drawGrid() {
        for week in grid.views {
            grid.removeView(week)
        }
        let days = ReportCalendarGrid.days(forMonthContaining: month, calendar: calendar)
        let dayNames = Self.dayNameFormatter(calendar: calendar, locale: locale)
        for week in 0 ..< ReportCalendarGrid.weeksShown {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 0
            for weekday in 0 ..< ReportCalendarGrid.daysPerWeek {
                row.addView(cell(days[week * ReportCalendarGrid.daysPerWeek + weekday], dayNames: dayNames), in: .leading)
            }
            grid.addView(row, in: .top)
        }
    }

    private func cell(_ day: Date, dayNames: DateFormatter) -> ReportDayCell {
        // A day sitting exactly on a bound counts as selectable even when the bound's time of day puts the cell's own
        // instant outside the range: the bounds are day-granular questions ("not before the start", "not after
        // today") carried on instants that hold a time.
        let onABound = ReportCalendarGrid.isSameDay(day, allowed.lowerBound, calendar: calendar)
            || ReportCalendarGrid.isSameDay(day, allowed.upperBound, calendar: calendar)
        let cell = ReportDayCell(
            date: day,
            number: String(calendar.component(.day, from: day)),
            style: ReportDayCell.Style(
                isSelected: ReportCalendarGrid.isSameDay(day, selection, calendar: calendar),
                isSelectable: allowed.contains(day) || onABound,
                isInMonth: ReportCalendarGrid.isSameMonth(day, month, calendar: calendar),
                isEmphasised: isEmphasised(day),
                isRangeStart: ReportCalendarGrid.isSameDay(day, emphasised.lowerBound, calendar: calendar),
                isRangeEnd: ReportCalendarGrid.isSameDay(day, emphasised.upperBound, calendar: calendar)
            ),
            metrics: metrics
        )
        cell.setAccessibilityIdentifier(Identifier.day(name, day, calendar: calendar))
        // The full date rather than the day number: "Monday, 3 August 2026" says which cell this is without the
        // surrounding grid, which a screen reader has no way to convey.
        cell.setAccessibilityLabel(dayNames.string(from: day))
        cell.onClick = { [weak self] in self?.onSelect?(day) }
        return cell
    }

    private func isEmphasised(_ day: Date) -> Bool {
        if ReportCalendarGrid.isSameDay(day, emphasised.lowerBound, calendar: calendar) { return true }
        if ReportCalendarGrid.isSameDay(day, emphasised.upperBound, calendar: calendar) { return true }
        return emphasised.contains(day)
    }

    // MARK: - paging

    @objc
    private func showPreviousMonth() {
        page(by: -1)
    }

    @objc
    private func showNextMonth() {
        page(by: 1)
    }

    private func page(by months: Int) {
        guard let target = ReportCalendarGrid.month(movedFrom: month, by: months, within: allowed, calendar: calendar)
        else { return }
        pagedMonth = target
        redraw()
        onShowMonth?(target)
    }

    // MARK: - building

    private func addContent() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Identifier.calendar(name))
        setAccessibilityLabel(title)

        titleLabel.stringValue = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Beside the title in a lighter style, for saying something about the selection itself rather than about the
        // calendar: the To calendar uses it for "not set, reporting one day".
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isHidden = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // White with a hairline round it, not the tinted panel the settings tabs use. The archive's own split, kept:
        // a panel of settings is a thing on the page, and something picked in -- this, the Faces tab's list -- is
        // part of it.
        panel.boxType = .custom
        panel.fillColor = .textBackgroundColor
        panel.borderWidth = 1
        panel.borderColor = .separatorColor
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false

        addMonthHeader()

        weekdayRow.orientation = .horizontal
        weekdayRow.alignment = .centerY
        weekdayRow.spacing = 0
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 0
        // Both, because `content` is a plain view now: a stack view sets this on anything handed to `addView`, and
        // `addSubview` sets nothing -- so these two kept their autoresizing frames, Auto Layout pinned them to the zero
        // frame they were built with, and the grid came out 0 by 0 with every constraint above it satisfied.
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(monthHeader)
        content.addSubview(weekdayRow)
        content.addSubview(grid)

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(panel)
        panel.contentView?.addSubview(content)
        guard let box = panel.contentView else { return }

        // Pinned to exactly the grid's width, and centred rather than stretched. The month header would otherwise be
        // the greedy row -- its arrows sit against the trailing edge -- and pull the columns out of step with the
        // cells under them.
        //
        // **Just under required, so it can lose.** The cell size has a floor, so below about 430pt of window the two
        // grids genuinely do not fit; at required priority that made the calendars push back and the pane was
        // resized *wider* than the window handed it (measured: a pane given 460pt came back 634pt, dragging the
        // window's own width with it). Losing here means the grid keeps its legible size and is clipped by the box
        // instead, which is what the archive's own floor said should happen.
        contentWidth = content.widthAnchor.constraint(equalToConstant: metrics.gridWidth)
        contentWidth.priority = .required - 1
        gridHeight = grid.heightAnchor.constraint(
            equalToConstant: CGFloat(ReportCalendarGrid.weeksShown) * metrics.cellSize
        )
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            subtitleLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Layout.titleSpacing),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            panel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.titleSpacing),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentWidth,
            gridHeight,
            // The three rows, at fixed gaps: month header, weekday letters, grid. Every edge here is a constant, which
            // is what makes the calendar's height a single number rather than a range.
            monthHeader.topAnchor.constraint(equalTo: content.topAnchor),
            monthHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            monthHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            weekdayRow.topAnchor.constraint(equalTo: monthHeader.bottomAnchor, constant: Layout.rowSpacing),
            weekdayRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),

            grid.topAnchor.constraint(equalTo: weekdayRow.bottomAnchor, constant: Layout.rowSpacing),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            content.topAnchor.constraint(equalTo: box.topAnchor, constant: Layout.padding),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Layout.padding),
            content.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        ])
        // So a squeezed grid is cut off at its own box rather than drawn over the calendar beside it.
        box.clipsToBounds = true
    }

    private let monthHeader = NSView()

    private func addMonthHeader() {
        monthLabel.lineBreakMode = .byTruncatingTail
        monthLabel.translatesAutoresizingMaskIntoConstraints = false
        monthLabel.setAccessibilityIdentifier(Identifier.month(name))

        arrow(previousButton, symbol: "chevron.left", label: "Previous month", identifier: Identifier.previousMonth(name), action: #selector(showPreviousMonth))
        arrow(nextButton, symbol: "chevron.right", label: "Next month", identifier: Identifier.nextMonth(name), action: #selector(showNextMonth))

        monthHeader.translatesAutoresizingMaskIntoConstraints = false
        monthHeader.addSubview(monthLabel)
        monthHeader.addSubview(previousButton)
        monthHeader.addSubview(nextButton)
        NSLayoutConstraint.activate([
            monthLabel.leadingAnchor.constraint(equalTo: monthHeader.leadingAnchor),
            monthLabel.centerYAnchor.constraint(equalTo: monthHeader.centerYAnchor),
            monthLabel.topAnchor.constraint(greaterThanOrEqualTo: monthHeader.topAnchor),
            // A long month name in a wordier locale is cut rather than pushing the arrows out of a calendar whose
            // width is fixed. (SwiftUI shrank the text instead; an AppKit label has no equivalent, and a cut name
            // still reads as a month where a shrinking one at some point stops being legible at all.)
            monthLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousButton.leadingAnchor, constant: -Layout.titleSpacing),

            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            previousButton.centerYAnchor.constraint(equalTo: monthHeader.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: monthHeader.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: monthHeader.centerYAnchor),
            // **As tall as an arrow, exactly.** This row was pinned with inequalities -- tall enough to hold the
            // arrows, and no more said -- which left it as the one part of a calendar that could still be stretched,
            // and it was: the totals list below pins its own bottom to the tab, and the pull travelled up through the
            // From calendar and spread this row into the middle of an empty box. The arrows are the taller of the two
            // things in it at every cell size, the ratios being what they are, so their height is the row's.
            monthHeader.heightAnchor.constraint(equalTo: previousButton.heightAnchor),
        ])
    }

    private func arrow(_ button: NSButton, symbol: String, label: String, identifier: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: metrics.arrowSize),
            button.heightAnchor.constraint(equalToConstant: metrics.arrowSize),
        ])
    }

    // MARK: - words

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month)
    }

    /// Built once per grid rather than once per cell: all 42 cells of a month share one calendar and locale, and a
    /// `DateFormatter` each was pure allocation churn on a view that redraws on every click.
    private static func dayNameFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }

    /// `yyyy-MM-dd`, for the identifier a script presses. Fixed rather than localised, deliberately: an identifier
    /// that changed with the machine's locale would be a name only some machines could type.
    nonisolated private static func identifierFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// One day in the grid: the number, on whatever the range and the selection say should be behind it.
///
/// **An `NSButton`**, so it is a button to the keyboard and to accessibility as well as to the mouse, and so a script
/// can press a date by name. The fills are drawn here rather than layered behind it as separate views: 42 cells with
/// two background views each is 126 views per calendar, and what is behind a cell is one decision anyway.
@MainActor
final class ReportDayCell: NSButton {
    struct Style: Equatable {
        let isSelected: Bool
        let isSelectable: Bool
        let isInMonth: Bool
        let isEmphasised: Bool
        let isRangeStart: Bool
        let isRangeEnd: Bool
    }

    let date: Date
    let style: Style
    private let metrics: ReportCalendarMetrics

    var onClick: (() -> Void)?

    init(date: Date, number: String, style: Style, metrics: ReportCalendarMetrics) {
        self.date = date
        self.style = style
        self.metrics = metrics
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        isEnabled = style.isSelectable
        // Every cell would otherwise take a focus ring as the tab gains focus, which reads as a selection rather than
        // as keyboard focus -- the same treatment the Faces tab's list gets.
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        attributedTitle = NSAttributedString(
            string: number,
            attributes: [
                .font: NSFont.systemFont(ofSize: metrics.dayFontSize, weight: style.isEmphasised ? .bold : .regular),
                .foregroundColor: Self.colour(for: style),
                .paragraphStyle: Self.centred,
            ]
        )
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: metrics.cellSize),
            heightAnchor.constraint(equalToConstant: metrics.cellSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc
    private func clicked() {
        onClick?()
    }

    /// The span first, the picked day on top of it: a tint for "inside the range", solid for "the date this calendar
    /// sets", so the two ends stay distinguishable from the days between them.
    override func draw(_ dirtyRect: NSRect) {
        if style.isEmphasised {
            NSColor.controlAccentColor.withAlphaComponent(ReportCalendar.Layout.rangeTintOpacity).setFill()
            rangePath().fill()
        }
        if style.isSelected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: metrics.dayCornerRadius,
                yRadius: metrics.dayCornerRadius
            ).fill()
        }
        super.draw(dirtyRect)
    }

    /// The selected span's background: one continuous fill, rounded **only** at the range's own two ends and square
    /// everywhere else.
    ///
    /// It deliberately does not round where a *row* ends. The archive tried that and found it put a corner on the
    /// right of one week and the left of the next; since the weeks stack directly on each other, those corners met as
    /// a notch running down both edges and the fill read as a stack of separate pills rather than one span. Squaring
    /// every internal edge is what lets the rows meet flush.
    ///
    /// Leading and trailing rather than left and right, so a right-to-left layout -- where the grid itself flips --
    /// rounds the visually correct ends.
    private func rangePath() -> NSBezierPath {
        let radius = metrics.dayCornerRadius
        let flipped = userInterfaceLayoutDirection == .rightToLeft
        let roundsLeft = flipped ? style.isRangeEnd : style.isRangeStart
        let roundsRight = flipped ? style.isRangeStart : style.isRangeEnd
        guard roundsLeft || roundsRight else { return NSBezierPath(rect: bounds) }
        if roundsLeft, roundsRight {
            return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        }
        // One end rounded: draw the pill and square off the end that carries on into the next cell, by covering it
        // with a rectangle half a cell wide. Cheaper to read than four arcs, and it cannot get a corner wrong.
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let square = NSRect(
            x: roundsLeft ? bounds.midX : bounds.minX,
            y: bounds.minY,
            width: bounds.width / 2,
            height: bounds.height
        )
        path.appendRect(square)
        return path
    }

    private static func colour(for style: Style) -> NSColor {
        if style.isSelected { return .white }
        if !style.isSelectable { return .tertiaryLabelColor }
        // A selectable day from the month either side is real, just not the month being read.
        return style.isInMonth ? .labelColor : .secondaryLabelColor
    }

    private static let centred: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()
}
