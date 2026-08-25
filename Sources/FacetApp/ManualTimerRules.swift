import Foundation

/// The faces the app times against when there is no cube: 13 and 14.
///
/// Real faces, seeded in `database/008_face.sql` alongside the twelve physical ones, so a manual session
/// resolves its category exactly as a flip does -- through `face` -- instead of needing a second path that
/// means the same thing. **Nothing above 12 ever comes from a device**, which is what leaves the numbers
/// above it free for the app to use.
///
/// **More than one, and that is the whole point.** A segment names a face, and the face's category is what
/// later says whose time it was, so reassigning a face while a finished segment is still waiting for its
/// `time_entry` changes the answer underneath it. One face made that the ordinary case: every switch of
/// category rewrote the same row's meaning, and only the order of three statements kept it correct. Two
/// faces make it impossible instead -- the segment that just ended and the one starting are never on the
/// same face, which is exactly why a cube never had this problem. Flipping from face 3 to face 5 leaves
/// face 3's mapping alone.
///
/// Two is the smallest pool that gives that. Widening it only buys grace for a conversion that happens
/// later than the close (a row stranded by a crash, say, swept up on the next launch), which is why this is
/// a list rather than a pair of constants: adding 15 here and to the DDL is the whole change.
enum ManualFace {
    /// The highest face a cube can report. **Nothing above this ever comes from a device**, which is what makes
    /// the numbers above it the app's to use, and what lets anything tell one kind of segment from the other
    /// without a column saying which it is.
    static let highestDeviceFace = 12

    /// Whether a face is one of the app's own, which is the same question as whether a segment on it was measured
    /// here rather than by a cube.
    ///
    /// **What decides whose clock may write that segment's duration.** The app measures its own stretches with the
    /// wall clock, because nothing else can; a cube measures its own and reports them in its history, and a
    /// wall-clock figure written over that is this app overwriting a measurement with a guess. Asked in the two
    /// places that would do it -- `DeviceEventRecorder.closeOpenSegment` and `refreshOpenSegment` -- rather than
    /// left to each caller to remember.
    static func isTheApps(_ face: Int) -> Bool {
        face > highestDeviceFace
    }

    /// In rotation order. `device_face`'s `CHECK` in `003_device_event.sql` bounds what the table will hold,
    /// so growing this list means changing that too.
    static let all = [13, 14]

    /// Where a session with no history starts.
    static var first: Int { all[0] }

    /// The face a new segment goes on, given the face the last one used.
    ///
    /// `nil` means nothing has been timed yet. A face that is not one of ours means the last segment came
    /// from somewhere else entirely -- a cube's flip -- and manual mode starts its own run from the top
    /// rather than trying to continue a rotation it was not part of.
    static func next(after face: Int?) -> Int {
        guard let face, let index = all.firstIndex(of: face) else { return first }
        return all[(index + 1) % all.count]
    }
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
    ///
    /// **A spent daily limit stops a resume and never a pause**, which is the whole of what makes the limit
    /// hard: reaching it stops the clock, and the app then refuses every path that would start it again while
    /// that category is still the one on show. Stopping stays available throughout -- refusing it would be a
    /// limit that trapped somebody into recording time, which is the opposite of what it is for.
    ///
    /// **Every path asks this, which is the point.** The dropdown item greys itself with it, the status item's
    /// right half turns into a no-op with it, and `togglePause` refuses with it, so the refusal cannot be
    /// implemented in one of the three and forgotten in the others. That is the exact fault the paragraph above
    /// records, and a limit is a second chance to make it.
    static func isClickable(_ state: TimingState, isLimitReached: Bool = false) -> Bool {
        guard state != .idle else { return false }
        return !(state == .paused && isLimitReached)
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
