import Foundation

/// What editing a category on the Categories tab is allowed to do: the bounds on a daily limit, and when retiring
/// one is refused.
///
/// Separate from the views for the reason every other `...Rules` type here is: a decision inside a control is a
/// decision no test can reach, and both of these have an edge that matters more than the common case.
enum CategoryEditRules {
    /// A day's worth of minutes, and the most a daily limit can be.
    ///
    /// The previous app's ceiling, with its reasoning: the limit is a budget for time tracked in one day, so a day is
    /// the most that can be spent against it and anything above it is unreachable rather than merely generous. It is
    /// also what a stepper needs in order to have somewhere to stop.
    static let maximumDailyLimitMinutes = 1_440

    /// Zero, which is the seeded value and means no limit at all rather than a limit of nothing.
    static let disabledDailyLimit = 0

    /// A typed or stepped limit, brought inside the bounds.
    ///
    /// Clamped rather than refused: the field is a number box, so the only ways out of range are a held arrow and a
    /// typed figure, and in both cases the nearest allowed value is what the person meant.
    static func dailyLimitMinutes(_ requested: Int) -> Int {
        min(maximumDailyLimitMinutes, max(disabledDailyLimit, requested))
    }

    /// Why retiring a category is not on offer, or `nil` when it is.
    enum RetireRefusal: Equatable {
        /// A locked face holds this category. Retiring takes a category off every face it is on, and a locked face is
        /// one the user has said keeps what it has, so the two instructions contradict each other.
        case lockedFaces([Int])
    }

    /// Whether this category can be retired, given the faces holding it.
    ///
    /// **The locked-face bar is the previous app's, and its reasoning is what makes it worth keeping**: the app does
    /// not get to pick which of two contradictory instructions wins, so it does neither and says why. The way through
    /// is to unlock the face on the Faces tab, which is a thing the user does deliberately.
    ///
    /// Only this direction is barred. Reinstating a category that a locked face holds -- which a database written
    /// before this rule can have -- must still work, because reinstating puts nothing on any face.
    static func retireRefusal(facesHolding faces: [(face: Int, isLocked: Bool)]) -> RetireRefusal? {
        let locked = faces.filter(\.isLocked).map(\.face)
        return locked.isEmpty ? nil : .lockedFaces(locked)
    }

    /// Whether a retired category can come back, and what stops it.
    enum ReinstateDecision: Equatable {
        case reinstate
        /// An active category already holds this name, so bringing this one back under it is not possible.
        case refuse(activeNamesake: CategoryRecord)
    }

    /// Whether ticking a retired category's Active box can do anything.
    ///
    /// **Asked before the write rather than after it.** The unique index over active names would refuse this anyway,
    /// and that index stays the last word -- but a write that comes back `false` cannot say *which* category is in
    /// the way, and that is the whole of what somebody needs to hear. So the question is asked first, for the
    /// message, and the index still has the final say.
    ///
    /// Matched case-insensitively, because the index is: `matching(name:)` uses `COLLATE NOCASE`, so a check that
    /// was stricter would pass a name the write then refuses.
    ///
    /// - Parameters:
    ///   - category: the retired row whose box was ticked.
    ///   - matches: every category holding that name, whatever state each is in -- `CategoryStore.matching(name:)`.
    static func reinstateDecision(for category: CategoryRecord, matching matches: [CategoryRecord]) -> ReinstateDecision {
        // Itself excluded: a retired row always matches its own name, and it is not in its own way.
        guard let namesake = matches.first(where: { $0.isActive && $0.id != category.id }) else {
            return .reinstate
        }
        return .refuse(activeNamesake: namesake)
    }

    /// What a row says about why its Active box cannot be unticked. `nil` when it can.
    static func retireRefusalHelp(_ refusal: RetireRefusal?, categoryName: String) -> String? {
        switch refusal {
        case nil:
            return nil
        case let .lockedFaces(faces):
            let list = faces.map(String.init).joined(separator: ", ")
            let plural = faces.count == 1 ? "Face \(list) is" : "Faces \(list) are"
            // Names the face, because the row gives no clue which one is in the way.
            return "\(plural) locked and still holding \"\(categoryName)\". Unlock it on the Faces tab to retire this "
                + "category."
        }
    }
}
