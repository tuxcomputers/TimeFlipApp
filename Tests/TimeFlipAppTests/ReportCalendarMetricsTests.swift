@testable import TimeFlipApp
import XCTest

/// Covers the one number every size in a Report tab calendar comes from.
///
/// The ratios are the archive's, taken from the fixed-size design it replaced: a 28pt cell carrying 12pt digits, a
/// 13pt month title, 20pt arrows. What these assert is that a calendar at any width still has those proportions --
/// the fault being prevented is a resize that leaves 17pt digits in a 28pt cell.
final class ReportCalendarMetricsTests: XCTestCase {
    func testTwoCalendarsAndEverythingAroundThemFitTheWidthTheyWereFittedTo() {
        let width: CGFloat = 640
        let metrics = ReportCalendarMetrics.fitting(tabWidth: width)

        let used = 2 * (metrics.gridWidth + 2 * ReportLayout.calendarPadding)
            + ReportLayout.calendarSpacing
            + 2 * ReportLayout.tabPadding
        XCTAssertLessThanOrEqual(used, width, "rounded down, so the second calendar is never pushed off the edge")
        XCTAssertGreaterThan(used, width - 2 * CGFloat(ReportCalendarGrid.daysPerWeek), "and no more than a pixel per column is left over")
    }

    func testTheCellNeverGoesBelowTheSizeKnownToBeLegible() {
        // A window narrower than expected shrinks nothing below the archive's fixed size; the calendars simply stop
        // filling it.
        XCTAssertEqual(ReportCalendarMetrics.fitting(tabWidth: 200).cellSize, ReportCalendarMetrics.minimumCellSize)
    }

    func testAWiderTabGivesABiggerCellAndEverythingWithIt() {
        let narrow = ReportCalendarMetrics.fitting(tabWidth: 640)
        let wide = ReportCalendarMetrics.fitting(tabWidth: 900)

        XCTAssertGreaterThan(wide.cellSize, narrow.cellSize)
        XCTAssertGreaterThan(wide.dayFontSize, narrow.dayFontSize)
        XCTAssertGreaterThan(wide.arrowSize, narrow.arrowSize)
    }

    func testEverySizeIsARatioOfTheCell() {
        // At the size the archive's fixed design used, the derived sizes are that design's own numbers.
        let metrics = ReportCalendarMetrics(cellSize: 28)

        XCTAssertEqual(metrics.gridWidth, 196)
        XCTAssertEqual(metrics.dayFontSize, 12)
        XCTAssertEqual(metrics.weekdayFontSize, 11)
        XCTAssertEqual(metrics.monthTitleFontSize, 13)
        XCTAssertEqual(metrics.arrowSize, 20)
        XCTAssertEqual(metrics.dayCornerRadius, 5)
    }
}
