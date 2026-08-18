import Foundation

/// The four accelerometer registers behind the cube's double tap, as the cube reports them.
///
/// **Not settings this app holds, and deliberately not compared with any.** `database/011_setting.sql` seeds
/// `double_tap_settings` with what the app would like the cube to be on, and nothing has ever sent them; these are
/// what the hardware is actually running, which is a different fact and the only one that explains why a tap does or
/// does not register.
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
        guard let data, data.count >= 9, data[data.startIndex] == read else { return nil }
        let bytes = Array(data)
        for (offset, register) in registers.enumerated() where bytes[1 + offset * 2] != register { return nil }
        return DoubleTapParameters(threshold: bytes[2], limit: bytes[4], latency: bytes[6], window: bytes[8])
    }
}
