@testable import FacetApp
import AppKit
import XCTest

/// Covers the Device tab: that it draws the archive's three sections, that every value on it comes from what it was
/// shown, and that the three folding rows fold.
///
/// **Nothing here writes**, which is the tab's defining property at this point rather than an omission: there is no
/// Bluetooth in this app yet for a control to reach. So what is worth pinning is the shape and the reading, and the
/// one behaviour that already works, which is the folds.
@MainActor
final class DevicePaneTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(of pane: DevicePane) -> [String] {
        descendants(of: pane).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func value(_ identifier: String, in pane: DevicePane) -> String? {
        descendants(of: pane)
            .first { $0.accessibilityIdentifier() == identifier }
            .flatMap { ($0 as? NSTextField)?.stringValue }
    }

    private func view(_ identifier: String, in pane: DevicePane) -> NSView? {
        descendants(of: pane).first { $0.accessibilityIdentifier() == identifier }
    }

    /// The field *inside* the control carries the identifier, so the control itself is its owner. The App tab's tests
    /// reach for one the same way, for the same reason.
    private func stepper(_ identifier: String, in pane: DevicePane) -> SteppedNumberField? {
        descendants(of: pane).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    private var paired: DevicePane.Values {
        var values = DevicePane.Values.seeded
        values.isPaired = true
        values.isConnected = true
        values.isManualMode = false
        values.deviceName = "Dibby"
        values.batteryPercent = 34
        values.manufacturer = "DI_LABS 2.0"
        values.model = "TimeFlip2"
        values.hardware = "TFv4.1"
        values.firmware = "FW_v3.64"
        return values
    }

    // MARK: - the sections

    func testTheThreeSectionsTheArchiveHadAreThere() {
        let pane = DevicePane()

        for title in ["Info", "Settings", "TimeFlip"] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing section: \(title)")
        }
    }

    func testEveryRowIsNamedForWhatItSays() {
        let pane = DevicePane()

        // Named so a scripted step can read one without hunting by position, which is the whole reason the old
        // locator layer existed and this app does not need one.
        for identifier in [
            DevicePane.Identifier.name,
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
            DevicePane.Identifier.more,
            DevicePane.Identifier.autoPause,
            DevicePane.Identifier.led,
            DevicePane.Identifier.doubleTap,
            DevicePane.Identifier.scan,
            DevicePane.Identifier.scanAll,
        ] {
            XCTAssertNotNil(view(identifier, in: pane), "missing: \(identifier)")
        }
    }

    // MARK: - what it shows

