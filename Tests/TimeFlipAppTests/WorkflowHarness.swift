@testable import TimeFlipApp
import Foundation
import SQLite3
import Testing

/// Shared setup and vocabulary for the workflow tests -- the CI counterpart of the on-device
/// checklists under `Tests/Bench/`.
///
/// A workflow test drives a whole sequence through the real object graph (`AppDataStore`,
/// `HistoryIngestor`, `DailyFaceTotals`, `AppState`) with `MockTimeFlipDevice` standing in for the
/// hardware, then asserts what landed in the database. Each *step* is its own `@Test` inside a
/// `@Suite(.serialized)`, which swift-testing runs in **declaration order** -- verified, unlike
/// XCTest's incidental alphabetical ordering, which is why these are swift-testing suites and the
/// single-function tests remain XCTest.
///
/// Three rules, mirroring `Tests/CLAUDE.md`'s conventions for the scripted checklists:
///
/// 1. **Every workflow states its preconditions** and its first step establishes them, rather than
///    inheriting state from whatever ran before.
/// 2. **A failed step fails the rest of the workflow fast.** Later steps open with
///    `try harness.requirePreviousStepsPassed()`, so a broken step 2 reports one line per remaining
///    step naming the step that actually broke, instead of a cascade of unrelated assertion diffs.
/// 3. **Workflows never depend on each other.** Each gets its own harness, and therefore its own
///    freshly created database and its own mock device. They may run in any order, or alone.
///
/// ## Use `try #require`, not `#expect`, for anything that gates later steps
///
/// `#expect` *records* a failure and carries on; only `try #require` throws. A step whose assertions
/// are all `#expect` therefore returns normally even when it failed, the gate below never trips, and
/// the remaining steps run against state they were promised wouldn't exist. Reach for `#expect` only
/// where a failure genuinely doesn't invalidate what follows.
@MainActor
final class WorkflowHarness {
    let workflow: String
    let dataStore: AppDataStore
    let device: MockTimeFlipDevice
    let appState: AppState
    let dailyTotals: DailyFaceTotals
    let ingestor: HistoryIngestor

    private let databaseURL: URL
    /// The step that broke, if any. Set by `failed(step:)`, read by `requirePreviousStepsPassed()`.
    private var brokenStep: String?

    /// A fixed base time so every expectation is deterministic: nothing here may read the real clock.
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private init(workflow: String) {
        self.workflow = workflow
        // A directory per workflow, so two workflows can never see each other's rows. Deliberately
        // not `AppDataStore.testDatabaseURL()`, which is one fixed path shared by every caller --
        // fine for a self-contained unit test, wrong for suites that accumulate state on purpose.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TimeFlipWorkflows", isDirectory: true)
            .appendingPathComponent(workflow, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = directory.appendingPathComponent("appdata.sqlite")

        self.dataStore = AppDataStore(databaseURL: databaseURL)
        self.device = MockTimeFlipDevice(
            configuration: .init(initialFaceID: 1, isInitiallyPaired: true, emitInitialStatus: false)
        )
        self.appState = AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
        self.dailyTotals = DailyFaceTotals(dataStore: dataStore)
        self.ingestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals
        )

        // MockTimeFlipDevice's initialiser puts two things on the *real* clock, and a workflow that
        // asserts on ordering has to neutralise both or it isn't deterministic:
        //
        //  1. Two sample history entries, derived from `Date()`. No configuration flag suppresses
        //     them, but `seedHistory` replaces rather than appends, so seeding empty drops them.
        //  2. The initial `activeSession`, also started at `Date()`. The first flip closes it as a
        //     zero-duration segment stamped with the wall clock, which then outranks every
        //     baseDate-relative segment. Since `AppDataStore.recordDeviceEvent` decides `finalised`
        //     by whether a row holds the max known `start_epoch`, that stale row would stay open for
        //     the life of the workflow while genuinely newer segments got finalised behind it.
        //
        // So: move the clock first, then flush the wall-clock session out with a throwaway flip pair,
        // then clear the history those flips produced. Everything after this sits on one timeline.
        device.setDeviceTime(Self.baseDate)
        device.flip(to: 2)
        device.flip(to: 1)
        device.seedHistory([])
    }

    // MARK: - One harness per workflow

    private static var harnesses: [String: WorkflowHarness] = [:]

