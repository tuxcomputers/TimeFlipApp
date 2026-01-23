@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
// Minimal fake device that returns canned history frames.
@MainActor
final class FakeDevice: TimeFlipSessionManaging {
    var events: AsyncStream<TimeFlipEvent> { AsyncStream { _ in } }
    private(set) var history: [TimeFlipHistoryEntry] = []
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
    func snapshot() -> TimeFlipDeviceSnapshot { snapshotValue }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        guard let start = eventNumber else { return history }
        return history.filter { entry in
            guard let eventNumber = entry.eventNumber else { return false }
            return eventNumber >= start
        }
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
        let appState = AppState()
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
        let appState = AppState()

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
        let appState = AppState()
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
}
// swiftlint:enable line_length
