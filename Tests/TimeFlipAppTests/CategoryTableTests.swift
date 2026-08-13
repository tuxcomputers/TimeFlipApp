@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the Categories tab: `CategoriesPane` and the `CategoryTable` in it, which is the list of active
/// categories in columns.
///
/// No database and no window: both are handed categories, which is the whole of their input. Layout is asserted by
/// setting a frame and laying out, per the note in `Tests/Methods.md` -- a missing or fighting constraint fails
/// nothing on its own, it just produces a size nobody chose.
@MainActor
final class CategoryTableTests: XCTestCase {
    private func category(
        _ id: Int,
        _ name: String,
        icon: String? = "ic_break",
        colour: NSColor? = .red,
        limit: Int = 0
    ) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: icon,
            colour: colour,
            usesWhiteLines: false,
            dailyLimitMinutes: limit,
            isActive: true
        )
    }

    private func rows(of table: CategoryTable) -> [CategoryTableRow] {
        // Reaching through the panel because that is where the rows live: the box is a container, not a layer of
        // meaning.
        table.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .compactMap { $0 as? CategoryTableRow }
    }

    private func header(of table: CategoryTable) -> NSView? {
        table.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .first { $0.accessibilityIdentifier() == CategoryTable.Identifier.header }
    }

    // MARK: - the rows

    func testEachCategoryGetsARow() {
        let table = CategoryTable()

        table.show([category(1, "Break"), category(2, "Meeting"), category(3, "Admin")])

        XCTAssertEqual(rows(of: table).map(\.category.name), ["Break", "Meeting", "Admin"], "in order")
        XCTAssertEqual(table.shownCategories.count, 3)
    }

    func testShowingAgainReplacesTheRows() {
        let table = CategoryTable()
        table.show([category(1, "Break"), category(2, "Meeting")])

        table.show([category(3, "Admin")])

        XCTAssertEqual(rows(of: table).map(\.category.name), ["Admin"], "the previous rows are gone, not appended to")
    }

    func testEveryRowIsNamedForItsCategory() {
        let table = CategoryTable()

        table.show([category(7, "Admin")])

        let row = rows(of: table).first
        XCTAssertEqual(row?.accessibilityIdentifier(), "category-detail-row-7")
        // Distinct from the Faces tab's row identifier for the same category, so a step cannot press one believing
        // it addressed the other.
        XCTAssertNotEqual(row?.accessibilityIdentifier(), CategoryListView.Identifier.row(category(7, "Admin")))
        XCTAssertEqual(row?.accessibilityLabel(), "Admin")
    }

    func testARowIsNotAControl() {
        // Nothing here is clickable yet, and a button would announce itself to the keyboard and to accessibility as
        // something to press.
        let table = CategoryTable()
        table.show([category(1, "Break")])

        XCTAssertFalse(rows(of: table).first is NSButton)
        XCTAssertEqual(rows(of: table).first?.accessibilityRole(), .group)
    }

    // MARK: - the columns

    func testTheColumnsAreCaptionedAndTheIconIsNot() throws {
        let table = CategoryTable()
        table.show([category(1, "Break")])

        let captions = try XCTUnwrap(header(of: table)).subviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(
            captions,
            // The archive's five columns, and its wording. No caption over the icon, there being nothing useful to
            // call it; the limit's says what 0 means, since a limit of nothing and no limit at all are opposites.
            ["Name", "Colour", "Daily limit (0 = disabled)", "Active"],
            "the icon column is the only one without a caption"
        )
    }

    // MARK: - the daily limit

    private func limitField(of row: CategoryTableRow) -> SteppedNumberField? {
        row.subviews.flatMap { $0.subviews }.compactMap { $0 as? SteppedNumberField }.first
    }

    private func activeBox(of row: CategoryTableRow) -> NSButton? {
        row.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first
    }

    func testTheLimitFieldShowsWhatTheCategoryHolds() throws {
        let table = CategoryTable()
        table.show([category(1, "Break", limit: 45)])

        let field = try XCTUnwrap(limitField(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertEqual(field.value, 45)
    }

    func testAChangedLimitIsReportedWithTheCategory() throws {
        let table = CategoryTable()
        var reported: (name: String, minutes: Int)?
        table.onSetDailyLimit = { reported = ($0.name, $1) }
        table.show([category(1, "Break", limit: 0)])

        try XCTUnwrap(limitField(of: try XCTUnwrap(rows(of: table).first))).onChange?(90)

        XCTAssertEqual(reported?.name, "Break")
        XCTAssertEqual(reported?.minutes, 90)
    }

    // MARK: - the Active box

    func testTheBoxIsTickedAndUntickingRetires() throws {
        let table = CategoryTable()
        var retired: String?
        table.onRetire = { retired = $0.name }
        table.show([category(1, "Break")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertEqual(box.state, .on, "this is the active list, so every box in it is ticked")
        XCTAssertTrue(box.isEnabled)

        box.performClick(nil)

        XCTAssertEqual(retired, "Break")
    }

    func testALockedFaceTakesTheBoxAwayRatherThanRefusingIt() throws {
        // Retiring takes a category off every face it is on, and a locked face is one the user has said keeps what it
        // has. A box that offered the edit and bounced back would be worse than one that says it is not on offer.
        let table = CategoryTable()
        table.facesHolding = { _ in [(face: 8, isLocked: true)] }
        table.show([category(1, "Break")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertFalse(box.isEnabled)
        // The row gives no clue which face is in the way, so the tooltip names it.
        XCTAssertEqual(box.toolTip?.contains("Face 8"), true)
        XCTAssertEqual(box.toolTip?.contains("Break"), true)
    }

    func testAnUnlockedFaceLeavesTheBoxAlone() throws {
        let table = CategoryTable()
        table.facesHolding = { _ in [(face: 13, isLocked: false), (face: 14, isLocked: false)] }
        table.show([category(1, "Break")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertTrue(box.isEnabled)
        XCTAssertNil(box.toolTip)
    }

    func testTheColumnsLineUpWithTheirCaptions() throws {
        let table = CategoryTable()
        table.show([category(1, "Break"), category(2, "A much longer category name than the first")])
        table.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        table.layoutSubtreeIfNeeded()

        // The point of fixing the name column's width: a label sized to its own content would put the colour column
        // at a different x on every row.
        let swatchColumns = rows(of: table).map { row in
            row.subviews.last.map { row.convert($0.frame.origin, to: table).x }
        }
        XCTAssertEqual(swatchColumns.count, 2)
        XCTAssertEqual(swatchColumns[0], swatchColumns[1], "the colour column starts at the same x whatever the name")
    }

    func testACategoryWithNoIconStillDrawsSomething() {
        let table = CategoryTable()
        table.show([category(1, "Break", icon: nil)])

        let images = rows(of: table).flatMap { $0.subviews }.compactMap { ($0 as? NSImageView)?.image }
        XCTAssertEqual(images.count, 1, "a gap would read as a column that failed to draw")
    }

    // MARK: - nothing to show

    func testAnEmptyListSaysSoAndDrawsNoColumns() {
        let table = CategoryTable()
        table.show([category(1, "Break")])

        table.show([])

        XCTAssertTrue(rows(of: table).isEmpty)
        XCTAssertNil(header(of: table), "columns with nothing under them are a table pretending to be empty")
        let labels = table.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["No active categories."])
    }

    // MARK: - the pane around it

    func testThePaneShowsWhatItIsGiven() {
        let pane = CategoriesPane()

        pane.show([category(1, "Break"), category(2, "Meeting")])

        XCTAssertEqual(pane.activeTable.shownCategories.map(\.name), ["Break", "Meeting"])
    }

    func testTheListSitsUnderTheHeadingAndSpansTheTab() throws {
        let pane = CategoriesPane()
        pane.show([category(1, "Break")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()

        let heading = try XCTUnwrap(
            pane.subviews.flatMap { $0.subviews }.first { $0.accessibilityIdentifier() == CategoriesPane.Identifier.activeHeading }
        )
        let table = pane.activeTable
        XCTAssertLessThan(
            table.frame.maxY, heading.frame.minY,
            "the list is below the heading: in this coordinate space, lower means a smaller y"
        )
        XCTAssertEqual(table.frame.width, heading.superview?.frame.width, "the list spans the section")
        XCTAssertGreaterThan(table.frame.height, 0, "a table with a row in it has a height")
    }
}
