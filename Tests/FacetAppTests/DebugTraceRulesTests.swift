@testable import FacetApp
import Foundation
import XCTest

/// Covers the `debug` setting as values: the folder in and out of the form the table stores, and what an empty
/// setting means.
final class DebugTraceRulesTests: XCTestCase {
    func testTheStoredFolderIsExpandedWhereItIsUsed() throws {
        // A stored absolute path names one machine's home directory, and a database is copied between machines and
        // rebuilt from the DDL by the test suite. So the `~` is stored and expanded at the read.
        let url = try XCTUnwrap(DebugTraceRules.directoryURL(from: "~/Documents/Facet"))

        XCTAssertFalse(url.path.contains("~"))
        XCTAssertEqual(url.path, NSHomeDirectory() + "/Documents/Facet")
    }

    func testAnAbsoluteFolderIsTakenAsItStands() throws {
        let url = try XCTUnwrap(DebugTraceRules.directoryURL(from: "/Volumes/Spare/Facet"))

        XCTAssertEqual(url.path, "/Volumes/Spare/Facet")
    }

    func testASettingNamingNothingAnswersNothing() {
        // `nil` rather than a fallback, so the caller decides what an empty setting means -- the same reason
        // `SettingStore` answers `nil` for a missing row.
        XCTAssertNil(DebugTraceRules.directoryURL(from: ""))
        XCTAssertNil(DebugTraceRules.directoryURL(from: "   "))
    }

    func testAFolderInsideHomeIsStoredWithATilde() {
        let inside = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Facet", isDirectory: true)

        XCTAssertEqual(DebugTraceRules.stored(for: inside), "~/Documents/Facet")
    }

    func testAFolderOutsideHomeIsStoredAsItStands() {
        let outside = URL(fileURLWithPath: "/Volumes/Spare/Facet", isDirectory: true)

        XCTAssertEqual(DebugTraceRules.stored(for: outside), "/Volumes/Spare/Facet")
    }

    func testTheTwoDirectionsAgree() throws {
        let stored = DebugTraceRules.defaultDirectory
        let url = try XCTUnwrap(DebugTraceRules.directoryURL(from: stored))

        XCTAssertEqual(DebugTraceRules.stored(for: url), stored)
    }

    func testTheDefaultsAreWhatTheSeedGives() {
        // `database/011_setting.sql` seeds `{"enabled":false,"directory":"~/Library/Application Support/Facet"}`, and
        // these are what a database missing that row falls back to. The two must not drift.
        XCTAssertFalse(DebugTraceRules.defaultEnabled)
        XCTAssertEqual(DebugTraceRules.defaultDirectory, "~/Library/Application Support/Facet")
    }

    func testTheSeededFolderIsTheOneTheAppAlreadyUses() throws {
        // So a database that never had the row and one seeded today put the trace in the same place.
        let seeded = try XCTUnwrap(DebugTraceRules.directoryURL(from: DebugTraceRules.defaultDirectory))

        XCTAssertEqual(
            DatabaseBootstrap.debugDatabaseURL(in: seeded).path,
            DatabaseBootstrap.debugDatabaseURL().path
        )
    }

    func testAFolderNamesTheFileInsideIt() {
        // What the trace is called is not a setting: the folder is the only part anybody chooses.
        let chosen = URL(fileURLWithPath: "/Volumes/Spare/Facet", isDirectory: true)

        XCTAssertEqual(DatabaseBootstrap.debugDatabaseURL(in: chosen).path, "/Volumes/Spare/Facet/debug.sqlite")
    }

    func testACopyIsNamedForTheMomentItWasTaken() {
        // So two traces from the same person are told apart by their filenames rather than by asking which is which.
        var parts = DateComponents()
        parts.year = 2_026
        parts.month = 9
        parts.day = 3
        parts.hour = 22
        parts.minute = 15
        parts.second = 38
        let moment = Calendar.current.date(from: parts)!

        XCTAssertEqual(DebugTraceRules.copyName(at: moment), "facet-debug-2026-09-03-22.15.38.sqlite")
    }

    func testARowShowsTheStoredFormAndFallsBackWhenItIsEmpty() {
        XCTAssertEqual(DebugTraceRules.display("~/Documents/Facet"), "~/Documents/Facet")
        XCTAssertEqual(
            DebugTraceRules.display(""), DebugTraceRules.defaultDirectory,
            "a row naming nowhere would say nothing about where the file is"
        )
    }
}
