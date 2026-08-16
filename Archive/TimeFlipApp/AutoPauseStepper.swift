import Foundation

/// Step-size/timing logic for the auto-pause field's press-and-hold arrows (see
/// `TimeFlipSettingsView.autoPauseControls`) -- kept separate from the view so the exact tick
/// sequence can be unit tested without driving real gestures/timers.
///
/// While held, ticks by 1 until the value has passed the *second* multiple of 5 beyond the value
/// the hold started at (in the direction of travel), then switches to ticking by 5 -- at a slower
/// interval than the single-digit phase. E.g. starting from 4 and holding the up arrow: 5, 6, 7,
/// 8, 9, 10 (single digits, crossing the 5 and 10 gridlines), then 15, 20, 25, 30... (by 5,
/// slower).
enum AutoPauseStepper {
    static let singleStepInterval: TimeInterval = 0.1
    static let fiveStepInterval: TimeInterval = 0.3
    static let initialHoldDelay: TimeInterval = 0.4

    /// The second multiple of 5 strictly beyond `holdStartValue` in the direction of travel
    /// (`direction` is `+1` for the up arrow, `-1` for the down arrow) -- once the current value
    /// reaches this, subsequent ticks switch from step 1 to step 5. If `holdStartValue` already
    /// sits on a multiple of 5, both gridlines are counted from the next one beyond it, not from
    /// itself -- e.g. holding up from 10 counts 15 then 20.
    static func secondBoundary(from holdStartValue: Int, direction: Int) -> Int {
        if direction > 0 {
            let firstBoundary = (holdStartValue / 5 + 1) * 5
            return firstBoundary + 5
        } else {
            let firstBoundary = ((holdStartValue - 1) / 5) * 5
            return firstBoundary - 5
        }
    }

    static func isPastSecondBoundary(current: Int, holdStartValue: Int, direction: Int) -> Bool {
        let boundary = secondBoundary(from: holdStartValue, direction: direction)
        return direction > 0 ? current >= boundary : current <= boundary
    }

    /// The value after one more tick while held, given the value the hold started at (fixed for
    /// the duration of the hold, used only to compute the boundary above) and the current,
    /// possibly already-advanced, value.
    static func nextValue(current: Int, holdStartValue: Int, direction: Int) -> Int {
        let step = (isPastSecondBoundary(current: current, holdStartValue: holdStartValue, direction: direction) ? 5 : 1) * direction
        return current + step
    }

    /// How long to wait before the *next* tick, given the value just reached.
    static func tickInterval(current: Int, holdStartValue: Int, direction: Int) -> TimeInterval {
        isPastSecondBoundary(current: current, holdStartValue: holdStartValue, direction: direction)
            ? fiveStepInterval
            : singleStepInterval
    }
}
