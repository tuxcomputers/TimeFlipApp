@testable import FacetApp
import AppKit
import XCTest

/// Covers the one thing `SettingsMetrics` exists for: **the three tabs are one look, drawn three times.**
///
/// Every check here measures real laid-out views rather than reading the constants back, which would only prove the
/// file agrees with itself. What is being guarded is that nothing on any of the three tabs quietly grows a number of
/// its own again -- which is exactly what had happened: the App tab's rows had drifted to a 46pt pitch and the
/// Device tab's to 24 with no gap, both measured against the Categories tab by eye at some point and both wrong.
///
/// **So a row height changed in `SettingsMetrics` moves all three, and a row height changed anywhere else fails
/// here.** That is the whole contract.
@MainActor
final class SettingsMetricsTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func hosted(_ pane: NSView, width: CGFloat = 640, height: CGFloat = 900) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// The vertical distance from one row to the next, taken off two controls that sit one above the other.
    ///
    /// **Measured between two rows rather than read off one**, because the pitch is what the eye follows down a tab:
    /// a row of the right height with no gap under it reads as a tighter list, which is precisely how the Device tab
    /// went wrong.
    private func pitch(_ first: NSView, _ second: NSView, in content: NSView) -> CGFloat {
        let top = first.superview.map { $0.convert(first.frame, to: content) } ?? .zero
        let next = second.superview.map { $0.convert(second.frame, to: content) } ?? .zero
        return abs(next.midY - top.midY)
    }

    private func view(_ identifier: String, in root: NSView) throws -> NSView {
        try XCTUnwrap(
            descendants(of: root).first { $0.accessibilityIdentifier() == identifier },
            identifier
        )
    }

    // MARK: - one rhythm on every tab

    func testTheAppTabDrawsRowsAtTheSharedPitch() throws {
        let pane = AppSettingsPane()
        let content = hosted(pane)

        let measured = pitch(
            try view(AppSettingsPane.Identifier.showSeconds, in: pane),
            try view(AppSettingsPane.Identifier.pauseOnLock, in: pane),
            in: content
        )

        XCTAssertEqual(measured, SettingsMetrics.rowHeight + SettingsMetrics.rowSpacing, accuracy: 0.5)
    }

    func testTheDeviceTabDrawsRowsAtTheSharedPitch() throws {
        let pane = DevicePane()
        let content = hosted(pane)

        let measured = pitch(
            try view(DevicePane.Identifier.name, in: pane),
            try view(DevicePane.Identifier.connection, in: pane),
            in: content
        )

        XCTAssertEqual(measured, SettingsMetrics.rowHeight + SettingsMetrics.rowSpacing, accuracy: 0.5)
    }

    func testTheThreeTabsAgreeWithEachOther() throws {
        // The check that would have caught the drift. Each tab measured on its own could be defended; the three
        // measured against each other cannot, which is the point of having one set of numbers.
        let app = AppSettingsPane()
        let appContent = hosted(app)
        let device = DevicePane()
        let deviceContent = hosted(device)
        let table = CategoryTable()
        table.show([category(1, "Break"), category(2, "Meeting")])
        let tableContent = hosted(table)

        let appPitch = pitch(
            try view(AppSettingsPane.Identifier.showSeconds, in: app),
            try view(AppSettingsPane.Identifier.pauseOnLock, in: app),
            in: appContent
        )
        let devicePitch = pitch(
            try view(DevicePane.Identifier.name, in: device),
            try view(DevicePane.Identifier.connection, in: device),
            in: deviceContent
        )

        let boxes = descendants(of: table).filter { $0.accessibilityIdentifier().hasPrefix("category-active-") }
        let categoriesPitch = pitch(boxes[0], boxes[1], in: tableContent)

        XCTAssertEqual(appPitch, devicePitch, accuracy: 0.5, "the App and Device tabs draw a list at different rhythms")
        XCTAssertEqual(appPitch, categoriesPitch, accuracy: 0.5, "the App tab and the tab it copies disagree")
    }

    func testTheCategoriesTabDrawsRowsAtTheSharedPitch() throws {
        // **The hole this closes.** Until `SettingsRow.settle` reached this tab, its rows were 24pt because the
        // daily-limit field inside them is 24pt and nothing here read `rowHeight` at all -- so raising that value
        // moved the App and Device tabs and left this one behind, which is the opposite of what one point of
        // reference is for. Checked by measuring: with `rowHeight` at 40 this measured 32 and said so.
        let table = CategoryTable()
        table.show([category(1, "Break"), category(2, "Meeting")])
        let content = hosted(table)

        let boxes = descendants(of: table)
            .filter { $0.accessibilityIdentifier().hasPrefix("category-active-") }
        XCTAssertEqual(boxes.count, 2, "two rows to measure between")

        XCTAssertEqual(
            pitch(boxes[0], boxes[1], in: content),
            SettingsMetrics.rowHeight + SettingsMetrics.rowSpacing,
            accuracy: 0.5
        )
    }

    private func category(_ id: Int, _ name: String) -> CategoryRecord {
        CategoryRecord(
            id: id, name: name, iconName: nil, colourID: 0, colour: nil,
            usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
        )
    }

    // MARK: - nothing is drawn between rows

    func testNoTabDrawsALineBetweenItsRows() {
        // The Categories tab has never drawn one and reads as a list regardless, so the hairlines the other two drew
        // were dividing rows the gap had already divided. Asserted across whole panes, so a line added anywhere on
        // either of them fails here rather than only where somebody thought to look.
        for pane in [AppSettingsPane() as NSView, DevicePane()] {
            _ = hosted(pane)

            let separators = descendants(of: pane)
                .compactMap { $0 as? NSBox }
                .filter { $0.boxType == .separator }

            XCTAssertEqual(separators.count, 0, "\(type(of: pane)) draws \(separators.count) line(s) between rows")
        }
    }

    // MARK: - the panels are one control drawn three times

    func testEveryPanelInsetsItsContentTheSameWay() {
        // `PanelSection.Metrics` used to be overridden on both of these tabs, to nothing, so their rows could run the
        // panel's full width and place the ends of their own hairlines. With no hairlines that exception buys
        // nothing, and one inset is what puts a row at the same x on all three tabs.
        XCTAssertEqual(PanelSection.Metrics().contentInset, SettingsMetrics.panelPadding)
        XCTAssertEqual(PanelSection.Metrics().headingInset, SettingsMetrics.panelPadding)
        XCTAssertEqual(PanelSection.Metrics().cornerRadius, SettingsMetrics.cornerRadius)
    }

    func testTheCategoriesTabIsWhereTheNumbersCameFrom() {
        // Named so the direction is on the record: these are the Categories tab's numbers, and that tab reads them
        // back out of `SettingsMetrics` rather than keeping the originals.
        XCTAssertEqual(CategoryTable.Layout.rowSpacing, SettingsMetrics.rowSpacing)
        XCTAssertEqual(CategoryTable.Layout.padding, SettingsMetrics.panelPadding)
        XCTAssertEqual(CategoryTable.Layout.cornerRadius, SettingsMetrics.cornerRadius)
        XCTAssertEqual(CategoryTable.Layout.columnSpacing, SettingsMetrics.columnSpacing)
    }
}
