@testable import FacetApp
import Foundation
import SQLite3
import XCTest

/// Covers `DebugLog`: that a recorded message becomes a row, that the row is shaped the way anything
/// reading it later expects, and that the tags stay aligned on the console.
///
/// Rows rather than console output, because the row is what a failed session is reconstructed from --
/// and because console output cannot be asserted on without capturing a file descriptor, which would
/// test the plumbing instead of the record.
@MainActor
final class DebugLogTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var log: DebugLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            // The trace's own database, which is the only one that has `debug_log` in it.
            try database.bootstrapDebug()
            log = DebugLog(databaseURL: database.debugURL)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            // Released before the file goes, so the connection closes first.
            log = nil
            database.remove()
        }
        super.tearDown()
    }

    /// Every `debug_log` row, oldest first.
    private func rows() -> [(loggedAt: String, timezoneID: Int64, tag: String, message: String)] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.debugURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not open the database")
            return []
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT logged_at, timezone_id, tag, message FROM debug_log ORDER BY debug_log_id;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            XCTFail("could not read debug_log")
            return []
        }
        var found: [(String, Int64, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append((
                String(cString: sqlite3_column_text(statement, 0)),
                sqlite3_column_int64(statement, 1),
                String(cString: sqlite3_column_text(statement, 2)),
                String(cString: sqlite3_column_text(statement, 3))
            ))
        }
        return found
    }

    // MARK: - the record

    func testARecordedMessageBecomesARow() {
        log.record(.click, "Status item clicked: side=left clicks=1 -> showMenu")

        let rows = rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tag, "click", "the tag is stored bare, without its brackets or padding")
        XCTAssertEqual(rows.first?.message, "Status item clicked: side=left clicks=1 -> showMenu")
    }

    func testMessagesAreRecordedInTheOrderTheyHappened() {
        log.record(.click, "first")
        log.record(.menu, "second")
        log.record(.tab, "third")

        XCTAssertEqual(rows().map(\.message), ["first", "second", "third"])
        XCTAssertEqual(rows().map(\.tag), ["click", "menu", "tab"])
    }

    func testTheTimestampIsLocalTimeToTheMillisecond() throws {
        log.record(.click, "timed")

        let loggedAt = try XCTUnwrap(rows().first?.loggedAt)
        // `2026-08-12T13:25:38.472`: no offset and no `Z`, because the zone is the row's own foreign key
        // rather than part of the text, and milliseconds because two clicks can share a second.
        let shape = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}$"#)
        XCTAssertEqual(
            shape.numberOfMatches(in: loggedAt, range: NSRange(loggedAt.startIndex..., in: loggedAt)), 1,
            "unexpected shape: \(loggedAt)"
        )
    }

    func testTheRowNamesTheZoneItsTimeWasRecordedIn() throws {
        log.record(.click, "zoned")

        let timezoneID = try XCTUnwrap(rows().first?.timezoneID)
        XCTAssertNotEqual(timezoneID, 0, "0 is the Unknown sentinel, and this machine has a real zone")
        XCTAssertEqual(
            // **The trace's own `timezone` table, not the app's.** The two files each carry one and each fills it
            // independently, so the same zone can be a different id in each -- which is why nothing may join across
            // them, and why a row in a submitted `debug.sqlite` is readable without the app's database beside it.
            database.debugString("SELECT timezone_name FROM timezone WHERE timezone_id = \(timezoneID);"),
            TimeZone.current.identifier,
            "the zone row should be got-or-created for the machine's current zone"
        )
    }

    // MARK: - the console prefix

    func testEveryTagBracketsToTheSameWidth() {
        let widths = Set(DebugLog.Tag.allCases.map(\.bracketed.count))
        XCTAssertEqual(
            widths.count, 1,
            "a new case must re-pad the rest rather than break alignment: "
                + DebugLog.Tag.allCases.map(\.bracketed).joined(separator: " ")
        )
    }

    func testTheLongestTagIsNotPadded() {
        // The one case that comes out flush, which is what proves the width is measured rather than a
        // number that happens to be big enough today.
        let longest = DebugLog.Tag.allCases.max { $0.rawValue.count < $1.rawValue.count }
        XCTAssertEqual(longest?.bracketed, longest.map { "[\($0.rawValue)]" })
    }

    // MARK: - a copy to send in

    func testTheLogNamesTheFileItIsWriting() {
        // The file that is open now, which is not the folder the `debug` setting names: a folder chosen on the App
        // tab holds no trace until the next launch.
        XCTAssertEqual(log.databaseURL, database.debugURL)
    }

    func testACopyOpensOnItsOwnAndCarriesTheRows() throws {
        log.record(.trace, "Something worth sending in")
        let destination = database.directory.appendingPathComponent("sent.sqlite")

        XCTAssertTrue(log.copy(to: destination))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        // Read back through its own connection: what makes the copy worth having is that it opens without the
        // original beside it.
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_open_v2(destination.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT message FROM debug_log ORDER BY debug_log_id;", -1, &statement, nil),
            SQLITE_OK
        )
        var messages: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            messages.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        XCTAssertTrue(messages.contains("Something worth sending in"), "\(messages)")
    }

    func testTakingACopyIsItselfRecorded() throws {
        let destination = database.directory.appendingPathComponent("sent.sqlite")

        XCTAssertTrue(log.copy(to: destination))

        XCTAssertTrue(
            rows().contains { $0.tag == "trace" && $0.message.hasPrefix("Trace copied to") },
            "the trace says where a copy of it went: \(rows().map(\.message))"
        )
    }

    func testACopyReplacesWhateverWasThere() throws {
        // `VACUUM INTO` refuses to write over a file, and the save panel has already had the conversation about
        // replacing one -- so a second copy to the same name has to work rather than fail silently.
        let destination = database.directory.appendingPathComponent("sent.sqlite")
        XCTAssertTrue(log.copy(to: destination))
        log.record(.trace, "Recorded after the first copy")

        XCTAssertTrue(log.copy(to: destination))

        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_open_v2(destination.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT count(*) FROM debug_log WHERE message = 'Recorded after the first copy';",
                -1, &statement, nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1, "the second copy is the trace as it stands now")
    }

    func testACopyThatCannotBeWrittenSaysSo() {
        // Never silently: a copy that did not happen looks exactly like one that did until somebody opens it.
        let destination = database.directory
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("sent.sqlite")

        XCTAssertFalse(log.copy(to: destination))
    }
}
