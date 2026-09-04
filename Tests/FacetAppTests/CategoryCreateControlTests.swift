@testable import FacetApp
import AppKit
import XCTest

/// Covers `CategoryCreateControl`: the swap between a Create button and a name field, and that it reports
/// the typed name rather than acting on it.
///
/// The state swap is worth testing because both halves being visible at once, or neither, is a layout
/// fault that fails nothing -- and because a control left in editing state after a save would show the
/// next person a field with the last name still in it.
@MainActor
final class CategoryCreateControlTests: XCTestCase, @unchecked Sendable {
    /// Kept alive for the length of a test: a click needs a window, and losing it takes the view's away.
    private var window: NSWindow?

    override func tearDown() {
        MainActor.assumeIsolated {
            window = nil
        }
        super.tearDown()
    }

    private func laidOutControl() -> CategoryCreateControl {
        let control = CategoryCreateControl()
        // Hosted in a window rather than left loose, because `performClick` does nothing without one -- see
        // `OffscreenWindow`.
        window = OffscreenWindow.host(control, width: 200, height: 40)
        return control
    }

    func testItStartsAsAButtonAlone() {
        let control = laidOutControl()

        XCTAssertFalse(control.isEditing)
        XCTAssertFalse(control.createButton.isHidden)
        XCTAssertTrue(control.nameField.isHidden, "the column is a list of categories, not an open form")
        XCTAssertTrue(control.saveButton.isHidden)
        XCTAssertEqual(control.createButton.title, "Create")
    }

    func testClickingCreateOpensTheNameField() {
        let control = laidOutControl()

        control.createButton.performClick(nil)

        XCTAssertTrue(control.isEditing)
        XCTAssertTrue(control.createButton.isHidden)
        XCTAssertFalse(control.nameField.isHidden)
        XCTAssertFalse(control.saveButton.isHidden)
    }

    func testSaveReportsWhatWasTypedWithoutTidyingItUp() {
        let control = laidOutControl()
        var saved: [String] = []
        control.onSave = { saved.append($0) }
        control.createButton.performClick(nil)

        control.nameField.stringValue = "  Deep   Work "
        control.saveButton.performClick(nil)

        // Raw, spaces and all: normalising is the rules' job, and a control that trimmed first would be a
        // second place where the name could be decided.
        XCTAssertEqual(saved, ["  Deep   Work "])
    }

    func testItDoesNotCollapseOnItsOwnWhenSaved() {
        let control = laidOutControl()
        control.createButton.performClick(nil)

        control.saveButton.performClick(nil)

        // Whoever handles the save decides when the field goes away, because the answer can be an alert
        // that has to be raised while the name is still on screen.
        XCTAssertTrue(control.isEditing)
    }

    func testCollapsingClearsTheNameSoTheNextOneStartsEmpty() {
        let control = laidOutControl()
        control.createButton.performClick(nil)
        control.nameField.stringValue = "Abandoned"

        control.collapse()

        XCTAssertFalse(control.isEditing)
        XCTAssertEqual(control.nameField.stringValue, "")
        XCTAssertFalse(control.createButton.isHidden)
    }

    func testOpeningAndClosingIsReported() {
        let control = laidOutControl()
        var reported: [Bool] = []
        control.onEditingChanged = { reported.append($0) }

        control.startEditing()
        control.collapse()

        // What the window needs to hear: while a field is open, Escape has to belong to it rather than to
        // the window's Close button.
        XCTAssertEqual(reported, [true, false])
    }

    func testEachPartIsNamedForAScript() {
        let control = laidOutControl()

        XCTAssertEqual(control.createButton.accessibilityIdentifier(), CategoryCreateControl.Identifier.create)
        XCTAssertEqual(control.nameField.accessibilityIdentifier(), CategoryCreateControl.Identifier.nameField)
        XCTAssertEqual(control.saveButton.accessibilityIdentifier(), CategoryCreateControl.Identifier.save)
    }

    func testTheFieldStopsAtTheLimit() {
        // Truncated as it is typed rather than refused at the end, which is what a length limit can do honestly: what
        // is on screen is what will be saved. `normalise` cuts it as well and is the guarantee; this is so that a name
        // does not quietly lose its tail somewhere between the field and the table.
        let control = laidOutControl()
        var saved: [String] = []
        control.onSave = { saved.append($0) }
        control.createButton.performClick(nil)

        control.nameField.stringValue = String(repeating: "a", count: CategoryCreateRules.maximumLength + 10)
        control.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control.nameField))
        control.saveButton.performClick(nil)

        XCTAssertEqual(control.nameField.stringValue.count, CategoryCreateRules.maximumLength)
        XCTAssertEqual(saved.first?.count, CategoryCreateRules.maximumLength, "and that is what Save is handed")
    }
}
