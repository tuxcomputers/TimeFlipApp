@testable import FacetApp
import Foundation
import XCTest

/// Which PINs are presented, and what the cube's answer means.
///
/// **Every one of these runs with no radio**, which is the whole reason the decisions live away from `BluetoothRadio`
/// and `DeviceLogin`: a `CBPeripheral` cannot be built outside CoreBluetooth, so a rule that read one directly could
/// only ever be checked with a cube on the desk. The archive's equivalents were three expressions inside a closure in
/// a delegate, unreachable by any test, which is how they came to guess four passwords and rotate the PIN of a cube
/// that had done nothing to deserve it.
final class DeviceLoginRulesTests: XCTestCase {

    // MARK: - which PINs

    func testTheVendorDefaultIsTriedFirst() {
        // New to this app, or power-cycled: taking the batteries out puts a cube back on the vendor default, so this
        // is the likeliest answer even for one this app has met before.
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "123456").first, "000000")
    }

    func testTheStoredPINIsTriedSecond() {
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "123456"), ["000000", "123456"])
    }

    func testThereIsNoThirdGuess() {
        // A cube on some other PIN is one neither this app nor its user can name, and finding it by search would be
        // a lockout dressed up as a feature.
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "123456").count, 2)
    }

    func testWithNothingStoredThereIsOnlyTheDefault() {
        XCTAssertEqual(DeviceLoginRules.candidates(stored: nil), ["000000"])
    }

    func testAStoredPINThatIsTheDefaultIsPresentedOnce() {
        // The second attempt costs a whole reconnect and a settle, which is a long way to go to learn nothing.
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "000000"), ["000000"])
    }

    func testAPINTheCharacteristicCouldNotHoldIsNeverPresented() {
        // Six bytes wide, fixed by the protocol. A wrong-length PIN is a bug on this side, and sending it would come
        // back as a refusal that looks like the cube's fault.
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "12345"), ["000000"])
        XCTAssertEqual(DeviceLoginRules.candidates(stored: "1234567"), ["000000"])
        XCTAssertEqual(DeviceLoginRules.candidates(stored: ""), ["000000"])
    }

    func testTheDefaultIsWhatTheProtocolSays() {
        // ASCII "000000", six bytes: `docs/TimeFlip2 BLE Protocol v4.3.md`, the password characteristic.
        XCTAssertEqual(Data(DeviceLoginRules.defaultPIN.utf8), Data([0x30, 0x30, 0x30, 0x30, 0x30, 0x30]))
    }

    // MARK: - what came back

    func testTwoMeansAccepted() {
        // **The opposite of the spec**, which says 0x01 is correct and 0x02 is wrong. Real hardware does the reverse
        // and a measurement beats the spec (root `CLAUDE.md`). Backwards, every correct PIN would be refused and
        // every wrong one accepted, so this is the single most load-bearing byte in the feature.
        XCTAssertEqual(DeviceLoginRules.verdict(for: Data([0x02])), .accepted)
    }

    func testOneMeansRejected() {
        XCTAssertEqual(DeviceLoginRules.verdict(for: Data([0x01])), .rejected)
    }

    func testOnlyTheFirstByteDecidesIt() {
        // The characteristic carries a command number and an error value in the general case; the login's answer is
        // in the first byte and what follows it is not this question's.
        XCTAssertEqual(DeviceLoginRules.verdict(for: Data([0x02, 0x00, 0x1F])), .accepted)
    }

    func testNoAnswerIsNotARefusal() {
        // A cube that said nothing has not said no. Treating silence as a wrong PIN would spend the next candidate
        // on a question that was never asked.
        XCTAssertEqual(DeviceLoginRules.verdict(for: nil), .unreadable)
        XCTAssertEqual(DeviceLoginRules.verdict(for: Data()), .unreadable)
    }

    func testSomebodyElsesAnswerIsNotARefusalEither() {
        // Finding 2 in `docs/timeflip2-firmware-observations.md`: the command result characteristic is often not
        // updated at all and holds whatever the last command left in it. A 0x17 double-tap response sitting there is
        // a stale answer to another question, not a verdict on this one.
        XCTAssertEqual(DeviceLoginRules.verdict(for: Data([0x17, 0x3A, 0x5A])), .unreadable)
    }

    // MARK: - what it says

    func testEachEndingSaysSomethingDifferent() {
        // A wrong PIN, a device that is not a TimeFlip and a cube that went away are three different problems with
        // three different things to do about them, and one message for all three sends everybody to the wrong one.
        let endings: [DeviceLoginOutcome] = [.loggedIn, .wrongPIN, .notATimeFlip, .unreachable, .timedOut]
        let messages = endings.map { $0.message(for: "Dibby") }

        XCTAssertEqual(Set(messages).count, endings.count, "two endings are saying the same thing")
        for message in messages {
            XCTAssertTrue(message.contains("Dibby"), "a message that does not name the device: \(message)")
        }
    }

    func testARefusalSaysWhatToDoAboutIt() {
        // The one ending with a way out: the batteries coming out put the cube back on the vendor default, which is
        // a candidate. Without that the message is a dead end.
        XCTAssertTrue(DeviceLoginOutcome.wrongPIN.message(for: "Dibby").contains("batteries"))
    }
}
