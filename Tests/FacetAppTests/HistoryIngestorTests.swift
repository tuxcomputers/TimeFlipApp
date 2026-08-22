@testable import FacetApp
import Foundation
import XCTest

/// Bringing the cube's record of the day into `device_event`: what is asked for, in what order rows are written, and
/// when the stream is not trusted.
///
/// **Against a real database with a stubbed cube**, which is the only split that works here: the sequence is about
/// what ends up in the table, and the table is the one thing that can say. The cube is two closures because that is
/// all the ingestor uses of it -- one frame, or a stream from a number.
@MainActor
final class HistoryIngestorTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var events: DeviceEventRecorder!

    /// What the stubbed cube answers, and what it was asked.
    private var deviceLast: DeviceEventSegment?
    private var stream: [DeviceEventSegment] = []
    private var askedFrom: [Int] = []
    private var lastEventReads = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: nil,
            debugLog: nil
        )
        deviceLast = nil
        stream = []
        askedFrom = []
        lastEventReads = 0
    }

    override func tearDown() {
        events = nil
        database.remove()
        super.tearDown()
    }

    private func ingestor() -> HistoryIngestor {
        HistoryIngestor(
            events: events,
            readLastEvent: { [self] answered in
                lastEventReads += 1
                answered(deviceLast)
            },
            fetchHistory: { [self] from, answered in
                askedFrom.append(from)
                answered(stream)
            },
            debugLog: nil
        )
    }

    /// Runs a refresh and hands back what it came to. Every stub answers immediately, so this is settled on return.
    @discardableResult
    private func refresh(_ ingestor: HistoryIngestor) -> HistoryIngestor.Outcome? {
        var outcome: HistoryIngestor.Outcome?
        ingestor.refresh(because: "a test") { outcome = $0 }
        return outcome
    }

    private func segment(
        _ event: Int,
        face: Int = 3,
        at epoch: Int,
        seconds: TimeInterval = 60,
        paused: Bool = false
    ) -> DeviceEventSegment {
        DeviceEventSegment(
            eventNumber: event,
            face: face,
            startedAt: Date(timeIntervalSince1970: TimeInterval(epoch)),
            durationSeconds: seconds,
            isPaused: paused
        )
    }

    private func rows() -> [(event: Int, face: Int, epoch: Int, seconds: Double, finalised: Bool)] {
        var found: [(Int, Int, Int, Double, Bool)] = []
        database.connection().forEachRow(
            "SELECT event_number, device_face, start_epoch, duration_seconds, finalised FROM device_event "
                + "ORDER BY start_epoch, event_number;"
        ) { row in
            found.append((Int(row.int(0)), Int(row.int(1)), Int(row.int(2)), row.double(3), row.bool(4)))
        }
        return found.map { (event: $0.0, face: $0.1, epoch: $0.2, seconds: $0.3, finalised: $0.4) }
    }

    // MARK: - a first fetch

    func testAnEmptyDatabaseAsksFromTheBeginning() {
        deviceLast = segment(3, at: 3000)
        stream = [segment(1, at: 1000), segment(2, at: 2000), segment(3, at: 3000)]

        refresh(ingestor())

        XCTAssertEqual(askedFrom, [0])
    }

    func testEverythingButTheLastFrameIsRecordedAsFinished() {
        // The last frame of a complete dump is the interval the cube is still on; everything before it has been closed
        // out by the frame that follows it.
        deviceLast = segment(3, at: 3000)
        stream = [segment(1, at: 1000), segment(2, at: 2000), segment(3, at: 3000)]

        let outcome = refresh(ingestor())

        XCTAssertEqual(outcome, .recorded(finished: 2, openSegment: true))
        XCTAssertEqual(rows().map(\.event), [1, 2, 3])
        XCTAssertEqual(rows().map(\.finalised), [true, true, false])
    }

    func testTheFacesAndDurationsLandAsReported() {
        deviceLast = segment(2, face: 7, at: 2000, seconds: 90)
        stream = [segment(1, face: 4, at: 1000, seconds: 30), segment(2, face: 7, at: 2000, seconds: 90)]

        refresh(ingestor())

        XCTAssertEqual(rows().map(\.face), [4, 7])
        XCTAssertEqual(rows().map(\.seconds), [30, 90])
    }

    func testFramesArrivingOutOfOrderStillLand() {
        // **Order is not tidiness.** The recorder decides update-versus-insert from the newest row it can see, so a
        // later segment written first makes every earlier one look already superseded -- they take the update branch
        // against rows that were never inserted, and the backlog is silently dropped.
        deviceLast = segment(3, at: 3000)
        stream = [segment(3, at: 3000), segment(1, at: 1000), segment(2, at: 2000)]

        refresh(ingestor())

        XCTAssertEqual(rows().map(\.event), [1, 2, 3], "a frame was lost to out-of-order writing")
    }

    // MARK: - the cheap check

    func testACubeSittingOnTheRecordedSegmentSkipsTheStream() {
        // The whole value of the cheap check being a frame rather than a number: nothing new, so no stream at all.
        events.record(segment(5, at: 5000, seconds: 60))
        deviceLast = segment(5, at: 5000, seconds: 120)

        let outcome = refresh(ingestor())

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(askedFrom.isEmpty, "the stream was fetched for a segment already on record")
    }

    func testTheUnchangedSegmentIsStillRefreshed() {
        // Its duration has grown since it was last looked at, which is the reason the row is written anyway.
        events.record(segment(5, at: 5000, seconds: 60))
        deviceLast = segment(5, at: 5000, seconds: 120)

        refresh(ingestor())

        XCTAssertEqual(rows().map(\.seconds), [120])
    }

    func testAPauseArrivingOnTheSameSegmentIsRecorded() {
        // What a double tap looks like: the same interval, back again, marked paused. It is the only way the app finds
        // out, so it has to survive the cheap-check path rather than only the stream.
        events.record(segment(5, at: 5000, seconds: 60, paused: false))
        deviceLast = segment(5, at: 5000, seconds: 60, paused: true)

        refresh(ingestor())

        XCTAssertEqual(events.openSegment()?.isPaused, true)
    }

    // MARK: - resuming

    func testItResumesAtTheRecordedSegmentRatherThanPastIt() {
        // That row is normally the cube's still-open segment, and asking for it again is how its finished duration
        // comes back.
        events.record(segment(5, at: 5000))
        deviceLast = segment(7, at: 7000)
        stream = [segment(5, at: 5000), segment(6, at: 6000), segment(7, at: 7000)]

        refresh(ingestor())

        XCTAssertEqual(askedFrom, [5])
    }

    func testACounterThatWentBackwardsRestartsFromTheBeginning() {
        // A factory reset. The stored position names a segment the cube cannot reach, so asking for it would return
        // nothing for ever while everything the cube does hold went unfetched.
        events.record(segment(38, at: 5000))
        deviceLast = segment(2, at: 9000)
        stream = [segment(1, at: 8000), segment(2, at: 9000)]

        refresh(ingestor())

        XCTAssertEqual(askedFrom, [0])
    }

    func testTheOldGenerationsRowsAreLeftWhereTheyAre() {
        // They are recorded time, and the cube restarting a counter says nothing about time already spent. The pair
        // `(event_number, start_epoch)` is what lets a reused number land as its own row.
        events.record(segment(1, at: 100))
        deviceLast = segment(1, at: 9000)
        stream = [segment(1, at: 9000)]

        refresh(ingestor())

        XCTAssertEqual(rows().map(\.epoch), [100, 9000])
    }

    func testACubeThatDidNotAnswerLeavesThePositionStanding() {
        // A timed-out read re-requests the same thing rather than re-streaming everything the cube holds.
        events.record(segment(5, at: 5000))
        deviceLast = nil
        stream = [segment(5, at: 5000)]

        refresh(ingestor())

        XCTAssertEqual(askedFrom, [5])
    }

    func testAManualSegmentDoesNotAnswerWhereTheCubeIsUpTo() {
        // **The one that reached hardware.** `device_event` holds the app's own segments too, on faces above 12, and
        // they carry the epoch as their event number because nothing issued them one. Read the newest row of any kind
        // and a manual stretch timed after the cube's answers this with about 1.8 billion -- which no cube can reach,
        // so every refresh restarts from zero and re-streams the whole history, and the cheap check never matches.
        events.record(segment(5, at: 5000))
        events.startSegment(face: ManualFace.first, at: Date(timeIntervalSince1970: 9000))
        deviceLast = segment(7, at: 7000)
        stream = [segment(5, at: 5000), segment(6, at: 6000), segment(7, at: 7000)]

        refresh(ingestor())

        XCTAssertEqual(askedFrom, [5], "a manual segment answered where the cube's history is up to")
    }

    func testACubeSittingStillIsStillRecognisedAfterAManualSegment() {
        // The same fault seen from the other side: the cheap check compares against the position, so a poisoned
        // position turns every tick into a full stream of a history that has not changed.
        events.record(segment(5, at: 5000, seconds: 60))
        events.startSegment(face: ManualFace.first, at: Date(timeIntervalSince1970: 9000))
        deviceLast = segment(5, at: 5000, seconds: 120)

        let outcome = refresh(ingestor())

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(askedFrom.isEmpty, "the stream was fetched for a segment already on record")
    }

    // MARK: - a stream that did not finish

    func testAStreamShortOfTheCubesLatestDoesNotOpenASegment() {
        // A dropped stream also ends on a frame, and that frame is a closed segment with more history behind it.
        // Taking it as current would draw a stretch that finished some time ago as what is happening now.
        deviceLast = segment(9, at: 9000)
        stream = [segment(1, at: 1000), segment(2, at: 2000)]

        let outcome = refresh(ingestor())

        XCTAssertEqual(outcome, .incomplete)
        XCTAssertNil(events.openSegment(), "a segment was opened from a stream that never reached the cube's latest")
    }

    func testNoneOfAPartialStreamIsWritten() {
        // Not even the frames that arrived. The recorder decides open-versus-closed from the newest row it can see, so
        // the last one written always becomes the open segment -- and a partial batch would leave a stretch that
        // finished long ago drawn as what is happening now, which is what withholding the live frame is for.
        deviceLast = segment(9, at: 9000)
        stream = [segment(1, at: 1000), segment(2, at: 2000)]

        refresh(ingestor())

        XCTAssertTrue(rows().isEmpty)
    }

    func testTheNextRefreshAsksAgainFromTheSamePlaceAndGetsItAll() {
        // Nothing is lost by waiting: the position is the table, so a stream that finishes later brings the lot.
        deviceLast = segment(9, at: 9000)
        stream = [segment(1, at: 1000), segment(2, at: 2000)]
        let loop = ingestor()
        refresh(loop)

        stream = [segment(1, at: 1000), segment(2, at: 2000), segment(9, at: 9000)]
        refresh(loop)

        XCTAssertEqual(askedFrom, [0, 0], "the second fetch asked from somewhere else")
        XCTAssertEqual(rows().map(\.event), [1, 2, 9])
        XCTAssertEqual(events.openSegment()?.eventNumber, 9)
    }

    // MARK: - nothing to do

    func testACubeWithNoHistoryAtAllRecordsNothing() {
        deviceLast = nil
        stream = []

        let outcome = refresh(ingestor())

        XCTAssertEqual(outcome, .nothingToAsk)
        XCTAssertTrue(rows().isEmpty)
    }

    // MARK: - one at a time

    func testARefreshArrivingMidFetchIsDropped() {
        // Two fetches at once would be two conversations on one characteristic with nothing in the answers to say
        // which is which. The next tick reads the table again and picks up whatever is still due.
        deviceLast = segment(2, at: 2000)
        stream = [segment(1, at: 1000), segment(2, at: 2000)]
        var inner: HistoryIngestor.Outcome?
        let loop = HistoryIngestor(
            events: events,
            readLastEvent: { [self] answered in
                lastEventReads += 1
                // Re-entered from inside the first fetch, which is exactly what a tick landing mid-stream does.
                if lastEventReads == 1 {
                    self.pending?.refresh(because: "a second trigger") { inner = $0 }
                }
                answered(deviceLast)
            },
            fetchHistory: { [self] from, answered in
                askedFrom.append(from)
                answered(stream)
            },
            debugLog: nil
        )
        pending = loop

        refresh(loop)

        XCTAssertEqual(inner, .nothingToAsk, "a second refresh ran on top of the first")
        XCTAssertEqual(lastEventReads, 1)
    }

    private var pending: HistoryIngestor?

    // MARK: - telling the app

    func testSomethingRecordedSaysSo() {
        deviceLast = segment(2, at: 2000)
        stream = [segment(1, at: 1000), segment(2, at: 2000)]
        let loop = ingestor()
        var changed = 0
        loop.onChanged = { changed += 1 }

        refresh(loop)

        XCTAssertEqual(changed, 1)
    }

    func testNothingToRecordSaysNothing() {
        deviceLast = nil
        stream = []
        let loop = ingestor()
        var changed = 0
        loop.onChanged = { changed += 1 }

        refresh(loop)

        XCTAssertEqual(changed, 0)
    }
}
