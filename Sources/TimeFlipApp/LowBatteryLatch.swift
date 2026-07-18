import Foundation

/// Hysteresis (Schmitt trigger) for the menu bar's low-battery latch -- kept separate from
/// `MenuBarController` (which owns the mutable latch state and feeds it live battery readings) so
/// the latch/recovery thresholds can be unit tested without a device.
///
/// Given the previous latched state and a new reading, returns the new latched state: it latches
/// on once the reading drops to/below `threshold`, and only clears once the reading climbs back
/// *strictly above* `threshold + recoveryMargin`. A `nil` reading (no live battery value) leaves
/// the latch unchanged. Without this margin a reading that wobbles right around the threshold (real
/// battery percentages are noisy) would flip the blink on and off on every single read instead of
/// staying latched until the battery has genuinely recovered.
enum LowBatteryLatch {
    static func updated(latched: Bool, currentLevel: UInt8?, threshold: Int, recoveryMargin: Int) -> Bool {
        guard let currentLevel else { return latched }
        if latched {
            let recoveryLevel = threshold + recoveryMargin
            if currentLevel > recoveryLevel {
                return false
            }
        } else if currentLevel <= threshold {
            return true
        }
        return latched
    }
}
