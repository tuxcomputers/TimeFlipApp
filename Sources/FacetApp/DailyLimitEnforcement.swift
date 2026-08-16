import Foundation

/// What the app must do to the cube's pause state, having compared the category on show against its `daily_limit`.
enum DailyLimitAction: Equatable {
    /// The pause state already matches the limit. Send nothing.
    case none
    /// The category on show has spent its limit and the cube is still counting: pause it (`0x06 0x01`).
    case pause
    /// The cube is paused, this app is what paused it, and the category on show has budget again -- the user flipped
    /// off the spent face. Resume it (`0x06 0x02`).
    case resume
}

/// A **hard** daily limit: when the category on show reaches its `daily_limit`, the app pauses the cube and then
/// refuses to send the unpause for as long as that category is the one on show.
///
/// **The decision is here and the sending is not**, which is what lets this exist before the app has any Bluetooth at
/// all. Everything below takes numbers and booleans and answers with a `DailyLimitAction`; something else will put
/// `0x06 0x01` on the wire when there is a wire. That split is the archive's too, and it is the reason the awkward
/// sequences -- the crossing, the stale total in the seconds after a pause, a double tap, a relaunch onto an already
/// paused cube -- can all be tested without a radio.
///
/// Refusing to send is the whole enforcement, and it is worth being clear that it is the app's refusal rather than the
/// cube's: nothing in the protocol asks the device to hold a pause against its own user. `0x06 0x02` would be honoured
/// whenever it arrived, so the limit is only as hard as the set of paths that can send it -- the dropdown's Resume
/// item, the status item's right half (both `MenuBarController`'s `togglePause`), and this type's own `.resume`. A
/// **double tap on the cube pauses and unpauses it in firmware**, with no app involvement at all (see the Double tap
/// characteristic in `docs/TimeFlip2 BLE Protocol v4.3.md`), so that one cannot be refused, only answered: it arrives
/// as a history frame reporting the cube running again, `evaluate` sees a spent category unpaused, and the pause goes
/// straight back out.
///
/// Flipping to a face whose own category has budget leaves the cube running, because pause is a property of the
/// **cube** and a limit is a property of a **category**: leaving it paused would spend one category's budget and stop
/// the day's tracking. Flipping back pauses it again.
///
/// **The firmware is what lifts it, not this type** (measured 2026-08-12: a flip always resumes the cube, the one
/// exception being a locked cube, which refuses the flip and reports no event). So the frame after a flip reports the
/// cube already running and `.resume` is never needed for it. What `.resume` is actually for is a pause that
/// *survives* -- the limit raised or cleared on the Categories tab while the cube sits paused on that same spent face,
/// where nothing physical has happened to lift it. Only a pause this type asked for is lifted (`isPausedByLimit`) -- a
/// pause the user asked for is theirs, and auto-resuming it would make the Pause item a control that undoes itself.
/// The claim is therefore dropped as soon as a frame reports the cube running with budget in hand, however it came to
/// be running; holding it past that turned the *user's* own pause into one this type believed it had placed.
///
/// ## Why the latch, and not just today's total against the limit
///
/// The obvious form of this is a comparison with no memory: reached = total >= limit, evaluated fresh each time. It
/// breaks, and it breaks in the one direction that matters. The figure the menu bar reports while paused is the
/// **recorded** total (`time_entry` rows, via `DayTotal.seconds`), because the live segment stops counting -- and the
/// segment that just ran the category out of budget is not recorded yet. It becomes a `time_entry` only once the pause
/// has closed it and the history behind it has been ingested. So in the seconds between "pause sent" and "segment
/// ingested", a memoryless comparison reads *under* the limit, sees a cube paused by the limit with budget to spare,
/// and issues `.resume` -- undoing the pause it just asked for, on the strength of a total it knows is incomplete.
///
/// So a category that has reached its limit stays reached for the day. The latch remembers the limit that was in force
/// when it caught, which is what lets a **deliberate** change clear it: edit the limit on the Categories tab (raise it,
/// lower it, or clear it to `0` for no limit) and the stored value no longer matches, so the category is measured
/// against the new number immediately. That is the one thing a stale total cannot imitate, since nothing about
/// ingesting a segment changes what the limit says.
///
/// **The latch is in memory and that is not a breach of the database rule**, it is the rule's own reasoning: it is not
/// a copy of anything a table holds. `category.daily_limit` and the recorded total are both read fresh on every
/// `evaluate` and neither is kept. What is kept is which categories have already caught *in this window* and at what
/// limit, which no table records and which is deliberately per-launch -- a relaunch re-derives it from the cube's own
/// pause state (see the relaunch case in `evaluate`).
struct DailyLimitEnforcement {
    /// Sixty. Named rather than written into the two comparisons below, so a limit stored in minutes and a total
    /// measured in seconds cannot drift apart in one of them.
    private static let secondsPerMinute: Double = 60

