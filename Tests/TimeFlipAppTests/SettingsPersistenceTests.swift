@testable import TimeFlipApp
import SQLite3
import XCTest

/// Automates the DB-round-trip core of the Device-tab persistence bench checklists (05 auto-pause,
/// 06 LED, 07 double-tap) without a device: each value written through `AppDataStore` must survive
/// being read back by a *separate* store instance opened on the same file -- which is exactly what
/// an app restart is (new process -> new store -> reads the persisted `setting` row). What's left
/// for the bench is only the UI wiring (slider/field/checkbox -> save) and the device sync, not the
/// persistence itself.
///
/// The merge cases matter most: `AppDataStore.saveSettingJSON` merges into the existing JSON row,
/// so saving one field (e.g. LED brightness) must leave its siblings (blink interval) untouched.
/// These use non-default sibling values on purpose -- a broken merge that clobbered the whole row
/// would fall back to the *seeded default*, which a default-valued assertion couldn't catch.
final class SettingsPersistenceTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SettingsPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("appdata.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Writes a `setting` row directly, bypassing `AppDataStore` entirely -- the only way to model
    /// a hand-edited row, which is what the load-side clamps exist for.
    private func writeRawSetting(name: String, value: String) {
        _ = reopenedStore() // ensures the file and schema exist before opening it raw
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return }
        sqlite3_exec(db, "UPDATE setting SET setting_value = '\(value)' WHERE setting_name = '\(name)';", nil, nil, nil)
        sqlite3_close(db)
    }

    /// A fresh store on the same file -- models quitting and relaunching the app.
    private func reopenedStore() -> AppDataStore {
        AppDataStore(databaseURL: dbURL)
    }

    // MARK: - 05 auto-pause

    func testAutoPauseMinutesSurvivesRestart() {
        reopenedStore().saveAutoPauseMinutes(4)
        XCTAssertEqual(reopenedStore().loadAutoPauseMinutes(), 4)
    }

    func testAutoPauseMinutesCanBeClearedBackToZero() {
        let store = reopenedStore()
        store.saveAutoPauseMinutes(26)
        store.saveAutoPauseMinutes(0)
        XCTAssertEqual(reopenedStore().loadAutoPauseMinutes(), 0)
    }

    // MARK: - blip time

    func testBlipTimeSurvivesRestart() {
        reopenedStore().saveBlipTimeSeconds(3)
        XCTAssertEqual(reopenedStore().loadBlipTimeSeconds(), 3)
    }

    func testBlipTimeCanBeTurnedOff() {
        // 0 is the off switch, the same way auto_pause_minutes uses it, so it has to round-trip
        // rather than being mistaken for "missing, fall back to the default".
        let store = reopenedStore()
        store.saveBlipTimeSeconds(5)
        store.saveBlipTimeSeconds(0)
        XCTAssertEqual(reopenedStore().loadBlipTimeSeconds(), 0)
    }

    func testBlipTimeIsClampedOnTheWayInAndOut() {
        // A hand-edited row must not make the app discard more time than the App tab would let
        // anyone set -- the load clamps, so the stored value cannot outrun the control.
        reopenedStore().saveBlipTimeSeconds(9_999)
        XCTAssertEqual(reopenedStore().loadBlipTimeSeconds(), TimeFlipConstants.maxBlipTimeSeconds)

        writeRawSetting(name: "blip_time", value: "{\"seconds\":9999}")
        XCTAssertEqual(
            reopenedStore().loadBlipTimeSeconds(), TimeFlipConstants.maxBlipTimeSeconds,
            "even a value written straight into the row, bypassing the save clamp, is clamped on read"
        )
    }

    // MARK: - 06 LED

    func testLEDBrightnessAndBlinkIntervalSurviveRestart() {
        let store = reopenedStore()
        store.saveLEDBrightnessPercent(77)
        store.saveLEDBlinkIntervalSeconds(42)

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadLEDBrightnessPercent(), 77)
        XCTAssertEqual(reopened.loadLEDBlinkIntervalSeconds(), 42)
    }

    func testSavingLEDBrightnessLeavesBlinkIntervalIntact() {
        let store = reopenedStore()
        store.saveLEDBlinkIntervalSeconds(42)  // non-default (seed is 15)
        store.saveLEDBrightnessPercent(77)     // must not clobber the blink interval

        XCTAssertEqual(reopenedStore().loadLEDBlinkIntervalSeconds(), 42)
    }

    func testSavingLEDBlinkIntervalLeavesBrightnessIntact() {
        let store = reopenedStore()
        store.saveLEDBrightnessPercent(77)     // non-default (seed is 50)
        store.saveLEDBlinkIntervalSeconds(42)  // must not clobber the brightness

        XCTAssertEqual(reopenedStore().loadLEDBrightnessPercent(), 77)
    }

    // MARK: - 07 double-tap

    func testDoubleTapEnabledFlagSurvivesRestart() {
        // Seeded enabled = true; flip it off and confirm the flip is what a restart reads back.
        reopenedStore().saveDoubleTapEnabled(false)
        XCTAssertFalse(reopenedStore().loadDoubleTapEnabled())

        reopenedStore().saveDoubleTapEnabled(true)
        XCTAssertTrue(reopenedStore().loadDoubleTapEnabled())
    }

    func testSavingDoubleTapEnabledLeavesAccelerometerParamsIntact() {
        // Write non-default accelerometer params, then toggle enabled -- the enabled write merges
        // into the same row and must not drop the params.
        let custom = DoubleTapParameters(clickThreshold: 111, limit: 22, latency: 33, window: 44)
        let store = reopenedStore()
        store.saveDoubleTapParameters(custom)
        store.saveDoubleTapEnabled(false)

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadDoubleTapParameters(), custom)
        XCTAssertFalse(reopened.loadDoubleTapEnabled())
    }

    // MARK: - pairing: device_uuid and device_name

    func testDeviceUUIDAndNameSurviveRestart() {
        let store = reopenedStore()
        store.recordDeviceUUID("CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        store.recordDeviceName("Solid cube")

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadDeviceUUID(), "CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        XCTAssertEqual(reopened.loadDeviceName(), "Solid cube")
    }

    func testClearingTheDeviceUUIDLeavesTheNameStanding() {
        // The reason they are two rows rather than one: Forget Device clears the uuid and keeps the
        // name, because forgetting does not un-rename the cube and that name is the only thing the
        // filtered scan can match a renamed device on. A single row would take both together.
        let store = reopenedStore()
        store.recordDeviceUUID("CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        store.recordDeviceName("Solid cube")

        store.recordDeviceUUID(nil)

        let reopened = reopenedStore()
        XCTAssertNil(reopened.loadDeviceUUID())
        XCTAssertEqual(reopened.loadDeviceName(), "Solid cube")
    }

    func testClearingBothLeavesNeitherBehind() {
        // A confirmed factory reset (0xFF) reverts the cube to the vendor name, so the remembered
        // one is wrong and goes with the uuid.
        let store = reopenedStore()
        store.recordDeviceUUID("CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        store.recordDeviceName("Solid cube")

        store.recordDeviceUUID(nil)
        store.recordDeviceName(nil)

        let reopened = reopenedStore()
        XCTAssertNil(reopened.loadDeviceUUID())
        XCTAssertNil(reopened.loadDeviceName())
    }

    // MARK: - device name, current and previous

    func testTheFirstNameRecordedLeavesNoPreviousOne() {
        let store = reopenedStore()
        store.recordDeviceName("Dibby")

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadDeviceName(), "Dibby")
        XCTAssertNil(reopened.loadPreviousDeviceName(), "a cube with one name has no previous one")
    }

    func testARenameKeepsTheNameItDisplaced() {
        // Why the row holds two: the GAP name macOS reports is a connection stale, so the scan
        // straight after a rename is still seeing "Dibby" and has to match on it.
        let store = reopenedStore()
        store.recordDeviceName("Dibby")

        store.recordDeviceName("Wobble")

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadDeviceName(), "Wobble")
        XCTAssertEqual(reopened.loadPreviousDeviceName(), "Dibby")
    }

    func testRecordingTheSameNameAgainDoesNotPushThePreviousOneOut() {
        // The failure this guards is silent and total: the name is re-recorded on every connect,
        // so a no-op write that rolled the pointer would replace the genuinely previous name with
        // the current one within seconds and undo the entire point of keeping it.
        let store = reopenedStore()
        store.recordDeviceName("Dibby")
        store.recordDeviceName("Wobble")

        store.recordDeviceName("Wobble")
        store.recordDeviceName("Wobble")

        XCTAssertEqual(reopenedStore().loadPreviousDeviceName(), "Dibby")
    }

    func testRenamingTwiceKeepsOnlyTheNameImmediatelyBefore() {
        // One step back, not a history: the stale GAP name is exactly one connection behind.
        let store = reopenedStore()
        store.recordDeviceName("Dibby")
        store.recordDeviceName("Wobble")
        store.recordDeviceName("Plopper")

        let reopened = reopenedStore()
        XCTAssertEqual(reopened.loadDeviceName(), "Plopper")
        XCTAssertEqual(reopened.loadPreviousDeviceName(), "Wobble")
    }

    func testClearingTheNameKeepsTheOneItHadForTheScanToMatchOn() {
        // A confirmed factory reset clears the name. The cube is still advertising something until
        // it reboots, so the name it had is still the useful thing to look for.
        let store = reopenedStore()
        store.recordDeviceName("Dibby")

        store.recordDeviceName(nil)

        let reopened = reopenedStore()
        XCTAssertNil(reopened.loadDeviceName())
        XCTAssertEqual(reopened.loadPreviousDeviceName(), "Dibby")
    }
}
