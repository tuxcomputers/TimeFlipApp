import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import FacetMac
@testable import FacetCore

/// `PortableSHA256` against answers that did not come from it.
///
/// **It is compiled on both platforms and used only on Linux**, which is the arrangement that puts it in
/// front of this suite at all: `swift test` runs on the Mac today and cannot run on Linux until the
/// swift-testing migration. So the vectors below are the only thing standing between a one-digit typo in
/// the round constants and a sign-in that fails on Linux and nowhere else.
final class PortableSHA256Tests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The deterministic filler the boundary cases below are built from. Any pattern would do; what
    /// matters is that the expected digests were produced by something else -- `hashlib` and `sha256sum`,
    /// not this implementation.
    private func filler(_ length: Int) -> Data {
        Data((0 ..< length).map { UInt8(($0 * 37 + 11) % 256) })
    }

    // MARK: - published vectors

    func testThePublishedVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(hex(PortableSHA256.hash(Data(input.utf8))), expected, "SHA-256 of \"\(input)\"")
        }
    }

    /// **The padding is the part a hand-written SHA-256 gets wrong**, and not gradually: a message with
    /// fewer than nine bytes left in its final block needs a whole extra block, so 55 and 56 take
    /// different paths and so do 63, 64 and 65. Every expected digest here came out of Python's `hashlib`.
    func testTheLengthsWherePaddingChangesShape() {
        let cases: [(Int, String)] = [
            (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (1, "e7cf46a078fed4fafd0b5e3aff144802b853f8ae459a4f0c14add3314b7cc3a6"),
            (55, "2900465fcb533e05a158fd2b3be0e5e3b03740d83060aa3580e0d98a96bf2384"),
            (56, "31454ff48ef36af2f08fd511bdc37d9d5855ac23e992e5ff5445cb6b7674a674"),
            (57, "bcc0a5d3791b985b7550e04ca660a6c63a589ba1edd2283c8e110e5b515df124"),
            (63, "5f6401b96532c36de4e65beec0409b69b1d181864c8009b7a04f43e5d56350d1"),
            (64, "94eb5de4943613fd048dc93393ab06877405faa39c11f53e9386083339833e7e"),
            (65, "fc518669b6eb4b4dd91827ecacef86689c725bd5bab888fd3b26dbb196eec954"),
            (119, "b0dc41b1a384e2f1203f0351b38fbeaafceef577ce1191d5bfc25da39f721eae"),
            (120, "5df24dd802ac26132ce608dcb5f09841eef039ee0f152acf98d26d17fe4e88e6"),
            (127, "0fe729ff19257bd6fec853acc2ea355f6b34b58e6c0f684c3e188fcdfcd9baae"),
            (128, "0aedd4856f8eba0963627336ad5144a9a7dbe12498e6066f0165fc97d8ddee4c"),
        ]
        for (length, expected) in cases {
            XCTAssertEqual(hex(PortableSHA256.hash(filler(length))), expected, "SHA-256 of \(length) bytes")
        }
    }

    /// The shape the one caller actually hashes: a 43-character base64url PKCE verifier.
    func testThePKCEShape() {
        XCTAssertEqual(
            hex(PortableSHA256.hash(Data(String(repeating: "A", count: 43).utf8))),
            "0f007385b6f9d4b7eeb2748605afe1a984a0a3bfa3f014d09e2a784ce9e5cd1a"
        )
    }

    // MARK: - against CryptoKit, where there is one

    #if canImport(CryptoKit)
    /// **The two implementations must agree**, since which one runs depends on the platform and only one
    /// of them is exercised by a sign-in anybody has actually done. This is the check that makes the
    /// Linux path's correctness a property this suite knows about rather than one it assumes.
    func testItAgreesWithCryptoKit() {
        for length in 0 ... 200 {
            let data = filler(length)
            XCTAssertEqual(
                PortableSHA256.hash(data),
                Array(SHA256.hash(data: data)),
                "the two implementations disagree at \(length) bytes"
            )
        }
    }

    /// And on a real PKCE pair, through the caller itself.
    func testTheChallengeWouldBeTheSameEitherWay() {
        let pkce = GoogleOAuthRules.pkce()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
        let ours = Data(PortableSHA256.hash(Data(pkce.verifier.utf8)))
        XCTAssertEqual(ours, expected, "the challenge for a generated verifier must not depend on the platform")
    }
    #endif
}
