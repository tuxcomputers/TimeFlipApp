import SQLite3
@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
// Minimal fake device that returns canned history frames.
@MainActor
final class FakeDevice: TimeFlipSessionManaging {
    var events: AsyncStream<TimeFlipEvent> { AsyncStream { _ in } }
    /// Nothing here reads the name; it exists to satisfy `TimeFlipDevice`. `nil` is the honest
    /// value for a double that has no peripheral behind it.
    var deviceName: String?
    var deviceIdentifier: String?
    private(set) var history: [TimeFlipHistoryEntry] = []
    private(set) var fetchHistoryCallCount = 0
    /// Overrides what readLastEvent() reports, decoupled from `history`, so tests can simulate a
    /// stream that got cut short before reaching the device's actual last event.
    var deviceLastEventOverride: TimeFlipHistoryEntry?
    var snapshotValue = TimeFlipDeviceSnapshot(
        faceID: TimeFlipConstants.minFaceID,
        isPaused: true,
        isLocked: false,
        autoPauseMinutes: 0,
        batteryLevel: 100,
        systemState: .ok,
        deviceTime: Date(),
        deviceInfo: nil
    )

    init(history: [TimeFlipHistoryEntry]) {
        self.history = history
    }

    func start() {}
    func stop() {}
    func connect() async -> Bool { true }
    func disconnect() async {}
    func login(password: String) async -> Bool { true }
    func enableNotifications() async {}
    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async {}
    func setFaceColor(faceID: UInt8, components: ColorComponents) async {}
    func setAutoPause(minutes: UInt16) async {}
    func setLEDBrightness(percent: UInt8) async {}
    func setBlinkInterval(seconds: UInt8) async {}
    func setDoubleTapParameters(_ params: DoubleTapParameters) async {}
    func readDoubleTapParameters() async -> DoubleTapParameters? { nil }
    // Nothing here exercises a reset or the task commands; MockTimeFlipDevice models them properly
    // and W06 / MockDeviceParityTests drive them.
    func factoryReset() async -> Bool { false }
    func setFaceTaskParameters(_ params: FaceTaskParameters) async -> Bool { false }
    func readFaceTaskParameters(faceID: UInt8) async -> FaceTaskParameters? { nil }
    func setDeviceName(_ name: String) async -> Bool { false }
    func resetTaskInfoToDefault() async -> Bool { false }
    func refreshDeviceInfo() async {}
    func readElapsedSeconds(faceID: UInt8) async -> TimeInterval? { nil }
    func setPause(_ paused: Bool) async {}
    func setLock(_ locked: Bool) async {}
    func refreshLockState() async -> Bool { snapshotValue.isLocked }
    func snapshot() -> TimeFlipDeviceSnapshot { snapshotValue }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        fetchHistoryCallCount += 1
        guard let start = eventNumber else { return history }
        return history.filter { entry in
            guard let eventNumber = entry.eventNumber else { return false }
            return eventNumber >= start
        }
    }

    func readLastEvent() async -> TimeFlipHistoryEntry? {
        deviceLastEventOverride ?? history.max { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
    }
}

