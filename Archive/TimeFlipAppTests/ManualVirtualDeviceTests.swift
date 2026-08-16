@testable import TimeFlipApp
import XCTest

/// The virtual device a manual session is timed against, configured the way
/// `ApplicationDelegate.startManualSession` configures it.
///
/// This is the same `MockTimeFlipDevice` the tests use, which is the point -- event numbering, the
/// history log and the segment bookkeeping all come for free. What is new is that its history now
/// reaches a **real** database, and the defaults that suit a test suit that badly.
@MainActor
final class ManualVirtualDeviceTests: XCTestCase {
    /// Fixed, so a segment's duration is what the test says it is rather than however long the test
    /// took to run.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeManualDevice() async -> MockTimeFlipDevice {
        let device = MockTimeFlipDevice(
            configuration: MockTimeFlipDevice.Configuration(
                initialFaceID: TimeFlipConstants.unassignedFaceID,
                isPaused: true,
                isInitiallyPaired: true,
                autoPauseMinutes: 0,
                emitInitialStatus: false,
                seedsSampleHistory: false,
                reportsOpenSegment: true
            )
        )
        _ = await device.connect()
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.setDeviceTime(start)
        return device
    }

    /// What `startManualTiming` does: flip onto the manual face, then unpause.
    private func pickCategory(on device: MockTimeFlipDevice) {
        device.flip(to: TimeFlipConstants.manualFaceID)
        device.setPaused(false)
    }

    // MARK: - Nothing invented, nothing running

    func testAManualDeviceStartsWithNoHistoryAtAll() async {
        // The default device invents two segments at init so a test has something to read. Ingested
        // into a real database those are hours the user never worked, on faces they never flipped,
        // landing in their daily totals and their Report as fact.
        let device = await makeManualDevice()
        let history = await device.fetchHistory(startingFrom: nil)
        XCTAssertTrue(history.isEmpty)
    }

    func testTheSampleHistoryIsStillThereByDefault() {
        // Both new flags default to the behaviour the rest of the suite was written against.
        XCTAssertTrue(MockTimeFlipDevice.Configuration().seedsSampleHistory)
        XCTAssertFalse(MockTimeFlipDevice.Configuration().reportsOpenSegment)
    }

    func testNothingIsBeingTimedUntilACategoryIsPicked() async {
        // No initial face means no active session. A device that opened one on face 4 -- the
        // default -- would be logging time against whatever category that face holds while the user
        // is still deciding what to time.
        let device = await makeManualDevice()
        let history = await device.fetchHistory(startingFrom: nil)
        XCTAssertTrue(history.isEmpty)
    }

    func testAutoPauseIsOffSoAManualTimerIsNeverStoppedForTheUser() async {
        // On a cube auto-pause is a convenience: it stops a timer left running by mistake. Here it
        // would stop one the user is deliberately relying on, with nothing on screen having changed.
        let device = await makeManualDevice()
        XCTAssertEqual(device.snapshot().autoPauseMinutes, 0)
    }

    // MARK: - The running segment is visible before it ends

    func testTheRunningSegmentIsReportedWhileItRuns() async {
        // The whole reason `reportsOpenSegment` exists. Without it a running segment lives only in
        // the device's memory until something closes it, so quitting -- which is the documented way
        // out of manual mode -- would lose whatever was being timed.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(90))

        guard let open = await device.fetchHistory(startingFrom: nil).last else {
            return XCTFail("expected the running segment to be reported")
        }
        XCTAssertEqual(open.faceID, TimeFlipConstants.manualFaceID)
        XCTAssertFalse(open.isPaused)
        XCTAssertEqual(open.duration, 90, accuracy: 0.5)
    }

    func testEverySegmentIsAWholeNumberOfSeconds() async {
        // A real device's history frame carries a count of seconds, so `device_event.duration_seconds`
        // has only ever held whole numbers. Subtracting two `Date`s does not, and manual mode is the
        // first path where that reaches the database: a segment closed a moment after it opened was
        // recording durations like 0.0000919103622437 seconds.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(12.75))
        device.setPaused(true)
        device.setDeviceTime(start.addingTimeInterval(30.4))

        let history = await device.fetchHistory(startingFrom: nil)
        XCTAssertFalse(history.isEmpty)
        for entry in history {
            XCTAssertEqual(entry.duration, entry.duration.rounded(.down), "fractional duration: \(entry.duration)")
        }
    }

    func testAPartSecondGoesToTheNearestWholeOne() async {
        // Nearest, not truncated. Truncating loses up to a second from every segment in the same
        // direction, and these feed the daily totals, so the loss accumulates over a day instead of
        // cancelling out.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(12.75))
        let roundedUp = await device.fetchHistory(startingFrom: nil).last?.duration
        XCTAssertEqual(roundedUp, 13)

        device.setDeviceTime(start.addingTimeInterval(20.25))
        let roundedDown = await device.fetchHistory(startingFrom: nil).last?.duration
        XCTAssertEqual(roundedDown, 20)
    }

    func testTheRunningSegmentKeepsOneEventNumberAsItGrows() async {
        // It has to be the same row growing, not a new row per refresh. `recordDeviceEvent` matches
        // on (event_number, start_epoch) and updates in place, so a fresh number each fetch would
        // record one segment several times over.
        let device = await makeManualDevice()
        pickCategory(on: device)

        device.setDeviceTime(start.addingTimeInterval(30))
        let first = await device.fetchHistory(startingFrom: nil).last
        device.setDeviceTime(start.addingTimeInterval(60))
        let second = await device.fetchHistory(startingFrom: nil).last

        XCTAssertNotNil(first?.eventNumber)
        XCTAssertEqual(first?.eventNumber, second?.eventNumber)
        XCTAssertEqual(first?.startedAt, second?.startedAt)
        XCTAssertGreaterThan(second?.duration ?? 0, first?.duration ?? 0)
    }

    func testTheDevicesCurrentRecordIsTheRunningSegment() async {
        // The cheap single-frame check the ingestor makes before pulling the stream. It has to name
        // the same segment the dump ends on, or the two disagree about what "current" is.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(45))

        let current = await device.readLastEvent()
        let lastFrame = await device.fetchHistory(startingFrom: nil).last
        XCTAssertEqual(current?.eventNumber, lastFrame?.eventNumber)
    }

    // MARK: - Stopping and switching

    func testStoppingClosesTheWorkedSegmentAndOpensAStoppedOne() async {
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(600))
        device.setPaused(true)

        let history = await device.fetchHistory(startingFrom: nil)
        let worked = history.filter { !$0.isPaused }
        XCTAssertEqual(worked.count, 1)
        XCTAssertEqual(worked.first?.duration ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(history.last?.isPaused, true, "the segment now open is the stopped one")
    }

    func testEveryZeroLengthStubIsPausedSoNoneBecomesATimeEntry() async {
        // Why `startManualTiming` flips before it unpauses. Either order leaves a zero-length stub
        // where one segment ends and the next begins; this order makes every such stub a *paused*
        // one, and paused segments are never converted into `time_entry` rows. The other order
        // would put zero-second entries in the user's totals against what they had been doing.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(300))
        device.setPaused(true)

        // Picked something else while stopped, which is the sequence that produces the stubs.
        device.setDeviceTime(start.addingTimeInterval(900))
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(1_200))

        let history = await device.fetchHistory(startingFrom: nil)
        let stubs = history.filter { $0.duration < 1 }
        XCTAssertFalse(stubs.isEmpty, "this sequence necessarily leaves stubs")
        for stub in stubs {
            XCTAssertTrue(stub.isPaused, "a zero-length stub must be paused so it never becomes a time_entry")
        }
    }

    func testSwitchingCategoryClosesTheSegmentBeforeTheNextOneOpens() async {
        // Two worked segments, not one long one: the category change has to land between them, and
        // that is only possible if the first is closed by the time the second starts.
        let device = await makeManualDevice()
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(120))
        pickCategory(on: device)
        device.setDeviceTime(start.addingTimeInterval(300))

        let history = await device.fetchHistory(startingFrom: nil)
        let worked = history.filter { !$0.isPaused && $0.duration >= 1 }
        XCTAssertEqual(worked.count, 2)
        XCTAssertEqual(worked.first?.duration ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(worked.last?.duration ?? 0, 180, accuracy: 0.5)
    }
}
