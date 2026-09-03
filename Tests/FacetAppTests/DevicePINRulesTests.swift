@testable import FacetApp
import XCTest

/// Covers `DevicePINRules`: when a cube's PIN is changed, what it is changed to, where that is written and how the
/// two stores are put back together when they disagree.
///
/// **The point of testing this without a Keychain is that a Keychain is what `swift test` does not have** -- nor CI,
/// nor a cube. Every decision here is taken away from all three, so what is left to a device run is only whether the
/// hardware took the PIN.
final class DevicePINRulesTests: XCTestCase {
    /// A generator a test can predict: `zeroDigits` draws that come out as the digit 0, and nines for ever after.
    ///
    /// **The numbers look arbitrary and are not.** `Int.random(in:using:)` uses Lemire's method: it multiplies the
    /// draw by the range and takes the **high** word, so a small draw like 0 or 7 is the digit 0 whatever it is, and
    /// a generator of small numbers can only ever produce `000000`. That is not a slow test, it is a hang -- `target`
    /// rejects the vendor default and asks again for ever. Measured, on the first two versions of this file.
    ///
    /// So 7 is the smallest draw that yields a digit at all (0 itself is *rejected* rather than used, the low word
    /// falling under the threshold), and `UInt64.max` is what yields a 9. `zeroDigits` therefore has to run out, or
    /// the hang comes back.
    private struct StubGenerator: RandomNumberGenerator {
        private let zeroDigits: Int
        private var used = 0

        init(zeroDigits: Int) { self.zeroDigits = zeroDigits }

        mutating func next() -> UInt64 {
            defer { used += 1 }
            return used < zeroDigits ? 7 : UInt64.max
        }
    }

    // MARK: - when a cube is given a PIN of its own

    func testACubeOnTheVendorDefaultIsRotated() {
        // The whole point: the default is public and printed in the protocol spec, so a cube left on it is one
        // anybody within a few metres can take over.
        XCTAssertTrue(DevicePINRules.rotates(from: DeviceLoginRules.defaultPIN))
    }

    func testACubeOnAPINThisAppSetIsLeftAlone() {
        // It is on a PIN this app put there and wrote down, so rotating again would spend a command and a confirming
        // login to replace a known value with another known value.
        XCTAssertFalse(DevicePINRules.rotates(from: "123456"))
        XCTAssertFalse(DevicePINRules.rotates(from: "654321"))
    }

    // MARK: - what it is rotated to

    func testARotationSetsSixRandomDigits() {
        // The half the previous app could not do, because it had nowhere durable to keep the answer. There is one
        // answer now: the fixed `123456` a developer build used to set went with the developer flag on 2026-09-04.
        var generator = StubGenerator(zeroDigits: 0)

        let pin = DevicePINRules.target(using: &generator)

        XCTAssertEqual(pin.count, DeviceLoginRules.length)
        XCTAssertTrue(pin.allSatisfy(\.isNumber), pin)
        XCTAssertTrue(DeviceLoginRules.isWellFormed(pin), "and the characteristic can hold it")
    }

    func testARandomPINIsNeverTheVendorDefault() {
        // The one draw in a million that would rotate a cube from 000000 to 000000: a command and a confirming login
        // spent to leave it exactly as exposed as it was.
        // A hundred zero digits is more than enough for the first attempt -- and for a dozen after it -- to come out
        // as the vendor default, so what this measures is the loop that rejects it rather than a lucky first draw.
        var generator = StubGenerator(zeroDigits: 100)

        XCTAssertNotEqual(DevicePINRules.target(using: &generator), "000000")
    }

    func testTwoRotationsDoNotProduceTheSamePIN() {
        // Not a claim about randomness, but about *when* the digits are drawn: a target worked out once and reused
        // would put one PIN on every cube a launch ever met.
        let first = DevicePINRules.target()
        let second = DevicePINRules.target()

        XCTAssertNotEqual(first, second, "one in a million, and worth knowing if it ever fires twice")
    }

    // MARK: - where it is written

    func testARotatedPINIsWrittenToTheKeychain() {
        // And to the file only when the Keychain refuses, which is `DevicePINSource.record`'s fallback rather than a
        // destination listed here: this is where a PIN is meant to go.
        XCTAssertEqual(DevicePINRules.destinations, [.keychain])
    }

    // MARK: - which PIN is presented first

