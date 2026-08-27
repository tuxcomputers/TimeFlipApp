import Foundation

/// What the app must do to the cube's pause state, having looked at the face it is resting on.
enum ForcedPauseAction: Equatable {
    /// The pause state already matches the face. Send nothing.
    case none
    /// The cube is counting on a face with no category: pause it (`0x06 0x01`).
    case pause
    /// The cube is paused, this app is what paused it, and the face it is on now has a category. Resume it
    /// (`0x06 0x02`).
    case resume
}

/// **A pause the app puts on the cube for a reason of its own**, rather than one anybody asked for.
///
/// **This is the first of the reasons: time the app cannot attribute is time it will not let the cube record.** A cube
/// resting on a face with no category is counting a stretch that has nowhere to go, so the clock stops until somebody
/// says what that face is.
///
/// **The second reason is a category that has spent its `daily_limit`**, and that decision is not here: it is
/// `DailyLimitEnforcement`, which already answers it in full, including the case of flipping onto a face whose
/// category is spent. The two are kept apart because they measure different things -- a face against the `face` table,
/// a category against a day's recorded total -- and share only the cube they are deciding about. What they must not
/// do is fight over it, which is what the `limitIsHolding` parameter below is for.
///
/// **This is not the cube's own auto-pause, and the two nearly share a word.** `Auto-pause` on the Device tab
/// (`DevicePane.Identifier.autoPause`, `DeviceCommandRules.Status.autoPauseMinutes`) is a firmware setting: an idle
/// timeout in whole minutes, which this app pins to 0 so the cube never stops itself. What is here is the app forcing
/// a pause, which the firmware knows nothing about.
///
/// **The decision is here and the sending is not**, the split `DailyLimitEnforcement` uses and for its reasons:
/// everything below takes a face, a boolean or two and answers with an action, so every awkward sequence can be
/// tested without a radio.
///
/// ## Only one of the two things you might expect has to be sent
///
/// **A flip resumes the cube in firmware, so the app sends nothing for it** (measured 2026-08-12, recorded in
/// `DailyLimitEnforcement`: "a flip always resumes the cube, the one exception being a locked cube, which refuses the
/// flip and reports no event"). So a cube stopped on an unassigned face and then turned onto a face that has a
/// category is already running by the time the frame arrives, and the answer here is `.none` rather than `.resume`.
/// That is the whole of "it resumes when the cube is flipped onto an assigned face": it costs no command and cannot
/// fail.
///
/// **What `.resume` is actually for is a pause that survives**: the face the cube is sitting on is given a category
/// on the Faces tab while the cube sits there stopped. Nothing physical has happened, so nothing lifts the pause but
/// this. That is the case worth having and it is the one the request names.
///
/// ## The latch, and why a pause has to be claimed
///
/// Only a pause this type placed is lifted. Without that, a pause the *user* made -- the status item's right half,
/// the dropdown's Pause -- would be undone the moment they gave the face a category, which is a control that undoes
/// itself. The claim is dropped as soon as the cube is seen running, however it came to be running, so a hand-pause
/// after that is theirs and stays theirs.
///
/// **The latch is in memory and that is not a breach of the database rule**, it is the rule's own reasoning:
/// it is not a copy of anything a table holds. Which face has a category comes from `face` on every ask and is never
/// kept; whether the cube is stopped comes from the open `device_event` row on every ask and is never kept. What is
/// kept is *which face this app stopped the cube on*, which no table records. A relaunch re-derives nothing and
/// claims nothing, which is the safe direction: an inherited pause is treated as the user's until the app makes one
/// of its own.
///
/// ## What it will not touch
///
/// - **A locked cube.** `docs/timeflip.md`: the status read answers `pause (0x01/0x02 unless locked)`, so a locked
///   cube reports itself paused whatever its pause byte says and nothing here could be confirmed. `CubeLock` refuses
///   for the same reason.
/// - **A cube the daily limit is holding.** Both types decide the same cube's pause state, and a hard limit has to
///   win or it is not hard: the limit's pause would be lifted the moment somebody assigned a category, which is a
///   refusal with a way round it. So `.resume` stands down while the limit is holding one. `.pause` needs no such
///   guard, since a cube already stopped is answered `.none` whoever stopped it.
/// - **The app's own faces.** 13 and 14 are manual mode's (`database/008_face.sql`), seeded `Unassigned` and meant to
///   be: there is no cube to stop and nothing to attribute time to but the category a click named.
struct ForcedPause {
    /// The face this app stopped the cube on, or `nil` for a pause it does not claim. See the latch note above.
    private var stoppedOnFace: Int?

