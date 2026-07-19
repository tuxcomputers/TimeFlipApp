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

    func testCollapseDeviceTabDisclosuresCancelsAnInFlightAutoPauseHold() {
        // Bench checklist 05 Scenario C: closing the Preferences window mid-hold (which calls
        // collapseDeviceTabDisclosures from windowWillClose) must cancel the repeating hold loop so
        // its device/DB writes stop, and clear the direction so a stale hold can't resume.
        let appState = makeAppState()
        let heldTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        appState.autoPauseHoldTask = heldTask
        appState.autoPauseHoldDirection = 1

        appState.collapseDeviceTabDisclosures()

        XCTAssertTrue(heldTask.isCancelled)
        XCTAssertNil(appState.autoPauseHoldTask)
        XCTAssertNil(appState.autoPauseHoldDirection)
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
