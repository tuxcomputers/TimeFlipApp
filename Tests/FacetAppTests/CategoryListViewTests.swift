@testable import FacetApp
import AppKit
import XCTest

/// Covers `CategoryListView`: that a list of categories becomes that many rows, in order, with a hairline
/// between each pair, and that showing a second list replaces the first.
///
/// No database and no window: the view is handed categories, which is the whole of its input.
@MainActor
final class CategoryListViewTests: XCTestCase {
    private func category(_ id: Int, _ name: String, icon: String? = "ic_break", colour: NSColor? = .red) -> CategoryRecord {
        CategoryRecord(id: id, name: name, iconName: icon, colourID: 0, colour: colour, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)
    }

    private func rowViews(of list: CategoryListView) -> [CategoryRowView] {
        // Reaching through the panel because that is where the rows live: the box is a container, not a
        // layer of meaning.
        list.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .compactMap { $0 as? CategoryRowView }
    }

    func testEachCategoryGetsARow() {
        let list = CategoryListView()

        list.show([category(1, "Break"), category(2, "Meeting"), category(3, "Admin")])

        XCTAssertEqual(rowViews(of: list).map(\.category.name), ["Break", "Meeting", "Admin"], "in order")
        XCTAssertEqual(list.shownCategories.count, 3)
    }

    func testThereIsAHairlineBetweenRowsAndNotAroundThem() {
        let list = CategoryListView()

        list.show([category(1, "Break"), category(2, "Meeting"), category(3, "Admin")])

        let separators = list.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSBox }
            .filter { $0.boxType == .separator }
        XCTAssertEqual(separators.count, 2, "three rows means two dividers, none above the first or below the last")
    }

    func testShowingAgainReplacesTheRows() {
        let list = CategoryListView()
        list.show([category(1, "Break"), category(2, "Meeting")])

        list.show([category(3, "Admin")])

        XCTAssertEqual(
            rowViews(of: list).map(\.category.name), ["Admin"],
            "a reread that appended would double the list every time the tab was opened"
        )
    }

    func testAnEmptyListDrawsNoRows() {
        let list = CategoryListView()
        list.show([category(1, "Break")])

        list.show([])

        XCTAssertTrue(rowViews(of: list).isEmpty)
    }

    func testARowIsNamedForItsCategory() {
        let row = CategoryRowView(category: category(7, "Meeting"))

        XCTAssertEqual(row.accessibilityIdentifier(), "category-row-7")
        XCTAssertEqual(row.accessibilityLabel(), "Meeting")
        // No `setAccessibilityElement(true)` here, unlike the plain views: a control is one already, and
        // `isAccessibilityElement()` reads false on it because the answer comes from the cell rather than the
        // view. The tree is what settles it, and it shows these as buttons carrying their identifiers.
    }

    func testARowIsTheSameHeightWhateverItHolds() {
        let withIcon = CategoryRowView(category: category(1, "Break"))
        let withoutIcon = CategoryRowView(category: category(2, "Bare", icon: nil, colour: nil))
        for row in [withIcon, withoutIcon] {
            row.frame = NSRect(x: 0, y: 0, width: 200, height: 0)
            row.layoutSubtreeIfNeeded()
        }

        // A category with no icon still fills the slot, so every name in the list lines up.
        XCTAssertEqual(withIcon.fittingSize.height, CategoryListView.Layout.rowHeight)
        XCTAssertEqual(withoutIcon.fittingSize.height, CategoryListView.Layout.rowHeight)
    }

    func testTheIconIsWhiteOnAColourThatNeedsIt() throws {
        let dark = CategoryRecord(id: 1, name: "Dark", iconName: "ic_break", colourID: 0, colour: .black, usesWhiteLines: true, dailyLimitMinutes: 0, isCategoryActive: true)
        let light = CategoryRecord(id: 2, name: "Light", iconName: "ic_break", colourID: 0, colour: .yellow, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)

        XCTAssertEqual(try iconTint(of: CategoryRowView(category: dark)), .white)
        XCTAssertEqual(try iconTint(of: CategoryRowView(category: light)), .black)
    }

    private func iconTint(of row: CategoryRowView) throws -> NSColor? {
        let imageView = row.subviews
            .flatMap { $0.subviews }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSImageView }
            .first
        return try XCTUnwrap(imageView, "the row should draw an icon at all").contentTintColor
    }

    // MARK: - picking one

    func testClickingARowReportsItsCategory() {
        let list = CategoryListView()
        // A click needs a window -- see `OffscreenWindow`.
        let window = OffscreenWindow.host(list, width: 240, height: 200)
        defer { _ = window }
        var picked: [String] = []
        list.onSelect = { picked.append($0.name) }
        list.show([category(1, "Break"), category(2, "Meeting")])

        rowViews(of: list).first { $0.category.name == "Meeting" }?.performClick(nil)

        XCTAssertEqual(picked, ["Meeting"], "the row reports which category, and decides nothing")
    }

    func testARowIsAButtonSoItIsReachableWithoutAMouse() throws {
        let list = CategoryListView()
        list.show([category(1, "Break")])

        // Not a view with a click handler bolted on: a real control, which is what makes it keyboard- and
        // script-reachable as well as clickable.
        //
        // **Asked of what being a control actually buys, rather than of the type.** `CategoryRowView` is declared
        // `: NSButton`, so `is NSButton` was true the instant a row existed and the assertion only ever proved the
        // list was not empty -- a clean build says as much, "succeeds whenever the value is non-nil". The two things
        // the declaration is *for* are below, and either of them going missing is the regression this guards.
        // **Target and action, which is the whole of what "a real control" buys.** Deliberately not the
        // accessibility role: a `CategoryRowView` outside a window answers `AXUnknown` rather than `AXButton`, and
        // whether that is true of one on screen is a question for the accessibility tree of a running app, not for
        // a view that has never been in a window. Asserting it here would pin an artefact.
        let row = try XCTUnwrap(rowViews(of: list).first)
        XCTAssertNotNil(row.action, "pressing it, by mouse or by keyboard or by script, does something")
        XCTAssertNotNil(row.target, "and there is something for it to do it to")
    }

    func testALongNameGivesWayRatherThanWideningTheList() throws {
        // **Measured on the running app**: a 56-character category name drew the Settings window 1295pt wide. A row
        // is as wide as the list, so the name has to take what is left of it -- and until the priority came down it
        // demanded its whole string instead, with nothing on the row to stop it.
        let list = CategoryListView()

        list.show([category(1, "When there is a long category it makes the windows wider")])

        let row = try XCTUnwrap(rowViews(of: list).first)
        let name = try XCTUnwrap(
            row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("When there is") }
        )
        XCTAssertEqual(
            name.contentCompressionResistancePriority(for: .horizontal), .defaultLow,
            "the name may still insist on its own width, which is what widened the window"
        )
        XCTAssertEqual(name.lineBreakMode, .byTruncatingTail, "and being squeezed has to end in an ellipsis, not a cut glyph")
        XCTAssertEqual(name.maximumNumberOfLines, 1, "a row is one line tall")
    }
}
