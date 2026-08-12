import Foundation

/// What is being timed, and since when. **The only place in the app that knows.**
///
/// That is the point of it existing rather than a pair of flags on whatever happens to be drawing.
/// The previous app kept "is it paused" in more than one place and the copies could disagree; the
/// worst of it was a pause being sent to the device three times over for one limit, because each
/// thing that could ask "have we paused yet?" had its own answer. Anything wanting to know, or to
/// change it, comes through here.
///
/// In memory only, like the mode it belongs to. It describes what this launch is doing; which
/// category the manual face holds is in the database (`face` 13), and is read from there.
@MainActor
final class TimingSession {
    /// The category being timed, or `nil` when nothing has been started.
    private(set) var categoryID: Int?

    /// Whether time is being recorded right now.
    private(set) var isRunning = false

    /// Time already banked from earlier runs of this session, excluding the run in progress.
    private var banked: TimeInterval = 0

    /// When the run in progress started, and `nil` while stopped.
    private var runningSince: Date?

    /// Injected so elapsed time can be tested without waiting for it.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Starts timing `categoryID`, from zero.
    ///
    /// Any previous session ends here, banked time and all. Picking a category is an instruction to time
    /// *that*, whether something else was running, the same thing was running, or nothing was -- so it is
    /// one path rather than three, and there is no state in which picking a category does nothing.
    func start(categoryID: Int) {
        self.categoryID = categoryID
        banked = 0
        runningSince = now()
        isRunning = true
    }

    /// Stops the clock, or starts it again. Does nothing when there is no session to stop: a toggle with
    /// nothing picked would be a session against no category.
    func togglePause() {
        guard categoryID != nil else { return }
        if isRunning {
            banked = elapsed
            runningSince = nil
            isRunning = false
        } else {
            runningSince = now()
            isRunning = true
        }
    }

    /// Time recorded for this session so far: what is banked, plus the run in progress.
    var elapsed: TimeInterval {
        guard let runningSince else { return banked }
        return banked + now().timeIntervalSince(runningSince)
    }
}