@MainActor
final class HistoryIngestorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDataStore.resetForTests(at: historyIngestorTestDBURL)
    }

    func testAdvancesCursorAndStoresEvents() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(
                eventNumber: 10,
                faceID: 3,
                startedAt: now.addingTimeInterval(-120),
                duration: 60,
                isPaused: false
            ),
            TimeFlipHistoryEntry(
                eventNumber: 11,
                faceID: 4,
                startedAt: now.addingTimeInterval(-30),
                duration: 20,
                isPaused: false
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)
        await ingestor.refreshHistory(trigger: "test")

        // The resume position is the newest segment recorded, which is the live entry 11, not the
        // last finalised one. Resuming *at* it is the point: that is how its finished duration comes
        // back on the next fetch.
        XCTAssertEqual(dataStore.latestRecordedEvent()?.eventNumber, 11)

        // Event 11 is the live entry and stays open, so 10 is the only finalised segment.
        XCTAssertEqual(finalisedEventNumbers(), [10])
    }

    func testSkipsAlreadyCommittedEvents() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(
                eventNumber: 5,
                faceID: 2,
                startedAt: now.addingTimeInterval(-300),
                duration: 120,
                isPaused: false
            ),
            TimeFlipHistoryEntry(
                eventNumber: 6,
                faceID: 2,
                startedAt: now.addingTimeInterval(-100),
                duration: 50,
                isPaused: false
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )

        // Seed device_event to mirror the device: 5 already closed out, 6 the open segment.
        // The derived resume position is therefore 5, so only event 6 is still in play.
        seedDeviceEvents(dataStore, [
            (event: 5, at: now.addingTimeInterval(-300)),
            (event: 6, at: now.addingTimeInterval(-100))
        ])
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)
        await ingestor.refreshHistory(trigger: "test")

        // Only the seeded 5 is finalised: 6 is still the open segment and this refresh committed
        // nothing new. Asserted as the exact set rather than a count of zero, which is what it read
        // when this went through the legacy logbook -- the seed writes device_event, so a count here
        // includes it.
        XCTAssertEqual(finalisedEventNumbers(), [5], "Nothing new should be committed; 6 is still open.")
        XCTAssertEqual(
            dataStore.latestRecordedEvent()?.eventNumber, 6,
            "The resume position is the seeded open segment 6, which this refresh had nothing to add to."
        )
    }

    func testLatestEntryIsSurfacedButNotQueued() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(
                eventNumber: 20,
                faceID: 1,
                startedAt: now.addingTimeInterval(-10),
                duration: 0,
                isPaused: true
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        var latest: TimeFlipHistoryEntry?

        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals
        ) { latest = $0 }
        await ingestor.refreshHistory(trigger: "test")

        XCTAssertEqual(latest?.eventNumber, 20, "Latest entry should be passed through for UI updates.")
        XCTAssertEqual(finalisedEventNumbers(), [], "The live entry is the open segment, so nothing is finalised yet.")
        XCTAssertEqual(
            dataStore.latestRecordedEvent()?.eventNumber, 20,
            "The live entry is recorded as the open segment, so it is the resume position; nothing is finalised."
        )
    }

    func testSkipsStreamOnFirstRefreshOfSessionWhenTheStoredPositionAlreadyMatchesDevice() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 20, faceID: 1, startedAt: now.addingTimeInterval(-10), duration: 10, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        // Simulates a fresh app launch reconnecting to a device it already has history for: the row
        // in device_event is the very segment the device is sitting on, same number and same start.
        seedDeviceEvents(dataStore, [(event: 20, at: now.addingTimeInterval(-10))])
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)

        // The very first refresh of a session has to read the position off disk, or it reads as
        // "nothing known yet" and falls through to a full stream on every launch regardless of
        // whether anything actually changed while disconnected. Nothing is hydrated to make that
        // work: the position is a query, so the first refresh asks the same question as the tenth.
        await ingestor.refreshHistory(trigger: "startup")
        XCTAssertEqual(device.fetchHistoryCallCount, 0, "Stream should be skipped on the very first refresh when the stored position already matches the device.")
    }

    func testSkipsStreamWhenDeviceMaxEventNumberUnchanged() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 20, faceID: 1, startedAt: now.addingTimeInterval(-10), duration: 10, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        var latest: TimeFlipHistoryEntry?
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals
        ) { latest = $0 }

        // First refresh observes the still-open entry 20 (nothing to commit yet, so the cheap
        // max-event-number check has nothing known to compare against and the stream runs).
        await ingestor.refreshHistory(trigger: "test")
        XCTAssertEqual(device.fetchHistoryCallCount, 1)

        // Device hasn't moved on to a new event -- same event 20 is still the device's reported
        // max -- but its duration has grown, since it's still the open segment. The second
        // refresh should short-circuit on the cheap check (no full stream) while still refreshing
        // the DB/UI with that duration, straight from the cheap check's own response.
        device.deviceLastEventOverride = TimeFlipHistoryEntry(
            eventNumber: 20, faceID: 1, startedAt: now.addingTimeInterval(-10), duration: 45, isPaused: false
        )
        await ingestor.refreshHistory(trigger: "test")
        XCTAssertEqual(device.fetchHistoryCallCount, 1, "Stream should be skipped when the device's max event number hasn't advanced.")
        XCTAssertEqual(latest?.duration, 45, "DB/UI should refresh with the latest duration even when the event number is unchanged.")
    }

    func testWithholdsLiveEntryWhenStreamIsCutShortOfDeviceMax() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 10, faceID: 2, startedAt: now.addingTimeInterval(-300), duration: 120, isPaused: false),
            TimeFlipHistoryEntry(eventNumber: 11, faceID: 3, startedAt: now.addingTimeInterval(-60), duration: 30, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        // Simulate a stream that got cut short partway: the device's actual last event is 15, but
        // the fetch above only returned through 11, so 11 can't be trusted as "the current entry".
        device.deviceLastEventOverride = TimeFlipHistoryEntry(
            eventNumber: 15,
            faceID: 4,
            startedAt: now.addingTimeInterval(-5),
            duration: 0,
            isPaused: false
        )
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        var latest: TimeFlipHistoryEntry?
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals
        ) { latest = $0 }
        await ingestor.refreshHistory(trigger: "test")

        // Event 10 is definitely closed (11 follows it in the same batch) so it's safe to commit.
        // Asserted against every stored row, not the finalised ones: 10 is committed but still open,
        // and this test is about the commit having happened.
        XCTAssertEqual(storedEventNumbers(), [10])
        XCTAssertEqual(
            finalisedEventNumbers(), [],
            "and nothing is finalised: 11 was withheld, so nothing arrived to close 10 out"
        )
        // Event 10 is committed but still open, having no successor to close it. The resume position
        // is that row, so the next fetch carries on from 10.
        //
        // This is where the old position hurt. It counted finalised rows only, so with nothing
        // finalised it read nil, and the next fetch re-streamed the whole history from 0 -- not
        // lossy, since re-ingest dedupes, but a full stream every time until some later event
        // happened to close 10 out. Asking for the newest row instead has no such state to get
        // stuck in.
        XCTAssertEqual(
            dataStore.latestRecordedEvent()?.eventNumber, 10,
            "the newest recorded segment is the resume position, finalised or not"
        )

        // Event 11's status is ambiguous (stream didn't reach the device's real last event, 15),
        // so it must not be surfaced as "current" yet.
        XCTAssertNil(latest, "Ambiguous entry should not be surfaced as the current activity.")
    }

    // MARK: - Where the stream resumes

    /// The resume rule, exercised directly as the pure function it is. The scenarios it has to get
    /// right are all combinations of two readings, so they are cheaper to state here than to stage
    /// through a fake device -- the ingestion tests below cover it in context.
    func testResumeCursorRules() {
        let recorded = RecordedEvent(eventNumber: 10, startEpoch: 1_000)
        func deviceEvent(_ number: UInt32?, at epoch: Int64) -> TimeFlipHistoryEntry {
            TimeFlipHistoryEntry(
                eventNumber: number,
                faceID: 2,
                startedAt: Date(timeIntervalSince1970: Double(epoch)),
                duration: 30,
                isPaused: false
            )
        }

        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: nil, deviceLast: deviceEvent(5, at: 2_000)), 0,
            "with nothing on record there is no position to resume from, so fetch everything"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: nil), 10,
            "a read the device did not answer leaves the stored position standing"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(nil, at: 2_000)), 10,
            "and so does a frame that came back without an event number"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(11, at: 2_000)), 10,
            "the ordinary case: the cube is ahead, so resume AT the stored position to re-read the open segment"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(11, at: 1_000)), 10,
            "a later event sharing its second is fine -- a zero-duration segment does exactly that"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(10, at: 1_000)), 10,
            "the very segment on record: nothing to fetch, and the position is still where to resume"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(4, at: 2_000)), 0,
            "a counter below the stored position cannot reach it, so start from the bottom"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(10, at: 2_000)), 0,
            "the same number at a different second is a different segment: a reset counted back up to it"
        )
        XCTAssertEqual(
            HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEvent(11, at: 999)), 0,
            "and a 'newer' event that began before the row on file cannot be the same generation"
        )
    }

    /// The case a number-only comparison could not see, and the reason the start time is compared.
    ///
    /// Seeded to production's own shape: a dead generation ending at event 10, then a cube that has
    /// been reset and counted back up to 10. The numbers match, so the old check called it "nothing
    /// changed" and skipped the stream -- measured against a copy of `production.sqlite`, that added
    /// one row where ten were due, losing events 1-9 of the new generation with nothing logged.
    func testAResetThatCountedBackToTheSameEventNumberStillIngests() async {
        let oldGeneration = Date(timeIntervalSince1970: 1_785_669_845)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        seedDeviceEvents(dataStore, (1...10).map { number in
            (event: UInt32(number), at: oldGeneration.addingTimeInterval(Double(number) * 60))
        })
        let seeded = storedEventNumbers().count

        // The cube after a reset: ten segments of its own, numbered from 1, hours later.
        let newGeneration = oldGeneration.addingTimeInterval(86_400)
        let history: [TimeFlipHistoryEntry] = (1...10).map { number in
            TimeFlipHistoryEntry(
                eventNumber: UInt32(number),
                faceID: 2,
                startedAt: newGeneration.addingTimeInterval(Double(number) * 300),
                duration: 300,
                isPaused: false
            )
        }
        let device = FakeDevice(history: history)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)
        await ingestor.refreshHistory(trigger: "startup")

        XCTAssertEqual(device.fetchHistoryCallCount, 1, "the stream has to run: the numbers agree but the segments do not")
        XCTAssertEqual(
            storedEventNumbers().count, seeded + 10,
            "all ten post-reset segments land as their own rows, and none of the old generation is purged"
        )
        let position = dataStore.latestRecordedEvent()
        XCTAssertEqual(position?.eventNumber, 10)
        XCTAssertEqual(
            position?.startEpoch, Int64(history[9].startedAt.timeIntervalSince1970),
            "and the newest row is the cube's event 10, not the dead generation's"
        )
    }

    /// The day's totals are re-derived from `time_entry` on every batch rather than added up as
    /// segments are written, so re-ingesting the same history must not inflate them. This is what the
    /// dropped event-number filter used to protect by suppressing the second write.
    ///
    /// Keyed by category, so the faces here matter for what they are mapped to in the seeded schema:
    /// face 2 is `Meeting` (id 2) and face 3 is `Unassigned` (id 0).
    func testReIngestingDoesNotInflateTheDayTotals() async {
        let now = Date()
        let history: [TimeFlipHistoryEntry] = [
            TimeFlipHistoryEntry(eventNumber: 1, faceID: 2, startedAt: now.addingTimeInterval(-900), duration: 300, isPaused: false),
            TimeFlipHistoryEntry(eventNumber: 2, faceID: 3, startedAt: now.addingTimeInterval(-600), duration: 300, isPaused: false),
            TimeFlipHistoryEntry(eventNumber: 3, faceID: 2, startedAt: now.addingTimeInterval(-300), duration: 60, isPaused: false)
        ]
        let device = FakeDevice(history: history)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        let dailyTotals = DailyCategoryTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)

        await ingestor.refreshHistory(trigger: "startup")
        let afterFirst = appState.dailyCategoryDurations
        XCTAssertEqual(afterFirst[2], 300, "Meeting's one finalised segment; event 3 is still open, so the menu bar counts it live instead")
        XCTAssertEqual(afterFirst[0], 300, "and Unassigned's, from face 3")

        await ingestor.refreshHistory(trigger: "periodic")
        await ingestor.refreshHistory(trigger: "periodic")
        XCTAssertEqual(appState.dailyCategoryDurations, afterFirst, "two more passes over the same history change nothing")
        XCTAssertEqual(storedEventNumbers(), [1, 2, 3], "and no segment is stored twice")
    }

    /// Every `device_event` row's event number, oldest first, whether finalised or not.
    private func storedEventNumbers() -> [UInt32] {
        eventNumbers(where: nil)
    }

    /// Just the closed ones: the segments the device has moved past and this app has written as
    /// final. The open segment is excluded, which is the distinction most of these tests turn on.
    ///
    /// Read straight from `device_event` rather than through an `AppDataStore` reader. There used to
    /// be one -- `loadEvents(overlappingSince:)`, which returned `finalised = 1` rows inside a time
    /// window -- and it survived its last production caller by exactly one commit, once the day's
    /// totals moved to `time_entry`. Every test using it passed an epoch-zero cutoff, so the window
    /// was never exercised, and every one of them looked only at event numbers. A production method
    /// whose only callers want less than it offers is the "dead code kept alive by its own coverage"
    /// that `docs/TODO-Legacy-removal.md` records deleting once already.
    private func finalisedEventNumbers() -> [UInt32] {
        eventNumbers(where: "finalised = 1")
    }

    private func eventNumbers(where condition: String?) -> [UInt32] {
        var numbers: [UInt32] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(historyIngestorTestDBURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return numbers
        }
        let clause = condition.map { " WHERE \($0)" } ?? ""
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT event_number FROM device_event\(clause) ORDER BY start_epoch ASC;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                numbers.append(UInt32(sqlite3_column_int64(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return numbers
    }

    /// Seeds `device_event` with the given rows, oldest first, exactly as the ingestor would.
    ///
    /// `recordDeviceEvent` closes out earlier rows when a newer `start_epoch` arrives, so every row
    /// but the last ends up finalised and the last stays open -- mirroring a real device, whose
    /// newest segment is always still growing. Pass rows matching what the fake device reports, or
    /// the ingestor will insert a second row for the same event number.
    private func seedDeviceEvents(_ dataStore: AppDataStore, _ rows: [(event: UInt32, at: Date)]) {
        for row in rows {
            _ = dataStore.recordDeviceEvent(
                eventNumber: row.event, deviceFace: 1,
                startedAt: row.at, durationSeconds: 10, isPaused: false
            )
        }
    }
}
// swiftlint:enable line_length
