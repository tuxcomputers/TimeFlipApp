@testable import FacetCore
import Foundation
import Testing

/// Covers `DevicePINStore` and `GoogleTokenStore` against an in-memory `SecretStore`.
///
/// **These two had no tests at all before candidate 3**, and `DevicePINStore`'s own doc explained why:
/// "deliberately not unit tested, as `GoogleTokenStore` is not: CI has no Keychain". That was true of the
/// `SecItem` calls and it was not true of anything else in either file, which also held the service naming, the
/// account naming, the label, the read-back rule and the three-answer contract. Those are what is tested here; the
/// Keychain itself is `KeychainSecretStore` and is still only provable on a machine that has one.
@Suite @MainActor
struct SecretStoreTests {
    // MARK: - the three answers

    @Test("A secret that was never stored reads as missing, not as unavailable")
    func nothingStoredIsMissing() {
        let secrets = InMemorySecretStore()
        #expect(DevicePINStore(secrets: secrets).lookUp() == .missing)
        #expect(GoogleTokenStore(secrets: secrets).lookUp() == .missing)
    }

    @Test("A store that will not answer is unavailable, which is not the same as empty")
    func aRefusingStoreIsUnavailable() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)
        secrets.put("123456", service: pins.service, account: pins.account)
        secrets.refusesWith = -25300

        // The distinction the whole three-case type exists for. The PIN is sitting right there; this process
        // cannot read it, and treating that as "there is no PIN" would rotate a cube that has a perfectly good one.
        #expect(pins.lookUp() == .unavailable(-25300))
        #expect(secrets.peek(service: pins.service, account: pins.account) == "123456")
    }

    @Test("The convenience readers fold both failures into nil, which is what they are for")
    func theConvenienceReadersFoldBothFailures() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)
        #expect(pins.pin() == nil)

        secrets.refusesWith = -25300
        #expect(pins.pin() == nil)

        // And a caller that must tell them apart still can, which is the point of keeping both readers.
        #expect(pins.lookUp() == .unavailable(-25300))
    }

    // MARK: - the read-back rule

    @Test("A write is believed only when it can be read back")
    func aWriteIsReadBackBeforeItIsBelieved() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)

        #expect(pins.save(pin: "654321") == true)
        #expect(pins.pin() == "654321")

        // A store that reports success and kept nothing. What follows a `true` here is a cube being left on this
        // PIN, so believing the status code alone would be a cube nobody can log into.
        secrets.silentlyDiscardsWrites = true
        #expect(pins.save(pin: "111111") == false)
        #expect(pins.pin() == "654321")
    }

    @Test("A refused write answers false rather than throwing the caller off")
    func aRefusedWriteAnswersFalse() {
        let secrets = InMemorySecretStore()
        secrets.refusesWith = -25308
        #expect(DevicePINStore(secrets: secrets).save(pin: "654321") == false)
        #expect(GoogleTokenStore(secrets: secrets).save(refreshToken: "r") == false)
    }

    // MARK: - the two are separate items

    @Test("The PIN and the refresh token are two items, not one overwritten by turns")
    func thePinAndTheTokenDoNotCollide() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)
        let tokens = GoogleTokenStore(secrets: secrets)

        pins.save(pin: "654321")
        tokens.save(refreshToken: "a-refresh-token")

        // **It is the accounts that keep these apart, not the service suffixes**, which is worth knowing because
        // both files' comments credit the suffix. Mutation-checked on 2026-09-10: giving the PIN the token's
        // `.google` suffix leaves this test green, because `device-pin` and `refresh-token` are still two keys.
        // The suffix is belt to the account's braces rather than the thing doing the work.
        #expect(pins.pin() == "654321")
        #expect(tokens.refreshToken() == "a-refresh-token")

        pins.clear()
        #expect(pins.pin() == nil)
        #expect(tokens.refreshToken() == "a-refresh-token")
    }

    @Test("Each store labels its item so a keyring shows a human which is which")
    func eachStoreLabelsItsItem() {
        let secrets = InMemorySecretStore()
        DevicePINStore(secrets: secrets).save(pin: "654321")
        GoogleTokenStore(secrets: secrets).save(refreshToken: "r")

        #expect(secrets.labels.contains("Facet: TimeFlip cube PIN"))
        #expect(secrets.labels.contains("Facet: Google refresh token"))
    }

    // MARK: - clearing

    @Test("Clearing something that was never there is success, because the caller got what it asked for")
    func clearingNothingIsSuccess() {
        let secrets = InMemorySecretStore()
        #expect(DevicePINStore(secrets: secrets).clear() == true)
        #expect(GoogleTokenStore(secrets: secrets).clear() == true)
    }

    @Test("Clearing removes it, and a later look-up says missing rather than unavailable")
    func clearingRemovesIt() {
        let secrets = InMemorySecretStore()
        let tokens = GoogleTokenStore(secrets: secrets)
        tokens.save(refreshToken: "a-refresh-token")

        #expect(tokens.clear() == true)
        #expect(tokens.lookUp() == .missing)
    }
}

