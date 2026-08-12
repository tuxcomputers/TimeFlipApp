import AppKit

/// Pure color/badge selection for the menu bar status title -- kept separate from
/// `MenuBarController.makeStatusTitle` so the "what color / which badges" decisions (which drive
/// the red lock badge, the low-battery red/white blink, the over-limit red, and the disconnected
/// yellow) can be unit tested without a status item, a device, or a rendered menu bar.
struct MenuBarStatusStyle: Equatable {
    /// Color of the leading activity-label text. While connected and low on battery this blinks
    /// red/white and overrides the steady color; otherwise it matches `steadyColor`.
    let categoryColor: NSColor
    /// Color of the trailing duration text and the space separators.
    let steadyColor: NSColor
    /// Whether the red lock badge is drawn to the left of the pause/play indicator.
    let showsLockBadge: Bool
    /// Whether the activity indicator is the pause glyph (vs. the play glyph).
    let showsPauseIcon: Bool
    /// Whether the pause/play indicator is tinted red because the session is over its time limit.
    let indicatorOverLimit: Bool

    static func make(
        isConnected: Bool,
        isPaused: Bool,
        overLimit: Bool,
        isLowBattery: Bool,
        blinkPhaseOn: Bool,
        isLocked: Bool
    ) -> MenuBarStatusStyle {
        // Disconnected means the app has no live read on the device any more, so both fields show a
        // flat "unknown" yellow -- not a stale over-limit/low-battery color left over from before
        // the drop, and not blinking (there's nothing to draw attention to that we can still
        // confirm). Only once actually connected do over-limit/low-battery apply, and low battery
        // always wins there regardless of paused/recording/locked/any combination.
        let steadyColor: NSColor
        let categoryColor: NSColor
        if !isConnected {
            steadyColor = .systemYellow
            categoryColor = .systemYellow
        } else {
            steadyColor = overLimit ? .systemRed : .systemGreen
            categoryColor = isLowBattery ? (blinkPhaseOn ? .systemRed : .white) : steadyColor
        }
        return MenuBarStatusStyle(
            categoryColor: categoryColor,
            steadyColor: steadyColor,
            showsLockBadge: isLocked,
            showsPauseIcon: isPaused,
            indicatorOverLimit: overLimit
        )
    }
}
