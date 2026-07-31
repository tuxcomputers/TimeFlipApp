@testable import TimeFlipApp
import XCTest

/// Covers the Device-tab-related `AppState` glue added alongside the settings-UI work: the
/// disclosure-collapse-on-close reset, the low-battery blink mirror the Settings window reads, and
/// the pending-tab hint that forces the Device tab open on a low-battery warning. All pure in-memory
/// state -- no device, no window.
@MainActor
final class AppStateDeviceTabTests: XCTestCase {
    private func makeAppState() -> AppState {
        AppState(
            preferencesStore: InMemoryPreferencesStore(),
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
    }

    func testCollapseDeviceTabDisclosuresResetsEveryExpandFlag() {
        let appState = makeAppState()
        appState.isMoreExpanded = true
        appState.isLEDExpanded = true
        appState.isDoubleTapExpanded = true

        appState.collapseDeviceTabDisclosures()

        XCTAssertFalse(appState.isMoreExpanded)
        XCTAssertFalse(appState.isLEDExpanded)
        XCTAssertFalse(appState.isDoubleTapExpanded)
    }

    func testCancelSteppedFieldHoldCancelsAnInFlightHold() {
        // Bench checklist 05b Scenario E: closing the Preferences window mid-hold must cancel the
        // repeating hold loop so its device/DB writes stop, and clear the key so a stale hold can't
        // resume. windowWillClose calls this for every stepper in the window, auto-pause included --
        // it used to have its own hold state, and asserting on that one now proves nothing about
        // what actually runs.
        let appState = makeAppState()
        let heldTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        appState.steppedFieldHoldTask = heldTask
        appState.steppedFieldHoldKey = "autoPause:1"

        appState.cancelSteppedFieldHold()

        XCTAssertTrue(heldTask.isCancelled)
        XCTAssertNil(appState.steppedFieldHoldTask)
        XCTAssertNil(appState.steppedFieldHoldKey)
    }

    func testSetLowBatteryBlinkStateMirrorsBothValues() {
        let appState = makeAppState()
        XCTAssertFalse(appState.isLowBattery)
        XCTAssertFalse(appState.lowBatteryBlinkPhaseOn)

        appState.setLowBatteryBlinkState(isLowBattery: true, blinkPhaseOn: true)
        XCTAssertTrue(appState.isLowBattery)
        XCTAssertTrue(appState.lowBatteryBlinkPhaseOn)

        // Phase toggles off while still low -- the label goes red->white on the same latch.
        appState.setLowBatteryBlinkState(isLowBattery: true, blinkPhaseOn: false)
        XCTAssertTrue(appState.isLowBattery)
        XCTAssertFalse(appState.lowBatteryBlinkPhaseOn)

        // Recovery clears both.
        appState.setLowBatteryBlinkState(isLowBattery: false, blinkPhaseOn: false)
        XCTAssertFalse(appState.isLowBattery)
        XCTAssertFalse(appState.lowBatteryBlinkPhaseOn)
    }

    func testPendingSettingsTabRoundTrips() {
        let appState = makeAppState()
        XCTAssertNil(appState.pendingSettingsTab)

        appState.pendingSettingsTab = .timeflip
        XCTAssertEqual(appState.pendingSettingsTab, .timeflip)

        // SettingsRootView consumes and clears it after honoring the hint.
        appState.pendingSettingsTab = nil
        XCTAssertNil(appState.pendingSettingsTab)
    }
}
