import Foundation

/// The step size and the cadence of a held arrow, kept apart from the control so the exact tick sequence can be
/// tested without driving real gestures or timers.
///
/// While held, ticks by 1 until the value has passed the **second** multiple of 5 beyond the value the hold started
/// at, in the direction of travel, then switches to ticking by 5 at a slower interval. Starting from 4 and holding
/// up: 5, 6, 7, 8, 9, 10, then 15, 20, 25, 30.
///
/// **Copied from the previous app (`Archive/TimeFlipApp/AutoPauseStepper`) as it stands**, because it is right and
/// rewriting it would land in the same place. Only the name changed: it began on the auto-pause field and ended up
/// shared by every stepper in that window, so a name pointing at one field was already wrong there.
///
/// It earns its keep on a wide range. A daily limit runs 0 to 1440, and stepping by 1 the whole way makes crossing
/// it a chore, which is the difference between a control somebody uses and one they give up on.
enum StepperHoldRules {
    static let singleStepInterval: TimeInterval = 0.1
    static let fiveStepInterval: TimeInterval = 0.3
    /// How long an arrow is held before it starts repeating, so a plain click is one step and nothing more.
    static let initialHoldDelay: TimeInterval = 0.4

    /// The second multiple of 5 strictly beyond `holdStartValue` in the direction of travel (`direction` is `+1` for
    /// the up arrow, `-1` for the down arrow). Once the value reaches this, ticks switch from 1 to 5.
    ///
    /// A hold that starts exactly on a multiple of 5 counts both gridlines from the next one beyond it rather than
    /// from itself, so holding up from 10 counts 15 and then 20.
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

    /// The value after one more tick while held, given the value the hold started at (fixed for the duration of the
    /// hold, and used only to work out the boundary) and the current, possibly already advanced, value.
    static func nextValue(current: Int, holdStartValue: Int, direction: Int) -> Int {
        let step = (isPastSecondBoundary(current: current, holdStartValue: holdStartValue, direction: direction) ? 5 : 1)
            * direction
        return current + step
    }

    /// How long to wait before the next tick, given the value just reached.
    static func tickInterval(current: Int, holdStartValue: Int, direction: Int) -> TimeInterval {
        isPastSecondBoundary(current: current, holdStartValue: holdStartValue, direction: direction)
            ? fiveStepInterval
            : singleStepInterval
    }
}
