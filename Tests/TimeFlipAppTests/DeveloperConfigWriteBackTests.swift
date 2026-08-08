@testable import TimeFlipApp
import XCTest

/// `config.json` is a developer input file, edited by hand. These pin the rule that the app reads
/// the PIN from it and never writes one back.
///
/// The bug they exist for cost a real evening on 2026-08-01. Forget Device set the in-memory
/// password to the factory default, the `$devicePassword` observer wrote that straight into
/// `config.json`, the re-pair then rotated the cube to a different PIN, and the file was left
/// describing a password the device no longer accepted. Nothing failed at the time. It surfaced
/// later as a login rejection on a launch nobody would connect to the forget, and every attempt to
/// fix the file by hand was overwritten again by the running app.
@MainActor
final class DeveloperConfigWriteBackTests: XCTestCase {
    private func makeAppState(
        configStore: InMemoryDeveloperConfigStore
    ) -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            developerConfigStore: configStore,
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true
        )
    }

    private var handEditedConfig: InMemoryDeveloperConfigStore {
        InMemoryDeveloperConfigStore(
            stored: DeveloperConfigPayload(
                googleClientID: "client-id",
                googleClientSecret: "secret",
                devicePassword: "123456"
            )
        )
    }

    /// The 2026-08-01 write-back was stopped, but the `000000` it had already stamped into the file
    /// stayed there, and the file still outranked the password a dev build starts on -- so the same
    /// evening repeated itself on 2026-08-08, halting `03b` with a cube on `123456` and an app
    /// presenting `000000` on every launch. Reading the PIN must not decide what the app connects
    /// with.
    func testAStaleConfigPINDoesNotBecomeTheConnectPassword() {
        let configStore = InMemoryDeveloperConfigStore(
            stored: DeveloperConfigPayload(
                googleClientID: "client-id",
                googleClientSecret: "secret",
                devicePassword: TimeFlipConstants.defaultPassword
            )
        )

        let appState = makeAppState(configStore: configStore)

        XCTAssertTrue(appState.isDeveloperConfigLoaded, "the dev-config path must actually be live, or this proves nothing")
        XCTAssertEqual(
            appState.devicePassword,
            DeveloperMode.devicePassword,
            "a dev build must start on the password it rotates a cube to, whatever config.json says"
        )
    }

    func testTheConfigPINIsStillAvailableAsAPairingCandidate() {
        // Pairing is the one place a password is legitimately guessed, so a hand-set PIN still has
        // somewhere to be used -- it just isn't what a reconnect presents.
        let appState = makeAppState(configStore: handEditedConfig)

        XCTAssertEqual(appState.developerConfigDevicePassword, "123456")
    }

    func testNoPINInConfigJSONLeavesNothingToOffer() {
        let configStore = InMemoryDeveloperConfigStore(
            stored: DeveloperConfigPayload(
                googleClientID: "client-id",
                googleClientSecret: "secret",
                devicePassword: nil
            )
        )

        let appState = makeAppState(configStore: configStore)

        XCTAssertNil(appState.developerConfigDevicePassword)
        XCTAssertEqual(appState.devicePassword, DeveloperMode.devicePassword)
    }

    func testForgettingADeviceDoesNotWriteConfigJSONAtAll() {
        let configStore = handEditedConfig
        let appState = makeAppState(configStore: configStore)
        XCTAssertTrue(appState.isDeveloperConfigLoaded, "the dev-config path must actually be live, or this proves nothing")

        appState.forgetDevice()

        XCTAssertTrue(
            configStore.saves.isEmpty,
            "Forget Device must not touch config.json; it once stamped the factory default over a hand-set PIN"
        )
        XCTAssertEqual(configStore.stored?.devicePassword, "123456")
    }

    func testTheInMemoryPasswordStillReturnsToTheFactoryDefaultOnForget() {
        // The suppression is about persistence only. Forget Device resets the cube over 0x30, so
        // the factory default genuinely is what the next pairing attempt should present.
        let appState = makeAppState(configStore: handEditedConfig)

        appState.forgetDevice()

        XCTAssertEqual(appState.devicePassword, TimeFlipConstants.defaultPassword)
    }

    func testSavingTheGoogleKeysCarriesTheExistingPINThroughUntouched() {
        // The Google keys legitimately persist to config.json, so the PIN has to survive that
        // write. Passing it through from disk rather than omitting it matters: an omitted key would
        // encode as absent and delete the developer's PIN rather than leave it in place.
        let configStore = handEditedConfig
        let appState = makeAppState(configStore: configStore)

        appState.googleClientSecret = "a-different-secret"

        // That persist is debounced by 200ms, so wait for the write rather than assuming it landed.
        let saved = expectation(description: "config.json written")
        Task { @MainActor in
            for _ in 0..<40 where configStore.saves.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)

        XCTAssertFalse(configStore.saves.isEmpty, "changing a Google key should still write config.json")
        XCTAssertEqual(configStore.saves.last?.devicePassword, "123456")
        XCTAssertEqual(configStore.stored?.devicePassword, "123456")
    }
}
