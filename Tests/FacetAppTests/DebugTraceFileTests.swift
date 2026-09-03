@testable import FacetApp
import Foundation
import SQLite3
import XCTest

/// Covers `DebugTraceFile`: the trace as a file, acted on whether or not this launch is writing to it.
///
/// **The point of the type, and what the tests are really about**, is that a copy and a clear have to work in a
/// launch with no logger. That is most of a support conversation: somebody turns logging on, reproduces the fault,
/// quits, and sends the file from a launch that is recording nothing.
@MainActor
final class DebugTraceFileTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var trace: DebugTraceFile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            try database.bootstrapDebug()
            trace = DebugTraceFile(url: database.debugURL)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated { database.remove() }
        super.tearDown()
    }

    /// Every `debug_log` message in a given file, oldest first.
    private func messages(in url: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not open \(url.path)")
            return []
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle, "SELECT message FROM debug_log ORDER BY debug_log_id;", -1, &statement, nil
        ) == SQLITE_OK else {
            XCTFail("could not read debug_log")
            return []
        }
        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return found
    }

    /// Writes a row without a `DebugLog`, so a test can act on a trace nothing has open.
    private func recordWithoutALogger(_ message: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.debugURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = "INSERT INTO debug_log (logged_at, timezone_id, tag, message) "
            + "VALUES ('2026-09-04T05:35:00.000', 0, 'trace', '\(message)');"
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    // MARK: - which file

    func testTheOpenFileWinsOverTheSetting() {
        // A folder chosen a minute ago names somewhere that holds no trace yet; the logger's own file is the one with
        // anything in it.
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)

        let chosen = DebugTraceFile.inUse(by: log, directory: "/Volumes/Spare/Facet")

        XCTAssertEqual(chosen.url, database.debugURL)
    }

    func testWithNoLoggerTheSettingIsTheOnlyAnswer() {
        let chosen = DebugTraceFile.inUse(by: nil, directory: "/Volumes/Spare/Facet")

        XCTAssertEqual(chosen.url.path, "/Volumes/Spare/Facet/debug.sqlite")
    }

    func testItSaysWhetherThereIsAFileAtAll() {
        XCTAssertTrue(trace.exists)

        XCTAssertFalse(DebugTraceFile(url: database.directory.appendingPathComponent("nothing.sqlite")).exists)
    }

    // MARK: - a copy to send in

    func testACopyOpensOnItsOwnAndCarriesTheRows() {
        // **With nothing holding the file open**, which is the case this type exists for: logging is off, and the
        // trace from the launch that went wrong is still there to be sent.
        recordWithoutALogger("Something worth sending in")
        let destination = database.directory.appendingPathComponent("sent.sqlite")

        XCTAssertTrue(trace.copy(to: destination))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(messages(in: destination), ["Something worth sending in"])
    }

    func testACopyTakenWhileTheAppIsWritingIsStillWhole() {
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)
        log.record(.trace, "Written by the running app")
        let destination = database.directory.appendingPathComponent("sent.sqlite")

        XCTAssertTrue(trace.copy(to: destination))

        XCTAssertEqual(messages(in: destination), ["Written by the running app"])
    }

    func testACopyReplacesWhateverWasThere() {
        // `VACUUM INTO` refuses to write over a file, and the save panel has already had the conversation about
        // replacing one -- so a second copy to the same name has to work rather than fail silently.
        let destination = database.directory.appendingPathComponent("sent.sqlite")
        XCTAssertTrue(trace.copy(to: destination))
        recordWithoutALogger("Recorded after the first copy")

        XCTAssertTrue(trace.copy(to: destination))

        XCTAssertEqual(messages(in: destination), ["Recorded after the first copy"])
    }

    func testACopyThatCannotBeWrittenSaysSo() {
        // Never silently: a copy that did not happen looks exactly like one that did until somebody opens it.
        let destination = database.directory
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("sent.sqlite")

        XCTAssertFalse(trace.copy(to: destination))
    }

    func testACopyOfATraceThatIsNotThereIsRefused() {
        let missing = DebugTraceFile(url: database.directory.appendingPathComponent("nothing.sqlite"))

        XCTAssertFalse(missing.copy(to: database.directory.appendingPathComponent("sent.sqlite")))
    }

    // MARK: - emptying it

    func testClearingTakesEveryRowAway() {
        recordWithoutALogger("Something from before")
        recordWithoutALogger("And something after it")
        XCTAssertEqual(messages(in: database.debugURL).count, 2, "precondition")

        XCTAssertTrue(trace.clear())

        // Nothing at all: the row saying it was cleared is the window's to write, through whatever logger this launch
        // has, and a launch with none was not writing rows in the first place.
        XCTAssertEqual(messages(in: database.debugURL), [])
    }

    func testARunningLogGoesOnWritingAfterwards() {
        // **The reason the rows go and the file stays.** Deleting the file would pull it out from under an open
        // connection and a prepared insert.
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)
        log.record(.trace, "Something from before")

        XCTAssertTrue(trace.clear())
        log.record(.face, "And something after it")

        XCTAssertEqual(messages(in: database.debugURL), ["And something after it"])
    }

    func testARowWrittenAfterClearingStillCarriesItsZone() {
        // `timezone` is left alone on purpose: a running log resolved its `timezone_id` when it opened and every row
        // carries it as a real foreign key, so clearing that table too would make the very next insert fail.
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)
        XCTAssertTrue(trace.clear())

        log.record(.face, "After the clear")

        XCTAssertEqual(messages(in: database.debugURL), ["After the clear"], "the insert was not refused")
    }

    func testTheRowIdsDoNotStartAgainAfterAClear() {
        // **Pinned because the scripted suite is built on it.** Every check marks `MAX(debug_log_id)` and then polls
        // for rows above it, so ids that restarted at 1 would put every later row underneath a baseline taken before
        // the clear, and every wait would time out against an app that was answering perfectly well. `AUTOINCREMENT`
        // is what guarantees this: sqlite keeps the highest id ever issued in `sqlite_sequence`, and neither the
        // delete nor the `VACUUM` touches it.
        recordWithoutALogger("Before the clear")
        let before = maximumID()

        XCTAssertTrue(trace.clear())
        recordWithoutALogger("After the clear")

        XCTAssertGreaterThan(try XCTUnwrap(maximumID()), try XCTUnwrap(before))
    }

    /// The highest `debug_log_id` in the trace, or `nil` when it holds no rows.
    private func maximumID() -> Int64? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.debugURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT max(debug_log_id) FROM debug_log;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    func testClearingATraceThatIsNotThereIsRefused() {
        let missing = DebugTraceFile(url: database.directory.appendingPathComponent("nothing.sqlite"))

        XCTAssertFalse(missing.clear())
        XCTAssertFalse(missing.exists, "and nothing was brought into being to clear")
    }
}
