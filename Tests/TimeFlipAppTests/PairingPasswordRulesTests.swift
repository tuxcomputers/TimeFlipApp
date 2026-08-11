@testable import TimeFlipApp
import XCTest

/// Which PINs pairing presents, and which cube gets a PIN of its own.
///
/// The policy was three expressions inside a closure in `ApplicationDelegate` until 2026-08-11, where
/// nothing could reach it -- which is how a dev build came to guess four passwords and how every
/// pairing came to rotate the cube's PIN, including one that had answered to the password already on
/// record. `Bench/02b` Scenario B is the same rule against the real cube; this is the half that needs
/// no radio.
final class PairingPasswordRulesTests: XCTestCase {

    func testItPresentsTheFactoryDefaultThenTheStoredPassword() {
        // The order is the rule, not a preference: a cube on the vendor default is the one that needs
        // a PIN of its own, and finding that out first is what decides whether to rotate.
        XCTAssertEqual(
            PairingPasswordRules.candidates(storedPassword: "123456"),
            [TimeFlipConstants.defaultPassword, "123456"]
        )
    }

    func testItNeverPresentsMoreThanTwo() {
        // The regression this type exists for. A dev build used to append `DeveloperMode.devicePassword`
        // and `config.json`'s PIN as well, so a pairing could spend four connect round trips and
        // "the stored password" had two rival meanings.
        for stored in ["123456", "999999", "000001", ""] {
            XCTAssertEqual(PairingPasswordRules.candidates(storedPassword: stored).count, 2, "stored=\(stored)")
        }
    }

    func testAStoredDefaultIsPresentedOnce() {
        // A second identical attempt would cost a whole connect round trip to learn nothing, and on a
        // rejection it would read as a different candidate having failed.
        XCTAssertEqual(
            PairingPasswordRules.candidates(storedPassword: TimeFlipConstants.defaultPassword),
            [TimeFlipConstants.defaultPassword]
        )
    }

    func testOnlyTheFactoryDefaultEarnsARotation() {
        // Reached on the default: a cube new to this app, or one power-cycled back to `000000`. It gets
        // a PIN of its own, and the stored password is updated when the device confirms it.
        XCTAssertTrue(PairingPasswordRules.rotatesPassword(passwordUsed: TimeFlipConstants.defaultPassword))
    }

    func testACubeReachedOnTheStoredPasswordIsLeftAlone() {
        // The same cube, paired before and since forgotten. Its PIN is already the one on record, so
        // rotating would change a device PIN nobody asked to change and overwrite a stored password
        // that was already right.
        XCTAssertFalse(PairingPasswordRules.rotatesPassword(passwordUsed: "123456"))
        XCTAssertFalse(PairingPasswordRules.rotatesPassword(passwordUsed: "999999"))
    }

    func testTheWrongPINCaseIsSimplyNeitherCandidate() {
        // `123457`, the deliberate one-digit-off PIN `02b` Scenario B stores to force a failure. It is
        // offered as the second candidate like any stored password, and earns no rotation if it were
        // somehow accepted -- there is no branch that treats a wrong guess as a special case, because
        // pairing has no third guess to fall back on.
        XCTAssertEqual(
            PairingPasswordRules.candidates(storedPassword: "123457"),
            [TimeFlipConstants.defaultPassword, "123457"]
        )
        XCTAssertFalse(PairingPasswordRules.rotatesPassword(passwordUsed: "123457"))
    }
}