    func testTheFileGoesAheadOfTheKeychain() {
        // Backwards for a release build, and the point of the fallback: the file only ever holds one because the
        // Keychain refused it, so the file's is the newer of the two.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "654321", keychain: "123456"),
            ["654321", "123456"]
        )
    }

    func testTwoStoresThatAgreeArePresentedOnce() {
        // Each candidate costs a whole connect, which is a long way to go to learn nothing.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "123456", keychain: "123456"),
            ["123456"]
        )
    }

    func testAPINTheCharacteristicCouldNotHoldIsNotPresented() {
        // Six bytes, which the protocol fixes. A wrong-length candidate is a bug on this side, and presenting it
        // would spend a connect on a refusal that reads as the cube's fault.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "12345", keychain: "1234567"),
            []
        )
    }

    func testWithNothingWrittenDownThereIsNothingToTry() {
        // Which leaves the vendor default on its own, and that is the honest answer: a cube this app has no record
        // of is either new or somebody else's.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: nil, keychain: nil),
            []
        )
    }

    func testAFileWithNothingBehindItIsTheWholeOfTheOrder() {
        // Nothing is invented alongside it. A guess offered as an extra candidate is the archive's own bug: it let a
        // build into a cube whose PIN the app had no record of, and made "the stored PIN" mean two different things.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "654321", keychain: nil),
            ["654321"]
        )
    }

    func testAStoreDisagreeingWithTheOtherPresentsBoth() {
        // The failed-write case: the file holds the newer PIN and the Keychain what the cube was called before it,
        // and only the cube can say which it took.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "123457", keychain: "123456"),
            ["123457", "123456"]
        )
    }

    func testAnUnusablePINInOneStoreLeavesTheOther() {
        // A half-typed PIN is a file somebody is in the middle of editing, and presenting five digits would spend a
        // connect on a refusal that reads as the cube's fault.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "12345", keychain: "123456"),
            ["123456"]
        )
    }

    // MARK: - what a launch settles on its own

    func testARedundantCopyIsTakenAway() {
        // **The case the first version of this missed.** Asking only whether the two disagree left a launch whose
        // file and Keychain matched holding a live PIN in a plain file for ever -- and it can get there whenever the
        // promotion works and the clearing fails.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "654321", keychain: "654321"),
            .clearConfigFile
        )
    }

    func testADisagreementWaitsForTheCube() {
        // Neither store can say which PIN the hardware took, and promoting the wrong one would overwrite the app's
        // record of the right one.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "654321", keychain: "123456"),
            .askTheCube
        )
    }

    func testAKeychainWithNothingInItStillWaitsForTheCube() {
        // The failed-write case at its starkest: the file is the only record, and it becomes the Keychain's only
        // once a cube has answered to it.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "654321", keychain: nil),
            .askTheCube
        )
    }

    func testAFileNamingNothingIsTheOrdinaryState() {
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: nil, keychain: "654321"),
            .nothing
        )
    }

    // MARK: - putting the two stores back together

    func testThePINTheCubeAnsweredToIsPromotedWhenTheKeychainDoesNotHaveIt() {
        let decision = DevicePINRules.reconciliation(
            accepted: "654321", configFile: "654321", keychain: "123456"
        )

        XCTAssertTrue(decision.promotesToKeychain)
        XCTAssertTrue(decision.clearsConfigFileOnSuccess, "and the copy in the clear stops being kept")
    }

    func testAPINTheKeychainAlreadyHoldsIsNotPromotedTwice() {
        let decision = DevicePINRules.reconciliation(
            accepted: "654321", configFile: "654321", keychain: "654321"
        )

        XCTAssertFalse(decision.promotesToKeychain)
        XCTAssertTrue(decision.clearsConfigFileOnSuccess, "the file has served its purpose either way")
    }

    func testAPINFromNeitherStoreMovesNothing() {
        // A cube on something else entirely -- the vendor default, or a PIN from another machine. Promoting on that
        // would overwrite the app's record of a PIN that may still be the right one for this cube.
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "000000", configFile: "654321", keychain: "123456"
            ),
            .nothingToDo
        )
    }

    func testTheKeychainsOwnPINMovesNothing() {
        // The ordinary case, and the reason `storesDisagree` is asked before any of this: there is nothing to heal.
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "123456", configFile: "654321", keychain: "123456"
            ),
            .nothingToDo
        )
    }

    func testWithNoFileThereIsNothingToReconcile() {
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "123456", configFile: nil, keychain: "123456"
            ),
            .nothingToDo
        )
    }
}
