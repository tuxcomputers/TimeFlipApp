@testable import FacetApp
import AppKit
import XCTest

/// Covers `CollapsibleSection`: that a folding group can be put back to the state it was built in, whatever somebody
/// left it as.
///
/// **The rule this exists for is that a fold does not outlive its window.** The Settings panes are made once and
/// reused for the life of the launch, so a section opened in one window is still open in the next -- and the second
/// open then shows a tab arranged by a gesture the user made minutes ago and has no reason to remember. Nothing
/// stores a fold, deliberately; the default is simply what the tab opens as, and this is what puts it back.
///
/// The walk that finds these lives on `SettingsWindowController`, which needs a window; what is pinned here is the
/// part that does not -- that each of the three kinds knows its own default and returns to it.
@MainActor
final class CollapsibleSectionTests: XCTestCase {
    private func content() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    // MARK: - a row that folds inside a panel

    func testARowBuiltFoldedGoesBackToFolded() {
        let row = DisclosureRow(title: "More", identifier: "device-more", isExpanded: false, content: content())

        row.setExpanded(true)
        XCTAssertTrue(row.isExpanded, "precondition: somebody opened it")

        row.restoreDefaultState()

        XCTAssertFalse(row.isExpanded)
    }

    func testARowBuiltOpenGoesBackToOpen() {
        // The default is whatever the caller built it as, not "closed": Categories' Active list opens, and a reset
        // that folded everything would be just as wrong as one that opened everything.
        let row = DisclosureRow(title: "LED", identifier: "device-led", isExpanded: true, content: content())

        row.setExpanded(false)

        row.restoreDefaultState()

        XCTAssertTrue(row.isExpanded)
    }

    func testARowLeftAloneStaysWhereItWas() {
        let row = DisclosureRow(title: "More", identifier: "device-more", isExpanded: false, content: content())

        row.restoreDefaultState()

        XCTAssertFalse(row.isExpanded)
    }

    // MARK: - a section with a panel of its own

    func testASectionGoesBackToWhatItWasBuiltAs() {
        let active = CategorySection(title: "Active", identifier: "active", isExpanded: true, content: content())
        let inactive = CategorySection(title: "Inactive", identifier: "inactive", isExpanded: false, content: content())

        active.setExpanded(false)
        inactive.setExpanded(true)
        active.restoreDefaultState()
        inactive.restoreDefaultState()

        // The two defaults differ, which is the whole point of each holding its own rather than the reset naming one.
        XCTAssertTrue(active.isExpanded)
        XCTAssertFalse(inactive.isExpanded)
    }

    // MARK: - a group that is a row of a list

    func testAReportGroupGoesBackToFolded() {
        // Its default is not a parameter: a totals row is built folded every time, the caller having no say in it.
        let total = CategoryTotal(
            categoryID: 1, name: "Admin", iconName: nil, colour: .red, usesWhiteLines: false, seconds: 900
        )
        let group = ReportCategoryGroup(total: total, showingSeconds: false)
        group.entries = { [] }

        group.setExpanded(true)

        group.restoreDefaultState()

        XCTAssertFalse(group.isExpanded)
    }

    // MARK: - resetting is not a fold anybody made

    func testRestoringDoesNotReportAFold() {
        // It must not reach `onToggle`: that is what writes a `debug_log` row, and a reset that narrated itself would
        // fill the log with folds nobody made, on every single open.
        let row = DisclosureRow(title: "More", identifier: "device-more", isExpanded: false, content: content())
        row.setExpanded(true)
        var reported: [Bool] = []
        row.onToggle = { reported.append($0) }

        row.restoreDefaultState()

        XCTAssertFalse(row.isExpanded, "precondition: it did fold")
        XCTAssertEqual(reported, [], "restoring is the window starting fresh, not the user folding anything")
    }
}
