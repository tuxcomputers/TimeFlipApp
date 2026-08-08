@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
/// Covers `ReportCalendarMetrics`, which sizes the Report tab's calendars to the window.
///
/// The property that matters is that two calendars plus everything between and around them fit the
/// width they were fitted to. Getting it wrong by a rounding step pushes the second calendar off the
/// edge, which is exactly the sort of thing that looks fine at one window size and breaks at another.
final class ReportCalendarMetricsTests: XCTestCase {
    /// What the tab spends on anything that is not grid: its own padding either side, the gap
    /// between the calendars, and each calendar's internal padding.
    private var chrome: CGFloat {
        (SettingsLayoutConstants.Report.padding * 2)
            + SettingsLayoutConstants.Report.pickerSpacing
            + (SettingsLayoutConstants.Report.calendarPadding * 4)
    }

    func testTwoCalendarsFitTheWidthTheyWereFittedTo() {
        // Every width from the window's minimum up to a wide one, so a rounding error at one size
        // cannot hide behind a lucky divisor at another.
        for width in stride(from: SettingsLayoutConstants.minimumWindowWidth, through: 1_600, by: 1) {
            let metrics = ReportCalendarMetrics.fitting(tabWidth: width)
            let used = (metrics.gridWidth * 2) + chrome
            XCTAssertLessThanOrEqual(used, width, "two calendars overflow a \(width)pt tab")
        }
    }

    func testTheCalendarsActuallyFillTheWidthRatherThanSittingSmall() {
        // Filling is the point of this type. Allow only what rounding down to a whole-point cell can
        // leave over: up to one point per column, per calendar.
        let slack = CGFloat(ReportCalendarGrid.daysPerWeek * 2)
        for width in stride(from: SettingsLayoutConstants.minimumWindowWidth, through: 1_600, by: 7) {
            let metrics = ReportCalendarMetrics.fitting(tabWidth: width)
            let used = (metrics.gridWidth * 2) + chrome
            XCTAssertGreaterThan(used, width - slack, "a \(width)pt tab is left largely empty")
        }
    }

    func testAWiderWindowGivesABiggerCell() {
        let narrow = ReportCalendarMetrics.fitting(tabWidth: SettingsLayoutConstants.minimumWindowWidth)
        let wide = ReportCalendarMetrics.fitting(tabWidth: 1_000)

        XCTAssertGreaterThan(wide.cellSize, narrow.cellSize)
    }

    func testTheCellNeverShrinksBelowTheKnownLegibleSize() {
        // A window narrower than the layout expects stops the calendars filling it, rather than
        // shrinking the digits past the size the fixed-size design already proved readable.
        let metrics = ReportCalendarMetrics.fitting(tabWidth: 200)

        XCTAssertEqual(metrics.cellSize, ReportCalendarMetrics.minimumCellSize)
    }

    func testAZeroOrNegativeWidthStillProducesAUsableCell() {
        // SwiftUI hands out a zero-size proposal during layout more often than seems reasonable, and
        // a zero or negative cell would collapse the grid or trap on a negative frame.
        for width in [CGFloat(0), -100, 1] {
            XCTAssertEqual(ReportCalendarMetrics.fitting(tabWidth: width).cellSize, ReportCalendarMetrics.minimumCellSize)
        }
    }

    // MARK: - derived sizes

    func testEverySizeGrowsWithTheCell() {
        // The reason these live together: a resize must not leave one of them behind.
        let small = ReportCalendarMetrics(cellSize: 28)
        let large = ReportCalendarMetrics(cellSize: 44)

        XCTAssertGreaterThan(large.dayFontSize, small.dayFontSize)
        XCTAssertGreaterThan(large.weekdayFontSize, small.weekdayFontSize)
        XCTAssertGreaterThan(large.monthTitleFontSize, small.monthTitleFontSize)
        XCTAssertGreaterThan(large.arrowSize, small.arrowSize)
        XCTAssertGreaterThan(large.arrowFontSize, small.arrowFontSize)
        XCTAssertGreaterThan(large.dayCornerRadius, small.dayCornerRadius)
    }

    func testTheOriginalFixedDesignIsReproducedAtItsOwnCellSize() {
        // The ratios were taken from the fixed-size layout, so at that cell size they must give it
        // back -- otherwise a narrow window renders something subtly different from what was
        // reviewed on screen.
        let metrics = ReportCalendarMetrics(cellSize: 28)

        XCTAssertEqual(metrics.dayFontSize, 12)
        XCTAssertEqual(metrics.weekdayFontSize, 11)
        XCTAssertEqual(metrics.monthTitleFontSize, 13)
        XCTAssertEqual(metrics.arrowSize, 20)
        XCTAssertEqual(metrics.arrowFontSize, 11)
        XCTAssertEqual(metrics.dayCornerRadius, 5)
        XCTAssertEqual(metrics.gridWidth, 196)
    }

    func testTheDigitsAlwaysFitInsideTheirCell() {
        // A font larger than its cell would clip two-digit days. The ratio makes this true by
        // construction; this is what stops a later tweak breaking it silently.
        for cell in stride(from: CGFloat(28), through: 80, by: 1) {
            let metrics = ReportCalendarMetrics(cellSize: cell)
            XCTAssertLessThan(metrics.dayFontSize, cell, "a \(cell)pt cell cannot carry \(metrics.dayFontSize)pt digits")
        }
    }
}
// swiftlint:enable line_length
