@testable import FacetApp
import Foundation
import XCTest

/// Covers `DevicePINSource`: reading the two stores in order, writing a rotated PIN to them, and healing them when
/// they disagree.
///
/// **Against a real file and a stand-in Keychain.** The file is a real one in a temporary directory, for the reason
/// `DeveloperConfigFileTests` gives -- these would otherwise rewrite the PIN of the cube this app is tested against.
/// The Keychain is a closure, because `swift test` and CI have none, and because the paths worth pinning here are
/// the ones where it **refuses**: that is what the config-file fallback exists for, and it is not a state anybody can
/// arrange on a real Keychain to order.
@MainActor
final class DevicePINSourceTests: XCTestCase {
    private var directory: URL!
    private var file: DeveloperConfigFile!
    /// What the stand-in Keychain holds, and whether it will take a write at all.
    private var keychain: String?
    private var keychainAccepts = true
    private var keychainReadable = true
    private var saved: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facet-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = DeveloperConfigFile(url: directory.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func source() -> DevicePINSource {
        DevicePINSource(
            keychainLookUp: { [self] in
                guard keychainReadable else { return .unavailable(-25300) }
                return keychain.map { .found($0) } ?? .missing
            },
            keychainSave: { [self] pin in
                guard keychainAccepts else { return false }
                keychain = pin
                saved.append(pin)
                return true
            },
            configFile: file,
            debugLog: nil
        )
    }

    // MARK: - what it presents

    func testTheFileGoesAheadOfTheKeychain() {
        file.record(pin: "654321")
        keychain = "123456"

        XCTAssertEqual(source().stored(), ["654321", "123456"])
    }

    func testTheOrdinaryCaseIsOnePIN() {
        keychain = "123456"

        XCTAssertEqual(source().stored(), ["123456"])
    }

    func testAKeychainThatWillNotAnswerIsNotTheSameAsAnEmptyOne() {
        // It leaves the app presenting one fewer candidate than it has, which is worth a row rather than silence --
        // the failure that follows is a cube refusing a PIN nobody knew was missing.
        keychain = "123456"
        keychainReadable = false

        XCTAssertEqual(source().stored(), [])
    }

    // MARK: - writing a rotated PIN down

    func testARotatedPINGoesToTheKeychainAndLeavesNoCopyInTheClear() {
        let recorded = source().record("654321")

        XCTAssertEqual(recorded.destinations, [.keychain])
        XCTAssertEqual(keychain, "654321")
        XCTAssertNil(file.pin(), "a release build has no reason to write the PIN to a plain file")
    }

    func testAKeychainThatRefusesSendsThePINToTheFileInstead() {
        // **The fallback, and the whole reason it exists**: the cube is on this PIN either way, so the only question
        // is whether the app can still name it. Without this the next launch presents the vendor default and a PIN
        // the cube no longer has, and the only recovery is the batteries.
        keychainAccepts = false

        let recorded = source().record("654321")

        XCTAssertTrue(recorded.isRecorded)
        XCTAssertTrue(recorded.isFallback)
        XCTAssertEqual(file.pin(), "654321")
    }

    func testAPINNothingWillHoldIsReportedAsSuch() {
        // The one fault this app cannot put right on its own, which is why the caller raises an alert on it.
        keychainAccepts = false
        file = DeveloperConfigFile(url: URL(fileURLWithPath: "/dev/null/not-a-directory/config.json"))

        let recorded = source().record("654321")

        XCTAssertFalse(recorded.isRecorded)
        XCTAssertEqual(recorded.destinations, [])
    }

    // MARK: - putting the two stores back together

    func testThePINTheCubeAnsweredToIsPromotedAndTheFileIsCleared() {
        // The healing, in a release build: the file held it because the Keychain refused a write, and the Keychain
        // taking it now is what makes the file's copy unnecessary.
        file.record(pin: "654321")
        keychain = "123456"

        let reconciled = source().reconcile(accepted: "654321")

        XCTAssertTrue(reconciled.promoted)
        XCTAssertTrue(reconciled.clearedConfigFile)
        XCTAssertEqual(keychain, "654321")
        XCTAssertNil(file.pin())
    }

    func testTheFileIsNotClearedWhileThePromotionFailed() {
        // The file is the only record at that moment. Clearing it would turn a Keychain fault into a lost cube.
        file.record(pin: "654321")
        keychain = "123456"
        keychainAccepts = false

        let reconciled = source().reconcile(accepted: "654321")

        XCTAssertFalse(reconciled.promoted)
        XCTAssertFalse(reconciled.clearedConfigFile)
        XCTAssertEqual(file.pin(), "654321")
    }

    func testAPINFromNeitherStoreMovesNothing() {
        file.record(pin: "654321")
        keychain = "123456"

        let reconciled = source().reconcile(accepted: "000000")

        XCTAssertEqual(reconciled, .nothingHappened)
        XCTAssertEqual(keychain, "123456")
        XCTAssertEqual(file.pin(), "654321")
    }

    func testNothingIsWrittenWhenTheStoresAlreadyAgree() {
        file.record(pin: "123456")
        keychain = "123456"

        let reconciled = source().reconcile(accepted: "123456")

        XCTAssertFalse(reconciled.promoted)
        XCTAssertEqual(saved, [], "the Keychain is not written to for the sake of it")
    }

    // MARK: - what a launch settles on its own

    func testALaunchTakesAwayARedundantCopyWithoutAskingTheCube() {
        // The Keychain is provably holding the same string, so there is nothing for a cube to settle and no reason
        // for a release build to leave a live PIN in a plain file.
        file.record(pin: "654321")
        keychain = "654321"

        XCTAssertEqual(source().settleAtLaunch(), .clearedARedundantCopy)
        XCTAssertNil(file.pin())
        XCTAssertEqual(keychain, "654321", "and the PIN itself is untouched")
    }

    func testALaunchThatFindsThemDisagreeingWaitsForTheCube() {
        file.record(pin: "654321")
        keychain = "123456"

        XCTAssertEqual(source().settleAtLaunch(), .awaitingTheCube)
        XCTAssertEqual(file.pin(), "654321", "and nothing is thrown away in the meantime")
    }

    func testALaunchWithNoFileHasNothingToSettle() {
        keychain = "123456"

        XCTAssertEqual(source().settleAtLaunch(), .nothingToSettle)
    }

    func testAFileThatWillNotGiveUpItsCopyIsNotReportedAsSettled() {
        // The write failing is not a reason to say it worked, and the next launch asks again.
        file.record(pin: "654321")
        keychain = "654321"
        let readOnly = directory.appendingPathComponent("config.json")
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: readOnly.path) }

        XCTAssertEqual(source().settleAtLaunch(), .nothingToSettle)
        XCTAssertEqual(file.pin(), "654321")
    }
}
