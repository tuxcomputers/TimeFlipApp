import Foundation

/// What is being timed right now: which category, whether its clock is running, and how much time it has today.
///
/// **One answer, for everything that draws it.** The Faces tab and the status item show the same session, and the
/// previous app let each work it out for itself: the menu bar resolved the activity from the face and totalled the
/// day, then handed the tab the duration *text* it had already formatted
/// (`Archive/TimeFlipApp/AppState.setCurrentDurationText`), so the tab's figure was whatever the menu bar last
/// happened to say. Reading it in one place is what stops the two disagreeing about what is running, and neither
/// of them keeps a copy.
///
/// **Every field is a read taken when the answer is wanted**, per the first rule in `CLAUDE.md`. Which of the app's
/// faces is in use comes from `device_event`, the category on it from `face`, whether the clock is running from
/// whether that table holds an open segment, and the figure from `time_entry` (see `DayTotal`). Nothing is held
/// between calls, which is what makes this right after a category is renamed, after a relaunch mid-session, and
/// after somebody edits a row by hand.
///
/// **A relaunch is the case that made the running flag a read.** It used to come from an in-memory session that a
/// new launch started empty, so an app reopened after lunch drew nothing at all until something was clicked, even
/// though the table knew exactly which category had been left and how much time it had. There is no restoring step
/// here and nothing to restore: an open row means running, no open row means paused, and a launch inherits the
/// answer by asking.
@MainActor
final class TimingReadout {
    /// What a view needs in order to draw the session, and nothing else.
    struct Reading: Equatable {
        /// The category on the face being timed, or `nil` when that face holds none.
        let category: CategoryRecord?

        /// Whether the clock is running, stopped, or there is nothing to run at all.
        let state: TimingState

        /// The category's total for the day so far, in seconds. Zero when there is no category to total.
        let seconds: TimeInterval

        /// Nothing being timed, which is what a view built without a database draws.
        static let idle = Reading(category: nil, state: .idle, seconds: 0)

        /// Whether the clock is running on this category right now, which is the one case where picking it again
        /// means nothing: the clock is already where it should be, and starting it over would rotate the face and
        /// close a segment for a click that asked for no change.
        func isTiming(_ categoryID: Int) -> Bool {
            state == .running && category?.id == categoryID
        }
    }

    private let categories: CategoryStore
    private let faces: FaceStore
    private let events: DeviceEventRecorder
    private let dayTotal: DayTotal

    init(categories: CategoryStore, faces: FaceStore, events: DeviceEventRecorder, dayTotal: DayTotal) {
        self.categories = categories
        self.faces = faces
        self.events = events
        self.dayTotal = dayTotal
    }

    /// The session as it stands at `now`.
    func read(at now: Date = Date()) -> Reading {
        let face = events.currentManualFace()
        let category = faces.categoryID(forFace: face).flatMap { categories.category(id: $0) }
        return Reading(
            category: category,
            // The face says whether there is anything to name and the open row says whether it is moving. A face
            // holding no category is idle whatever the table says about segments: there would be nothing to draw
            // beside the clock.
            state: ManualTimerRules.state(categoryID: category?.id, isRunning: isRunning(on: face)),
            seconds: category.map { dayTotal.seconds(categoryID: $0.id, at: now) } ?? 0
        )
    }

    /// Whether time is being recorded on `face` at this moment, which is a question `device_event` answers on its
    /// own: **an open segment is what running means.**
    ///
    /// Nothing else is consulted, and there is no flag beside it. That is the manual-mode scar in `CLAUDE.md`
    /// applied to the clock: two answers to one question cannot fail, they can only disagree, and pausing already
    /// closes the segment -- so a second flag saying "paused" would be restating what the absence of a row says.
    ///
    /// The face is checked as well as the row's existence. A segment open on some other face is not this face's
    /// session, which is what keeps a cube's own timing (faces 1 to 12) from reading as the app's.
    private func isRunning(on face: Int) -> Bool {
        guard let open = events.openSegment() else { return false }
        return open.face == face && !open.isPaused
    }
}
