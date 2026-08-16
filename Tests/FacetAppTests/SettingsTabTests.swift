@testable import FacetApp
import XCTest

/// Covers `SettingsTab`: the tabs that exist, their labels, and the identifiers a script addresses
/// their panes by.
///
/// Cheap to test and worth it, because both ways this can go wrong are silent. A duplicate identifier
/// does not fail -- it finds the wrong pane, and the test that used it passes against the wrong tab.
/// A title that drifts from its case name does the same to anyone reading the code.
final class SettingsTabTests: XCTestCase {
    func testTheTabsAndTheirOrder() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["Faces", "Categories", "Report", "App", "Device"],
            "the order here is the order they are drawn in"
        )
    }

    /// `@MainActor` for one reason: `tabOnOpen` belongs to the window controller, which is main-actor isolated.
    @MainActor
    func testTheWindowOpensAtTheFirstTabRatherThanOneAlongFromIt() {
        // Faces is where the time is and every open lands on it, so it is also the leftmost. Device is last, being
        // the tab somebody visits to set a cube up or to find out what is wrong with it.
        XCTAssertEqual(SettingsTab.allCases.first, SettingsWindowController.tabOnOpen)
        XCTAssertEqual(SettingsTab.allCases.last, .device)
    }

    func testEveryTitleIsItsOwnCaseName() {
        // The property that makes the two impossible to disagree: nothing is written down twice.
        for tab in SettingsTab.allCases {
            XCTAssertEqual(tab.title.lowercased(), tab.rawValue)
        }
    }

    func testEveryPaneIdentifierIsUniqueAndKebabCase() {
        let identifiers = SettingsTab.allCases.map(\.paneIdentifier)

        XCTAssertEqual(Set(identifiers).count, identifiers.count, "a repeat would point two tabs at one pane")
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("settings-pane-"))
            XCTAssertEqual(identifier, identifier.lowercased(), "kebab-case, like every other identifier")
            XCTAssertFalse(identifier.contains(" "))
        }
    }
}
