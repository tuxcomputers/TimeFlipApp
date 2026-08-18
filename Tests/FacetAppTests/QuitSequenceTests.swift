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
    private var settings: SettingStore!
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
        settings = SettingStore(connection: connection)
        quit = QuitSequence(deviceEvents: events, settings: settings, debugLog: nil)
    }

    override func tearDown() {
        quit = nil
        settings = nil
        events = nil
        database.remove()
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
        let open = try XCTUnwrap(events.startSegment(face: 8, at: moment))
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
        let open = try XCTUnwrap(events.startSegment(face: 8, at: moment))
        quit.letGoOfTheDevice = nil

        quit.run(at: moment.addingTimeInterval(60))

        XCTAssertEqual(column("finalised", ofRow: open.deviceEventID), "1")
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

    // MARK: - pausing and locking the cube on the way out

    /// Records what was sent and hands back the answer the cube is pretending to give.
    private func recordSends(taking answer: Bool = true, into sent: NSMutableArray) -> (Data, @escaping (Bool) -> Void) -> Void {
        { command, reported in
            sent.add(command)
            reported(answer)
        }
    }

    func testTheCubeIsPausedAndThenLocked() {
        let sent = NSMutableArray()
        setPauseOnLock(true)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = recordSends(into: sent)
        var finished = false

        quit.pauseAndLockTheCube { finished = true }

        XCTAssertTrue(finished)
        XCTAssertEqual(sent.count, 2)
        // The order is the protocol's, not a preference: a cube that is locked and not paused goes on recording
        // against whatever face was up, for as long as it sits there with nobody watching.
        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.pause(true))
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.lock(true))
    }

    func testTheLockIsStillSentWhenThePauseDidNotTake() {
        // A pause the cube did not take is a reason to want the lock more, not less: giving up here would let one
        // failure cost both steps. Note what is being reported now -- the read-back, not the write.
        let sent = NSMutableArray()
        setPauseOnLock(true)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = recordSends(taking: false, into: sent)
        var finished = false

        quit.pauseAndLockTheCube { finished = true }

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.lock(true))
        XCTAssertTrue(finished, "and the quit is not held up by a cube that refused")
    }

    func testACubeThatNeverAnswersDoesNotHoldTheQuitOpen() {
        // The deadline. Nothing acknowledges here, which is a cube that went out of range mid-quit: the app must not
        // sit in the menu bar waiting for it.
        setPauseOnLock(true)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = { _, _ in }
        var finished = false
        quit.pauseAndLockTheCube { finished = true }
        XCTAssertFalse(finished, "precondition: nothing has answered yet")

        let ran = expectation(description: "the deadline fires")
        // Comfortably past `deviceSeconds`, and the only test here that spends real time: what is being asserted is
        // that a timer somebody could forget to arm is armed.
        DispatchQueue.main.asyncAfter(deadline: .now() + QuitSequence.deviceSeconds + 1) { ran.fulfill() }
        wait(for: [ran], timeout: QuitSequence.deviceSeconds + 5)

        XCTAssertTrue(finished)
    }

    func testTheQuitIsNotFinishedTwice() {
        // The deadline and the last acknowledgement race for it. Two replies to one quit is the sort of thing that
        // works until it does not.
        setPauseOnLock(true)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = { _, reported in reported(true) }
        var finishes = 0

        quit.pauseAndLockTheCube { finishes += 1 }

        XCTAssertEqual(finishes, 1)
    }

    func testWithNothingToSendToTheQuitJustProceeds() {
        // A build that never scanned, or a cube that went away before the quit: there is nothing to pause, and the
        // quit must not wait to discover that. Reported by the return value rather than by calling back, because a
        // completion run here would reply to a termination the delegate has not asked to delay yet.
        setPauseOnLock(true)
        quit.sendToTheDevice = nil
        var finished = false

        XCTAssertFalse(quit.pauseAndLockTheCube { finished = true })

        XCTAssertFalse(finished)
    }

    // MARK: - the gate

    func testTheCubeIsLeftAloneWhenPauseOnLockIsOff() {
        // The setting's own meaning: quitting is one of the two ways the app locks the cube, so with it off the quit
        // touches the cube in no way -- which is what somebody wanting it to go on tracking by itself has asked for.
        let sent = NSMutableArray()
        setPauseOnLock(false)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = recordSends(into: sent)

        XCTAssertFalse(quit.pauseAndLockTheCube { })

        XCTAssertEqual(sent.count, 0)
    }

    func testTheSettingIsReadAtTheStepAndNotBefore() {
        // `CLAUDE.md`'s worked example of the source-of-truth rule. Somebody who changes it on the App tab and then
        // quits gets the answer they just set, not the one that was true when the app launched.
        let sent = NSMutableArray()
        setPauseOnLock(false)
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = recordSends(into: sent)
        XCTAssertFalse(quit.pauseAndLockTheCube { }, "precondition: off means nothing is sent")

        setPauseOnLock(true)

        XCTAssertTrue(quit.pauseAndLockTheCube { })
        XCTAssertEqual(sent.count, 2)
    }

    func testAnUnreadableSettingLeavesTheCubeAlone() {
        // Deliberately not the seeded default. Of the two ways to be wrong, leaving the cube running is undone by
        // flipping it; a lock is not, since nothing in this app sends 0x04 0x02.
        let sent = NSMutableArray()
        XCTAssertTrue(database.execute("UPDATE setting SET setting_value = '{}' WHERE setting_name = 'pause_on_lock';"))
        quit.isDeviceConnected = { true }
        quit.sendToTheDevice = recordSends(into: sent)

        XCTAssertFalse(quit.pauseAndLockTheCube { })

        XCTAssertEqual(sent.count, 0)
    }

    func testADisconnectedCubeIsNotSentToEvenWithTheSettingOn() {
        setPauseOnLock(true)
        let sent = NSMutableArray()
        quit.isDeviceConnected = { false }
        quit.sendToTheDevice = recordSends(into: sent)

        XCTAssertFalse(quit.pauseAndLockTheCube { })

        XCTAssertEqual(sent.count, 0)
    }
}
