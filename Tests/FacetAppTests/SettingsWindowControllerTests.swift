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

    /// The App tab's pane, whichever tab is on show. Found the way the controller finds it.
    private func appPane(in controller: SettingsWindowController) -> AppSettingsPane? {
        controller.panes.tabViewItems.compactMap { $0.view as? AppSettingsPane }.first
    }

    /// The Device tab's pane, found the same way.
    private func devicePane(in controller: SettingsWindowController) -> DevicePane? {
        controller.panes.tabViewItems.compactMap { $0.view as? DevicePane }.first
    }

    /// The field *inside* the control carries the identifier, so the control itself is its owner. Both pane test
    /// suites reach for one the same way.
    private func stepper(_ identifier: String, in root: NSView) -> SteppedNumberField? {
        descendants(of: root).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// Waits out `WriteDebounce.interval` on the run loop, which is what the writing rows on the Device tab are
    /// scheduled behind. Spun rather than slept: the timer is on this run loop.
    private func waitForTheDebouncedWrite() {
        let deadline = Date().addingTimeInterval(WriteDebounce.interval + 1)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
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

    // MARK: - what a written setting has to reach

    func testChangingTheWarningLevelTellsTheLowBatteryWatch() throws {
        // **The one path nothing else covers.** `LowBatteryWatchTests` proves the watch re-judges when asked, and
        // `DevicePaneTests` proves the field reports a change; this is the join between them, and without it
        // raising the level against a steady cube would look like a control that did nothing -- for as long as the
        // charge held, which the measurements put at over an hour.
        //
        // **On the Device tab since 2026-09-03**, where it was driven through the App pane's `onChange` before.
        let database = TemporaryDatabase()
        try database.bootstrap()
        let settings = SettingStore(connection: database.connection())
        defer { database.remove() }

        // A cube sitting at 15%: above the seeded warning level of 10, so nothing is wrong yet.
        let watch = LowBatteryWatch(level: { 15 }, settings: settings, debugLog: nil)
        defer { watch.stop() }
        let controller = SettingsWindowController(
            debugLog: nil, categories: nil, faces: nil, settings: settings, lowBattery: watch
        )
        controller.select(.device)
        let pane = try XCTUnwrap(devicePane(in: controller))
        XCTAssertFalse(watch.alert.isBatteryLow, "precondition: 15% is not low while the level is the seeded 10%")

        // **The field is stepped and the debounce waited out**, rather than a change being posted: the write is
        // scheduled off the field now, so a report that never settles never reaches the table.
        try XCTUnwrap(stepper(DevicePane.Identifier.batteryWarning, in: pane)).value = 20
        pane.onBatteryWarningChanged?()
        waitForTheDebouncedWrite()

        XCTAssertEqual(settings.integer("low_battery_level", field: "percent"), 20, "the row has to be written first")
        XCTAssertTrue(watch.alert.isBatteryLow, "the warning was never told that what counts as low had moved")
    }
}
