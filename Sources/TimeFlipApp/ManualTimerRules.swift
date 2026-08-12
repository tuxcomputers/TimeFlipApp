import Foundation

/// The face the app times against when there is no cube: face 13.
///
/// A real face, seeded in `database/008_face.sql` alongside the twelve physical ones, so a manual session
/// resolves its category exactly as a flip does -- through `face` -- instead of needing a second path that
/// means the same thing. One face is enough because manual mode times one thing at a time: whatever
/// category face 13 holds is what is being timed.
enum ManualFace {
    static let id = 13
}

/// What the timing control is doing, as far as the Faces tab needs to draw it.
enum TimingState: Equatable {
    /// Nothing picked, so nothing is being timed.
    case idle
    /// Timing a category right now.
    case running
    /// A category is picked and its clock is stopped.
    case paused
}

/// The play/pause control on the Faces tab.
///
/// **The icons say what is happening, not what clicking does.** Play showing means time is being
/// recorded; pause showing means it is stopped. That is the opposite of a media player, where play showing
/// is an offer to start, and it is deliberate rather than an oversight: this is a status readout standing
/// where the device graphic sits the rest of the time, and the question someone glances at it to answer is
/// "am I still on the clock?"
///
/// Carried over from the previous app, reasoning included, because the reasoning still holds.
enum ManualTimerRules {
    static func state(categoryID: Int?, isRunning: Bool) -> TimingState {
        guard categoryID != nil else { return .idle }
        return isRunning ? .running : .paused
    }

    /// The SF Symbol the control draws, and `nil` when there is nothing to draw. Idle shows nothing: an
    /// empty space is the honest picture of a session that has not started, and it is also the invitation
    /// to pick a category.
    static func symbolName(for state: TimingState) -> String? {
        switch state {
        case .idle: return nil
        case .running: return "play.fill"
        case .paused: return "pause.fill"
        }
    }

    /// Whether clicking the control does anything. Nothing is being timed when idle, so there is no clock
    /// to stop, and the click is ignored rather than starting one -- starting is what picking a category is
    /// for, and a click on a blank space names no category to start.
    ///
    /// The dropdown's Pause item asks the same question and gets the same answer, deliberately. The previous
    /// app had these as two separate expressions and they came to disagree: the status item's right half was
    /// taught about manual mode and the menu item beside it was not, leaving a dead Pause above a live one,
    /// and nothing failed.
    static func isClickable(_ state: TimingState) -> Bool {
        state != .idle
    }

    /// What the dropdown's Pause item is called.
    ///
    /// **A menu item says what clicking does**, which is the opposite of the glyph beside it -- and both are
    /// deliberate. A glyph is a status readout, so play showing means recording; a menu item is an
    /// instruction, so it reads "Pause" while time is being recorded.
    ///
    /// With nothing being timed it reads "Pause" rather than "Resume", carried over from the previous app
    /// with its reasoning: the item is disabled either way, and a dead item claiming there is something to
    /// resume is worse than a dead item claiming there is something to pause.
    static func pauseMenuTitle(for state: TimingState) -> String {
        state == .paused ? "Resume" : "Pause"
    }
}
