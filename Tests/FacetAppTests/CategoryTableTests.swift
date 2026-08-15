@testable import FacetApp
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
        colourID: Int = 0,
        limit: Int = 0
    ) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: icon,
            colourID: colourID,
            colour: colour,
            usesWhiteLines: false,
            dailyLimitMinutes: limit,
            isActive: true
        )
    }

    /// Every view under `root`, at any depth. Recursive rather than a fixed chain of `flatMap`s, per the note in
    /// `Tests/Methods.md`: a column that grows a wrapper -- the swatch gaining the button that opens the palette --
    /// should not make a test fail for the depth it sits at.
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func rows(of table: CategoryTable) -> [CategoryTableRow] {
        // Searched rather than walked down a fixed chain of `subviews`: this counted the box the list used to draw
        // its own tint on, and every one of these tests broke on the day that box moved out to the section.
        descendants(of: table).compactMap { $0 as? CategoryTableRow }
    }

    private func header(of table: CategoryTable) -> NSView? {
        descendants(of: table).first { $0.accessibilityIdentifier() == CategoryTable.Identifier.header }
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
            // The archive's five columns and its wording, with Active moved to the front to match the Inactive
            // list. No caption over the icon, there being nothing useful to call it; the limit's says what 0 means,
            // since a limit of nothing and no limit at all are opposites.
            ["Active", "Name", "Colour", "Daily limit (0 = disabled)"],
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

    // MARK: - a locked face holds the whole row

    private func lockedRow(_ name: String = "Break") -> (CategoryTable, CategoryTableRow) {
        let table = CategoryTable()
        table.facesHolding = { _ in [(face: 8, isLocked: true)] }
        table.show([category(1, name, limit: 45)])
        // swiftlint:disable:next force_unwrapping
        return (table, rows(of: table).first!)
    }

    func testALockedFaceRefusesTheIcon() throws {
        let (table, row) = lockedRow()
        var asked = false
        table.onPickIcon = { _, _ in asked = true }

        let button = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier().hasPrefix("category-icon-") }
        )
        button.performClick(nil)

        XCTAssertFalse(asked, "the picker would offer an edit the row cannot make")
        // Still drawn as it was, and still explaining itself: a disabled button greys its artwork and shows no
        // tooltip at all, which would lose both the icon and the reason.
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.toolTip?.contains("Face 8"), true)
    }

    func testALockedFaceRefusesTheColour() throws {
        let (table, row) = lockedRow()
        var asked = false
        table.onPickColour = { _, _ in asked = true }

        let button = try XCTUnwrap(swatchButton(of: row))
        button.performClick(nil)

        XCTAssertFalse(asked)
        XCTAssertTrue(button.isEnabled, "a greyed swatch would be a different colour, which is a different fact")
        XCTAssertEqual(button.toolTip?.contains("Face 8"), true)
    }

    func testALockedFaceRefusesTheName() throws {
        let (_, row) = lockedRow()

        let cell = try XCTUnwrap(nameCell(of: row))
        cell.beginEditing()

        XCTAssertFalse(cell.isEditing, "clicking the name opens nothing")
        XCTAssertEqual(cell.disabledHelp?.contains("Face 8"), true)
    }

    func testALockedFaceTurnsTheDailyLimitOffAndStillShowsIt() throws {
        let (_, row) = lockedRow()

        let field = try XCTUnwrap(limitField(of: row))
        XCTAssertFalse(field.isEnabled)
        // The value is worth reading where it cannot be changed, so it is greyed rather than blanked.
        XCTAssertEqual(field.value, 45)
        XCTAssertEqual(field.disabledHelp?.contains("Face 8"), true)
    }

    func testOneLockedFaceIsEnoughEvenWhenOtherFacesHoldItUnlocked() throws {
        // The case the database is actually in: Break sits on face 8, which is locked, and on faces 13 and 14, which
        // are not. **One locked face freezes the row.** Editing the category changes what face 8 shows -- its name,
        // its artwork, the colour it lights -- and that face has been told to keep what it has. The unlocked faces
        // are no argument against it: they are not asking for anything.
        let table = CategoryTable()
        table.facesHolding = { _ in
            [(face: 8, isLocked: true), (face: 13, isLocked: false), (face: 14, isLocked: false)]
        }
        table.show([category(1, "Break", limit: 45)])
        let row = try XCTUnwrap(rows(of: table).first)

        XCTAssertFalse(try XCTUnwrap(activeBox(of: row)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(limitField(of: row)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(nameCell(of: row)).isEnabled)
        XCTAssertEqual(row.editRefusal, .lockedFaces([8]), "and only the locked one is named")
        // Which is what the tooltip says, so the two unlocked faces are not paraded as reasons.
        let help = try XCTUnwrap(try XCTUnwrap(nameCell(of: row)).disabledHelp)
        XCTAssertTrue(help.contains("Face 8 is"), help)
        XCTAssertFalse(help.contains("13"), help)
    }

    func testAnUnlockedRowLeavesEveryControlAlone() throws {
        let table = CategoryTable()
        table.facesHolding = { _ in [(face: 13, isLocked: false)] }
        table.show([category(1, "Break", limit: 45)])
        let row = try XCTUnwrap(rows(of: table).first)

        XCTAssertTrue(try XCTUnwrap(limitField(of: row)).isEnabled)
        XCTAssertNil(try XCTUnwrap(limitField(of: row)).disabledHelp)
        XCTAssertTrue(try XCTUnwrap(nameCell(of: row)).isEnabled)
        XCTAssertNil(try XCTUnwrap(swatchButton(of: row)).toolTip)
        XCTAssertTrue(try XCTUnwrap(activeBox(of: row)).isEnabled)
    }

    func testEveryControlInALockedRowSaysTheSameThing() throws {
        // Whichever is reached for first is the one that has to explain itself, and one wording means one fact.
        let (_, row) = lockedRow()
        let expected = CategoryEditRules.editRefusalHelp(.lockedFaces([8]), categoryName: "Break")

        XCTAssertEqual(try XCTUnwrap(activeBox(of: row)).toolTip, expected)
        XCTAssertEqual(try XCTUnwrap(swatchButton(of: row)).toolTip, expected)
        XCTAssertEqual(try XCTUnwrap(nameCell(of: row)).disabledHelp, expected)
        XCTAssertEqual(try XCTUnwrap(limitField(of: row)).disabledHelp, expected)
    }

    func testAnUnlockedFaceLeavesTheBoxAlone() throws {
        let table = CategoryTable()
        table.facesHolding = { _ in [(face: 13, isLocked: false), (face: 14, isLocked: false)] }
        table.show([category(1, "Break")])

        let box = try XCTUnwrap(activeBox(of: try XCTUnwrap(rows(of: table).first)))
        XCTAssertTrue(box.isEnabled)
        XCTAssertNil(box.toolTip)
    }

    // MARK: - the colour swatch

    private func swatchButton(of row: CategoryTableRow) -> NSButton? {
        descendants(of: row).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier().hasPrefix("category-colour-") }
    }

    func testClickingTheSwatchAsksForThePaletteAnchoredToIt() throws {
        let table = CategoryTable()
        var asked: (name: String, anchor: NSView)?
        table.onPickColour = { asked = ($0.name, $1) }
        table.show([category(1, "Break")])
        let row = try XCTUnwrap(rows(of: table).first)

        let button = try XCTUnwrap(swatchButton(of: row))
        button.performClick(nil)

        XCTAssertEqual(asked?.name, "Break")
        // The button itself, not the row: a popover has to hang under the square that was clicked, and this list is
        // the only thing that knows which view that is.
        XCTAssertIdentical(asked?.anchor, button)
    }

    func testTheSwatchIsInsideTheButtonSoAClickOnTheSquareCounts() throws {
        let table = CategoryTable()
        table.show([category(1, "Break")])
        let row = try XCTUnwrap(rows(of: table).first)

        let button = try XCTUnwrap(swatchButton(of: row))
        // Drawn by the square, pressed by the button around it. `ColourSwatch` handles no mouse event of its own, so
        // a click on it reaches the button holding it.
        XCTAssertTrue(button.subviews.contains { $0 is ColourSwatch })
        XCTAssertFalse(button.isBordered, "a bordered button here would read as a control in a column of readings")
    }

    func testASwatchWithNoColourSaysSoOutLoud() throws {
        let table = CategoryTable()
        table.show([category(1, "Break", colour: nil), category(2, "Meeting", colour: .red)])

        let labels = rows(of: table).compactMap { swatchButton(of: $0)?.accessibilityLabel() }
        // Nothing on screen distinguishes a hollow square from a pale one to a screen reader.
        XCTAssertEqual(labels, ["Break colour, none", "Meeting colour"])
    }

    // MARK: - the name

    private func nameCell(of row: CategoryTableRow) -> EditableNameCell? {
        descendants(of: row).compactMap { $0 as? EditableNameCell }.first
    }

    func testACommittedNameIsReportedWithItsCategory() throws {
        let table = CategoryTable()
        var asked: (name: String, typed: String)?
        table.onRename = { asked = ($0.name, $1) }
        table.show([category(1, "Break"), category(2, "Meeting")])

        let cell = try XCTUnwrap(nameCell(of: try XCTUnwrap(rows(of: table).last)))
        cell.onCommit?("Standup")

        // The row it came from, not whichever was edited last: two rows are editing the same column.
        XCTAssertEqual(asked?.name, "Meeting")
        XCTAssertEqual(asked?.typed, "Standup")
    }

    func testTheTableSaysWhenANameIsBeingEdited() throws {
        let table = CategoryTable()
        var reported: [Bool] = []
        table.onRenameEditingChanged = { reported.append($0) }
        table.show([category(1, "Break")])

        try XCTUnwrap(nameCell(of: try XCTUnwrap(rows(of: table).first))).onEditingChanged?(true)

        XCTAssertEqual(reported, [true], "which is what lends the field Escape, the Close button holding it otherwise")
    }

    func testTheColumnsLineUpWithTheirCaptions() throws {
        let table = CategoryTable()
        table.show([category(1, "Break"), category(2, "A much longer category name than the first")])
        table.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        table.layoutSubtreeIfNeeded()

        // The point of fixing the name column's width: a label sized to its own content would put the colour column
        // at a different x on every row. Found by what it holds rather than by position, so a column added before it
        // cannot turn this into an assertion about something else.
        let swatchColumns = rows(of: table).map { row -> CGFloat? in
            row.subviews
                .first { descendants(of: $0).contains { $0 is ColourSwatch } }
                .map { row.convert($0.frame.origin, to: table).x }
        }
        XCTAssertEqual(swatchColumns.count, 2)
        XCTAssertNotNil(swatchColumns[0])
        XCTAssertEqual(swatchColumns[0], swatchColumns[1], "the colour column starts at the same x whatever the name")
    }

    func testTheActiveBoxLeadsTheRowAndLinesUpWithTheInactiveList() throws {
        let table = CategoryTable()
        table.show([category(1, "Break")])
        // Laid out before measuring: a constraint is a promise about a frame, and nothing has produced one yet.
        table.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        table.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(rows(of: table).first)

        // First, matching the Inactive list. The archive put it last here on the reading that a row of settings ends
        // with its toggle, which is true of either list alone and wrong once the two are stacked on one tab: the box
        // means the same thing in both, so it should be one column running down the tab.
        let box = try XCTUnwrap(activeBox(of: row))
        XCTAssertEqual(row.subviews.first, box.superview, "the box's own column is the leading one")

        // Both lists hold that column open at the same width, so the boxes land at the same x.
        XCTAssertEqual(box.superview?.frame.width, CategoryTable.Layout.activeColumnWidth)
    }

    func testACategoryWithNoIconStillDrawsSomething() {
        let table = CategoryTable()
        table.show([category(1, "Break", icon: nil)])

        // The icon is a button now, since it opens the picker, so what draws the "no sign" glyph is its image.
        let images = rows(of: table).flatMap { $0.subviews }.compactMap { ($0 as? NSButton)?.image }
        XCTAssertEqual(images.count, 1, "a gap would read as a column that failed to draw")
    }

    // MARK: - nothing to show

    func testAnEmptyListSaysSoAndDrawsNoColumns() {
        let table = CategoryTable()
        table.show([category(1, "Break")])

        table.show([])

        XCTAssertTrue(rows(of: table).isEmpty)
        XCTAssertNil(header(of: table), "columns with nothing under them are a table pretending to be empty")
        let labels = descendants(of: table).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["No active categories."])
    }

    // MARK: - the pane around it

    func testThePaneOffersToCreateACategory() {
        let pane = CategoriesPane()

        // The same control the Faces tab has, not a second implementation of creating one: the window wires both to
        // the same rules and the same writer.
        XCTAssertEqual(pane.createControl.createButton.title, "Create")
        XCTAssertFalse(pane.createControl.isEditing, "collapsed until it is clicked")
    }

    func testTheCreateControlSitsUnderTheList() {
        let pane = CategoriesPane()
        pane.show(active: [category(1, "Break")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()

        // Converted into the pane, because the table is inside the section view and the control is not: two frames
        // read straight off `frame` would be measured against different origins and compare as nonsense.
        let listBottom = pane.activeTable.convert(pane.activeTable.bounds, to: pane).minY
        // Under the list rather than inside it, which is the archive's placement: in the gap between the two lists,
        // so it belongs to the tab rather than to one section of it.
        XCTAssertLessThan(
            pane.createControl.frame.maxY, listBottom,
            "lower means a smaller y in this coordinate space"
        )
    }

    func testTheListSpansTheWindow() throws {
        // The rule in CLAUDE.md, for every tab, checked on this one as well as the App tab: a panel is inset by the
        // tab's own padding and nothing more. Hosted the way `NSTabView` hosts a pane, because that is the only
        // arrangement in which the fault appears -- a pane on its own keeps whatever frame it is handed.
        let pane = CategoriesPane()
        pane.show(active: [category(1, "Break")], inactive: [])
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.frame.width, 640)
        // The tinted panel is what the rule is about, and it is the section's rather than the list's: the list sits
        // inside it, held off both edges by the panel's own padding.
        let panel = content.convert(pane.activeSection.panel.bounds, from: pane.activeSection.panel)
        XCTAssertEqual(panel.minX, 20, accuracy: 0.5)
        XCTAssertEqual(panel.maxX, 620, accuracy: 0.5)

        let list = content.convert(pane.activeTable.bounds, from: pane.activeTable)
        XCTAssertEqual(list.minX, panel.minX + CategoryTable.Layout.padding, accuracy: 0.5)
        XCTAssertEqual(list.maxX, panel.maxX - CategoryTable.Layout.padding, accuracy: 0.5)
    }

    func testThePaneShowsWhatItIsGiven() {
        let pane = CategoriesPane()

        pane.show(active: [category(1, "Break"), category(2, "Meeting")])

        XCTAssertEqual(pane.activeTable.shownCategories.map(\.name), ["Break", "Meeting"])
    }

    func testTheListSitsUnderTheHeadingAndSpansTheTab() throws {
        let pane = CategoriesPane()
        pane.show(active: [category(1, "Break")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()

        let section = pane.activeSection!
        // Inside the heading button rather than beside it, which is what makes a click on the word fold the section.
        let heading = try XCTUnwrap(
            descendants(of: section).first { $0.accessibilityIdentifier() == CategoriesPane.Identifier.activeHeading }
        )
        let table = pane.activeTable
        // Converted, because the label is measured in its button's space and the table in the section's: comparing
        // the two directly does not error, it just answers about different origins (see `Tests/Methods.md`).
        let headingFrame = section.convert(heading.bounds, from: heading)
        XCTAssertLessThan(
            table.frame.maxY, headingFrame.minY,
            "the list is below the heading: in this coordinate space, lower means a smaller y"
        )
        XCTAssertEqual(
            table.frame.width, section.frame.width - 2 * CategoryTable.Layout.padding,
            "the list spans the section, inset by the panel's padding"
        )
        XCTAssertGreaterThan(table.frame.height, 0, "a table with a row in it has a height")
    }

    func testTheHeadingSitsOnTheSamePanelAsTheList() throws {
        // What the archive drew: each section was a `Section` of a grouped form, and a grouped form's box holds the
        // disclosure label as its first row. So the tint runs from above the heading to below the last category.
        let pane = CategoriesPane()
        pane.show(active: [category(1, "Break")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()

        let section = pane.activeSection!
        let heading = try XCTUnwrap(
            descendants(of: section).first { $0.accessibilityIdentifier() == CategoriesPane.Identifier.activeHeading }
        )
        let panel = section.convert(section.panel.bounds, from: section.panel)
        XCTAssertTrue(
            panel.contains(section.convert(heading.bounds, from: heading)),
            "the words are on the tint, not above it"
        )
        XCTAssertTrue(panel.contains(pane.activeTable.frame), "and so is the list under them")

        // Behind both, so a click still reaches the heading line: AppKit hit-tests later subviews first.
        XCTAssertEqual(section.subviews.first, section.panel)
    }

    func testAFoldedSectionIsOnlyItsHeading() {
        // Hiding the list is not enough on its own: Auto Layout does not care that a view is hidden, and this
        // measured 150pt open and 150pt shut until the section's bottom moved up to the heading with it. Invisible
        // against a plain background, an empty tinted box now.
        let pane = CategoriesPane()
        pane.show(active: [category(1, "Break"), category(2, "Meeting")])
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        let open = pane.activeSection.frame.height

        pane.activeSection.setExpanded(false)
        pane.layoutSubtreeIfNeeded()

        XCTAssertLessThan(pane.activeSection.frame.height, open)
        XCTAssertEqual(
            pane.activeSection.frame.height, pane.activeSection.panel.frame.height,
            "the panel closes around the heading rather than staying open over nothing"
        )
    }
}
