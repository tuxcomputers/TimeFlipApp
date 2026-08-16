@testable import FacetApp
import AppKit
import XCTest

/// Covers the Inactive list and the two folding sections it arrived with.
///
/// A separate type from the Active list rather than the same one with columns hidden, so this is a separate set of
/// tests: what matters is that it draws a *narrower* row, and that the only two things on it are the two a retired
/// category still has answers for -- bringing it back, and what it is called.
@MainActor
final class RetiredCategoryTableTests: XCTestCase {
    private func retired(_ id: Int, _ name: String) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: "ic_break",
            colourID: 0, colour: .red,
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
        // **What the row shows, not every text field under it.** The name is an `EditableNameCell` and carries its
        // own editor, hidden until the name is clicked, so a bare count of text fields counts the rename this row has
        // gained rather than a column it draws. Two columns of words is the claim, and it survived the name becoming
        // editable, which is the point: this row is still a record with one thing to correct on it.
        XCTAssertEqual(
            descendants(of: row).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.count, 2
        )
    }

    // MARK: - renaming a retired category

    func testTheNameOpensForEditing() throws {
        // The one edit this list offers. A retired row is a record, but a record with the wrong name on it is worth
        // correcting -- and where several retired rows share a name, correcting one is the only way to keep them
        // apart once the Last used column has told them apart.
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])
        let cell = try XCTUnwrap(rows(of: table).first?.nameCell)

        // Hosted, because `performClick` needs a window and a size and macOS 15 enforces both -- see Methods.md.
        let window = OffscreenWindow.host(table)
        defer { window.close() }
        table.layoutSubtreeIfNeeded()
        cell.beginEditing()

        XCTAssertTrue(cell.isEditing)
        XCTAssertTrue(cell.isEnabled, "never disabled: a rename touches no face, so a lock has nothing to protect")
    }

    func testACommittedNameIsReportedWithItsCategory() throws {
        let table = RetiredCategoryTable()
        var asked: (name: String, typed: String)?
        table.onRename = { asked = ($0.name, $1) }
        table.show([retired(3, "Old"), retired(4, "Older")])

        let cell = try XCTUnwrap(rows(of: table).last?.nameCell)
        cell.onCommit?("Older still")

        // The row it came from, not whichever was edited last: every row is editing the same column.
        XCTAssertEqual(asked?.name, "Older")
        XCTAssertEqual(asked?.typed, "Older still")
    }

    func testTheTableSaysWhenANameIsBeingEdited() throws {
        let table = RetiredCategoryTable()
        var reported: [Bool] = []
        table.onRenameEditingChanged = { reported.append($0) }
        table.show([retired(3, "Old")])

        try XCTUnwrap(rows(of: table).first?.nameCell).onEditingChanged?(true)

        XCTAssertEqual(reported, [true], "which is what lends the field Escape, the Close button holding it otherwise")
    }

    func testTheNameKeepsTheIdentifierItHadAsALabel() throws {
        // It was a plain label before it could be edited, and the scripted checks address it by this name. A rename
        // that renamed the element too would have broken every step that reads the Inactive list.
        let table = RetiredCategoryTable()
        table.show([retired(3, "Old")])

        XCTAssertTrue(
            descendants(of: table).contains { $0.accessibilityIdentifier() == "retired-category-name-3" }
        )
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
        XCTAssertTrue(pane.retiredTable.isHidden, "and the section's own bottom moves up to the heading with it")
    }

    func testTheWholeHeadingLineFoldsTheSectionRatherThanJustTheTriangle() throws {
        // The rule in CLAUDE.md, for every collapsible group the app grows: a triangle is a small target for a
        // gesture the heading beside it is obviously about.
        let pane = CategoriesPane()
        var reported: [Bool] = []
        pane.inactiveSection.onToggle = { reported.append($0) }

        let line = try XCTUnwrap(
            pane.inactiveSection.subviews
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier().hasSuffix("-heading-button") }
        )
        line.performClick(nil)

        XCTAssertTrue(pane.inactiveSection.isExpanded)
        XCTAssertFalse(pane.retiredTable.isHidden)
        XCTAssertEqual(reported, [true], "and it reports outward, as the triangle does")

        line.performClick(nil)
        XCTAssertFalse(pane.inactiveSection.isExpanded)
        XCTAssertEqual(reported, [true, false])
    }

    func testTheWordsAreInsideTheButtonRatherThanBesideIt() throws {
        // The part that cannot be got wrong. A click on a label goes up the responder chain to the label's own
        // *superview*, so a button merely sitting behind a sibling label is never reached -- which is how this
        // shipped: the heading looked right and a real click on the word "Inactive" produced no `debug_log` row at
        // all. The words are the button's own subview now.
        let pane = CategoriesPane()

        let line = try XCTUnwrap(
            pane.inactiveSection.subviews
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier().hasSuffix("-heading-button") }
        )
        XCTAssertTrue(
            line.subviews.contains { ($0 as? NSTextField)?.stringValue == "Inactive" },
            "the heading is inside the button that folds the section"
        )
    }

    func testTheHeadingButtonSpansTheRowBehindTheTriangle() throws {
        let pane = CategoriesPane()
        pane.show(active: [], inactive: [retired(3, "Old")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()

        let section = pane.inactiveSection!
        let line = try XCTUnwrap(
            section.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier().hasSuffix("-heading-button") }
        )
        XCTAssertEqual(
            line.frame.width, section.frame.width,
            "the words, the triangle, and the space after them, out to the panel's own edges"
        )
        // In front of the tint and behind the triangle: the panel would swallow a click on the padding either side of
        // the words, and the triangle has to keep drawing itself.
        XCTAssertEqual(section.subviews.first, section.panel)
        XCTAssertEqual(section.subviews.firstIndex(of: line), 1)
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
                id: 1, name: "Break", iconName: nil, colourID: 0, colour: nil,
                usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            )],
            inactive: [retired(3, "Old")]
        )

        XCTAssertEqual(pane.activeTable.shownCategories.map(\.name), ["Break"])
        XCTAssertEqual(pane.retiredTable.shownCategories.map(\.name), ["Old"])
    }
}
