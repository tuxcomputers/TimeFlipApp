@testable import FacetApp
import AppKit
import XCTest

/// Covers the icon picker: how the grid is laid out, what a click on a cell answers, and how a filename becomes a
/// name for a human.
///
/// The popover itself is not tested here and cannot be driven by a script at all -- it is absent from the
/// accessibility tree entirely (see `Tests/Methods.md`). What can be tested is everything inside it.
@MainActor
final class IconGridTests: XCTestCase {
    private func icons(_ count: Int) -> [IconRecord] {
        (1 ... count).map { IconRecord(id: $0, fileName: "ic_\($0)", name: "\($0)") }
    }

    private func cells(of grid: IconGrid) -> [IconGridCell] {
        grid.subviews.flatMap { $0.subviews }.flatMap { $0.subviews }.compactMap { $0 as? IconGridCell }
    }

    private func lines(of grid: IconGrid) -> [NSStackView] {
        grid.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSStackView }
    }

    // MARK: - the grid

    func testEveryIconGetsACell() {
        let grid = IconGrid(icons: icons(42), selected: nil)

        XCTAssertEqual(cells(of: grid).count, 42)
    }

    func testSixToARow() {
        // Not a preference: 42 icons are seeded, so six columns lay them out as an even 6 by 7 with no partial last
        // row and nothing to scroll.
        let grid = IconGrid(icons: icons(42), selected: nil)

        XCTAssertEqual(lines(of: grid).count, 7)
        XCTAssertEqual(lines(of: grid).map { $0.views.count }, Array(repeating: 6, count: 7))
    }

    func testAShortListFillsWhatItCanAndStops() {
        let grid = IconGrid(icons: icons(8), selected: nil)

        XCTAssertEqual(lines(of: grid).map { $0.views.count }, [6, 2], "no empty cells padding out the last row")
    }

    func testEveryCellIsNamedForItsIconAndSaysSoOutLoud() throws {
        let grid = IconGrid(icons: [IconRecord(id: 4, fileName: "ic_break", name: "Break")], selected: nil)

        let cell = try XCTUnwrap(cells(of: grid).first)
        XCTAssertEqual(cell.accessibilityIdentifier(), "icon-cell-ic_break")
        // The readable name, not the filename, which is not a thing to show anybody.
        XCTAssertEqual(cell.accessibilityLabel(), "Break")
        XCTAssertEqual(cell.toolTip, "Break")
    }

    func testTheChosenIconIsTheOneOutlined() throws {
        let grid = IconGrid(icons: icons(3), selected: "ic_2")

        let outlined = cells(of: grid).filter(\.isSelected)
        XCTAssertEqual(outlined.map(\.icon.fileName), ["ic_2"], "one cell, and it is the category's own")
        XCTAssertEqual(
            try XCTUnwrap(outlined.first).layer?.borderWidth,
            IconGrid.Layout.selectedStrokeWidth
        )
    }

    func testACategoryWithNoIconOutlinesNothing() {
        let grid = IconGrid(icons: icons(3), selected: nil)

        XCTAssertTrue(cells(of: grid).allSatisfy { !$0.isSelected })
    }

    // MARK: - what a click answers

    func testClickingAnIconPicksIt() throws {
        let grid = IconGrid(icons: icons(3), selected: "ic_2")
        var picked: Int?
        grid.onPick = { picked = $0 }

        try XCTUnwrap(cells(of: grid).first { $0.icon.fileName == "ic_3" }).performClick(nil)

        XCTAssertEqual(picked, 3)
    }

    func testClickingTheChosenIconClearsIt() throws {
        // The archive's rule, and the reason a grid with no None cell can still unset one: `icon_id` 0 is a sentinel
        // row rather than artwork, so there is nothing to draw in a cell for it.
        let grid = IconGrid(icons: icons(3), selected: "ic_2")
        var picked: Int?
        grid.onPick = { picked = $0 }

        try XCTUnwrap(cells(of: grid).first { $0.icon.fileName == "ic_2" }).performClick(nil)

        XCTAssertEqual(picked, CategoryEditRules.noIcon)
    }

    func testTheRuleIsAskedRatherThanRestated() {
        let grid = IconGrid(icons: icons(3), selected: "ic_2")

        // The grid resolves the category's filename to an id and hands the question to `CategoryEditRules`, so the
        // toggle cannot come to mean one thing here and another there.
        XCTAssertEqual(grid.selection(clicking: icons(3)[2]), CategoryEditRules.iconSelection(clicked: 3, selected: 2))
        XCTAssertEqual(grid.selection(clicking: icons(3)[1]), CategoryEditRules.iconSelection(clicked: 2, selected: 2))
    }

    // MARK: - naming an icon

    func testAFilenameBecomesAReadableName() {
        XCTAssertEqual(IconStore.displayName(for: "ic_admin"), "Admin")
        XCTAssertEqual(IconStore.displayName(for: "ic_deep_work"), "Deep Work")
        XCTAssertEqual(IconStore.displayName(for: "admin"), "Admin", "the prefix is optional")
    }
}