/// Covers `DevicePINSource` reaching a store that will not answer.
///
/// **This is the path candidate 3 was really about.** `DevicePINSource` used to inject two closures to get around
/// `DevicePINStore` being statics, which is the workaround the review called out; now it holds the store, so the
/// case that matters can be set up by saying so rather than by hand-building a fake `lookUp`.
///
/// **The row is the assertion, not the returned value**, and that is worth stating because the obvious test does
/// not work. `keychainPIN` folds `.missing` and `.unavailable` into `nil` deliberately, so "the PIN is not in the
/// order presented" is true either way and a test asserting only that passes with the distinction removed.
/// Mutation-checked on 2026-09-10: collapsing `unavailable` into `missing` there leaves such a test green. What
/// actually differs is that the app says out loud it could not tell, which is the whole of what stops a cube
/// refusing a PIN nobody knew was missing.
@Suite @MainActor
final class DevicePINSourceAgainstAStoreTests {
    private let database: TemporaryDatabase
    private let debugLog: DebugLog

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        try database.bootstrapDebug()
        debugLog = DebugLog(databaseURL: database.debugURL, isRecording: true)
    }

    deinit {
        database.remove()
    }

    private func rows() -> String {
        database.debugString("SELECT group_concat(message, ' | ') FROM debug_log;") ?? ""
    }

    @Test("A store that cannot be read says so, rather than passing for a cube with no PIN")
    func anUnreadableStoreIsAnnounced() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)
        secrets.put("654321", service: pins.service, account: pins.account)
        secrets.refusesWith = -25300

        let source = DevicePINSource(keychain: pins, debugLog: debugLog)

        // `stored()` is what a reconnect presents to the cube. The PIN is there and unreadable, so it is not
        // presented, and the app records that it could not tell rather than proceeding as though there were none.
        #expect(source.stored().contains("654321") == false)
        #expect(rows().contains("would not say whether it holds a PIN"))
    }

    @Test("A store that is merely empty says nothing, because there is nothing to say")
    func anEmptyStoreIsSilent() {
        let source = DevicePINSource(keychain: DevicePINStore(secrets: InMemorySecretStore()), debugLog: debugLog)

        #expect(source.stored().contains("654321") == false)
        // The other half of the distinction: no cube has been paired, which is ordinary and not worth a row.
        #expect(rows().contains("would not say whether it holds a PIN") == false)
    }

    @Test("A readable store puts its PIN in the order presented to the cube")
    func areadableStoreContributesItsPIN() {
        let secrets = InMemorySecretStore()
        let pins = DevicePINStore(secrets: secrets)
        secrets.put("654321", service: pins.service, account: pins.account)

        let source = DevicePINSource(keychain: pins, debugLog: debugLog)
        #expect(source.stored().contains("654321"))
    }
}