    /// Whether `totalSeconds` has spent a `limitMinutes` budget. `limitMinutes <= 0` is *no limit*
    /// (`database/007_category.sql`), so it is never reached.
    ///
    /// `>=` rather than `>`: a 60-minute limit is reached at 60:00, not at 60:01. This is the same comparison the menu
    /// bar's red duration will be drawn from, deliberately -- the colour and the pause are two faces of one fact, and a
    /// limit that turned the text red a second before it stopped the cube would be two rules with one name.
    static func isReached(totalSeconds: TimeInterval, limitMinutes: Int) -> Bool {
        guard limitMinutes > 0 else { return false }
        return totalSeconds >= Double(limitMinutes) * secondsPerMinute
    }

    /// How long until `totalSeconds` reaches the limit, for arming a one-shot timer on the exact second rather than
    /// waiting for the next display tick. `nil` when there is no limit or it is already reached, i.e. when there is
    /// nothing to wait for.
    ///
    /// **The archive's reason for this no longer applies and it is worth keeping anyway.** There, the menu bar redrew
    /// once a *minute* with `display_seconds` off, so enforcing on the tick would have let a hard limit overrun by up
    /// to 59 seconds and made the overrun depend on a display preference. This app's item ticks once a second whatever
    /// the preference says (`MenuBarController`), so that particular fault cannot happen here.
    ///
    /// What survives is the smaller reason: the tick only runs **while the clock is running**, and it exists to redraw
    /// rather than to decide. A limit that reached its number a moment after the last repaint would wait for the next
    /// one, and enforcement hanging off a timer whose job is drawing is the kind of coupling that is fine until
    /// somebody optimises the redraw.
    static func secondsUntilReached(totalSeconds: TimeInterval, limitMinutes: Int) -> TimeInterval? {
        guard limitMinutes > 0 else { return nil }
        let remaining = Double(limitMinutes) * secondsPerMinute - totalSeconds
        return remaining > 0 ? remaining : nil
    }

    /// The day window the latches below belong to, so they clear themselves at the `daily_reset_time` boundary rather
    /// than needing anyone to remember to.
    private var latchedWindowStart: Date?
    /// Categories that have reached their limit in this window, each remembering the `daily_limit` in force when it
    /// caught -- see the type's note on why the limit is stored and not just the fact.
    private var limitWhenReached: [Int: Int] = [:]
    /// Whether the cube's current pause is one this type asked for, and so one it may lift again.
    private(set) var isPausedByLimit = false

