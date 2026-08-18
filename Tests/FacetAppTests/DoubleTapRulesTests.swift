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
        XCTAssertEqual(parameters?.described, "threshold 90, limit 20, latency 50, window 50")
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

    func testTheEchoedRegisterAddressesAreChecked() {
        // A reply that carries the right command byte and the wrong registers is not this answer, and reading values
        // out of it by position would invent four numbers about the hardware.
        var wrong = Array(real)
        wrong[5] = 0x3F
        XCTAssertNil(DoubleTapRules.parameters(from: data(wrong)))
    }
}
