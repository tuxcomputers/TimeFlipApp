@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
// Minimal fake device that returns canned history frames.
@MainActor
final class FakeDevice: TimeFlipSessionManaging {
    var events: AsyncStream<TimeFlipEvent> { AsyncStream { _ in } }
    private(set) var history: [TimeFlipHistoryEntry] = []
    private(set) var fetchHistoryCallCount = 0
    /// Overrides what readLastEvent() reports, decoupled from `history`, so tests can simulate a
    /// stream that got cut short before reaching the device's actual last event.
    var deviceLastEventOverride: TimeFlipHistoryEntry?
    var snapshotValue = TimeFlipDeviceSnapshot(
        facetID: TimeFlipConstants.minFacetID,
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
    func setFacetColor(facetID: UInt8, components: ColorComponents) async {}
    func setAutoPause(minutes: UInt16) async {}
    func setLEDBrightness(percent: UInt8) async {}
    func setBlinkInterval(seconds: UInt8) async {}
    func setDoubleTapParameters(_ params: DoubleTapParameters) async {}
    func readDoubleTapParameters() async -> DoubleTapParameters? { nil }
    func refreshDeviceInfo() async {}
    func readElapsedSeconds(facetID: UInt8) async -> TimeInterval? { nil }
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
                facetID: 3,
                startedAt: now.addingTimeInterval(-120),
                duration: 60,
                isPaused: false
            ),
            TimeFlipHistoryEntry(
                eventNumber: 11,
                facetID: 4,
                startedAt: now.addingTimeInterval(-30),
                duration: 20,
                isPaused: false
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )
        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)
        await ingestor.refreshHistory(trigger: "test")

        // Verify cursor advanced only through completed events (excludes live last entry).
        let cursor = dataStore.loadEventCursor(target: .local, identifier: "device-history")
        XCTAssertEqual(cursor, 10)

        // Verify only completed events stored
        let stored = dataStore.loadEvents(after: nil, limit: 10)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.eventNumber, 10)
    }

    func testSkipsAlreadyCommittedEvents() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(
                eventNumber: 5,
                facetID: 2,
                startedAt: now.addingTimeInterval(-300),
                duration: 120,
                isPaused: false
            ),
            TimeFlipHistoryEntry(
                eventNumber: 6,
                facetID: 2,
                startedAt: now.addingTimeInterval(-100),
                duration: 50,
                isPaused: false
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )

        // Seed cursor to 5 so only event 6 should be processed.
        dataStore.saveEventCursor(target: .local, identifier: "device-history", lastSentEventID: 5)
        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)
        await ingestor.refreshHistory(trigger: "test")

        let stored = dataStore.loadEvents(after: nil, limit: 10)
        XCTAssertEqual(stored.count, 0, "Live last entry should not be stored yet.")
        let cursor = dataStore.loadEventCursor(target: .local, identifier: "device-history")
        XCTAssertEqual(cursor, 5, "Cursor should remain at last committed event.")
    }

    func testLatestEntryIsSurfacedButNotQueued() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(
                eventNumber: 20,
                facetID: 1,
                startedAt: now.addingTimeInterval(-10),
                duration: 0,
                isPaused: true
            )
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )
        var latest: TimeFlipHistoryEntry?

        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals,
            onNewEvents: nil
        ) { latest = $0 }
        await ingestor.refreshHistory(trigger: "test")

        XCTAssertEqual(latest?.eventNumber, 20, "Latest entry should be passed through for UI updates.")
        let stored = dataStore.loadEvents(after: nil, limit: 10)
        XCTAssertTrue(stored.isEmpty, "Live entry should not be stored in the logbook.")
        let cursor = dataStore.loadEventCursor(target: .local, identifier: "device-history")
        XCTAssertNil(cursor, "Cursor should not advance when only a live entry is present.")
    }

    func testSkipsStreamOnFirstRefreshOfSessionWhenPersistedCursorAlreadyMatchesDevice() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 20, facetID: 1, startedAt: now.addingTimeInterval(-10), duration: 10, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )
        // Simulates a fresh app launch reconnecting to a device it already has history for: the
        // persisted cursor from a previous session already matches the device's current event,
        // with no in-memory state populated yet (lastCommittedEventNumber/lastObservedEventNumber
        // are both nil until something reads them).
        dataStore.saveEventCursor(target: .local, identifier: "device-history", lastSentEventID: 20)
        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(device: device, dataStore: dataStore, appState: appState, dailyTotals: dailyTotals)

        // The very first refresh call of this instance's lifetime must still hydrate the
        // persisted cursor before comparing against the device's reported max -- otherwise it
        // reads as "nothing known yet" and always falls through to a full stream regardless of
        // whether anything actually changed while disconnected.
        await ingestor.refreshHistory(trigger: "startup")
        XCTAssertEqual(device.fetchHistoryCallCount, 0, "Stream should be skipped on the very first refresh when the persisted cursor already matches the device.")
    }

    func testSkipsStreamWhenDeviceMaxEventNumberUnchanged() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 20, facetID: 1, startedAt: now.addingTimeInterval(-10), duration: 10, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )
        var latest: TimeFlipHistoryEntry?
        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals,
            onNewEvents: nil
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
            eventNumber: 20, facetID: 1, startedAt: now.addingTimeInterval(-10), duration: 45, isPaused: false
        )
        await ingestor.refreshHistory(trigger: "test")
        XCTAssertEqual(device.fetchHistoryCallCount, 1, "Stream should be skipped when the device's max event number hasn't advanced.")
        XCTAssertEqual(latest?.duration, 45, "DB/UI should refresh with the latest duration even when the event number is unchanged.")
    }

    func testWithholdsLiveEntryWhenStreamIsCutShortOfDeviceMax() async {
        let now = Date()
        let entries = [
            TimeFlipHistoryEntry(eventNumber: 10, facetID: 2, startedAt: now.addingTimeInterval(-300), duration: 120, isPaused: false),
            TimeFlipHistoryEntry(eventNumber: 11, facetID: 3, startedAt: now.addingTimeInterval(-60), duration: 30, isPaused: false)
        ]
        let device = FakeDevice(history: entries)
        // Simulate a stream that got cut short partway: the device's actual last event is 15, but
        // the fetch above only returned through 11, so 11 can't be trusted as "the current entry".
        device.deviceLastEventOverride = TimeFlipHistoryEntry(
            eventNumber: 15,
            facetID: 4,
            startedAt: now.addingTimeInterval(-5),
            duration: 0,
            isPaused: false
        )
        let dataStore = AppDataStore(databaseURL: historyIngestorTestDBURL)
        let appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore()
        )
        var latest: TimeFlipHistoryEntry?
        let dailyTotals = DailyFacetTotals(dataStore: dataStore)
        let ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals,
            onNewEvents: nil
        ) { latest = $0 }
        await ingestor.refreshHistory(trigger: "test")

        // Event 10 is definitely closed (11 follows it in the same batch) so it's safe to commit.
        let stored = dataStore.loadEvents(after: nil, limit: 10)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.eventNumber, 10)
        let cursor = dataStore.loadEventCursor(target: .local, identifier: "device-history")
        XCTAssertEqual(cursor, 10, "Cursor should stop before the unconfirmed entry so it's re-requested next time.")

        // Event 11's status is ambiguous (stream didn't reach the device's real last event, 15),
        // so it must not be surfaced as "current" yet.
        XCTAssertNil(latest, "Ambiguous entry should not be surfaced as the current activity.")
    }
}
// swiftlint:enable line_length
