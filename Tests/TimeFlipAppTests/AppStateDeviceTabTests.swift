@testable import TimeFlipApp
import XCTest

/// Covers the Device-tab-related `AppState` glue added alongside the settings-UI work: the
/// disclosure-collapse-on-close reset, the low-battery blink mirror the Settings window reads, and
/// the pending-tab hint that forces the Device tab open on a low-battery warning. All pure in-memory
/// state -- no device, no window.
@MainActor
final class AppStateDeviceTabTests: XCTestCase {
    /// Every store injected, including the developer-config one. Omitting that argument defaults it
    /// to `DeveloperConfigStore.shared`, which is the developer's **real** `config.json` -- a test
    /// that then takes any path writing to it rewrites a file on the machine running the suite. That
    /// is not hypothetical: it happened here on 2026-08-09, when the forget path briefly recorded the
    /// factory default and these four `forgetDevice()` calls stamped it into the real file.
    private func makeAppState() -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            developerConfigStore: InMemoryDeveloperConfigStore(),
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

    // MARK: - renaming the device

    func testASuccessfulRenameAdoptsTheNameOnlyAfterTheWriteLands() async {
        let appState = makeAppState()
        appState.confirmConnected(name: "TimeFlip v2.0", uuid: "uuid")
        var written: [String] = []
        appState.onDeviceRenameRequest = { name in
            written.append(name)
            return true
        }

        let problem = await appState.renameDevice(to: "Solid cube")

        XCTAssertNil(problem)
        XCTAssertEqual(written, ["Solid cube"])
        XCTAssertEqual(appState.deviceName, "Solid cube")
        XCTAssertEqual(appState.pairedDeviceName, "Solid cube")
    }

