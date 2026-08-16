import Foundation

/// What is drawn on the centre face of the device graphic.
enum DeviceFaceCentre: Equatable {
    /// Nothing. The face is drawn bare.
    case empty
    /// The assigned category's icon, by its name in the app's asset catalogue.
    case categoryIcon(String)
    /// An SF Symbol, which is what manual mode's play/pause control is drawn from.
    case symbol(String)
}

/// What manual mode's timer is doing, as far as the Faces tab needs to draw it.
enum ManualTimerState: Equatable {
    /// Manual mode is on but nothing has been picked yet, so nothing is being timed and the centre
    /// of the device is drawn empty.
    case idle
    /// Timing a category right now.
    case running
    /// A category is picked and its timer is stopped.
    case paused
}

/// The play/pause control on the Faces tab, in manual mode.
///
/// **The icons say what is happening, not what clicking does.** Play showing means time is being
/// recorded; pause showing means it is stopped. That is the opposite of a media player, where play
/// showing is an offer to start, and it is a deliberate choice rather than an oversight: this is a
/// status readout standing where the device graphic and its category icon sit the rest of the time,
/// and the question someone glances at it to answer is "am I still on the clock?"
enum ManualTimerRules {

    /// Manual mode's face is the only one this control belongs to. Before the first category is
    /// picked the app has no face at all (`unassignedFaceID`), which is what `idle` reads.
    static func state(currentFaceID: UInt8, isPaused: Bool) -> ManualTimerState {
        guard currentFaceID == TimeFlipConstants.manualFaceID else { return .idle }
        return isPaused ? .paused : .running
    }

    /// What the centre of the device graphic shows. Idle draws nothing: an empty face is the honest
    /// picture of a session that has not started, and it is also the invitation to pick a category.
    static func centre(for state: ManualTimerState) -> DeviceFaceCentre {
        switch state {
        case .idle: return .empty
        case .running: return .symbol("play.fill")
        case .paused: return .symbol("pause.fill")
        }
    }

    /// Whether clicking the centre does anything. Nothing is being timed when idle, so there is no
    /// timer to stop and the click is ignored rather than starting one -- starting is what picking a
    /// category is for, and a click on a blank face names no category to start.
    static func isCentreClickable(_ state: ManualTimerState) -> Bool {
        state != .idle
    }
}