    /// Whether `categoryID` has spent its budget. **Asked at the moment it matters, not remembered from the last
    /// `evaluate`.**
    ///
    /// This is what the refusal is built on: the dropdown's Resume greys with it, the status item's right half becomes
    /// a no-op, the Faces tab's glyph greys, and the menu bar draws the duration red. All four ask as they are drawn or
    /// as they are clicked, so none of them can be showing an answer that has since stopped being true.
    ///
    /// **It was a stored flag until 2026-08-16, and that was a bug with a scripted run behind it.** `DailyLimitWatch`
    /// only ticks while the clock is running, so the flag stopped being updated at the very moment it latched: a limit
    /// raised on the Categories tab afterwards was never noticed and the refusal stayed up for the rest of the launch.
    /// Run 15 of `Tests/Scripted/12-daily-limit.sh` caught it -- the right half still answered `ignore` two seconds
    /// after the limit went from 5 minutes to 10.
    ///
    /// Non-mutating, deliberately. It is asked from draw code and from click handlers, and a query that quietly latched
    /// something would make what is on screen depend on how often it was looked at. `evaluate` stays the only thing
    /// here that changes anything.
    func isReached(
        categoryID: Int?,
        limitMinutes: Int,
        totalSeconds: TimeInterval,
        windowStart: Date
    ) -> Bool {
        guard let categoryID else { return false }
        // A latch from a window that has since rolled over is not an answer about this one. `evaluate` is what actually
        // clears it; this only declines to believe it in the meantime.
        if latchedWindowStart == windowStart,
           let latchedLimit = limitWhenReached[categoryID],
           latchedLimit == limitMinutes {
            return true
        }
        // The fall-through `evaluate` uses once a latch is dropped for disagreeing with the limit: the old answer is
        // gone and the current number decides. Raising the limit lifts the refusal here, lowering it holds, and
        // clearing it to 0 releases -- all without waiting for a tick that may have stood down.
        return DailyLimitEnforcement.isReached(totalSeconds: totalSeconds, limitMinutes: limitMinutes)
    }

    /// Fold in the current state of play and say what the cube needs.
    ///
    /// - Parameters:
    ///   - categoryID: `category_id` of the category on show, or `nil` when there is no activity to measure (the
    ///     "Idle" placeholder). A `nil` leaves every latch alone: there is no category to have spent anything, but the
    ///     ones already spent have not been given their time back.
    ///   - limitMinutes: that category's `daily_limit`, `0` for none.
    ///   - totalSeconds: what the category has tracked in this window, live segment included -- the figure the menu bar
    ///     draws (`DayTotal.seconds`), so the limit is measured against what the user is looking at.
    ///   - isPaused: whether the cube is paused *now*, as last reported by a history frame.
    ///   - windowStart: the current day window, from `DayTotal.windowStart(at:)`.
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

        guard let categoryID else { return .none }

        // A limit edited since this category caught is a new question, so the old answer is dropped and the new number
        // decides below. Clearing the limit to 0 lands here too, and then fails `isReached`, which is how "no limit"
        // releases a category the same day.
        if let latchedLimit = limitWhenReached[categoryID], latchedLimit != limitMinutes {
            limitWhenReached[categoryID] = nil
        }

        let reached = limitWhenReached[categoryID] != nil
            || DailyLimitEnforcement.isReached(totalSeconds: totalSeconds, limitMinutes: limitMinutes)

        guard reached else {
            // Budget again on this face, and the cube already running: whatever pause this type placed is gone, so the
            // claim goes with it. On real hardware this is the ordinary way a limit's pause ends -- **a flip resumes
            // the cube in firmware**, the app having no part in it (measured 2026-08-12; the sole exception is a
            // locked cube, which refuses the flip outright and reports no event at all). Clearing here is what stops
            // the *user's* next pause on a budgeted face being read as this type's own and undone on the following
            // frame: before this, the claim survived the firmware's resume, and Pause on a budgeted face was a control
            // that undid itself one frame later.
            guard isPaused else {
                isPausedByLimit = false
                return .none
            }
            // Still paused with budget to spare. Only lift a pause of this type's own making; see the note above on
            // why a user's pause is not this type's to undo.
            guard isPausedByLimit else { return .none }
            isPausedByLimit = false
            return .resume
        }

        limitWhenReached[categoryID] = limitMinutes
        guard !isPaused else {
            // Already stopped, so nothing to send -- but claim the pause, which is what makes the flip away from this
            // face lift it. Two states arrive here and both want claiming: the pause this type asked for a moment ago,
            // and a cube found already paused on a spent category by a relaunch, where the flag itself did not survive
            // the quit but the cube's pause did.
            isPausedByLimit = true
            return .none
        }
        isPausedByLimit = true
        return .pause
    }
}