    func testAFailedWriteLeavesTheNameAsTheDeviceStillHasIt() {
        // The stored name is what a scan filter matches a renamed cube on, so adopting a name the
        // device never took would leave the app looking for something that does not exist.
        let appState = makeAppState()
        appState.confirmConnected(name: "TimeFlip v2.0", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in false }

        let expectation = expectation(description: "rename returns")
        Task { @MainActor in
            let problem = await appState.renameDevice(to: "Solid cube")
            XCTAssertEqual(problem, .writeFailed)
            XCTAssertEqual(appState.deviceName, "TimeFlip v2.0")
            XCTAssertEqual(appState.pairedDeviceName, "TimeFlip v2.0")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testARefusedNameNeverReachesTheDevice() async {
        let appState = makeAppState()
        appState.confirmConnected(name: "TimeFlip v2.0", uuid: "uuid")
        var writes = 0
        appState.onDeviceRenameRequest = { _ in
            writes += 1
            return true
        }

        let problem = await appState.renameDevice(to: "Cube 🎲")

        XCTAssertEqual(problem, .unwritableCharacters)
        XCTAssertEqual(writes, 0, "a name the device would reject should not cost a BLE write")
        XCTAssertEqual(appState.deviceName, "TimeFlip v2.0")
    }

    func testRenamingToTheCurrentNameSpendsNoWrite() async {
        let appState = makeAppState()
        appState.confirmConnected(name: "Solid cube", uuid: "uuid")
        var writes = 0
        appState.onDeviceRenameRequest = { _ in
            writes += 1
            return true
        }

        let problem = await appState.renameDevice(to: "Solid cube")

        XCTAssertNil(problem, "an unchanged name is a no-op, not an error to report")
        XCTAssertEqual(writes, 0)
    }

    // MARK: - telling the user why a rename does not look like it worked

    func testASuccessfulRenamePostsTheLagNoticeNamingBothNames() async {
        let appState = makeAppState()
        appState.confirmConnected(name: "Pibble", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in true }

        _ = await appState.renameDevice(to: "Chomper")

        let notice = appState.renameLagNotice ?? ""
        // Both names, because the notice is read while looking at a scan list showing the old one.
        XCTAssertTrue(notice.contains("Chomper"), notice)
        XCTAssertTrue(notice.contains("Pibble"), notice)
    }

    func testARefusedOrFailedRenamePostsNoNotice() async {
        // The notice says the device has taken the name. Nothing took it here.
        let appState = makeAppState()
        appState.confirmConnected(name: "Pibble", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in false }

        _ = await appState.renameDevice(to: "Chomper")
        XCTAssertNil(appState.renameLagNotice)

        _ = await appState.renameDevice(to: "Cube 🎲")
        XCTAssertNil(appState.renameLagNotice)
    }

    func testTheLagNoticeSurvivesTheReconnectThatStillReportsTheOldName() async {
        // The measured behaviour this notice exists for: a cube renamed to Plopper reported Dibby
        // on the next connect and Plopper only on the one after. Clearing on "a connect happened"
        // would retire the notice while the stale name was still exactly what a scan would show.
        let appState = makeAppState()
        appState.confirmConnected(name: "Dibby", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in true }
        _ = await appState.renameDevice(to: "Plopper")

        appState.confirmConnected(name: "Dibby", uuid: "uuid")
        XCTAssertNotNil(appState.renameLagNotice, "the device is still reporting the old name")

        appState.confirmConnected(name: "Plopper", uuid: "uuid")
        XCTAssertNil(appState.renameLagNotice, "the names agree, so there is no lag left to describe")
    }

    func testALiveNameChangeFromTheDeviceClearsTheLagNotice() async {
        // peripheralDidUpdateName about two seconds into the connection after a rename, which is
        // the earliest the app ever hears the new name back from the cube.
        let appState = makeAppState()
        appState.confirmConnected(name: "Dibby", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in true }
        _ = await appState.renameDevice(to: "Plopper")

        appState.adoptReportedDeviceName("Plopper")

        XCTAssertNil(appState.renameLagNotice)
        XCTAssertEqual(appState.deviceName, "Plopper")
        XCTAssertEqual(appState.pairedDeviceName, "Plopper")
    }

    func testForgetDeviceDropsTheLagNotice() async {
        let appState = makeAppState()
        appState.confirmConnected(name: "Dibby", uuid: "uuid")
        appState.onDeviceRenameRequest = { _ in true }
        _ = await appState.renameDevice(to: "Plopper")

        appState.forgetDevice()

        XCTAssertNil(appState.renameLagNotice, "the Name row reads 'Not paired'; there is no rename to explain")
    }

    // MARK: - the device name outliving a forget

    func testForgetDeviceKeepsTheDeviceNameAndDropsTheUUID() {
        // Forgetting does not un-rename the cube, so the name has to survive: it is the only string
        // the filtered scan can match a device that no longer answers to "timeflip". The Device tab
        // still reads "Not paired", because that is a rendering of "no pairing", not of "no name".
        let appState = makeAppState()
        appState.confirmConnected(name: "Solid cube", uuid: "CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        XCTAssertEqual(appState.pairedDeviceName, "Solid cube")

        appState.forgetDevice()

        XCTAssertFalse(appState.isPaired)
        XCTAssertNil(appState.pairedDeviceUUID)
        XCTAssertEqual(appState.deviceName, "Solid cube")
        XCTAssertEqual(appState.pairedDeviceName, "Not paired")
    }

    func testAConfirmedFactoryResetDiscardsTheDeviceNameToo() {
        // 0xFF reverts the cube to the vendor name, so a remembered custom one is now wrong and
        // would make the scan filter match a name that no longer exists.
        let appState = makeAppState()
        appState.confirmConnected(name: "Solid cube", uuid: "CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")

        appState.forgetDevice(deviceWasWiped: true)

        XCTAssertNil(appState.pairedDeviceUUID)
        XCTAssertNil(appState.deviceName)
        XCTAssertEqual(appState.pairedDeviceName, "Not paired")
    }

    func testAReconnectDoesNotOverwriteTheStoredNameWithAStaleOne() {
        // Measured on the device 2026-08-01: `CBPeripheral.name` is cached and refreshes only on
        // the next connection, so the connect after a rename reports the name from *before* it.
        // Adopting that reverted the correct stored name for a whole session -- and since the scan
        // filter matches on the stored name, it spent that session hunting a name the cube had
        // stopped answering to.
        let appState = makeAppState()
        appState.confirmConnected(name: "Dibby", uuid: "uuid")
        appState.deviceName = "Plopper"
        appState.pairedDeviceName = "Plopper"

        // A reconnect, reporting the pre-rename name.
        appState.confirmConnected(name: "Dibby", uuid: "uuid")

        XCTAssertEqual(appState.deviceName, "Plopper", "the name we wrote and got an ack for must win over a cached read")
        XCTAssertEqual(appState.pairedDeviceName, "Plopper")
    }

    func testAFirstPairingDoesTakeTheNameTheCubeReports() {
        // The one moment the cube's answer beats ours: nothing is stored, and a peripheral this Mac
        // has not connected to before has nothing cached to be stale.
        let appState = makeAppState()

        appState.confirmConnected(name: "TimeFlip v2.0", uuid: "uuid")

        XCTAssertEqual(appState.deviceName, "TimeFlip v2.0")
    }

    func testPairingADifferentCubeAfterAForgetTakesTheNewCubesName() {
        // Forget Device keeps `deviceName` on purpose, so "adopt only when nothing is stored" would
        // make a second cube inherit the first one's name forever.
        let appState = makeAppState()
        appState.confirmConnected(name: "Dibby", uuid: "uuid-1")
        appState.forgetDevice()
        XCTAssertEqual(appState.deviceName, "Dibby", "forget keeps the name; that is what makes this case possible")

        appState.confirmConnected(name: "Someone else's cube", uuid: "uuid-2")

        XCTAssertEqual(appState.deviceName, "Someone else's cube")
    }

    func testReconnectingWithoutANameShowsTheRememberedOne() {
        // `confirmConnected` is called with whatever the peripheral has told us, which can be nil
        // before the name is known. That must not leave the tab on the placeholder a previous
        // forget left behind when a perfectly good name is already remembered.
        let appState = makeAppState()
        appState.confirmConnected(name: "Solid cube", uuid: "CBDFFEFE-C6F4-4977-A5C3-D40F3CA6E561")
        appState.forgetDevice()
        XCTAssertEqual(appState.pairedDeviceName, "Not paired")

        appState.confirmConnected(name: nil, uuid: nil)

        XCTAssertEqual(appState.pairedDeviceName, "Solid cube")
        XCTAssertEqual(appState.deviceName, "Solid cube")
    }

    func testALaunchThatIsNotPairedShowsThePlaceholderDespiteARememberedName() {
        // The state after Forget Device + quit: device_name is still in the database, but there is
        // no pairing for it to belong to, so the tab must not present it as the paired device.
        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            isPaired: false,
            deviceName: "Solid cube"
        )

        XCTAssertEqual(appState.pairedDeviceName, "Not paired")
        XCTAssertEqual(appState.deviceName, "Solid cube")
    }
}
