import Foundation

/// SHA-256, FIPS 180-4, in Swift with nothing under it.
///
/// **Why this exists rather than a dependency.** One call needs it: the PKCE challenge in
/// `GoogleOAuthRules.pkce()`, which is `SHA256(verifier)` base64url-encoded. On Darwin that is CryptoKit
/// and stays CryptoKit -- this is what the same line uses where there is no CryptoKit to call. The
/// alternative was `swift-crypto`, which would be the first package dependency this project has ever
/// had; `Package.swift` says out loud that it has none, and the archived app's one dependency was dropped
/// precisely because this app owns the sign-in flow itself. Sixty lines with published test vectors was
/// judged the smaller price than a fetch at build time.
///
/// **Compiled on both platforms even though only Linux calls it**, deliberately: that is what puts it in
/// front of the Mac's test run, which is the only suite that can run today. `PortableSHA256Tests` checks
/// it against published vectors and, on Darwin, against CryptoKit's own answer for the same input.
///
/// **What it is not for.** A hash of a public, freshly generated random string, where a wrong answer is
/// rejected immediately and loudly by Google. It is not a password hash, it is not keyed, and nothing
/// here is constant-time. Anything needing those properties should bring a real library rather than this.
///
/// Named to sit beside CryptoKit's `SHA256` without shadowing it: both are visible in this module on
/// Darwin, and two types differing only in capitalisation would be a trap for whoever read the call site.
package enum PortableSHA256 {
    /// The 32-byte digest of `data`.
    package static func hash(_ data: Data) -> [UInt8] {
        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]

        for block in blocks(of: data) {
            compress(block, into: &state)
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    /// The message split into 64-byte blocks, padded as the standard requires: a `0x80` byte, then zeros
    /// until 56 bytes into the last block, then the original length in **bits** as a big-endian `UInt64`.
    ///
    /// **The padding is where a hand-written SHA-256 goes wrong**, because a message whose length leaves
    /// fewer than 9 bytes of room needs a whole extra block rather than a shorter one. Lengths 55, 56, 63,
    /// 64 and 65 are the cases that tell the two apart, and the tests walk every length from 0 to 200.
    private static func blocks(of data: Data) -> [[UInt8]] {
        var padded = [UInt8](data)
        let bitLength = UInt64(padded.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        return stride(from: 0, to: padded.count, by: 64).map { Array(padded[$0 ..< $0 + 64]) }
    }

    private static func compress(_ block: [UInt8], into state: inout [UInt32]) {
        var w = [UInt32](repeating: 0, count: 64)
        for index in 0 ..< 16 {
            let byte = index * 4
            w[index] = UInt32(block[byte]) << 24
                | UInt32(block[byte + 1]) << 16
                | UInt32(block[byte + 2]) << 8
                | UInt32(block[byte + 3])
        }
        for index in 16 ..< 64 {
            let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
            let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
            w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0 ..< 64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choose &+ roundConstants[index] &+ w[index]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority

            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private static func rotate(_ value: UInt32, _ places: UInt32) -> UInt32 {
        (value >> places) | (value << (32 - places))
    }

    /// The first 32 bits of the fractional parts of the cube roots of the first 64 primes, per the
    /// standard. Wrong by one digit and every vector fails, which is what the tests are for.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
