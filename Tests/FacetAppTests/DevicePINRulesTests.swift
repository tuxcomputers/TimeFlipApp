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

    func testADeveloperBuildSetsTheFixedPIN() {
        // Fixed rather than random so a dev cube's PIN is always known and typeable when something goes wrong.
        XCTAssertEqual(DevicePINRules.target(isDeveloperMode: true), "123456")
        XCTAssertEqual(DevicePINRules.developerPIN, "123456")
    }

    func testAnyOtherBuildSetsSixRandomDigits() {
        // The half the previous app could not do, because it had nowhere durable to keep the answer.
        var generator = StubGenerator(zeroDigits: 0)

        let pin = DevicePINRules.target(isDeveloperMode: false, using: &generator)

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

        XCTAssertNotEqual(DevicePINRules.target(isDeveloperMode: false, using: &generator), "000000")
    }

    func testTwoRotationsDoNotProduceTheSamePIN() {
        // Not a claim about randomness, but about *when* the digits are drawn: a target worked out once and reused
        // would put one PIN on every cube a launch ever met.
        let first = DevicePINRules.target(isDeveloperMode: false)
        let second = DevicePINRules.target(isDeveloperMode: false)

        XCTAssertNotEqual(first, second, "one in a million, and worth knowing if it ever fires twice")
    }

    // MARK: - where it is written

    func testADeveloperBuildWritesBothStores() {
        // The file is what a person reads; the Keychain is what a release build will have. Writing both keeps the
        // path a dev build exercises the same path a release build takes.
        XCTAssertEqual(DevicePINRules.destinations(isDeveloperMode: true), [.keychain, .configFile])
    }

    func testAnyOtherBuildWritesTheKeychain() {
        XCTAssertEqual(DevicePINRules.destinations(isDeveloperMode: false), [.keychain])
    }

    // MARK: - which PIN is presented first

    func testTheFileGoesAheadOfTheKeychain() {
        // Backwards for a release build, and the point of the fallback: the file only ever holds one because the
        // Keychain refused it, so the file's is the newer of the two.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "654321", keychain: "123456", isDeveloperMode: false),
            ["654321", "123456"]
        )
    }

    func testTwoStoresThatAgreeArePresentedOnce() {
        // Each candidate costs a whole connect, which is a long way to go to learn nothing.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "123456", keychain: "123456", isDeveloperMode: true),
            ["123456"]
        )
    }

    func testAPINTheCharacteristicCouldNotHoldIsNotPresented() {
        // Six bytes, which the protocol fixes. A wrong-length candidate is a bug on this side, and presenting it
        // would spend a connect on a refusal that reads as the cube's fault.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: "12345", keychain: "1234567", isDeveloperMode: false),
            []
        )
    }

    func testWithNothingWrittenDownADeveloperBuildStillHasOneToTry() {
        // The stand-in, and only with nothing written down at all: a dev cube is only ever left on 000000 or this.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: nil, keychain: nil, isDeveloperMode: true),
            ["123456"]
        )
    }

    func testWithNothingWrittenDownAnyOtherBuildHasNothingToTry() {
        // Which leaves the vendor default on its own, and that is the honest answer: a cube this app has no record
        // of is either new or somebody else's.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: nil, keychain: nil, isDeveloperMode: false),
            []
        )
    }

    func testTheStandInNeverJoinsAStoredPIN() {
        // The archive's own bug: offered as an extra guess it let a dev build into a cube whose PIN the app had no
        // record of, and made "the stored PIN" mean two different things.
        XCTAssertEqual(
            DevicePINRules.readOrder(configFile: nil, keychain: "654321", isDeveloperMode: true),
            ["654321"]
        )
    }

    // MARK: - what a launch settles on its own

    func testAReleaseBuildTakesAwayARedundantCopy() {
        // **The case the first version of this missed.** Asking only whether the two disagree left a release build
        // whose file and Keychain matched holding a live PIN in a plain file for ever -- and it can get there: the
        // promotion works and the clearing fails, or a developer build wrote both and the machine then runs a
        // release build.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "654321", keychain: "654321", isDeveloperMode: false),
            .clearConfigFile
        )
    }

    func testADeveloperBuildKeepsItsCopy() {
        // The file is the dev build's ordinary store, and the place a person looks.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "123456", keychain: "123456", isDeveloperMode: true),
            .nothing
        )
    }

    func testADisagreementWaitsForTheCube() {
        // Neither store can say which PIN the hardware took, and promoting the wrong one would overwrite the app's
        // record of the right one.
        for isDeveloperMode in [true, false] {
            XCTAssertEqual(
                DevicePINRules.launchAction(configFile: "654321", keychain: "123456", isDeveloperMode: isDeveloperMode),
                .askTheCube
            )
        }
    }

    func testAKeychainWithNothingInItStillWaitsForTheCube() {
        // The failed-write case at its starkest: the file is the only record, and it becomes the Keychain's only
        // once a cube has answered to it.
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: "654321", keychain: nil, isDeveloperMode: false),
            .askTheCube
        )
    }

    func testAFileNamingNothingIsTheOrdinaryState() {
        XCTAssertEqual(
            DevicePINRules.launchAction(configFile: nil, keychain: "654321", isDeveloperMode: false),
            .nothing
        )
    }

    // MARK: - putting the two stores back together

    func testThePINTheCubeAnsweredToIsPromotedWhenTheKeychainDoesNotHaveIt() {
        let decision = DevicePINRules.reconciliation(
            accepted: "654321", configFile: "654321", keychain: "123456", isDeveloperMode: false
        )

        XCTAssertTrue(decision.promotesToKeychain)
        XCTAssertTrue(decision.clearsConfigFileOnSuccess, "and a release build stops keeping a copy in the clear")
    }

    func testADeveloperBuildKeepsItsFileAfterPromoting() {
        // The file is the dev build's ordinary store, not an emergency one, and it is where a person looks.
        let decision = DevicePINRules.reconciliation(
            accepted: "654321", configFile: "654321", keychain: "123456", isDeveloperMode: true
        )

        XCTAssertTrue(decision.promotesToKeychain)
        XCTAssertFalse(decision.clearsConfigFileOnSuccess)
    }

    func testAPINTheKeychainAlreadyHoldsIsNotPromotedTwice() {
        let decision = DevicePINRules.reconciliation(
            accepted: "654321", configFile: "654321", keychain: "654321", isDeveloperMode: false
        )

        XCTAssertFalse(decision.promotesToKeychain)
        XCTAssertTrue(decision.clearsConfigFileOnSuccess, "the file has served its purpose either way")
    }

    func testAPINFromNeitherStoreMovesNothing() {
        // A cube on something else entirely -- the vendor default, or a PIN from another machine. Promoting on that
        // would overwrite the app's record of a PIN that may still be the right one for this cube.
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "000000", configFile: "654321", keychain: "123456", isDeveloperMode: false
            ),
            .nothingToDo
        )
    }

    func testTheKeychainsOwnPINMovesNothing() {
        // The ordinary case, and the reason `storesDisagree` is asked before any of this: there is nothing to heal.
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "123456", configFile: "654321", keychain: "123456", isDeveloperMode: false
            ),
            .nothingToDo
        )
    }

    func testWithNoFileThereIsNothingToReconcile() {
        XCTAssertEqual(
            DevicePINRules.reconciliation(
                accepted: "123456", configFile: nil, keychain: "123456", isDeveloperMode: false
            ),
            .nothingToDo
        )
    }
}
