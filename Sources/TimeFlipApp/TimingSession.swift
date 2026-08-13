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

    /// Whether the clock is running on this category right now, which is the one case where picking it
    /// again means nothing.
    ///
    /// Asked by the caller rather than folded into `start`, because picking a category is more than the
    /// clock -- the face is written too -- and a `start` that quietly did nothing would still report having
    /// started something.
    func isTiming(_ categoryID: Int) -> Bool {
        isRunning && self.categoryID == categoryID
    }

    /// Starts timing `categoryID`, from zero.
    ///
    /// Any previous session ends here, banked time and all: picking a category is an instruction to time
    /// *that*, whether something else was running or nothing was.
    ///
    /// **The clock already running on this same category is the exception, and it is the caller's to make**
    /// -- see `isTiming(_:)`. Restarting it would throw away the seconds it holds for a click that asked for
    /// nothing to change, and the figure beside it is meant to be the category's total for the day (see
    /// `Archive/TimeFlipApp/AppState.replaceDailyTotals`), which nothing makes smaller.
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
