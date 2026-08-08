import CoreGraphics

/// Every size inside a Report tab calendar, derived from the width the tab has to spend.
///
/// The two calendars fill the window rather than sitting at a fixed size, so the day cell is
/// whatever divides the available width into seven columns, and each font and radius is a ratio of
/// that cell. Deriving them all from one number is what stops a resize leaving 17pt digits in a 28pt
/// cell: there is only one thing to change, and everything else follows.
///
/// The ratios are taken from the fixed-size design this replaced (a 28pt cell carrying 12pt digits,
/// a 13pt month title, 20pt arrows), so a window at its minimum width still looks like that layout
/// rather than a differently-proportioned one.
struct ReportCalendarMetrics: Equatable {
    /// The side of one day cell. Everything else is a ratio of this.
    let cellSize: CGFloat

    /// Never smaller than the fixed size this replaced, so a window narrower than expected shrinks
    /// nothing below what was already known to be legible -- the calendars simply stop filling it.
    static let minimumCellSize: CGFloat = 28

    private enum Ratio {
        static let dayFont: CGFloat = 12.0 / 28.0
        static let weekdayFont: CGFloat = 11.0 / 28.0
        static let monthTitleFont: CGFloat = 13.0 / 28.0
        static let arrow: CGFloat = 20.0 / 28.0
        static let arrowFont: CGFloat = 11.0 / 28.0
        static let dayCorner: CGFloat = 5.0 / 28.0
    }

    /// The metrics that make two calendars, side by side, span `tabWidth`.
    ///
    /// Accounts for what sits between them and the window edges: the tab's own padding either side,
    /// the gap between the pair, and each calendar's internal padding. Rounded **down** so seven
    /// cells plus the padding can never come to more than the width they were fitted to and push the
    /// second calendar off the edge.
    static func fitting(tabWidth: CGFloat) -> ReportCalendarMetrics {
        let betweenAndAround = (SettingsLayoutConstants.Report.padding * 2)
            + SettingsLayoutConstants.Report.pickerSpacing
        let perCalendar = (tabWidth - betweenAndAround) / 2
        let gridWidth = perCalendar - (SettingsLayoutConstants.Report.calendarPadding * 2)
        let cell = (gridWidth / CGFloat(ReportCalendarGrid.daysPerWeek)).rounded(.down)
        return ReportCalendarMetrics(cellSize: max(minimumCellSize, cell))
    }

    var gridWidth: CGFloat { cellSize * CGFloat(ReportCalendarGrid.daysPerWeek) }
    var dayFontSize: CGFloat { (cellSize * Ratio.dayFont).rounded() }
    var weekdayFontSize: CGFloat { (cellSize * Ratio.weekdayFont).rounded() }
    var monthTitleFontSize: CGFloat { (cellSize * Ratio.monthTitleFont).rounded() }
    var arrowSize: CGFloat { (cellSize * Ratio.arrow).rounded() }
    var arrowFontSize: CGFloat { (cellSize * Ratio.arrowFont).rounded() }
    var dayCornerRadius: CGFloat { (cellSize * Ratio.dayCorner).rounded() }
}
