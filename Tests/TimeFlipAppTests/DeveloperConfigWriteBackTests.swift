@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
/// `config.json` holds a dev cube's PIN. These pin the rule that the app writes that field at the
/// **two moments the cube's password actually changes** -- a pairing rotating it, and a forget or
/// confirmed reset putting it back to the factory default -- and never on any other save.
///
/// The bug they exist for cost a real evening on 2026-08-01, and the fix has since been turned
/// around, so the distinction is worth holding precisely. Forget Device set the in-memory password
/// to the factory default and the `$devicePassword` observer wrote it into `config.json` -- but the
/// re-pair afterwards **wrote nothing**, so the cube ended up on a rotated PIN the file did not
/// name. It surfaced later as a login rejection on a launch nobody would connect to the forget, and
/// every attempt to fix the file by hand was overwritten again by the running app.
///
/// The write was never the problem; the half-loop was. Both ends are closed now, so the file tracks
/// the cube instead of describing one moment of it, and the write on every unrelated save -- the
/// part that fought the developer's editor -- is still gone.
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

    /// The file's PIN **is** the connect password now, which is the opposite of what this once
    /// asserted, and the reason the reversal is safe is worth keeping next to it.
    ///
    /// The 2026-08-01 write-back stamped `000000` into the file while pairing rotated the cube to
    /// `123456`, and the same evening repeated itself on 2026-08-08 when the file's stale value
    /// still outranked the constant: `03b` halted with a cube on one PIN and every launch
    /// presenting the other. The fix then was to keep the file out of the connect path.
    ///
    /// What makes it the right source now is that the app **writes** the field at the pairing that
    /// sets it (`recordDevicePasswordInConfig`), so a stale value is no longer something the app can
    /// produce -- only something a developer can type, deliberately, which is exactly what the
    /// manual-mode checklist needs to do to stage a refused PIN.
    func testTheConfigPINIsWhatAPairedBuildPresents() {
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
            TimeFlipConstants.defaultPassword,
            "config.json is the record of what the paired cube is on, so it decides what is presented"
        )
    }

    /// The half that is **not** reversed, and the one that stops a mismatch being unrecoverable.
    ///
    /// Pairing still rotates onto the compiled constant, which is also a pairing candidate, so a
    /// cube this app has paired can always be reached again by a re-pair no matter what happens to
    /// the file. Rotating onto the file's own value instead would leave the cube on a PIN that only
    /// that file names, and an edit afterwards would strand it: nothing left to guess, and neither
    /// Forget nor a factory reset can help, both needing a login first.
    func testPairingStillRotatesOntoTheCompiledConstant() throws {
        try XCTSkipUnless(DeveloperMode.isEnabled)

        XCTAssertEqual(
            DeveloperMode.devicePassword,
            "123456",
            "the rotation target is compiled in and in the pairing candidate list; changing it strands paired cubes"
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

    /// The other half of the reversal, and the one that looks most like the original bug.
    ///
    /// Forgetting a device resets the cube over `0x30` and only proceeds once that is confirmed, so
    /// the cube really is back on the factory default and the file has to say so. This is the write
    /// that caused the 2026-08-01 evening, and what makes it right now is what was missing then: the
    /// **re-pair also writes**, so the file tracks the cube through both transitions rather than
    /// being stamped on the way out and abandoned on the way back in.
    ///
    /// Leaving it stale is not the safe option it looks like. The file is what a paired build
    /// presents, so a forget that left `123456` in place would name a password the cube no longer
    /// holds -- which is the lockout, not the protection from it.
    func testForgettingADeviceRecordsTheFactoryDefault() async {
        let configStore = handEditedConfig
        let appState = makeAppState(configStore: configStore)
        XCTAssertTrue(appState.isDeveloperConfigLoaded, "the dev-config path must actually be live, or this proves nothing")

        await appState.resetAndForgetDevice()

        XCTAssertEqual(configStore.stored?.devicePassword, TimeFlipConstants.defaultPassword)
        XCTAssertEqual(configStore.stored?.googleClientID, "client-id", "the keys sharing the file must survive it")
        XCTAssertEqual(configStore.stored?.googleClientSecret, "secret")
    }

    func testThePlainUnpairPrimitiveWritesNothing() {
        // `forgetDevice` is called by a dozen tests on an `AppState` built with default stores, which
        // means the real `config.json`. The write belongs to the callers that know a password was
        // actually reset, and this is the line that keeps it there.
        let configStore = handEditedConfig
        let appState = makeAppState(configStore: configStore)

        appState.forgetDevice()

        XCTAssertTrue(configStore.saves.isEmpty)
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
// swiftlint:enable line_length
