import Foundation

/// Starting and stopping the app's own clock, which is not the cube's and not a window's.
///
/// **Three controls land here and one of them is not in a window at all.** The status item's right half and the
/// dropdown's Pause item both reach this with Settings shut, and the Timing column's glyph reaches it with the
/// window open. That is why it is here: a decision three surfaces share, one of which the Settings window does
/// not own, was living in `SettingsWindowController` (candidate 8 of
/// `docs/architecture-review-2026-09.md`).
///
/// **The refusal is the enforcement rather than the courtesy.** Both controls grey themselves when the daily
/// limit is spent, which is the courtesy; this is what makes finding another button useless. It is also why the
/// limit is asked at the moment of the press rather than held: the limit lands part way through a session, and
/// a boolean read when a window opened would refuse the wrong thing.
///
/// **What it deliberately does not do is draw.** It answers with the reading the table now holds, and the
/// caller repaints whatever it has on screen. A surface with nothing showing simply ignores the answer.
@MainActor
package enum ManualClock {
    /// Stops the clock if it is running and starts it if it is not, or refuses.
    ///
    /// - Parameter isLimitReached: asked now rather than remembered, for the reason above.
    /// - Returns: what the table holds afterwards, or `nil` when nothing was done. `nil` is both the refusal and
    ///   the case where nothing was being timed, which are the same thing to a caller: do not repaint.
    package static func toggle(
        timing: TimingReadout?,
        events: DeviceEventRecorder?,
        isLimitReached: Bool,
        at moment: Date = Date(),
        debugLog: DebugLog?
    ) -> TimingReadout.Reading? {
        // Read before anything is written, since it is what decides which of the two this is.
        let before = timing?.read() ?? .idle
        // Nothing being timed means no clock and no row, so there is nothing here to stop or start. The same
        // question the dropdown's Pause item and the status item's right side ask, and the same answer.
        guard ManualTimerRules.isClickable(before.timingState, isLimitReached: isLimitReached) else {
            debugLog?.record(
                .limit,
                "Resume refused, \(before.category?.name ?? "nothing") has spent its daily limit"
            )
            return nil
        }
        // One moment for both halves, so the segment that ends and the one that begins meet exactly.
        if before.timingState == .running {
            events?.closeOpenSegment(at: moment)
        } else {
            // The same face the paused stretch was on, not the next one, and nothing is written to it. Rotating
            // exists to stop a face's category changing under a finished segment, and resuming does not change
            // it: this is the same category continuing. Reusing the face is therefore safe, and it keeps a
            // pause-heavy session from cycling the pool for no reason.
            events?.startSegment(face: events?.currentManualFace() ?? ManualFace.first, at: moment)
        }
        // Read back rather than assumed, which is the rule applied to the app's own writes as well as to what it
        // shows: this says what the table now holds, so a write that did not take says so here.
        let after = timing?.read() ?? .idle
        debugLog?.record(
            .mode,
            "Timing: \(after.timingState == .running ? "running" : "stopped") "
                + "\(after.category?.name ?? "nothing"), \(Int(after.seconds))s today"
        )
        return after
    }
}
