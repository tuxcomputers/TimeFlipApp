import Foundation

/// What a battery reading means: the figure to show for it, and whether it is low enough to warn about.
///
/// A rule with no radio and no database in it, as `DeviceInfoRules` and `DeviceLoginRules` are: readings go in,
/// a figure and a verdict come out. Both halves exist because **the cube's reported level is noisy in a way that
/// is measured rather than assumed**, and a level drawn or judged straight off the wire would flicker all day.
///
/// The measurement, from the archived app's own `debug_log` on real hardware: 2,847 readings across eleven days of
/// traffic (2026-08-02 to 2026-08-13), while the charge itself went from 100% to 98% over the fortnight its own rows
/// cover. On 2026-08-13 alone the cube reported 2,168 values, every single one of them either 98 or 99, flipping
/// between the two roughly every two seconds -- one value every 11 seconds of connected time. It notifies on change
/// and only on change, so a level that cannot make its mind up between two adjacent percentages produces a
/// notification every time it wavers.
enum BatteryRules {
    /// What the cube is allowed to say, from `docs/TimeFlip2 BLE Protocol v4.3.md`: a percentage, 1 to 100.
    ///
    /// Anything else is discarded rather than shown. A byte outside this is not a battery level, and the one thing
    /// worse than not knowing the charge is drawing a number nobody can act on.
    static let reportedRange = 1...100

    /// How far a reading has to climb above the figure on show before the higher one is adopted.
    ///
    /// **Two, because one is what the flap is made of.** The dither above is always across a single percent, so
    /// requiring the reading to reach the figure plus two is what tells "the level actually went up" from "the same
    /// level, reported by a cube that keeps changing its mind". A cell that has genuinely recovered -- new batteries,
    /// which is the only way this hardware's level rises at all -- clears that in one reading and by a mile.
    static let riseToAdopt = 2

    /// How far above the warning level the charge has to climb before the warning is taken back.
    ///
    /// **The archive's five, copied**, and its reasoning survives inspection: without a margin a reading wobbling
    /// across the threshold would arm and disarm the warning on every notification, which on the numbers above is
    /// twice a second. See `latched`.
    static let recoveryMargin = 5

    /// The figure to show, given what is already being shown and a reading that has just arrived.
    ///
    /// **The lower of the two adjacent values wins, and it keeps winning.** Shown 65 with the cube alternating
    /// 65, 66, 65, 66 stays 65 throughout, because none of those readings reaches 67. Feed it 67 and it becomes 67:
    /// that is the charge having actually moved rather than the same charge being described twice.
    ///
    /// **A fall is taken at once**, with no margin at all, and the asymmetry is the point. A battery running down is
    /// what this figure exists to report, so the pessimistic reading is never the one held back; only a *rise* has to
    /// prove itself, because on this hardware a rise is either the flap or somebody changing the cells.
    ///
    /// - Parameters:
    ///   - shown: the figure currently on show, or `nil` if none has arrived yet on this connection.
    ///   - reading: the percentage the cube has just reported.
    /// - Returns: the figure to show now. `shown` unchanged when the reading is absorbed or is not a level at all.
    static func shown(_ shown: Int?, reading: Int) -> Int? {
        guard reportedRange.contains(reading) else { return shown }
        // The first reading of a connection is simply the answer: there is nothing yet for it to flap against.
        guard let shown else { return reading }
        if reading < shown { return reading }
        return reading >= shown + riseToAdopt ? reading : shown
    }

    /// Whether the low-battery warning is on, given whether it was on and what the level is now.
    ///
    /// Hysteresis, a Schmitt trigger: it arms once the level is at or below `threshold`, and only disarms once the
    /// level climbs **strictly above** `threshold + recoveryMargin`. **Massaged from the archive's `LowBatteryLatch`**
    /// -- the same two comparisons and the same margin, now reading the threshold from the `setting` table at the
    /// moment it is asked rather than from a copy held beside the menu bar.
    ///
    /// **A missing level leaves the warning exactly as it was.** No reading means no cube to hear from, which is not
    /// evidence that the cells recovered: a warning that cleared itself when the link dropped would be taken back at
    /// the one moment nothing can confirm it. What *does* stop while there is no reading is the blinking, which is
    /// `LowBatteryWatch`'s doing and a separate question from whether the warning stands.
    ///
    /// - Parameters:
    ///   - latched: whether the warning is currently on.
    ///   - level: the figure on show, from `shown(_:reading:)`, or `nil` while there is no live reading.
    ///   - threshold: `low_battery_level`, read from the table at this moment.
    static func latched(_ latched: Bool, level: Int?, threshold: Int) -> Bool {
        guard let level else { return latched }
        guard latched else { return level <= threshold }
        return level <= threshold + recoveryMargin
    }
}
