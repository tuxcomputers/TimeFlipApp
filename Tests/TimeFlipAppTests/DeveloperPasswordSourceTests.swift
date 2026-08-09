@testable import TimeFlipApp
import XCTest

/// Where a dev build gets the PIN it presents to a cube.
///
/// The rule is that guessing stops at pairing. The factory default and `DeveloperMode.devicePassword`
/// are for a cube whose PIN the app does not know yet: still on the vendor default, or left on the
/// constant by an older build. Once there is a pairing there is exactly one right answer, and it is
/// `config.json`'s PIN, because that is what pairing rotated the cube onto.
///
/// The failure this guards is not hypothetical. When the two ends read different values, a dev build
/// locks itself out of its own cube on the next launch and cannot recover without a re-pair -- which
/// is `03b` on 2026-08-08, where the file said one thing, the cube held another, and every launch
/// afterwards was refused with `Login rejected, code=0x01`.
@MainActor
final class DeveloperPasswordSourceTests: XCTestCase {
    private func makeAppState(
        configPIN: String?,
        store: InMemoryDeveloperConfigStore? = nil
    ) -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            developerConfigStore: store ?? InMemoryDeveloperConfigStore(
                stored: DeveloperConfigPayload(
                    googleClientID: "id",
                    googleClientSecret: "secret",
                    devicePassword: configPIN
                )
            ),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            isPaired: true,
            deviceName: "Solid cube"
        )
    }

    func testAPairedDevBuildPresentsTheConfigPIN() throws {
        try XCTSkipUnless(DeveloperMode.isEnabled, "release builds take the Keychain path")

        XCTAssertEqual(makeAppState(configPIN: "654321").devicePassword, "654321")
    }

    func testAConfigWithoutAPINFallsBackToTheConstant() throws {
        // A file that has never carried a PIN, or one whose symlink is broken. Behaving exactly as
        // the build did before this existed is the point: the fallback is what stops a missing file
        // turning into a device the app cannot reach.
        try XCTSkipUnless(DeveloperMode.isEnabled, "release builds take the Keychain path")

        XCTAssertEqual(makeAppState(configPIN: nil).devicePassword, DeveloperMode.devicePassword)
    }

    func testTheKeychainIsNeverConsultedInADevBuild() throws {
        // The Keychain holds whatever a release build last rotated to, which has nothing to do with
        // the cube a developer is pointing at.
        try XCTSkipUnless(DeveloperMode.isEnabled, "release builds are the case that does read it")
        let keychain = InMemoryDevicePasswordStore()
        try keychain.savePassword("999999")

        let appState = AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: keychain,
            developerConfigStore: InMemoryDeveloperConfigStore(
                stored: DeveloperConfigPayload(googleClientID: nil, googleClientSecret: nil, devicePassword: "111111")
            ),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            isPaired: true
        )

        XCTAssertEqual(appState.devicePassword, "111111")
    }

    func testTheConfigPINIsStillReadableAsAPairingCandidate() throws {
        // Pairing keeps its own list, and this is the third entry in it. Adopting the PIN for
        // connecting must not remove it from there: a cube already on that PIN has to be pairable.
        try XCTSkipUnless(DeveloperMode.isEnabled)

        XCTAssertEqual(makeAppState(configPIN: "654321").developerConfigDevicePassword, "654321")
    }

    // MARK: - How the file comes to hold the right PIN

    func testPairingRecordsThePINItRotatedTheCubeOnto() throws {
        // The one write the app makes to that field, and the reason the two ends agree without the
        // developer having to keep them in step by hand.
        try XCTSkipUnless(DeveloperMode.isEnabled)
        let store = InMemoryDeveloperConfigStore(
            stored: DeveloperConfigPayload(googleClientID: "id", googleClientSecret: "secret", devicePassword: nil)
        )
        let appState = makeAppState(configPIN: nil, store: store)

        appState.recordPairedDevicePassword(DeveloperMode.devicePassword)

        XCTAssertEqual(store.stored?.devicePassword, DeveloperMode.devicePassword)
        XCTAssertEqual(appState.developerConfigDevicePassword, DeveloperMode.devicePassword)
    }

    func testRecordingThePINKeepsTheGoogleKeys() {
        // The whole payload is rewritten, so the two keys that share the file have to survive it.
        // Losing a client secret to a pairing would be a bad way to find this out.
        let store = InMemoryDeveloperConfigStore(
            stored: DeveloperConfigPayload(googleClientID: "id", googleClientSecret: "secret", devicePassword: "123456")
        )
        let appState = makeAppState(configPIN: "123456", store: store)

        appState.recordPairedDevicePassword("654321")

        XCTAssertEqual(store.stored?.googleClientID, "id")
        XCTAssertEqual(store.stored?.googleClientSecret, "secret")
    }
}