    /// The harness for `workflow`, created on first use. swift-testing builds a fresh suite *instance*
    /// per test, so a stored property could never carry state from one step to the next -- the shared
    /// state has to live here.
    static func shared(_ workflow: String) -> WorkflowHarness {
        if let existing = harnesses[workflow] { return existing }
        let created = WorkflowHarness(workflow: workflow)
        harnesses[workflow] = created
        return created
    }

    // MARK: - Fail-fast gate

    struct PreviousStepFailed: Error, CustomStringConvertible {
        let workflow: String
        let step: String
        var description: String {
            "workflow '\(workflow)' stopped: step '\(step)' failed, so this step did not run"
        }
    }

    /// Records that `step` broke. Every later step then fails immediately naming it.
    func failed(step: String) {
        if brokenStep == nil { brokenStep = step }
    }

    /// Call at the top of every step after the first.
    func requirePreviousStepsPassed() throws {
        if let brokenStep {
            throw PreviousStepFailed(workflow: workflow, step: brokenStep)
        }
    }

    /// Runs `body`, and if it throws or records the step as broken, marks the workflow broken so the
    /// remaining steps stop rather than reporting knock-on noise.
    func step(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            failed(step: name)
            throw error
        }
    }

    // MARK: - Device verbs

    /// Brings the device up the way `ApplicationDelegate.startDeviceEvents` does: connect, log in,
    /// enable notifications. Until all three happen `MockTimeFlipDevice.emit` drops every event.
    func connect() async throws {
        #expect(await device.connect())
        let loggedIn = await device.login(password: TimeFlipConstants.defaultPassword)
        try #require(loggedIn, "mock login failed -- nothing will be emitted")
        await device.enableNotifications()
    }

    /// Flips to `face` at `secondsFromBase`, which also closes off the previous segment in the
    /// device's own history (the mock models the real device's behaviour here).
    func flip(to face: UInt8, atSecondsFromBase secondsFromBase: TimeInterval) {
        device.setDeviceTime(Self.baseDate.addingTimeInterval(secondsFromBase))
        device.flip(to: face)
    }

    /// What the app does on (re)connect before it starts processing live events.
    func ingestHistory(trigger: String) async {
        await ingestor.refreshHistory(trigger: trigger)
    }

    // MARK: - Database assertions

    /// Event numbers of every `device_event` row, in `start_epoch` order.
    ///
    /// Read straight from `device_event` rather than via `AppDataStore.loadEvents`, which queries the
    /// **legacy `logbook`** table (see `docs/TODO-Legacy-removal.md`) and so omits the still-open
    /// segment -- using it here silently hid the newest row and made "the newest event is the open
    /// one" look false.
    func storedEventNumbers() -> [UInt32] {
        var numbers: [UInt32] = []
        withReadOnlyDatabase { db in
            var stmt: OpaquePointer?
            let sql = "SELECT event_number FROM device_event ORDER BY start_epoch ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    numbers.append(UInt32(sqlite3_column_int64(stmt, 0)))
                }
            }
            sqlite3_finalize(stmt)
        }
        return numbers
    }

    /// How many rows are still open (`finalised = 0`). Read straight from sqlite: `finalised` drives
    /// the cursor logic but isn't exposed on `DeviceEventRecord`, and a workflow's whole point is to
    /// assert that exactly one segment is left in progress.
    func openEventCount() -> Int {
        countRows("SELECT COUNT(*) FROM device_event WHERE finalised = 0;")
    }

    func storedEventCount() -> Int {
        countRows("SELECT COUNT(*) FROM device_event;")
    }

    /// The event number of the single open row, or nil if none is open.
    func openEventNumber() -> Int64? {
        var value: Int64?
        withReadOnlyDatabase { db in
            var stmt: OpaquePointer?
            let sql = "SELECT event_number FROM device_event WHERE finalised = 0 ORDER BY start_epoch DESC LIMIT 1;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                value = sqlite3_column_int64(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        return value
    }

    private func countRows(_ sql: String) -> Int {
        var count = 0
        withReadOnlyDatabase { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return count
    }

    private func withReadOnlyDatabase(_ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            Issue.record("could not open \(databaseURL.path) read-only")
            return
        }
        body(db)
        sqlite3_close(db)
    }

    /// Event numbers the device itself has recorded, oldest first. Segments are built by flipping
    /// rather than by hand-writing `TimeFlipHistoryEntry` values, so the numbers come from the mock's
    /// own counter and stay consistent with whatever it allocates next.
    func deviceHistoryEventNumbers() -> [UInt32] {
        device.history.compactMap(\.eventNumber).sorted()
    }
}
