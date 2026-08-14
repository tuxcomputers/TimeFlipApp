@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the App tab's settings section: that every row the archive had is there, that each shows what the table
/// says, and the two conversions between what is stored and what is drawn.
///
/// **Nothing here writes**, and that is the thing worth pinning: a change reports outward and the row is left showing
/// the stored value, so the window can read it back. Until each setting has a writer, every change is a refused write
/// and the database rule says a refused write re-reads.
@MainActor
final class AppSettingsPaneTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(of pane: AppSettingsPane) -> [String] {
        descendants(of: pane).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func control<T: NSView>(_ identifier: String, in pane: AppSettingsPane) -> T? {
        descendants(of: pane).first { $0.accessibilityIdentifier() == identifier } as? T
    }

    private func field(_ identifier: String, in pane: AppSettingsPane) -> SteppedNumberField? {
        // The field inside the control carries the identifier, so the control itself is its owner.
        descendants(of: pane).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    private var stored: AppSettingsPane.Values {
        AppSettingsPane.Values(
            showsSeconds: false,
            pausesOnLock: false,
            dailyResetHour24: 4,
            batteryWarningPercent: 15,
            fetchIntervalSeconds: 600,
            blipSeconds: 2
        )
    }

    // MARK: - the rows

    func testEveryRowTheArchiveHadIsThere() {
        let pane = AppSettingsPane()

        // The archive's six, in its order and its wording (`Archive/TimeFlipApp/ReportSettingsView.swift`).
        for title in [
            "App settings",
            "Show seconds",
            "Pause the device when locking it",
            "Daily reset at",
            "Battery warning at",
            "Fetch history every",
            "Ignore flips under",
        ] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing: \(title)")
        }
    }

    func testTheRowsAreInTheArchivesOrder() {
        let pane = AppSettingsPane()

        let titles = labels(of: pane).filter { $0.hasPrefix("Show") || $0.hasPrefix("Pause") || $0.hasPrefix("Daily")
            || $0.hasPrefix("Battery") || $0.hasPrefix("Fetch") || $0.hasPrefix("Ignore") }
        XCTAssertEqual(
            titles,
            [
                "Show seconds",
                "Pause the device when locking it",
                "Daily reset at",
                "Battery warning at",
                "Fetch history every",
                "Ignore flips under",
            ],
            "the two switches first, then the four numbers"
        )
    }

    func testEveryControlIsNamedForItsSetting() {
        let pane = AppSettingsPane()

        for identifier in [
            AppSettingsPane.Identifier.showSeconds,
            AppSettingsPane.Identifier.pauseOnLock,
            AppSettingsPane.Identifier.dailyReset,
            AppSettingsPane.Identifier.batteryWarning,
            AppSettingsPane.Identifier.fetchInterval,
            AppSettingsPane.Identifier.blipTime,
        ] {
            XCTAssertTrue(
                descendants(of: pane).contains { $0.accessibilityIdentifier() == identifier },
                "missing: \(identifier)"
            )
        }
    }

    // MARK: - what they show

