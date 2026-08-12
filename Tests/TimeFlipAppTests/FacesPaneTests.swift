@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers `FacesPane`'s layout: the two-to-one column split and the padding around it.
///
/// Layout is worth a test precisely because it is the part normally only checked by eye. A constraint
/// that is missing or fighting another does not fail anything -- the columns just come out a size
/// nobody chose, and only a screenshot would say so. Laid out here in a fixed frame, with no window and
/// nothing on screen.
@MainActor
final class FacesPaneTests: XCTestCase {
    private let width: CGFloat = 640
    private let height: CGFloat = 600
    private let padding: CGFloat = 20
    private let columnSpacing: CGFloat = 24

    private func laidOutPane() -> FacesPane {
        let pane = FacesPane()
        pane.frame = NSRect(x: 0, y: 0, width: width, height: height)
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    func testTheLeftColumnIsTwiceTheWidthOfTheRight() {
        let pane = laidOutPane()

        XCTAssertEqual(
            pane.timingColumn.frame.width, pane.categoriesColumn.frame.width * 2, accuracy: 0.5,
            "a two-thirds / one-third split, expressed as a ratio between the columns"
        )
    }

    func testTheColumnsFillTheWidthInsideThePaddingAndGutter() {
        let pane = laidOutPane()

        XCTAssertEqual(pane.timingColumn.frame.minX, padding, accuracy: 0.5)
        XCTAssertEqual(pane.categoriesColumn.frame.maxX, width - padding, accuracy: 0.5)
        XCTAssertEqual(
            pane.categoriesColumn.frame.minX - pane.timingColumn.frame.maxX, columnSpacing, accuracy: 0.5,
            "one gutter between them, and no slack absorbed anywhere else"
        )
    }

    func testBothColumnsStartAtTheSameHeight() {
        let pane = laidOutPane()

        // Top-aligned, so the two headings sit on one line however tall either column becomes.
        XCTAssertEqual(pane.timingColumn.frame.maxY, pane.categoriesColumn.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(pane.timingColumn.frame.maxY, height - padding, accuracy: 0.5)
    }

    func testTheSplitHoldsWhenTheWindowIsResized() {
        let pane = laidOutPane()
        pane.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.timingColumn.frame.width, pane.categoriesColumn.frame.width * 2, accuracy: 0.5)
        XCTAssertEqual(pane.categoriesColumn.frame.maxX, 1_000 - padding, accuracy: 0.5)
    }

    func testEachColumnIsNamedForAScript() {
        let pane = laidOutPane()

        XCTAssertEqual(pane.timingColumn.accessibilityIdentifier(), FacesPane.Identifier.timingColumn)
        XCTAssertEqual(pane.categoriesColumn.accessibilityIdentifier(), FacesPane.Identifier.categoriesColumn)
        XCTAssertTrue(pane.timingColumn.isAccessibilityElement(), "otherwise the identifier is never asked for")
        XCTAssertTrue(pane.categoriesColumn.isAccessibilityElement())
    }

    // MARK: - the create button

    func testCreateSitsUnderTheListAtTheColumnsLeadingEdge() {
        let pane = laidOutPane()
        pane.show([CategoryRecord(id: 1, name: "Break", iconName: nil, colour: nil, usesWhiteLines: false)])
        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.createButton.title, "Create")
        XCTAssertEqual(
            pane.createButton.frame.minX, pane.categoryList.frame.minX, accuracy: 0.5,
            "flush with the list above it, not indented"
        )
        XCTAssertLessThan(
            pane.createButton.frame.maxY, pane.categoryList.frame.minY,
            "below the list: in this coordinate space, lower on screen means a smaller y"
        )
    }

    func testCreateReportsItsClick() {
        let pane = laidOutPane()
        var clicks = 0
        pane.onCreateCategory = { clicks += 1 }

        pane.createButton.performClick(nil)

        XCTAssertEqual(clicks, 1, "the pane reports the click rather than acting on it")
    }

    func testCreateIsNamedForAScript() {
        XCTAssertEqual(laidOutPane().createButton.accessibilityIdentifier(), FacesPane.Identifier.createCategory)
    }

    func testEachColumnHasItsHeading() {
        let pane = laidOutPane()

        let headings = [pane.timingColumn, pane.categoriesColumn].map { column in
            (column.subviews.first as? NSTextField)?.stringValue
        }
        XCTAssertEqual(headings, ["Timing", "Categories"])
    }
}
