@testable import FacetApp
import Foundation
import XCTest

/// Covers reading the cube's double-tap registers back off it.
///
/// **The sample is a real one.** `17 3A 5A 3B 14 3C 32 3D 32` is a response the archive recorded from this hardware
/// and wrote into a comment in `TimeFlipBLEDevice.factoryReset`, where it appears as the *stale* value a later read
/// picked up. That accident is what makes it worth testing against: the bytes are the cube's own, and the reason the
/// archive was looking at them is exactly the failure this parsing has to survive.
final class DoubleTapRulesTests: XCTestCase {
    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private let real = Data([0x17, 0x3A, 0x5A, 0x3B, 0x14, 0x3C, 0x32, 0x3D, 0x32])

    func testARealAnswerIsRead() {
        let parameters = DoubleTapRules.parameters(from: real)

        XCTAssertEqual(
            parameters,
            DoubleTapParameters(threshold: 0x5A, limit: 0x14, latency: 0x32, window: 0x32)
        )
        // The register names as the Device tab labels them, so a row out of `debug_log` and the fields it came from
        // can be read side by side without translating either.
        XCTAssertEqual(parameters?.described, "Threshold: 90, Limit: 20, Latency: 50, Window: 50")
    }

    func testTrailingBytesDoNotSpoilIt() {
        // The characteristic is 20 bytes and the answer is 9, so whatever is behind it is somebody else's.
        XCTAssertEqual(DoubleTapRules.parameters(from: real + data([0xFF, 0xFF])), DoubleTapRules.parameters(from: real))
    }

    func testSomebodyElsesAnswerIsRefused() {
        // Finding 2 of `docs/timeflip2-firmware-observations.md`: this characteristic frequently holds the previous
        // command's reply, so the echoed command byte is what tells an answer from a leftover. `02` is the login
        // verdict, which is what sits there at the moment this question is asked.
        XCTAssertNil(DoubleTapRules.parameters(from: data([0x02])))
        XCTAssertNil(DoubleTapRules.parameters(from: data([0x10, 0x02, 0x02, 0x00, 0x00])))
        XCTAssertNil(DoubleTapRules.parameters(from: nil))
    }

    func testAnAnswerCutShortIsRefused() {
        XCTAssertNil(DoubleTapRules.parameters(from: real.prefix(8)))
    }

    // MARK: - setting them

    func testTheCommandIsTheAnswersShapeWithTheWriteByte() throws {
        // The vendor spec defines `0x16` and `0x17` as one nine-byte layout with the command byte swapped, which is
        // what lets one parser read both. Asserted against the recorded answer rather than a hand-built expectation:
        // send back what the cube said and the bytes should differ in exactly one place.
        let command = DoubleTapRules.command(for: try XCTUnwrap(DoubleTapRules.parameters(from: real)))

        XCTAssertEqual(Array(command), [0x16, 0x3A, 0x5A, 0x3B, 0x14, 0x3C, 0x32, 0x3D, 0x32])
        XCTAssertEqual(Array(command.dropFirst()), Array(real.dropFirst()), "only the command byte differs")
    }

    func testWhatWasAskedForIsReadBackOutOfTheCommand() {
        // So a confirmation compares against the bytes that actually went out, rather than a copy worked out
        // alongside them at some other moment.
        let wanted = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50)

        XCTAssertEqual(DoubleTapRules.parameters(sentIn: DoubleTapRules.command(for: wanted)), wanted)
    }

    func testAnAnswerIsNotMistakenForACommand() {
        // The two shapes differ only in the leading byte, so each parser has to insist on its own -- otherwise a
        // `0x17` sitting in the characteristic reads as a command this app sent.
        XCTAssertNil(DoubleTapRules.parameters(sentIn: real), "an answer is not a command")
        XCTAssertNil(
            DoubleTapRules.parameters(from: DoubleTapRules.command(for: DoubleTapParameters(
                threshold: 90, limit: 20, latency: 50, window: 50
            ))),
            "a command is not an answer"
        )
    }

    func testTurningTheGestureOffClosesTheWindowAndNothingElse() {
        // **The other three are what somebody dialled in**, and turning it back on has to put those back rather than
        // a guess at them -- so only `window` moves, and only in what is sent.
        let real = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50)

        let off = DoubleTapRules.asSent(real, isEnabled: false)

        XCTAssertEqual(off, DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0))
        XCTAssertEqual(DoubleTapRules.asSent(real, isEnabled: true), real, "on sends exactly what is held")
    }

    func testTheStoredWindowIsNotTheOneThatWasZeroed() {
        // The trick is in what is *sent*. A caller that zeroed what it holds would have nothing to turn back on with,
        // and the next enable would send window 0 and appear to do nothing.
        let held = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50)

        _ = DoubleTapRules.asSent(held, isEnabled: false)

        XCTAssertEqual(held.window, 50)
    }

    func testTheEchoedRegisterAddressesAreChecked() {
        // A reply that carries the right command byte and the wrong registers is not this answer, and reading values
        // out of it by position would invent four numbers about the hardware.
        var wrong = Array(real)
        wrong[5] = 0x3F
        XCTAssertNil(DoubleTapRules.parameters(from: data(wrong)))
    }
}
