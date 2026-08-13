import Foundation

/// Whether a finished segment becomes tracked time. **The decisions only**, against numbers, so they can be
/// asserted without a database.
///
/// A `device_event` is what a device says happened; a `time_entry` is what the app counts. Keeping them apart
/// is what lets the second question have an answer of its own -- and the answer is not always yes, which is
/// the whole reason this exists rather than an `INSERT ... SELECT`.
enum TimeEntryRules {

    /// What to do with a finished segment.
    enum Decision: Equatable {
        /// It becomes a `time_entry`.
        case create
        /// It does not, for this reason. Nothing is written and the segment stays as it is.
        case ignore(Reason)
    }

    /// Why a segment produced no entry. Named rather than boolean, because "no entry" covers cases that need
    /// telling apart afterwards: one of these is normal, one is a pause, and one means the question was asked
    /// too early.
    enum Reason: Equatable {
        /// Still running. The question belongs to the moment it closes, not before.
        case stillRunning
        /// A paused stretch is time not spent, so it is never counted. The previous app's conversion said the
        /// same thing as `WHERE paused = 0`.
        case paused
        /// Shorter than `blip_time`: the cube being turned *past* a face on the way to another, rather than
        /// time on it.
        case blip(shorterThan: Int)
    }

    /// Where `blip_time` sits when the row is missing or holds something that is not a number, and the bounds
    /// a hand-edited row is held to. All three match `database/011_setting.sql` and the previous app's
    /// `TimeFlipConstants`; five seconds comes from the vendor spec.
    static let defaultBlipSeconds = 5
    static let minimumBlipSeconds = 0
    static let maximumBlipSeconds = 30

    /// The threshold to use, from what the row says. `0` is a real value and means the filter is off.
    static func blipSeconds(from stored: Int?) -> Int {
        let requested = stored ?? defaultBlipSeconds
        return min(maximumBlipSeconds, max(minimumBlipSeconds, requested))
    }

    /// Decides, from the segment's own state and the threshold in force.
    ///
    /// **Strictly shorter**, so a segment exactly as long as the threshold is kept: the setting reads "ignore
    /// flips under N", and a five-second segment is not under five.
    ///
    /// A blip is **skipped, not merged into the following segment.** That was specified once and dropped, for a
    /// reason worth keeping: merging needs a duration this data does not reliably have, since a segment the
    /// next event proves ran three seconds can be stored as `0.0` (production `device_event` 28). Losing a few
    /// seconds per pass-over is the cheaper mistake.
    ///
    /// One consequence to know: **lowering `blip_time` makes previously-skipped segments eligible again** if
    /// anything ever re-asks, because a skipped blip has no entry to find. Raising it changes nothing, since
    /// entries already made stay made.
    static func decision(
        durationSeconds: Double,
        isPaused: Bool,
        isFinalised: Bool,
        blipSeconds: Int
    ) -> Decision {
        guard isFinalised else { return .ignore(.stillRunning) }
        guard !isPaused else { return .ignore(.paused) }
        // `> 0` first: with the filter off, a zero-second segment is still an entry, because switching the
        // filter off is a request to count everything.
        if blipSeconds > 0, durationSeconds < Double(blipSeconds) {
            return .ignore(.blip(shorterThan: blipSeconds))
        }
        return .create
    }
}
