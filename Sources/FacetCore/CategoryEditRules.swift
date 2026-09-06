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

    /// Why a category cannot be changed at all, or `nil` when it can.
    enum EditRefusal: Equatable {
        /// A locked face holds this category. A locked face is one the user has said keeps what it has, and what it
        /// has is not only *which* category but how that category looks on the cube -- its icon and its colour are
        /// what the face shows.
        case lockedFaces([Int])
    }

    /// Whether this category can be edited at all, given the faces holding it.
    ///
    /// **A locked face freezes the whole row**, not only the Active box: the name, the icon, the colour and the daily
    /// limit as well. The previous app barred retiring alone, on the narrower reading that retiring is what takes a
    /// category off a face. This is the wider one, and it is the one that matches what locking a face is for: the
    /// face is to stay exactly as it is, and half of what it *is* -- the artwork and the colour it lights -- lives on
    /// the category rather than on the face.
    ///
    /// The way through is unlocking the face on the Faces tab, which is a thing somebody does deliberately.
    ///
    /// Only the *active* list is affected, which needs no check here because it is the only list that offers edits.
    /// Reinstating a category a locked face holds -- which a database written before any of this can have -- must
    /// still work, since reinstating puts nothing on any face.
    static func editRefusal(facesHolding faces: [(face: Int, isFaceLocked: Bool)]) -> EditRefusal? {
        let locked = faces.filter(\.isFaceLocked).map(\.face)
        return locked.isEmpty ? nil : .lockedFaces(locked)
    }

    /// The `icon_id` a click on the icon grid should store.
    ///
    /// **Re-clicking the icon already chosen clears it**, which is how a grid with no None cell can still unset one.
    /// Copied from the previous app along with its reasoning: the None row (`icon_id` 0) is a sentinel rather than a
    /// bundled asset, so there is nothing to draw in a cell for it, and a grid that could only ever set an icon would
    /// make "no icon" a state a category could leave but never return to.
    static func iconSelection(clicked iconID: Int, selected selectedIconID: Int) -> Int {
        iconID == selectedIconID ? noIcon : iconID
    }

    /// The `icon_id` meaning no icon at all, which is what every category starts with.
    static let noIcon = 0

    /// The `colour_id` a click on the colour list should store.
    ///
    /// **The same rule as `iconSelection`, and named for its own column rather than shared with it.** Both columns
    /// clear by re-picking what is already set, and both have a None row at id 0 that no cell offers -- but they are
    /// two independent decisions about two different tables, and one of them changing later should not have to be
    /// untangled from the other first. What they do share is the sentence above, so a call site reads the same way
    /// whichever it is asking about.
    static func colourSelection(clicked colourID: Int, selected selectedColourID: Int) -> Int {
        colourID == selectedColourID ? noColour : colourID
    }

    /// The `colour_id` meaning no colour at all, which is what every category starts with. The seeded *None* row,
    /// which is a real row rather than a null, so the foreign key holds when a colour is cleared.
    static let noColour = 0

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
        guard let namesake = matches.first(where: { $0.isCategoryActive && $0.id != category.id }) else {
            return .reinstate
        }
        return .refuse(activeNamesake: namesake)
    }

    /// What a row says about why nothing on it can be changed. `nil` when it can.
    ///
    /// Every control in the row carries this, rather than one of them: whichever is reached for first is the one that
    /// has to explain itself, and a disabled control with no reason is a control that looks broken.
    static func editRefusalHelp(_ refusal: EditRefusal?, categoryName: String) -> String? {
        switch refusal {
        case nil:
            return nil
        case let .lockedFaces(faces):
            let list = faces.map(String.init).joined(separator: ", ")
            let subject = faces.count == 1 ? "Face \(list) is" : "Faces \(list) are"
            let object = faces.count == 1 ? "it" : "them"
            // Names the face, because the row gives no clue which one is in the way.
            return "\(subject) locked and still holding \"\(categoryName)\". Unlock \(object) on the Faces tab to "
                + "change this category."
        }
    }
}
