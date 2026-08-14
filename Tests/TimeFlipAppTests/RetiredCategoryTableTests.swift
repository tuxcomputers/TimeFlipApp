@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the Inactive list and the two folding sections it arrived with.
///
/// A separate type from the Active list rather than the same one with columns hidden, so this is a separate set of
/// tests: what matters is that it draws a *narrower* row, and that nothing on it offers an edit.
@MainActor
final class RetiredCategoryTableTests: XCTestCase {
    private func retired(_ id: Int, _ name: String) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: "ic_break",
            colour: .red,
            usesWhiteLines: false,
            dailyLimitMinutes: 45,
            isActive: false
        )
    }

    /// Every view under `root`, at any depth. Recursive rather than a fixed chain of `flatMap`s: the panel, its
    /// content view and the stack inside it are containers rather than layers of meaning, and counting them is how a
    /// test comes to fail because a view was wrapped in another one.
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func rows(of table: RetiredCategoryTable) -> [RetiredCategoryRow] {
        descendants(of: table).compactMap { $0 as? RetiredCategoryRow }
    }

    private func labels(of table: RetiredCategoryTable) -> [String] {
        descendants(of: table).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func header(of table: RetiredCategoryTable) -> NSView? {
        descendants(of: table).first { $0.accessibilityIdentifier() == RetiredCategoryTable.Identifier.header }
    }

    // MARK: - the rows

    func testEachRetiredCategoryGetsARow() {
        let table = RetiredCategoryTable()

        table.show([retired(3, "Old"), retired(4, "Older")])

        XCTAssertEqual(rows(of: table).map(\.category.name), ["Old", "Older"])
        XCTAssertEqual(table.shownCategories.count, 2)
    }

    func testEveryRowIsNamedForItsCategoryAndNotForTheOtherLists() {
        let table = RetiredCategoryTable()

        table.show([retired(7, "Old")])

        let row = rows(of: table).first
        XCTAssertEqual(row?.accessibilityIdentifier(), "retired-category-row-7")
        // Three lists can hold the same category, so all three name their rows differently: a step cannot press one
        // believing it addressed another.
        XCTAssertNotEqual(row?.accessibilityIdentifier(), CategoryTable.Identifier.row(retired(7, "Old")))
        XCTAssertNotEqual(row?.accessibilityIdentifier(), CategoryListView.Identifier.row(retired(7, "Old")))
    }

    func testARowIsANarrowerThingThanAnActiveOne() throws {
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])

        let row = try XCTUnwrap(rows(of: table).first)

        // The box, the name and the date, and nothing else. The icon, the colour and the limit describe what it
        // *was*, and drawing them invites an edit that means nothing.
        XCTAssertTrue(descendants(of: row).compactMap { $0 as? NSImageView }.isEmpty, "no icon")
        XCTAssertTrue(descendants(of: row).compactMap { $0 as? SteppedNumberField }.isEmpty, "no daily limit")
        XCTAssertEqual(descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }.count, 2)
    }

    // MARK: - last used

    func testTheDateIsWhateverItIsToldAndFormattedForReading() throws {
        let table = RetiredCategoryTable()
        let moment = Date(timeIntervalSince1970: 1_786_600_000)
        table.lastUsed = { _ in moment }

        table.show([retired(3, "Old")])

        let expected = CategoryLastUsedText.defaultFormatter.string(from: moment)
        XCTAssertTrue(labels(of: table).contains(expected))
    }

    func testACategoryThatNeverRecordedTimeSaysSo() {
        let table = RetiredCategoryTable()
        table.lastUsed = { _ in nil }

        table.show([retired(3, "Old")])

        // Not blank: an empty cell reads as something that failed to load, where the interesting fact is that there
        // is genuinely nothing behind this row.
        XCTAssertTrue(labels(of: table).contains(CategoryLastUsedText.neverUsed))
    }

    func testTheDateIsAskedForPerRowRatherThanOnce() {
        let table = RetiredCategoryTable()
        var asked: [Int] = []
        table.lastUsed = { category in
            asked.append(category.id)
            return nil
        }

        table.show([retired(3, "Old"), retired(4, "Older")])

        XCTAssertEqual(asked, [3, 4])
    }

    // MARK: - the columns and the empty case

    func testTheColumnsAreActiveNameAndLastUsed() throws {
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])

        let captions = try XCTUnwrap(header(of: table)).subviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
        // Active leads: in the Active list that box is the far end of a row full of settings, and here there are no
        // settings, so putting it first makes it the point of the row rather than something to read past.
        XCTAssertEqual(captions, ["Active", "Name", CategoryLastUsedText.columnTitle])
    }

    // MARK: - bringing one back

    private func activeBox(of row: RetiredCategoryRow) -> NSButton? {
        row.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first
    }

    func testTheBoxIsUntickedAndTickingItReportsTheCategory() throws {
        let table = RetiredCategoryTable()
        var reinstated: String?
        table.onReinstate = { reinstated = $0.name }
        table.show([retired(3, "Old")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertEqual(box.state, .off, "this is the retired list, so nothing in it is active")

        box.performClick(nil)

        XCTAssertEqual(reinstated, "Old")
    }

    func testTheBoxIsNeverDisabled() throws {
        // Unlike its opposite number on the Active list. Retiring is barred while a locked face holds the category,
        // because retiring clears faces; reinstating puts nothing on any face, and a database written before that
        // rule can hold exactly that case.
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertTrue(box.isEnabled)
        XCTAssertNil(box.toolTip)
    }

    func testAnEmptyListSaysSoAndDrawsNoColumns() {
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])

        table.show([])

        XCTAssertTrue(rows(of: table).isEmpty)
        XCTAssertNil(header(of: table))
        XCTAssertEqual(labels(of: table), ["No inactive categories."])
    }

    // MARK: - the sections around them

    func testActiveOpensAndInactiveIsFoldedAway() {
        let pane = CategoriesPane()

        // Active is the section somebody works in; Inactive is an archive to go looking in occasionally.
        XCTAssertTrue(pane.activeSection.isExpanded)
        XCTAssertFalse(pane.inactiveSection.isExpanded)
        XCTAssertFalse(pane.activeTable.isHidden)
        XCTAssertTrue(pane.retiredTable.isHidden, "a hidden arranged view collapses, so the section is its heading")
    }

    func testFoldingASectionHidesItsListAndSaysSo() {
        let pane = CategoriesPane()
        var reported: [Bool] = []
        pane.activeSection.onToggle = { reported.append($0) }

        pane.activeSection.setExpanded(false)
        XCTAssertTrue(pane.activeTable.isHidden)

        pane.inactiveSection.setExpanded(true)
        XCTAssertFalse(pane.retiredTable.isHidden)

        // setExpanded is the answer, not the announcement: only a click reports outward.
        XCTAssertTrue(reported.isEmpty)
    }

    func testThePaneShowsBothLists() {
        let pane = CategoriesPane()

        pane.show(
            active: [CategoryRecord(
                id: 1, name: "Break", iconName: nil, colour: nil,
                usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            )],
            inactive: [retired(3, "Old")]
        )

        XCTAssertEqual(pane.activeTable.shownCategories.map(\.name), ["Break"])
        XCTAssertEqual(pane.retiredTable.shownCategories.map(\.name), ["Old"])
    }
}
