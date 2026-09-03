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
            log = DebugLog(databaseURL: database.debugURL, isRecording: true)
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

    // MARK: - the switch, while the app runs

    func testALogThatIsNotRecordingWritesNothing() {
        let quiet = DebugLog(databaseURL: database.debugURL, isRecording: false)

        quiet.record(.click, "Nobody asked for this")

        XCTAssertTrue(rows().isEmpty)
    }

    func testTheMessageIsNotEvenBuiltWhileItIsOff() {
        // **The property the whole design rests on.** Every call site reads `debugLog?.record(.transmit, "…\(hex)")`,
        // and Swift would build that string before entering this at all -- so a launch that records nothing would
        // still pay for a hex dump of every BLE packet. The message is an autoclosure for exactly this, and this is
        // what says so.
        let quiet = DebugLog(databaseURL: database.debugURL, isRecording: false)
        var built = 0

        quiet.record(.click, Self.expensive(counting: &built))

        XCTAssertEqual(built, 0, "the message was composed for a log that was never going to write it")
    }

    func testTheMessageIsBuiltExactlyOnceWhileItIsOn() {
        var built = 0

        log.record(.click, Self.expensive(counting: &built))

        XCTAssertEqual(built, 1, "the console and the row take the same string, built once")
    }

    private static func expensive(counting built: inout Int) -> String {
        built += 1
        return "Something that cost a string to say"
    }

    func testTurningItOnStartsRecordingAtThatMoment() {
        let log = DebugLog(databaseURL: database.debugURL, isRecording: false)
        log.record(.click, "Before")

        log.setRecording(true)
        log.record(.face, "After")

        // The switch is the first row, so a submitted trace says where it begins rather than starting mid-story.
        XCTAssertEqual(rows().map(\.message), ["Logging turned on", "After"])
    }

    func testTurningItOffStopsRecordingAtThatMoment() {
        log.record(.click, "Before")

        log.setRecording(false)
        log.record(.face, "After")

        // And the switch is the last row, so a trace that ends abruptly is saying it was switched off rather than
        // that the app died.
        XCTAssertEqual(rows().map(\.message), ["Before", "Logging turned off"])
    }

    func testBeingToldWhatItAlreadyIsWritesNothing() {
        // The window writes the row on every press, including one that did not change the value.
        log.setRecording(true)

        XCTAssertTrue(rows().isEmpty)
    }

    func testALaunchThatRecordsNothingLeavesNoFileBehind() {
        // The file is brought up on the first message, not at launch, so somebody who has never turned this on finds
        // nothing in the folder.
        let elsewhere = TemporaryDatabase()
        defer { elsewhere.remove() }
        let quiet = DebugLog(databaseURL: elsewhere.debugURL, isRecording: false)

        quiet.record(.click, "Nobody asked for this")

        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.debugURL.path))
    }

    func testTheFileIsBroughtUpByTheFirstMessageRecorded() {
        let elsewhere = TemporaryDatabase()
        defer { elsewhere.remove() }
        let log = DebugLog(databaseURL: elsewhere.debugURL, isRecording: true)

        log.record(.click, "The first thing that happened")

        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.debugURL.path))
    }

    // MARK: - the file it is writing

    func testTheLogNamesTheFileItIsWriting() {
        // The file that is open now, which is not the folder the `debug` setting names: a folder chosen on the App
        // tab holds no trace until the next launch. `DebugTraceFile` reads it for exactly that reason.
        XCTAssertEqual(log.databaseURL, database.debugURL)
    }
}
