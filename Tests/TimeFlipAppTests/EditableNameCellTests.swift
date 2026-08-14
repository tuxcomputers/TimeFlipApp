@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the click-to-edit name: how an edit opens, and the three ways it ends.
///
/// Hosted in a window for every test that focuses or clicks, per the note in `Tests/Methods.md`: `performClick` does
/// nothing at all without one, silently, so a test would otherwise pass or fail on whether some other test happened
/// to make a window first.
@MainActor
final class EditableNameCellTests: XCTestCase {
    private func cell(_ name: String = "Break") -> EditableNameCell {
        EditableNameCell(name: name, width: 160, identifier: "category-name-1")
    }

    private func nameButton(of cell: EditableNameCell) -> NSButton? {
        cell.subviews.compactMap { $0 as? NSButton }.first
    }

    private func field(of cell: EditableNameCell) -> NSTextField? {
        cell.subviews.compactMap { $0 as? NSTextField }.first
    }

    // MARK: - opening it

    func testItDrawsTheNameAndNoFieldUntilItIsClicked() throws {
        let cell = cell()

        XCTAssertFalse(try XCTUnwrap(nameButton(of: cell)).isHidden)
        XCTAssertTrue(try XCTUnwrap(field(of: cell)).isHidden)
        XCTAssertFalse(cell.isEditing)
    }

    func testTheNameLivesInsideTheButtonSoAClickOnTheWordCounts() throws {
        // A click on a label goes up the responder chain to the label's own superview, so a button merely behind it
        // is never pressed (see `Tests/Methods.md`, and the folding headings that shipped with exactly that fault).
        let button = try XCTUnwrap(nameButton(of: cell()))

        XCTAssertEqual(button.subviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["Break"])
        XCTAssertFalse(button.isBordered, "and it still reads as a name rather than a row of controls")
    }

    func testTheOnlyHintIsATooltipAndAName() throws {
        // The gesture is hidden by design -- a column of buttons would read as controls -- so the two things that can
        // say so without drawing anything do.
        let button = try XCTUnwrap(nameButton(of: cell()))

        XCTAssertEqual(button.toolTip, "Click to rename")
        XCTAssertEqual(button.accessibilityLabel(), "Break, click to rename")
        XCTAssertEqual(button.accessibilityIdentifier(), "category-name-1")
    }

    func testClickingTheNameOpensAFieldHoldingIt() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()

        try XCTUnwrap(nameButton(of: cell)).performClick(nil)

        XCTAssertTrue(cell.isEditing)
        XCTAssertTrue(try XCTUnwrap(nameButton(of: cell)).isHidden)
        let field = try XCTUnwrap(field(of: cell))
        XCTAssertFalse(field.isHidden)
        // Pre-filled, so a correction is a correction rather than retyping the whole name.
        XCTAssertEqual(field.stringValue, "Break")
        XCTAssertEqual(field.accessibilityIdentifier(), "category-name-1-field")
    }

    func testOpeningItSaysSoSoTheWindowCanLendItEscape() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        var reported: [Bool] = []
        cell.onEditingChanged = { reported.append($0) }

        cell.beginEditing()
        cell.endEditing()

        XCTAssertEqual(reported, [true, false])
    }

    func testOpeningTwiceChangesNothing() {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        var reported: [Bool] = []
        cell.onEditingChanged = { reported.append($0) }

        cell.beginEditing()
        cell.beginEditing()

        XCTAssertEqual(reported, [true], "the second one is not a new edit, and would report one that never opened")
    }

    // MARK: - ending it

    func testReturnCommitsWhatWasTyped() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        var committed: String?
        cell.onCommit = { committed = $0 }
        cell.beginEditing()

        try XCTUnwrap(field(of: cell)).stringValue = "Admin"
        endEditing(cell, movement: .return)

        XCTAssertEqual(committed, "Admin")
        XCTAssertFalse(cell.isEditing, "and the field closes: what happens next is a dialogue, not more typing")
    }

    func testLosingFocusAbandonsRatherThanCommitting() throws {
        // The distinction the whole thing turns on: an NSTextField's action and its end-editing notification both
        // fire on Return *and* on losing focus. Committing on the way out would raise a dialogue about a rename
        // nobody asked for, on top of whatever they were reaching for.
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        var committed: String?
        cell.onCommit = { committed = $0 }
        cell.beginEditing()

        try XCTUnwrap(field(of: cell)).stringValue = "Admin"
        endEditing(cell, movement: .other)

        XCTAssertNil(committed)
        XCTAssertFalse(cell.isEditing)
    }

    func testEscapeAbandonsIt() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        var committed: String?
        cell.onCommit = { committed = $0 }
        cell.beginEditing()
        let field = try XCTUnwrap(field(of: cell))
        field.stringValue = "Admin"

        let handled = cell.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(handled, "the field has to eat the key, or the window closes behind it")
        XCTAssertFalse(cell.isEditing)
        XCTAssertNil(committed)
    }

    func testAnotherKeyIsLeftAlone() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        cell.beginEditing()

        let handled = cell.control(
            try XCTUnwrap(field(of: cell)),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveLeft(_:))
        )

        XCTAssertFalse(handled)
        XCTAssertTrue(cell.isEditing, "moving the caret is not leaving")
    }

    func testTheNameOnScreenIsUnchangedByAnEdit() throws {
        // What a commit does is ask. The name changes when the table has been written and the row read back, so a
        // cell that redrew itself here would be a second answer to what the category is called.
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        cell.beginEditing()
        try XCTUnwrap(field(of: cell)).stringValue = "Admin"
        endEditing(cell, movement: .return)

        let button = try XCTUnwrap(nameButton(of: cell))
        XCTAssertEqual(button.subviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["Break"])
    }

    // MARK: - the click that lands somewhere else

    func testAClickInsideTheFieldIsNotAClickElsewhere() throws {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()
        cell.beginEditing()
        cell.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(field(of: cell))
        let inside = cell.convert(NSPoint(x: field.frame.midX, y: field.frame.midY), to: nil)
        XCTAssertFalse(cell.isOutsideField(windowPoint: inside), "a click to place the caret is not a click away")
    }

    func testAClickBeyondTheFieldIsAClickElsewhere() {
        let cell = cell()
        let window = OffscreenWindow.host(cell)
        defer { window.close() }
        cell.layoutSubtreeIfNeeded()
        cell.beginEditing()
        cell.layoutSubtreeIfNeeded()

        XCTAssertTrue(cell.isOutsideField(windowPoint: NSPoint(x: 5_000, y: 5_000)))
    }

    /// Ends the edit the way AppKit does, with the movement that says which way it ended.
    private func endEditing(_ cell: EditableNameCell, movement: NSTextMovement) {
        cell.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: field(of: cell),
                userInfo: ["NSTextMovement": movement.rawValue]
            )
        )
    }
}
