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
            "Show seconds in the menu bar",
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
                "Show seconds in the menu bar",
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

    // MARK: - nothing is stored yet

    func testAChangedSwitchIsReportedAndTheRowIsLeftAlone() throws {
        let pane = AppSettingsPane()
        var reported: [(String, String)] = []
        pane.onChange = { reported.append(($0, $1)) }
        pane.show(stored)

        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane))
        box.performClick(nil)

        XCTAssertEqual(reported.map(\.0), [AppSettingsPane.Identifier.showSeconds])
        XCTAssertEqual(reported.map(\.1), ["on"])
        // The pane does not adopt it. What it holds is still what the table said, so the window's read-back has
        // something to put the row back to.
        XCTAssertEqual(pane.values, stored)
    }

    func testAChangedNumberIsReportedTheSameWay() throws {
        let pane = AppSettingsPane()
        var reported: [(String, String)] = []
        pane.onChange = { reported.append(($0, $1)) }
        pane.show(stored)

        try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).onChange?(9)

        XCTAssertEqual(reported.map(\.0), [AppSettingsPane.Identifier.blipTime])
        XCTAssertEqual(reported.map(\.1), ["9"])
        XCTAssertEqual(pane.values.blipSeconds, 2, "unchanged: nothing here writes")
    }

    // MARK: - layout

    func testTheControlsLineUpUnderEachOther() throws {
        let pane = AppSettingsPane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        pane.layoutSubtreeIfNeeded()

        // The point of a fixed label column: a label sized to its own words would start each control at a different
        // x, which is the same reason the Categories tab fixes its columns.
        let xs = [
            AppSettingsPane.Identifier.dailyReset,
            AppSettingsPane.Identifier.batteryWarning,
            AppSettingsPane.Identifier.fetchInterval,
            AppSettingsPane.Identifier.blipTime,
        ].compactMap { identifier -> CGFloat? in
            guard let field = field(identifier, in: pane) else { return nil }
            return pane.convert(field.bounds, from: field).minX
        }
        XCTAssertEqual(xs.count, 4)
        XCTAssertEqual(Set(xs).count, 1, "one x, not four: \(xs)")
    }
}