    func testAPaneNobodyHasReadIntoShowsWhatAFreshDatabaseHolds() {
        // The seeds in `database/011_setting.sql`, so an unread pane shows what a new database would rather than
        // zeroes that mean nothing. The only guess made anywhere on this tab.
        let pane = DevicePane()

        XCTAssertEqual(pane.values, .seeded)
        XCTAssertEqual(value(DevicePane.Identifier.name, in: pane), "Not paired")
        XCTAssertEqual(value(DevicePane.Identifier.connection, in: pane), "Manual mode, no device")
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "Not paired")
    }

    func testTheInfoRowsComeFromWhatItWasShown() {
        let pane = DevicePane()

        pane.show(paired)

        XCTAssertEqual(value(DevicePane.Identifier.name, in: pane), "Dibby")
        XCTAssertEqual(value(DevicePane.Identifier.connection, in: pane), "Connected")
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "34%")
        XCTAssertEqual(value(DevicePane.Identifier.manufacturer, in: pane), "DI_LABS 2.0")
        XCTAssertEqual(value(DevicePane.Identifier.firmware, in: pane), "FW_v3.64")
    }

    func testTheSettingsRowsCarryTheirUnits() {
        var values = DevicePane.Values.seeded
        values.autoPauseMinutes = 12
        values.ledBrightnessPercent = 70
        values.ledBlinkSeconds = 20
        let pane = DevicePane()

        pane.show(values)

        // The unit is part of the answer: "20" against Blink Interval could be seconds or minutes, and the archive
        // wrote both out for that reason.
        XCTAssertEqual(value(DevicePane.Identifier.ledBrightness, in: pane), "70 %")
        XCTAssertEqual(value(DevicePane.Identifier.ledBlink, in: pane), "20 sec")
        XCTAssertEqual(stepper(DevicePane.Identifier.autoPause, in: pane)?.value, 12)
    }

    func testTheDoubleTapBoxIsTickedWhenTheGestureIsOff() throws {
        // "Disable", not "Enable", which is the archive's wording and the right way round: the setting is on by
        // default, so the box somebody ticks is the one that turns the gesture off. Ticked means disabled, and
        // getting this backwards would be invisible in a screenshot.
        var values = DevicePane.Values.seeded
        values.isDoubleTapEnabled = false
        let pane = DevicePane()

        pane.show(values)

        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)
        XCTAssertEqual(box.state, .on)
        pane.show(.seeded)
        XCTAssertEqual(box.state, .off, "the gesture is on by default, so the Disable box is clear")
    }

    func testValuesGreyWhenNothingCanBeHeardFrom() throws {
        let pane = DevicePane()

        pane.show(.seeded)
        let name = try XCTUnwrap(view(DevicePane.Identifier.name, in: pane) as? NSTextField)
        XCTAssertEqual(name.textColor, .secondaryLabelColor, "a placeholder is not a reading")

        pane.show(paired)
        XCTAssertEqual(name.textColor, .labelColor)
    }

    // MARK: - the folds

    func testTheThreeGroupsStartFolded() {
        // Each is the least urgent thing in its panel, which is why the archive folded them too.
        let pane = DevicePane()

        XCTAssertFalse(pane.moreRow.isExpanded)
        XCTAssertFalse(pane.ledRow.isExpanded)
        XCTAssertFalse(pane.doubleTapRow.isExpanded)
    }

    func testFoldingTakesTheSpaceBackRatherThanLeavingItBehind() {
        // Auto Layout does not care that a view is hidden, so hiding alone leaves the full height behind. This is the
        // check that a folded row is actually shorter than an open one -- the fault it guards against measured 150pt
        // either way and looked like a gap nobody could explain.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()
        let folded = pane.ledRow.frame.height

        pane.ledRow.setExpanded(true)
        pane.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(pane.ledRow.frame.height, folded)
    }

    func testTheWholeHeadingLineFoldsIt() throws {
        // `CLAUDE.md`: the triangle, the words, and the space after them. The words sit inside the button because a
        // click on a label goes up the responder chain to the label's own superview -- a button merely behind a
        // sibling label is never pressed, which shipped once on the Categories headings.
        let pane = DevicePane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.led)-heading-button", in: pane) as? NSButton
        )
        button.performClick(nil)

        XCTAssertTrue(pane.ledRow.isExpanded)
    }

    func testAFoldIsReported() throws {
        let pane = DevicePane()
        var reported: [(String, Bool)] = []
        pane.onToggle = { reported.append(($0, $1)) }

        pane.moreRow.setExpanded(true)
        XCTAssertTrue(reported.isEmpty, "setting it directly is the window drawing, not somebody clicking")

        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.more)-heading-button", in: pane) as? NSButton
        )
        button.performClick(nil)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, DevicePane.Identifier.more)
        XCTAssertEqual(reported.first?.1, false, "it was open, so the click shut it")
    }

    // MARK: - the width

    func testThePanelsSpanTheTab() throws {
        // `CLAUDE.md`, for every tab: a panel is inset by the tab's own padding and nothing more. The trap this
        // guards is a stack aligned to its leading edge, where each row is only as wide as its own contents and
        // every value ends up against the widest label instead of the right-hand edge.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.infoPanel,
            DevicePane.Identifier.settingsPanel,
            DevicePane.Identifier.pairingPanel,
        ] {
            let panel = try XCTUnwrap(view(identifier, in: pane))
            XCTAssertEqual(pane.convert(panel.bounds, from: panel).maxX, 620, accuracy: 0.5, identifier)
        }
    }

    func testTheValuesAreAgainstTheRightHandEdge() throws {
        // The archive's shape: the column of answers runs down the right-hand side rather than following the words.
        // Measured on the alignment rect, not the frame, because AppKit pads some controls beyond what they draw and
        // the padding differs by OS version -- see `Tests/Methods.md`.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.name,
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
        ] {
            let field = try XCTUnwrap(view(identifier, in: pane))
            let aligned = try XCTUnwrap(field.superview).convert(
                field.alignmentRect(forFrame: field.frame), to: pane
            )
            XCTAssertEqual(aligned.maxX, 600, accuracy: 0.5, identifier)
        }
    }
}
