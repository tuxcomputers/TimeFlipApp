@testable import FacetApp
import Foundation
import XCTest

/// Covers `QuitSequence`: what the app does to the segment still running when it ends.
///
/// Driven by calling `run(at:)` rather than by terminating the test process. What that skips is AppKit
/// delivering `applicationWillTerminate`, which is the part with no decisions in it -- and the part `main.swift`
/// holds the delegate in a binding for, since `NSApplication.delegate` is weak.
@MainActor
final class QuitSequenceTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var events: DeviceEventRecorder!
    private var quit: QuitSequence!

    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        // Segments here run on face 8, which the DDL seeds with Break and locked, so they have a category to be
        // filed under without this test assigning one.
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: TimeEntryRecorder(
                connection: connection,
                settings: SettingStore(connection: connection),
                faces: FaceStore(connection: connection),
                debugLog: nil
            ),
            debugLog: nil
        )
        quit = QuitSequence(deviceEvents: events, debugLog: nil)
    }

    override func tearDown() {
        quit = nil
        events = nil
        database.remove()
        super.tearDown()
    }

    private func column(_ name: String, ofRow rowID: Int) -> String? {
        database.string("SELECT \(name) FROM device_event WHERE device_event_id = \(rowID);")
    }

    func testQuittingClosesTheSegmentStillRunning() throws {
        let open = try XCTUnwrap(events.startSegment(face: 8, at: moment))

        quit.run(at: moment.addingTimeInterval(300))

        XCTAssertEqual(column("finalised", ofRow: open.deviceEventID), "1")
        XCTAssertEqual(column("duration_seconds", ofRow: open.deviceEventID), "300.0", "it ran until the app ended")
    }

    func testTheClosedSegmentBecomesTrackedTime() throws {
        // Closing is what raises the entry question, so quitting is the last chance a session has to be counted.
        let open = try XCTUnwrap(events.startSegment(face: 8, at: moment))

        quit.run(at: moment.addingTimeInterval(900))

        XCTAssertEqual(
            database.string("SELECT duration_seconds FROM time_entry WHERE device_event_id = \(open.deviceEventID);"),
            "900.0"
        )
    }

    func testQuittingWithNothingBeingTimedChangesNothing() {
        quit.run(at: moment)

        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event;"), "0")
        XCTAssertEqual(database.string("SELECT COUNT(*) FROM time_entry;"), "0")
    }

    func testNothingIsLeftOpenForTheNextLaunchToFind() throws {
        // The defect this exists for. A row left open is closed by the next launch's first click, measuring every
        // second since -- including the hours the app was not running -- and that is an entry, not just a
        // duration: a session of a few minutes came back as 39.
        events.startSegment(face: 8, at: moment)

        quit.run(at: moment.addingTimeInterval(120))

        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;"), "0")

        // A launch a day later: there is nothing for its first click to close, so nothing can be measured from
        // yesterday's start to now.
        XCTAssertNil(events.closeOpenSegment(at: moment.addingTimeInterval(86_400)))
        XCTAssertEqual(database.string("SELECT SUM(duration_seconds) FROM time_entry;"), "120.0")
    }
}
