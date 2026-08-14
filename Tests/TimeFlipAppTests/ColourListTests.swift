@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the colour picker: what the list holds, what a click on a row answers, and which row is ticked.
///
/// The popover around it is not tested here and cannot be driven by a script at all -- it is absent from the
/// accessibility tree entirely (see `Tests/Methods.md`). What can be tested is everything inside it.
@MainActor
final class ColourListTests: XCTestCase {
    private func colours(_ count: Int) -> [ColourRecord] {
        (1 ... count).map { ColourRecord(id: $0, name: "Colour \($0)", colour: .red, usesWhiteLines: false) }
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func rows(of list: ColourList) -> [ColourListRow] {
        descendants(of: list).compactMap { $0 as? ColourListRow }
    }

    // MARK: - the list

    func testEveryColourGetsARow() {
        let list = ColourList(colours: colours(20), selected: CategoryEditRules.noColour)

        XCTAssertEqual(rows(of: list).count, 20)
    }

    func testTheOrderIsThePalettesRatherThanAlphabetical() {
        // The ids run Red, Maroon, Brown, Tan ... which is a wheel somebody arranged. Sorting by name would scatter
        // the shades that belong beside each other.
        let palette = [
            ColourRecord(id: 1, name: "Red", colour: .red, usesWhiteLines: false),
            ColourRecord(id: 2, name: "Maroon", colour: .brown, usesWhiteLines: true),
            ColourRecord(id: 3, name: "Brown", colour: .brown, usesWhiteLines: true),
        ]

        let list = ColourList(colours: palette, selected: CategoryEditRules.noColour)

        XCTAssertEqual(rows(of: list).map(\.colour.name), ["Red", "Maroon", "Brown"])
    }

    func testEachRowCarriesItsNameBesideTheSquare() throws {
        // A colour is not recognisable the way a picture is: "Maroon" and "Brown" are one shade apart and nothing but
        // the word tells them apart, which is why this is a list and the icons are a grid.
        let list = ColourList(colours: [ColourRecord(id: 4, name: "Tan", colour: .orange, usesWhiteLines: false)], selected: 0)

        let row = try XCTUnwrap(rows(of: list).first)
        XCTAssertTrue(row.subviews.contains { $0 is ColourSwatch })
        XCTAssertEqual(row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["Tan"])
    }

    func testEveryRowIsNamedForItsColour() throws {
        let list = ColourList(colours: [ColourRecord(id: 4, name: "Tan", colour: .orange, usesWhiteLines: false)], selected: 0)

        let row = try XCTUnwrap(rows(of: list).first)
        XCTAssertEqual(row.accessibilityIdentifier(), "colour-option-Tan")
        XCTAssertEqual(row.accessibilityLabel(), "Tan")
    }

    // MARK: - which one is ticked

    func testTheChosenColourIsTheOneTicked() {
        let list = ColourList(colours: colours(3), selected: 2)

        XCTAssertEqual(rows(of: list).filter(\.isSelected).map(\.colour.id), [2], "one row, and it is the category's own")
    }

    func testACategoryWithNoColourTicksNothing() {
        let list = ColourList(colours: colours(3), selected: CategoryEditRules.noColour)

        XCTAssertTrue(rows(of: list).allSatisfy { !$0.isSelected })
        XCTAssertEqual(CategoryEditRules.noColour, 0)
    }

    func testTheTickIsWhatMarksItRatherThanTheFocusRing() throws {
        // The first row takes focus when the popover opens, and a focus ring there reads as a second selection
        // sitting beside the real one. The archive turned it off for that reason.
        let list = ColourList(colours: colours(3), selected: 2)

        let selected = try XCTUnwrap(rows(of: list).first { $0.isSelected })
        let plain = try XCTUnwrap(rows(of: list).first { !$0.isSelected })
        XCTAssertEqual(descendants(of: selected).compactMap { $0 as? NSImageView }.count, 1)
        XCTAssertTrue(descendants(of: plain).compactMap { $0 as? NSImageView }.isEmpty)
        XCTAssertEqual(selected.focusRingType, NSFocusRingType.none)
    }

    func testTheTickedRowSaysSoOutLoud() throws {
        let list = ColourList(colours: colours(3), selected: 2)

        let selected = try XCTUnwrap(rows(of: list).first { $0.isSelected })
        // A checkmark is an image, and an image reaches nobody using a screen reader.
        XCTAssertEqual(selected.accessibilityLabel(), "Colour 2, selected")
    }

    // MARK: - what a click answers

    func testClickingAColourPicksIt() throws {
        let list = ColourList(colours: colours(3), selected: 2)
        var picked: Int?
        list.onPick = { picked = $0 }

        try XCTUnwrap(rows(of: list).first { $0.colour.id == 3 }).performClick(nil)

        XCTAssertEqual(picked, 3)
    }

    func testClickingTheChosenColourClearsIt() throws {
        // The archive's rule, and the reason a list with no None row can still unset one: `colour_id` 0 is a sentinel
        // row with no hex, so there is nothing to draw in a row for it.
        let list = ColourList(colours: colours(3), selected: 2)
        var picked: Int?
        list.onPick = { picked = $0 }

        try XCTUnwrap(rows(of: list).first { $0.colour.id == 2 }).performClick(nil)

        XCTAssertEqual(picked, CategoryEditRules.noColour)
    }

    func testTheRuleIsAskedRatherThanRestated() {
        let list = ColourList(colours: colours(3), selected: 2)

        // The list hands the question to `CategoryEditRules`, so the toggle cannot come to mean one thing here and
        // another there.
        XCTAssertEqual(list.selection(clicking: colours(3)[2]), CategoryEditRules.colourSelection(clicked: 3, selected: 2))
        XCTAssertEqual(list.selection(clicking: colours(3)[1]), CategoryEditRules.colourSelection(clicked: 2, selected: 2))
    }

    func testTheRowItselfIsTheButtonSoAClickOnTheWordCounts() throws {
        // Not a button sitting behind the square and the word: a click on a label goes up the responder chain to the
        // label's *superview*, so a sibling button is never reached. Measured on the running app -- with the button
        // behind, a real click on the word stored nothing at all (see `Tests/Methods.md`).
        let list = ColourList(colours: colours(3), selected: 0)

        let row = try XCTUnwrap(rows(of: list).first)
        XCTAssertTrue(row.subviews.contains { $0 is NSTextField }, "the word is inside the button, not beside it")
        XCTAssertTrue(row.subviews.contains { $0 is ColourSwatch })
        XCTAssertFalse(row.isBordered, "and it still looks like a list rather than twenty buttons")
    }

    func testEveryRowIsAsWideAsTheWidestName() throws {
        // Otherwise a short name like "Red" gives a short row, and a click beside the word lands in a gap.
        let list = ColourList(
            colours: [
                ColourRecord(id: 1, name: "Red", colour: .red, usesWhiteLines: false),
                ColourRecord(id: 17, name: "Magenta", colour: .magenta, usesWhiteLines: false),
            ],
            selected: 0
        )
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        list.layoutSubtreeIfNeeded()

        let widths = Set(rows(of: list).map(\.frame.width))
        XCTAssertEqual(widths.count, 1, "one width, not one per name: \(widths)")
    }
}
