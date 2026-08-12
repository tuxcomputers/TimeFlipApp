import Foundation

/// What the app must do to the cube's pause state, having compared the category on show against its
/// `daily_limit`.
enum DailyLimitAction: Equatable {
    /// The pause state already matches the limit. Send nothing.
    case none
    /// The category on show has spent its limit and the cube is still counting: pause it
    /// (`0x06 0x01`).
    case pause
    /// The cube is paused, this app is what paused it, and the category on show has budget again --
    /// the user flipped off the spent face. Resume it (`0x06 0x02`).
    case resume
}

/// A **hard** daily limit: when the category on show reaches its `daily_limit`, the app pauses the
/// cube and then refuses to send the unpause for as long as that category is the one on show.
///
/// Refusing to send is the whole enforcement, and it is worth being clear that it is the app's
/// refusal rather than the cube's: nothing in the protocol asks the device to hold a pause against
/// its own user. `0x06 0x02` would be honoured whenever it arrived, so the limit is only as hard as
/// the set of paths that can send it -- the dropdown's Resume item, the status item's right half
/// (both `MenuBarController.togglePause`), and this type's own `.resume`. A **double tap on the cube
/// pauses and unpauses it in firmware**, with no app involvement at all (see the Double tap
/// characteristic in `docs/TimeFlip2 BLE Protocol v4.3.md`), so that one cannot be refused, only
/// answered: it arrives as a history frame reporting the cube running again, `evaluate` sees a spent
/// category unpaused, and the pause goes straight back out.
///
/// Flipping to a face whose own category has budget leaves the cube running, because pause is a
/// property of the **cube** and a limit is a property of a **category**: leaving it paused would
/// spend one category's budget and stop the day's tracking. Flipping back pauses it again.
///
/// **The firmware is what lifts it, not this type** (measured 2026-08-12: a flip always resumes the
/// cube, the one exception being a locked cube, which refuses the flip and reports no event). So the
/// frame after a flip reports the cube already running and `.resume` is never needed for it. What
/// `.resume` is actually for is a pause that *survives* -- the limit raised or cleared on the
/// Categories tab while the cube sits paused on that same spent face, where nothing physical has
/// happened to lift it. Only a pause this type asked for is lifted (`isPausedByLimit`) -- a pause the
/// user asked for is theirs, and auto-resuming it would make the Pause item a control that undoes
/// itself. The claim is therefore dropped as soon as a frame reports the cube running with budget in
/// hand, however it came to be running; holding it past that turned the *user's* own pause into one
/// this type believed it had placed.
///
/// ## Why the latch, and not just today's total against the limit
///
/// The obvious form of this is a comparison with no memory: reached = total >= limit, evaluated
/// fresh each time. It breaks, and it breaks in the one direction that matters. The figure
/// `MenuBarController.currentDuration` reports while paused is the **recorded** total (`time_entry`
/// rows), because the live segment stops counting -- and the segment that just ran the category out
/// of budget is not recorded yet. It becomes a `time_entry` only once the pause has closed it and
/// the history fetch behind `onPauseToggle` has ingested it. So in the seconds between "pause sent"
/// and "segment ingested", a memoryless comparison reads *under* the limit, sees a cube paused by
/// the limit with budget to spare, and issues `.resume` -- undoing the pause it just asked for, on
/// the strength of a total it knows is incomplete.
///
/// So a category that has reached its limit stays reached for the day. The latch remembers the
/// limit that was in force when it caught, which is what lets a **deliberate** change clear it: edit
/// the limit on the Categories tab (raise it, lower it, or clear it to `0` for no limit) and the
/// stored value no longer matches, so the category is measured against the new number immediately.
/// That is the one thing a stale total cannot imitate, since nothing about ingesting a segment
/// changes what the limit says.
struct DailyLimitEnforcement {
    /// Whether `totalSeconds` has spent a `limitMinutes` budget. `limitMinutes <= 0` is *no limit*
    /// (`database/007_category.sql`), so it is never reached.
    ///
    /// `>=` rather than `>`: a 60-minute limit is reached at 60:00, not at 60:01. This is the same
    /// comparison the menu bar's red duration is drawn from, deliberately -- the colour and the pause
    /// are two faces of one fact, and a limit that turned the text red a second before it stopped the
    /// cube would be two rules with one name.
    static func isReached(totalSeconds: TimeInterval, limitMinutes: Int) -> Bool {
        guard limitMinutes > 0 else { return false }
        return totalSeconds >= Double(limitMinutes) * TimeConstants.secondsPerMinute
    }

