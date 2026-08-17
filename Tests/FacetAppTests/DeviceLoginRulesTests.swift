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

    // MARK: - going back to a cube already paired

    func testAReconnectPresentsTheStoredPINFirst() {
        // The other way round from a pairing, and that is the only difference. A cube this app has already set a PIN on
        // is on that PIN, so trying the default first would spend a whole reconnect on every single reconnect learning
        // what the app already knew.
        XCTAssertEqual(DeviceLoginRules.reconnectCandidates(stored: "123456"), ["123456", "000000"])
    }

    func testAReconnectStillOffersTheDefaultAfterIt() {
        // A cube whose batteries have come out is back on the vendor default (measured 2026-08-11). Dropping it from the
        // list would turn a battery change into a Forget and a re-pair.
        XCTAssertEqual(DeviceLoginRules.reconnectCandidates(stored: "123456").last, "000000")
    }

    func testAReconnectWithNoStoredPINStillHasSomethingToTry() {
        XCTAssertEqual(DeviceLoginRules.reconnectCandidates(stored: nil), ["000000"])
        XCTAssertEqual(DeviceLoginRules.reconnectCandidates(stored: "12345"), ["000000"])
    }

    func testAReconnectDoesNotPresentTheSamePINTwice() {
        XCTAssertEqual(DeviceLoginRules.reconnectCandidates(stored: "000000"), ["000000"])
    }

    func testTheDefaultIsWhatTheProtocolSays() {
        // ASCII "000000", six bytes: `docs/TimeFlip2 BLE Protocol v4.3.md`, the password characteristic.
        XCTAssertEqual(Data(DeviceLoginRules.defaultPIN.utf8), Data([0x30, 0x30, 0x30, 0x30, 0x30, 0x30]))
    }

    // MARK: - what the cube is left on

    func testACubeOnTheVendorDefaultIsGivenAPINOfItsOwn() {
        // The whole point: the default is public, so a cube left on it is one anybody within a few metres can take
        // over.
        XCTAssertEqual(DeviceLoginRules.rotation(from: "000000", to: "123456"), "123456")
    }

    func testACubeAlreadyOnThePINThisBuildSetsIsLeftAlone() {
        // A same-value write costs a command round trip and a second login to confirm it, which is a long way to go
        // to change nothing.
        XCTAssertNil(DeviceLoginRules.rotation(from: "123456", to: "123456"))
    }

    func testACubeOnSomeOtherStoredPINConvergesOnTheOneThisBuildSets() {
        // Where this parts company with the archive's `rotatesPassword`, which only ever rotated a cube reached on
        // the vendor default. A cube that let the app in on a stored PIN that is not the one this build sets is a
        // cube whose PIN came from somewhere else, and leaving it there means two PINs in circulation.
        XCTAssertEqual(DeviceLoginRules.rotation(from: "654321", to: "123456"), "123456")
    }

    func testWithNoPINToSetTheCubeKeepsTheOneItAccepted() {
        // What a build with nowhere to write a PIN down does, which is every build that is not a developer build:
        // setting a PIN it cannot record would lock the cube out of every app including this one.
        XCTAssertNil(DeviceLoginRules.rotation(from: "000000", to: nil))
    }

    func testAPINTheCharacteristicCouldNotHoldIsNeverSet() {
        // Six bytes, same as presenting one. A wrong-length target would be a write the cube refuses, on the one
        // command where a half-done job is a cube nobody can open.
        XCTAssertNil(DeviceLoginRules.rotation(from: "000000", to: "12345"))
        XCTAssertNil(DeviceLoginRules.rotation(from: "000000", to: "1234567"))
        XCTAssertNil(DeviceLoginRules.rotation(from: "000000", to: ""))
    }

    func testTheCommandIsTheOneTheSpecNames() {
        // `0x30` on the command characteristic, followed by the six bytes of the new PIN: section 4 of
        // `docs/TimeFlip2 BLE Protocol v4.3.md`, and the byte the archive sent.
        XCTAssertEqual(DeviceLoginRules.setPIN, 0x30)
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
        let endings: [DeviceLoginOutcome] = [
            .loggedIn, .wrongPIN, .newPINRefused, .notATimeFlip, .unreachable, .timedOut,
        ]
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

    // MARK: - how a reset ended

    func testTheResetCommandIsTheVendorsSingleByte() {
        // One byte, no arguments. Worth pinning because it is the most destructive value in the app and a typo here
        // would be a different command entirely.
        XCTAssertEqual(DeviceLoginRules.factoryReset, 0xFF)
    }

    func testEachResetEndingSaysSomethingDifferentAndNamesTheDevice() {
        // The same reasoning as the login endings: "sent" and "the cube actually came back" are different claims, and
        // one message for both would hide the only one that means the wipe happened.
        let endings: [FactoryResetOutcome] = [.confirmed, .notConfirmed, .notSent]
        let messages = endings.map { $0.message(for: "Dibby") }

        XCTAssertEqual(Set(messages).count, endings.count, "two endings are saying the same thing")
        for message in messages {
            XCTAssertTrue(message.contains("Dibby"), "a message that does not name the device: \(message)")
        }
    }

    func testAnUnconfirmedResetSaysNothingWasChanged() {
        // The message somebody reads after the one ending that is neither success nor failure. It has to say that the
        // app changed nothing, or a wipe that may well have happened reads as one that definitely did.
        let message = FactoryResetOutcome.notConfirmed.message(for: "Dibby")

        XCTAssertTrue(message.contains("nothing has been changed"), message)
        // And what to do about it, for the same reason a refused PIN names the batteries.
        XCTAssertTrue(message.contains("Flip it to wake it"), message)
    }

    func testOnlyAConfirmedResetReadsAsDone() {
        XCTAssertTrue(FactoryResetOutcome.confirmed.message(for: "Dibby").contains("back to factory settings"))
        XCTAssertFalse(FactoryResetOutcome.notConfirmed.message(for: "Dibby").contains("was reset and"))
    }
}
