@testable import FacetApp
import AppKit
import XCTest

/// Covers the wiring between the tab bar and the panes behind it.
///
/// Worth testing because there are now two controls that have to agree, and nothing enforces it: the
/// bar's segments and the tab view's items are separate lists in the same order, and if they ever
/// diverge -- a tab added to one, a reorder applied to the other -- every click still selects *a* tab
/// and nothing fails. That exact mistake is on record in `Archive/Tests/Methods.md`: steps addressing tabs by
/// index went on passing while testing the wrong tab after `Categories` was inserted second.
///
/// No window is shown. Building the controller builds the bar and the panes, which is all this needs.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private func controller() -> SettingsWindowController {
        SettingsWindowController(debugLog: nil, categories: nil, faces: nil)
    }

    func testTheBarHasOneSegmentPerTab() {
        let bar = controller().tabBar

        XCTAssertEqual(bar.segmentCount, SettingsTab.allCases.count)
        let labels = (0 ..< bar.segmentCount).map { bar.label(forSegment: $0) }
        XCTAssertEqual(labels, SettingsTab.allCases.map(\.title), "same tabs, same order")
    }

    func testThePanesAreInTheSameOrderAsTheSegments() {
        let controller = controller()

        let identifiers = controller.panes.tabViewItems.map { $0.identifier as? String }
        XCTAssertEqual(identifiers, SettingsTab.allCases.map(\.rawValue))
        for (index, tab) in SettingsTab.allCases.enumerated() {
            XCTAssertEqual(
                controller.tabBar.label(forSegment: index), tab.title,
                "segment \(index) must belong to the same tab as pane \(index)"
            )
        }
    }

    func testChoosingASegmentShowsThatTabsPane() throws {
        let controller = controller()
        let report = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .report))

        controller.tabBar.selectedSegment = report
        controller.tabBar.performClick(nil)

        XCTAssertEqual(
            controller.panes.selectedTabViewItem?.identifier as? String, SettingsTab.report.rawValue,
            "the bar moved, so the pane behind it should have moved too"
        )
    }

    func testTheBarAndThePanesStartOnTheSameTab() {
        let controller = controller()

        XCTAssertEqual(controller.tabBar.selectedSegment, 0)
        XCTAssertEqual(
            controller.panes.selectedTabViewItem?.identifier as? String,
            SettingsTab.allCases.first?.rawValue
        )
    }

    func testEveryOpenLandsOnFaces() throws {
        // Whatever the window was last left on. Faces is where the time is -- the list, the clock, and starting
        // or stopping it -- so a glance at another tab should not cost a click to get back to work.
        XCTAssertEqual(SettingsWindowController.tabOnOpen, .faces)

        let controller = controller()
        let report = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .report))
        controller.tabBar.selectedSegment = report
        controller.tabBar.performClick(nil)
        XCTAssertEqual(
            controller.panes.selectedTabViewItem?.identifier as? String, SettingsTab.report.rawValue,
            "precondition: left on Report"
        )

        // What `show()` does before the window reaches the screen.
        controller.select(SettingsWindowController.tabOnOpen)

        XCTAssertEqual(controller.panes.selectedTabViewItem?.identifier as? String, SettingsTab.faces.rawValue)
        XCTAssertEqual(
            controller.tabBar.selectedSegment, SettingsTab.allCases.firstIndex(of: .faces),
            "the bar has to move with the pane, or the two disagree about which tab is showing"
        )
    }

    func testTheFacesTabGetsTheFacesLayout() throws {
        let controller = controller()
        let faces = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .faces))

        XCTAssertTrue(
            controller.panes.tabViewItems[faces].view is FacesPane,
            "the pane built for a tab has to be the one that tab is for"
        )
    }
}