    /// Whether the pause on the cube right now is one this type placed. What the menu bar would ask to say *why* the
    /// cube is stopped, and what a test asserts instead of reaching inside.
    var isLimitHoldingPause: Bool { stoppedOnFace != nil }

    /// One decision.
    ///
    /// - Parameters:
    ///   - face: the face the cube's open segment names, or `nil` for a cube with no open segment to read -- one
    ///     reset and not yet flipped. Nothing is decided about a cube that has not said where it is.
    ///   - hasCategory: whether that face holds a category, read from `face` at the moment of the ask.
    ///     `FaceStore.categoryID(forFace:)` answers `nil` for the seeded *Unassigned* row, which is this being false.
    ///   - isPaused: whether the cube is stopped, from the open `device_event` row -- the cube's own account.
    ///   - isLocked: whether the cube is locked, from `BluetoothRadio.cubeStatus`. `nil` is "nobody has asked yet",
    ///     which is treated as locked: nothing is sent on a guess about the one state that makes the pause byte lie.
    ///   - isCubeConnected: whether there is a link to send anything down.
    ///   - limitIsHolding: whether `DailyLimitEnforcement` is holding a pause of its own.
    mutating func evaluate(
        face: Int?,
        hasCategory: Bool,
        isPaused: Bool,
        isLocked: Bool?,
        isCubeConnected: Bool,
        limitIsHolding: Bool
    ) -> ForcedPauseAction {
        // **A pause the app cannot see is not one it holds.** The link going down says nothing about what the cube is
        // doing, and a claim carried across a reconnect would be a claim about a cube that may have been double
        // tapped, had its batteries out, or been driven by the vendor's app in the meantime.
        guard isCubeConnected else {
            stoppedOnFace = nil
            return .none
        }

        // A locked cube reports itself paused whatever its pause byte says, so there is nothing here that could be
        // read back and believed. The claim stands: unlocking does not change who stopped it.
        guard isLocked == false else { return .none }

        // No open segment, or one of the app's own faces. Neither is a cube resting somewhere unattributable.
        guard let face, (1...12).contains(face) else { return .none }

        // **The cube is running.** Whatever this type had claimed is over -- a flip lifted it, or a double tap did,
        // or the user did -- and the claim goes before anything else is decided, so a hand-resume on an unassigned
        // face is answered by a fresh pause rather than by a claim that never lapsed.
        guard isPaused else {
            stoppedOnFace = nil
            return hasCategory ? .none : .pause
        }

        // From here the cube is stopped. Either this type stopped it on this face, or the pause is somebody else's.
        guard stoppedOnFace == face, hasCategory else { return .none }
        guard !limitIsHolding else { return .none }
        return .resume
    }

    /// Records that the resume this type just asked for actually took, which is what gives the claim up.
    ///
    /// **The mirror of `pauseTook`, and it exists for the case that goes wrong quietly.** Giving the claim up at the
    /// moment `.resume` was *decided* would mean a refused resume left a cube paused with nobody claiming it: the next
    /// look would find a face with a category, a stopped cube and no claim, answer `.none`, and leave it stopped for
    /// good. Held until the cube confirms, the same look answers `.resume` again and it is retried.
    mutating func resumeTook() {
        stoppedOnFace = nil
    }

    /// Records that the pause this type just asked for actually took, which is what makes the claim.
    ///
    /// **Separate from `evaluate`, because a command that was refused is not a pause.** Every command goes out through
    /// `CubeLock`, which reads it back before believing it (`CLAUDE.md`), and claiming at the moment of asking would
    /// leave this type holding a pause the cube never made -- then lifting it, on a cube that was running all along,
    /// the moment somebody assigned a category.
    mutating func pauseTook(onFace face: Int) {
        stoppedOnFace = face
    }
}
