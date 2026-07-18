@testable import TimeFlipApp
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
}
