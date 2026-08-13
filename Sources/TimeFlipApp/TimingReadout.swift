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
/// faces is in use comes from `device_event`, the category on it from `face`, and the figure from `time_entry` (see
/// `DayTotal`). Nothing is held between calls, which is what makes this right after a category is renamed, after a
/// relaunch mid-session, and after somebody edits a row by hand.
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
    }

    private let session: TimingSession
    private let categories: CategoryStore
    private let faces: FaceStore
    private let events: DeviceEventRecorder
    private let dayTotal: DayTotal

    init(
        session: TimingSession,
        categories: CategoryStore,
        faces: FaceStore,
        events: DeviceEventRecorder,
        dayTotal: DayTotal
    ) {
        self.session = session
        self.categories = categories
        self.faces = faces
        self.events = events
        self.dayTotal = dayTotal
    }

    /// The session as it stands at `now`.
    func read(at now: Date = Date()) -> Reading {
        let category = faces.categoryID(forFace: events.currentManualFace()).flatMap { categories.category(id: $0) }
        return Reading(
            category: category,
            // The face says whether there is anything to name and the session says whether it is moving. A face
            // holding no category is idle whatever the clock claims: there would be nothing to draw beside it.
            state: ManualTimerRules.state(
                categoryID: category == nil ? nil : session.categoryID,
                isRunning: session.isRunning
            ),
            seconds: category.map { dayTotal.seconds(categoryID: $0.id, at: now) } ?? 0
        )
    }
}