    /// How long until `totalSeconds` reaches the limit, for arming a one-shot timer on the exact
    /// second rather than waiting for the next display tick. `nil` when there is no limit or it is
    /// already reached, i.e. when there is nothing to wait for.
    ///
    /// The menu bar's own tick is not good enough to enforce on: it runs once a **minute** when the
    /// seconds preference is off (`MenuBarController.startRefreshTimer`), which would let a hard
    /// limit overrun by up to 59 seconds, and would make the overrun depend on a display preference.
    static func secondsUntilReached(totalSeconds: TimeInterval, limitMinutes: Int) -> TimeInterval? {
        guard limitMinutes > 0 else { return nil }
        let remaining = Double(limitMinutes) * TimeConstants.secondsPerMinute - totalSeconds
        return remaining > 0 ? remaining : nil
    }

    /// The day window the latches below belong to, so they clear themselves at the `daily_reset_time`
    /// boundary rather than needing anyone to remember to.
    private var latchedWindowStart: Date?
    /// Categories that have reached their limit in this window, each remembering the `daily_limit` in
    /// force when it caught -- see the type's note on why the limit is stored and not just the fact.
    private var limitWhenReached: [Int: Int] = [:]
    /// Whether the cube's current pause is one this type asked for, and so one it may lift again.
    private(set) var isPausedByLimit = false
    /// Whether the category on show has spent its budget, as of the last `evaluate`. What the menu
    /// bar draws red, and what `MenuBarController.togglePause` refuses to resume through.
    private(set) var isReachedForCurrentCategory = false

    /// Fold in the current state of play and say what the cube needs.
    ///
    /// - Parameters:
    ///   - categoryID: `category_id` of the category on show, or `nil` when there is no activity to
    ///     measure (the "Idle" placeholder). A `nil` leaves every latch alone: there is no category
    ///     to have spent anything, but the ones already spent have not been given their time back.
    ///   - limitMinutes: that category's `daily_limit`, `0` for none.
    ///   - totalSeconds: what the category has tracked in this window, live segment included -- the
    ///     figure the menu bar draws, so the limit is measured against what the user is looking at.
    ///   - isPaused: whether the cube is paused *now*, as last reported by a history frame.
    ///   - windowStart: the current day window, from `DailyCategoryTotals.windowStart`.
    mutating func evaluate(
        categoryID: Int?,
        limitMinutes: Int,
        totalSeconds: TimeInterval,
        isPaused: Bool,
        windowStart: Date
    ) -> DailyLimitAction {
        if latchedWindowStart != windowStart {
            latchedWindowStart = windowStart
            limitWhenReached = [:]
        }

        guard let categoryID else {
            isReachedForCurrentCategory = false
            return .none
        }

        // A limit edited since this category caught is a new question, so the old answer is dropped
        // and the new number decides below. Clearing the limit to 0 lands here too, and then fails
        // `isReached`, which is how "no limit" releases a category the same day.
        if let latchedLimit = limitWhenReached[categoryID], latchedLimit != limitMinutes {
            limitWhenReached[categoryID] = nil
        }

        let reached = limitWhenReached[categoryID] != nil
            || DailyLimitEnforcement.isReached(totalSeconds: totalSeconds, limitMinutes: limitMinutes)
        isReachedForCurrentCategory = reached

        guard reached else {
            // Budget again on this face, and the cube already running: whatever pause this type
            // placed is gone, so the claim goes with it. On real hardware this is the ordinary way a
            // limit's pause ends -- **a flip resumes the cube in firmware**, the app having no part
            // in it (measured 2026-08-12; the sole exception is a locked cube, which refuses the flip
            // outright and reports no event at all). Clearing here is what stops the *user's* next
            // pause on a budgeted face being read as this type's own and undone on the following
            // frame: before this, the claim survived the firmware's resume, and Pause on a budgeted
            // face was a control that undid itself one frame later.
            guard isPaused else {
                isPausedByLimit = false
                return .none
            }
            // Still paused with budget to spare. Only lift a pause of this type's own making; see the
            // note above on why a user's pause is not this type's to undo.
            guard isPausedByLimit else { return .none }
            isPausedByLimit = false
            return .resume
        }

        limitWhenReached[categoryID] = limitMinutes
        guard !isPaused else {
            // Already stopped, so nothing to send -- but claim the pause, which is what makes the
            // flip away from this face lift it. Two states arrive here and both want claiming: the
            // pause this type asked for a moment ago, and a cube found already paused on a spent
            // category by a relaunch, where the flag itself did not survive the quit but the cube's
            // pause did.
            isPausedByLimit = true
            return .none
        }
        isPausedByLimit = true
        return .pause
    }
}
