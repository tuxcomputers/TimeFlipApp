import Foundation

/// The four accelerometer registers behind the cube's double tap.
///
/// **Two facts wear this one type, and which is which depends on where it came from.** Read off the cube (`0x17`) it
/// is what the hardware is actually running. Built from `double_tap_settings` it is what the app would like the
/// hardware to be running. They have no reason to agree until something sends `0x16`, and `DeviceLogin` deliberately
/// compares them nowhere.
struct DoubleTapParameters: Equatable {
    /// `CLICK_THS`. How hard a knock has to be. Lower is more sensitive, which is what makes a cube fire on a bang
    /// through the desk while ignoring a finger.
    let threshold: UInt8
    /// `TIME_LIMIT`. How long a single knock may last and still count as one.
    let limit: UInt8
    /// `TIME_LATENCY`. The dead time after the first knock, before the second is looked for.
    let latency: UInt8
    /// `TIME_WINDOW`. How long the second knock has to arrive in. Zero is the archive's kill switch for the whole
    /// gesture (`Archive/Tests/Methods.md` Method 22), which is worth knowing because no command disables it.
    let window: UInt8

    /// The same registers with the second knock given no time to arrive in, which is the whole of how this app turns
    /// the gesture off.
    ///
    /// **The other three are left exactly as they are, deliberately.** They are what somebody dialled in, and turning
    /// the gesture back on has to put back what was there rather than a guess at it -- so what is stored keeps the
    /// real `window` and only what is *sent* is zeroed. Nothing reads this back out of the cube to recover it either:
    /// a disabled cube reports `window 0` because that is genuinely what its register holds.
    var withTheGestureOff: DoubleTapParameters {
        DoubleTapParameters(threshold: threshold, limit: limit, latency: latency, window: 0)
    }

    var described: String {
        "threshold \(threshold), limit \(limit), latency \(latency), window \(window)"
    }
}

/// Reading the cube's double-tap registers: the command that asks, and what the answer has to look like.
///
/// A rule with no radio in it, like `DeviceLoginRules`: bytes go in, a value or `nil` comes out.
enum DoubleTapRules {
    /// `0x17`, which the vendor spec answers in the command result characteristic.
    static let read: UInt8 = 0x17

    /// `0x16`, which sets the same four registers `0x17` reports.
    static let write: UInt8 = 0x16

    /// The register addresses the cube echoes back, in the order it sends them: `CLICK_THS`, `LIMIT`, `LATENCY`,
    /// `WINDOW`. Spec command `0x16` names them, and a real answer captured by the archive has them exactly here:
    /// `17 3A 5A 3B 14 3C 32 3D 32`.
    static let registers: [UInt8] = [0x3A, 0x3B, 0x3C, 0x3D]

    /// What the cube said, or `nil` if what it said was not an answer to this question.
    ///
    /// **Every byte of the shape is checked, not just the length**, and finding 2 in
    /// `docs/timeflip2-firmware-observations.md` is why: a good number of commands never update this characteristic,
    /// so what is read may be the previous command's reply sitting there. The echoed command byte and the four
    /// register addresses are what tell an answer from a leftover -- and the archive has a recorded case of exactly
    /// that, a stale `17 3A 5A ...` being read back after a factory reset that answered nothing.
    ///
    /// The values sit at the odd indices, each one following the address it belongs to.
    static func parameters(from data: Data?) -> DoubleTapParameters? {
        parameters(from: data, leadingWith: read)
    }

    /// What a `0x16` was asked to write, read back out of the command's own bytes.
    ///
    /// **So the confirmation compares against what actually went out**, rather than against a copy passed alongside
    /// it that could have been worked out at a different moment. There is one place that knows this layout and it is
    /// `command(for:)`, directly above.
    static func parameters(sentIn command: Data) -> DoubleTapParameters? {
        parameters(from: command, leadingWith: write)
    }

    /// The bytes that set all four registers: `0x16 0x3A th 0x3B li 0x3C la 0x3D wd`.
    ///
    /// **The same nine-byte shape the read answers with**, the vendor spec defining `0x16` and `0x17` as one layout
    /// with the command byte swapped -- which is what lets the confirmation below parse both with one parser.
    static func command(for parameters: DoubleTapParameters) -> Data {
        Data([
            write,
            registers[0], parameters.threshold,
            registers[1], parameters.limit,
            registers[2], parameters.latency,
            registers[3], parameters.window,
        ])
    }

    /// What is actually sent, which is not always what is stored.
    ///
    /// **Turning the gesture off is faked, because the hardware has no switch for it.** The vendor spec defines no
    /// command that disables double tap, and the archive measured the same on a real cube: "no BLE command disables
    /// it. The only lever is accelerometer sensitivity" (`Archive/Tests/Methods.md` Method 22). So off is `window`
    /// zero, and it is suppression rather than an off switch -- a knock hard enough is still a knock.
    ///
    /// The archive's `effectiveDoubleTapParameters`, massaged: same trick and same reason, and a free function of two
    /// arguments rather than a property reading two pieces of published state.
    static func asSent(_ parameters: DoubleTapParameters, isEnabled: Bool) -> DoubleTapParameters {
        isEnabled ? parameters : parameters.withTheGestureOff
    }

    private static func parameters(from data: Data?, leadingWith command: UInt8) -> DoubleTapParameters? {
        guard let data, data.count >= 9, data[data.startIndex] == command else { return nil }
        let bytes = Array(data)
        for (offset, register) in registers.enumerated() where bytes[1 + offset * 2] != register { return nil }
        return DoubleTapParameters(threshold: bytes[2], limit: bytes[4], latency: bytes[6], window: bytes[8])
    }
}
