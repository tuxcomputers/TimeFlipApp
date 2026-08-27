@testable import FacetApp
import Foundation
import XCTest

/// Covers `QuitSequence`: what the app does to the segment still running when it ends.
///
/// Driven by calling `run(at:)` rather than by terminating the test process. What that skips is AppKit
/// delivering `applicationWillTerminate`, which is the part with no decisions in it -- and the part `main.swift`
/// holds the delegate in a binding for, since `NSApplication.delegate` is weak.
@MainActor
final class QuitSequenceTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var events: DeviceEventRecorder!
    private var settings: SettingStore!
    private var quit: QuitSequence!

    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            try database.bootstrap()
            let connection = database.connection()
            // Segments here run on `ManualFace.first`, because that is the only kind of segment a quit closes: a face
            // of the app's own, timed by the app's own clock. A cube's face is left alone -- see
            // `testACubesOwnSegmentIsLeftForItsHistoryToClose` -- so a test that started one on face 8 would be asserting
            // the very thing that must not happen.
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
            settings = SettingStore(connection: connection)
            quit = QuitSequence(deviceEvents: events, debugLog: nil)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            quit = nil
            settings = nil
            events = nil
            database.remove()
        }
        super.tearDown()
    }

    private func setPauseOnLock(_ enabled: Bool) {
        XCTAssertTrue(
            database.execute(
                "UPDATE setting SET setting_value = '{\"enabled\":\(enabled)}' WHERE setting_name = 'pause_on_lock';"
            )
        )
    }

    private func column(_ name: String, ofRow rowID: Int) -> String? {
        database.string("SELECT \(name) FROM device_event WHERE device_event_id = \(rowID);")
    }

    func testQuittingClosesTheSegmentStillRunning() throws {
        let open = try XCTUnwrap(events.startSegment(face: ManualFace.first, at: moment))

        quit.run(at: moment.addingTimeInterval(300))

        XCTAssertEqual(column("finalised", ofRow: open.deviceEventID), "1")
        XCTAssertEqual(column("duration_seconds", ofRow: open.deviceEventID), "300.0", "it ran until the app ended")
    }

    func testTheClosedSegmentBecomesTrackedTime() throws {
        // Closing is what raises the entry question, so quitting is the last chance a session has to be counted.
        let open = try XCTUnwrap(events.startSegment(face: ManualFace.first, at: moment))

        quit.run(at: moment.addingTimeInterval(900))

        XCTAssertEqual(
            database.string("SELECT duration_seconds FROM time_entry WHERE device_event_id = \(open.deviceEventID);"),
            "900.0"
        )
    }

    func testACubesOwnSegmentIsLeftForItsHistoryToClose() throws {
        // **The cube keeps timing after this process has gone**, so the stretch it is on has not ended and its length
        // is not this app's to write. Closing it here measured from its start to the quit, filed that guess as
        // tracked time, and left the next launch to fetch the very same event back from the cube.
        let open = try XCTUnwrap(
            events.record(
                DeviceEventSegment(
                    eventNumber: 40,
                    face: 5,
                    startedAt: moment,
                    durationSeconds: 60,
                    isPaused: false
                )
            )
        )
        XCTAssertTrue(open.isOpen, "precondition: the cube is timing")

        quit.run(at: moment.addingTimeInterval(300))

        XCTAssertEqual(column("finalised", ofRow: open.deviceEventID), "0", "still open")
        XCTAssertEqual(
            column("duration_seconds", ofRow: open.deviceEventID), "60.0",
            "and still the length the cube reported, not the length the quit would have measured"
        )
        XCTAssertEqual(database.string("SELECT COUNT(*) FROM time_entry;"), "0", "nothing has finished, so nothing counts")
    }

    func testQuittingWithNothingBeingTimedChangesNothing() {
        quit.run(at: moment)

        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event;"), "0")
        XCTAssertEqual(database.string("SELECT COUNT(*) FROM time_entry;"), "0")
    }

    // MARK: - letting go of the device

    func testQuittingGivesTheDeviceBack() {
        // The connection outlives the Settings window now, so the app is what ends it. Nothing else would: the
        // process simply stops, and the last thing written would say the cube is connected.
        var letGo = 0
        quit.letGoOfTheDevice = { letGo += 1; return true }

        quit.run(at: moment)

        XCTAssertEqual(letGo, 1)
    }

    func testTheSegmentIsClosedBeforeTheDeviceIsLetGo() throws {
        // The entry is made from the app's own rows rather than from anything the cube says, so this is about order
        // being decided rather than the second step depending on the first.
        let open = try XCTUnwrap(events.startSegment(face: ManualFace.first, at: moment))
        var finalisedWhenLetGo: String?
        let database = self.database!
        quit.letGoOfTheDevice = {
            finalisedWhenLetGo = database.string(
                "SELECT finalised FROM device_event WHERE device_event_id = \(open.deviceEventID);"
            )
            return false
        }

        quit.run(at: moment.addingTimeInterval(60))

        XCTAssertEqual(finalisedWhenLetGo, "1")
    }

    func testAQuitWithNoDeviceStillRunsTheRestOfTheSequence() throws {
        // A build that has never scanned has no radio at all, which is the ordinary case and must not stop the
        // segment being closed.
        let open = try XCTUnwrap(events.startSegment(face: ManualFace.first, at: moment))
        quit.letGoOfTheDevice = nil

        quit.run(at: moment.addingTimeInterval(60))

        XCTAssertEqual(column("finalised", ofRow: open.deviceEventID), "1")
    }

    func testNothingIsLeftOpenForTheNextLaunchToFind() throws {
        // The defect this exists for. A row left open is closed by the next launch's first click, measuring every
        // second since -- including the hours the app was not running -- and that is an entry, not just a
        // duration: a session of a few minutes came back as 39.
        events.startSegment(face: ManualFace.first, at: moment)

        quit.run(at: moment.addingTimeInterval(120))

        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;"), "0")

        // A launch a day later: there is nothing for its first click to close, so nothing can be measured from
        // yesterday's start to now.
        XCTAssertNil(events.closeOpenSegment(at: moment.addingTimeInterval(86_400)))
        XCTAssertEqual(database.string("SELECT SUM(duration_seconds) FROM time_entry;"), "120.0")
    }

    // MARK: - stopping the cube on the way out

    /// A lock wired to a cube that answers, and a note of what was sent. What the sequence *is* belongs to
    /// `CubeLockTests`; what is checked here is the quit's own part -- that it waits, and that it does not wait for
    /// ever.
    private func cubeLock(answering: Bool = true, into sent: NSMutableArray) -> CubeLock {
        CubeLock(
            settings: settings,
            isConnected: { true },
            send: { command, reported in
                sent.add(command)
                reported(answering)
            },
            debugLog: nil
        )
    }

    private func silentCubeLock() -> CubeLock {
        // Nothing ever answers, which is a cube that went out of range mid-quit.
        CubeLock(settings: settings, isConnected: { true }, send: { _, _ in }, debugLog: nil)
    }

    func testTheCubeIsStoppedBeforeTheAppGoes() {
        setPauseOnLock(true)
        let sent = NSMutableArray()
        quit.cubeLock = cubeLock(into: sent)
        var finished = false

        XCTAssertTrue(quit.pauseAndLockTheCube { finished = true })

        XCTAssertTrue(finished)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.pause(true))
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.lock(true))
    }

    func testACubeThatNeverAnswersDoesNotHoldTheQuitOpen() {
        // The deadline, which is the quit's own contribution: the app must not sit in the menu bar waiting for a cube
        // that has gone. Nothing else here spends real time.
        setPauseOnLock(true)
        quit.cubeLock = silentCubeLock()
        var finished = false
        XCTAssertTrue(quit.pauseAndLockTheCube { finished = true })
        XCTAssertFalse(finished, "precondition: nothing has answered yet")

        let ran = expectation(description: "the deadline fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + QuitSequence.deviceSeconds + 1) { ran.fulfill() }
        wait(for: [ran], timeout: QuitSequence.deviceSeconds + 5)

        XCTAssertTrue(finished)
    }

    func testTheQuitIsNotFinishedTwice() {
        // The deadline and the sequence race for it. Two replies to one quit is the sort of thing that works until it
        // does not.
        setPauseOnLock(true)
        let sent = NSMutableArray()
        quit.cubeLock = cubeLock(into: sent)
        var finishes = 0

        quit.pauseAndLockTheCube { finishes += 1 }

        XCTAssertEqual(finishes, 1)
    }

    func testWithNothingToSendToTheQuitJustProceeds() {
        // A build that never scanned, or a cube that went away before the quit. Reported by the return value rather
        // than by calling back, because a completion run here would reply to a termination the delegate has not asked
        // to delay yet.
        setPauseOnLock(true)
        quit.cubeLock = nil
        var finished = false

        XCTAssertFalse(quit.pauseAndLockTheCube { finished = true })

        XCTAssertFalse(finished)
    }

    func testQuittingWithPauseOnLockOffStillLocksAndIsStillWaitedFor() {
        // **Quit is the second of the two places that lock**, so it moved with the first. The setting decides whether
        // a pause goes in front of the lock, not whether quitting locks at all, and the quit has to be deferred for
        // the one command exactly as it is for the two -- a lock nobody waits for is a lock that races the process
        // going away.
        setPauseOnLock(false)
        let sent = NSMutableArray()
        quit.cubeLock = cubeLock(into: sent)
        var finished = false

        XCTAssertTrue(quit.pauseAndLockTheCube { finished = true })

        XCTAssertEqual(sent.count, 1, "the lock, and no pause in front of it")
        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(true))
        XCTAssertTrue(finished)
    }
}
