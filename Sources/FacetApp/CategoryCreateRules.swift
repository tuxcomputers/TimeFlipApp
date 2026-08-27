import Foundation

/// What saving a typed category name should do.
///
/// A rule with no view and no database in it: a name and whatever categories already hold that name go
/// in, a decision comes out. The previous app learned this the hard way -- these decisions lived as
/// private methods inside a SwiftUI view, which made the most error-prone logic in the tab unreachable
/// by any test.
enum CategoryCreateRules {
    enum Decision: Equatable {
        /// Nothing typed. Not an error, and not worth an alert -- just nothing to do.
        case ignore
        /// Insert a new category under this name.
        case insert(name: String)
        /// Retired categories hold the name, and there is at least one. **What to do about that is the user's to
        /// say**, not this rule's: bringing an old one back keeps its history, and making a new one leaves that
        /// history where it is under a name being reused deliberately. Both are legitimate and nothing here can tell
        /// which was meant.
        ///
        /// All of them are carried, not just the first, because **how many there are changes what can be offered**:
        /// with one there is an "the old one" to bring back, and with several there is not -- see
        /// `choices(retiredNamesakes:)`. Never empty.
        case retiredNamesakes([CategoryRecord])
        /// An active category already holds the name. There is nothing to decide, only something to say.
        case alreadyActive(CategoryRecord)
    }

    /// What the dialogue about a retired namesake can end in.
    ///
    /// **The order is the order the buttons are added**, which on this platform means the first is the default and
    /// sits rightmost. Reactivate leads because it is the answer that keeps the history, and it is what typing a name
    /// somebody used before usually means; Cancel is last, and the only one that changes nothing.
    enum RetiredNamesakeChoice: String, Equatable, CaseIterable {
        case reactivate
        case createNew
        case cancel

        var buttonTitle: String {
            switch self {
            case .reactivate: return "Reactivate"
            case .createNew: return "Create new one"
            case .cancel: return "Cancel"
            }
        }
    }

    /// The buttons the dialogue offers, in the order they are drawn.
    ///
    /// **Reactivate is absent once there is more than one retired namesake**, because there is no answer to *which*
    /// one to bring back: they share a name and nothing on the button distinguishes them. Offering it would mean the
    /// app picking one on the user's behalf, which is the thing it cannot know. Creating a new one is unaffected --
    /// only an *active* namesake bars a name -- so that button stays, and Cancel with it.
    static func choices(retiredNamesakes count: Int) -> [RetiredNamesakeChoice] {
        count == 1 ? [.reactivate, .createNew, .cancel] : [.createNew, .cancel]
    }

    /// What the dialogue says. The name is quoted, as it is in every other message this window shows, so a name with
    /// a space in it cannot be misread as part of the sentence.
    static func retiredNamesakeMessage(name: String) -> String {
        "The category \"\(name)\" already exists as a deactivated category"
    }

    /// How many of them there are, said out loud under the message.
    ///
    /// **Because the count is also the reason a button is missing.** With more than one there is no Reactivate to
    /// offer, and a dialogue that quietly presented fewer choices than it did last time would read as a bug rather
    /// than as an answer nobody can give.
    static func retiredNamesakeCount(_ count: Int) -> String {
        count == 1
            ? "There is one category with the same name."
            : "There are \(count) categories with the same name."
    }

    /// Which choice a button at `index` is, given the buttons that were offered. `nil` for an index none of them
    /// occupies.
    ///
    /// Turning an answer back into a choice lives here rather than at the alert, and takes the same list the buttons
    /// were built from, so the order on screen and the meaning of the answer cannot drift apart -- including when
    /// the list is the shorter one.
    static func choice(forButtonIndex index: Int, offering choices: [RetiredNamesakeChoice]) -> RetiredNamesakeChoice? {
        guard choices.indices.contains(index) else { return nil }
        return choices[index]
    }

    /// Collapses whitespace, so a trailing space cannot slip a duplicate past the check that follows and
    /// two categories cannot differ only by how they were typed.
    static func normalise(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `matching` is asked for **every** category holding the normalised name, active one first (see
    /// `CategoryStore.matching`), because how many there are changes the answer.
    static func decision(rawName: String, matching: (String) -> [CategoryRecord]) -> Decision {
        let name = normalise(rawName)
        guard !name.isEmpty else { return .ignore }

        let matches = matching(name)
        guard let first = matches.first else { return .insert(name: name) }
        // At most one match can be active, and the ordering puts it first.
        if first.isCategoryActive { return .alreadyActive(first) }
        // Every retired namesake, however many. Several of them used to insert outright, on the grounds that
        // bringing one back would mean picking blind -- true, and not a reason to make the decision silently:
        // creating alongside them is one of two answers, and the other is to go and look at the Inactive list.
        return .retiredNamesakes(matches)
    }
}