    func testTheSwitchesShowWhatTheTableSays() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let seconds: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane))
        let lock: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.pauseOnLock, in: pane))
        XCTAssertEqual(seconds.state, .off)
        XCTAssertEqual(lock.state, .off)

        pane.show(AppSettingsPane.Values.seeded)
        XCTAssertEqual(seconds.state, .on, "and a second read replaces the first, rather than being ignored")
        XCTAssertEqual(lock.state, .on)
    }

    func testTheHourIsDrawnOnATwelveHourFace() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)).value, 4)
        // AM is a fixed word rather than a second thing to set: a reset in the middle of the afternoon would cut a
        // working day's accounting in half, so PM was only ever a way to pick a wrong value.
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)).suffix, "AM")
    }

    func testTheIntervalIsDrawnInMinutesThoughItIsStoredInSeconds() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let field = try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane))
        XCTAssertEqual(field.value, 10, "600 seconds")
        XCTAssertEqual(field.suffix, "mins")
    }

    func testOneMinuteReadsAsSingular() throws {
        let pane = AppSettingsPane()
        var values = stored
        values.fetchIntervalSeconds = 60

        pane.show(values)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).suffix, "min")
    }

    func testTheBatteryAndBlipRowsShowTheirOwnUnits() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let battery = try XCTUnwrap(field(AppSettingsPane.Identifier.batteryWarning, in: pane))
        XCTAssertEqual(battery.value, 15)
        XCTAssertEqual(battery.suffix, "%")

        let blip = try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane))
        XCTAssertEqual(blip.value, 2)
        XCTAssertEqual(blip.suffix, "secs")
    }

    func testASingleSecondReadsAsSingular() throws {
        let pane = AppSettingsPane()
        var values = stored
        values.blipSeconds = 1

        pane.show(values)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).suffix, "sec")
    }

    func testAPaneNobodyHasReadIntoShowsTheSeededValues() throws {
        // Which is what a database missing every one of these rows would give, and the only guess made anywhere.
        let pane = AppSettingsPane()

        XCTAssertEqual(pane.values, .seeded)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).value, 5)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.batteryWarning, in: pane)).value, 10)
    }

    // MARK: - a change, and what the pane holds

    func testAChangedSwitchIsReportedAndNotAdoptedUntilItIsStored() throws {
        let pane = AppSettingsPane()
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)

        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane))
        box.performClick(nil)

        XCTAssertEqual(reported, [.showsSeconds(true)])
        // Not adopted here: the window writes it, checks the table took it, and only then hands it back. What this
        // pane holds is still what the table said, so a refused write has something to put the row back to.
        XCTAssertEqual(pane.values, stored)
    }

    func testAChangedNumberIsReportedInTheUnitTheRowShows() throws {
        let pane = AppSettingsPane()
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)

        try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).onChange?(9)

        // Minutes, which is what the row shows. Converting to the seconds the table stores is a rule, and doing it
        // here would be a second place it happens.
        XCTAssertEqual(reported, [.fetchIntervalMinutes(9)])
        XCTAssertEqual(pane.values.fetchIntervalSeconds, 600, "unchanged until the table has it")
    }

    func testAUnitThatIsAWordKeepsUpWithTheNumber() throws {
        let pane = AppSettingsPane()
        pane.show(stored)

        try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).onChange?(1)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).suffix, "min")

        try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).onChange?(1)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).suffix, "sec")
    }

    func testAdoptingAChangeMakesItWhatThePaneHolds() {
        let pane = AppSettingsPane()
        pane.show(stored)

        pane.adopt(.dailyResetHour12(2))
        pane.adopt(.fetchIntervalMinutes(9))
        pane.adopt(.showsSeconds(true))

        // Stored in the table's units, converted once, by the rules.
        XCTAssertEqual(pane.values.dailyResetHour24, 2)
        XCTAssertEqual(pane.values.fetchIntervalSeconds, 540)
        XCTAssertTrue(pane.values.showsSeconds)
    }

    func testAdoptingMidnightStoresItAsZero() {
        let pane = AppSettingsPane()
        pane.show(stored)

        pane.adopt(.dailyResetHour12(12))

        XCTAssertEqual(pane.values.dailyResetHour24, 0, "12 on the face is 0 on the clock")
    }

    func testRestoringPutsEveryRowBackToWhatThePaneHolds() throws {
        let pane = AppSettingsPane()
        pane.show(stored)
        let field = try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane))
        field.value = 29

        pane.restore()

        XCTAssertEqual(field.value, 2, "which is what a refused write needs: the row was showing what the table refused")
    }

    // MARK: - layout

    /// Hosts the pane the way `NSTabView` does: a content view of a given width, the pane filling it and resizing
    /// with it.
    ///
    /// **Setting the pane's own frame is not the same test.** A pane on its own keeps whatever frame it is handed,
    /// even one that has thrown its autoresizing away, so a test that skips the container passes on the broken
    /// version -- measured: it did, before this was written this way.
    private func hosted(_ pane: AppSettingsPane, width: CGFloat) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func panel(of pane: AppSettingsPane) throws -> NSView {
        try XCTUnwrap(
            descendants(of: pane).first { $0.accessibilityIdentifier() == AppSettingsPane.Identifier.section }
        )
    }

    func testThePanelSpansTheWindow() throws {
        // The rule in CLAUDE.md, for every tab: a panel is inset by the tab's own padding and nothing more. The trap
        // it exists for is that a pane which sets `translatesAutoresizingMaskIntoConstraints = false` on *itself*
        // throws away the frame the tab view gives it and is sized by its own contents instead, which looks like a
        // panel stopping short of the right-hand edge with nothing in the constraints to explain it.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        XCTAssertEqual(pane.frame.width, 640, "the pane fills the tab before anything inside it can span")
        let frame = content.convert(try panel(of: pane).bounds, from: try panel(of: pane))
        XCTAssertEqual(frame.minX, 20, accuracy: 0.5, "the tab's padding, on the left")
        XCTAssertEqual(frame.maxX, 620, accuracy: 0.5, "and the same on the right")
    }

    func testThePanelStillSpansAfterAResize() throws {
        // Resizing is where a panel that merely happened to fit gives itself away.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        content.frame = NSRect(x: 0, y: 0, width: 1_000, height: 500)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.frame.width, 1_000)
        XCTAssertEqual(
            content.convert(try panel(of: pane).bounds, from: try panel(of: pane)).maxX, 980, accuracy: 0.5
        )
    }

    func testEveryControlIsPinnedToTheRightHandEdge() throws {
        // The archive's shape: the controls run down the right-hand side of the panel rather than following the words.
        // A fixed label column would line them up too, and would park them in the middle with dead space beyond.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try panel(of: pane)
        let right = content.convert(panel.bounds, from: panel).maxX
        let controls: [NSView] = try [
            XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane) as NSButton?),
            XCTUnwrap(control(AppSettingsPane.Identifier.pauseOnLock, in: pane) as NSButton?),
            XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)),
            XCTUnwrap(field(AppSettingsPane.Identifier.batteryWarning, in: pane)),
            XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)),
            XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)),
        ]

        for control in controls {
            XCTAssertEqual(
                content.convert(control.bounds, from: control).maxX, right - 20, accuracy: 0.5,
                "\(control.accessibilityIdentifier()) does not reach the panel's inset"
            )
        }
    }

    func testTheLabelsStartAtOneXAndTheRowsSpanThePanel() throws {
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try panel(of: pane)
        let panelFrame = content.convert(panel.bounds, from: panel)
        // Every row is as wide as the panel, which is what puts the hairlines where the archive's are. The rows are
        // the stack's own arranged views, rather than anything that happens to hold a label -- a number field holds
        // one too.
        let stack = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(stack.views.count, 6)
        let rowWidths = Set(stack.views.map(\.frame.width))
        XCTAssertEqual(rowWidths, [panelFrame.width], "one width: \(rowWidths)")
    }

    func testEveryRowButTheLastHasAHairlineUnderIt() throws {
        // Under the last one it would draw against the panel's own bottom edge and read as a row that failed to load
        // rather than as a divider.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let separators = descendants(of: pane).compactMap { $0 as? NSBox }.filter { $0.boxType == .separator }
        XCTAssertEqual(separators.count, 5, "six rows, five hairlines")

        let panel = try panel(of: pane)
        let panelFrame = content.convert(panel.bounds, from: panel)
        for separator in separators {
            let frame = content.convert(separator.bounds, from: separator)
            XCTAssertEqual(frame.minX, panelFrame.minX + 20, accuracy: 0.5)
            XCTAssertEqual(frame.maxX, panelFrame.maxX - 20, accuracy: 0.5, "not the full width, which would cut the panel in two")
        }
    }
}
