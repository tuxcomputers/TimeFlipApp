import Foundation

/// What renaming a category should do, and what the dialogue about it says.
///
/// A rule with no view and no database in it, as `CategoryCreateRules` is: the typed name, the name it is replacing
/// and whatever categories already hold the typed one go in, a decision comes out.
///
/// **Every rename is confirmed, even when the name is free.** That is the previous app's decision and the reason
/// survives inspection: every table references a category by `category_id`, so a rename carries backwards as well as
/// forwards -- a report covering last month will show the new name, not the one that was in use then. Nothing is lost
/// and nothing needs backfilling, but it is not what somebody necessarily expects, so it is said before rather than
/// discovered after.
enum CategoryRenameRules {
    enum Decision: Equatable {
        /// Nothing typed, or nothing changed. Not an error, and not worth a dialogue.
        case ignore
        /// The name is free. Confirm it, because of what a rename does to history.
        case confirm(name: String)
        /// Retired categories hold the name. **Allowed**, only one *active* name being unique, and worth saying out
        /// loud: it leaves two categories with one name and separate histories behind them. Never empty.
        case confirmAgainstRetired(name: String, retired: [CategoryRecord])
        /// An active category already holds the name. There is nothing to decide, only something to say.
        case refuse(activeNamesake: CategoryRecord)
    }

    /// What a dialogue about a rename can end in. **The order is the order the buttons are added**, which on this
    /// platform means the first is the default and sits rightmost -- see `choices(for:)`, where Cancel takes that
    /// place.
    enum Choice: String, Equatable {
        case rename
        /// The same answer as `rename`, under a title that says the name is already in use. A separate case so a
        /// button that means "yes, and I know what I am doing" cannot be built from the wording for one that does not.
        case renameAnyway
        case cancel

        var buttonTitle: String {
            switch self {
            case .rename: return "Rename"
            case .renameAnyway: return "Rename anyway"
            case .cancel: return "Cancel"
            }
        }

        /// Whether this answer writes anything.
        var isRename: Bool { self != .cancel }
    }

    /// The buttons a decision offers, in the order they are drawn. Empty for the decisions that raise no dialogue.
    ///
    /// **Cancel leads**, which on this platform makes it the rightmost button and the default one, so Return dismisses
    /// the dialogue rather than agreeing with it. That is the right way round for a question about changing something
    /// already recorded: the answer that changes nothing is the one to arrive at by accident.
    ///
    /// **It is on every one of them**, including the dead end, where it is the only button: a dialogue that can only
    /// be agreed with is a dialogue that has taken the decision already.
    static func choices(for decision: Decision) -> [Choice] {
        switch decision {
        case .ignore: return []
        case .confirm: return [.cancel, .rename]
        case .confirmAgainstRetired: return [.cancel, .renameAnyway]
        case .refuse: return [.cancel]
        }
    }

    /// Which choice a button at `index` is, given the buttons that were offered. `nil` for an index none occupies.
    static func choice(forButtonIndex index: Int, offering choices: [Choice]) -> Choice? {
        guard choices.indices.contains(index) else { return nil }
        return choices[index]
    }

    /// The heading of the dialogue. `nil` when there is none to raise.
    static func title(for decision: Decision) -> String? {
        switch decision {
        case .ignore: return nil
        case .confirm: return "Rename this category?"
        case .confirmAgainstRetired: return "That category already exists"
        case .refuse: return "That name is already in use"
        }
    }

    /// What the dialogue says, under its heading. `nil` when there is none to raise.
    ///
    /// **The history caveat rides along with the retired case rather than following it in a second dialogue**: both
    /// facts are about one decision, and stacking two alerts to agree to one rename is worse than one alert saying
    /// both. The previous app's reasoning, kept.
    static func message(for decision: Decision, currentName: String) -> String? {
        switch decision {
        case .ignore:
            return nil

        case let .confirm(name):
            return historyWarning(currentName: currentName, newName: name)

        case let .confirmAgainstRetired(name, retired):
            return """
            \(retiredCount(retired.count, name: name)) Renaming to it leaves two categories with that name, and \
            telling them apart in a report later is on you.

            \(historyWarning(currentName: currentName, newName: name))
            """

        case let .refuse(existing):
            return """
            An active category is already called "\(existing.name)", so this name is taken.

            Rename that one first, or pick another name.
            """
        }
    }

    /// How many retired categories hold the name, said out loud. The same sentence shape the create dialogue uses, so
    /// one fact reads the same way wherever it is met.
    private static func retiredCount(_ count: Int, name: String) -> String {
        count == 1
            ? "There is one inactive category called \"\(name)\"."
            : "There are \(count) inactive categories called \"\(name)\"."
    }

    /// What a rename does to everything already recorded. Both halves matter: nothing is lost, and the old reports
    /// change too.
    private static func historyWarning(currentName: String, newName: String) -> String {
        """
        "\(currentName)" keeps all of its history -- nothing recorded against it is lost.

        But everything links to a category by its id rather than by its name, so reports covering time before the \
        rename will show "\(newName)" too, not the name that was in use then.
        """
    }

    /// What renaming `current` to `rawName` should do.
    ///
    /// The name is normalised first, by `CategoryCreateRules.normalise`, so the two ways a name reaches the table
    /// cannot disagree about what counts as the same name.
    ///
    /// **A row matching its own name is not a collision.** The lookup is `COLLATE NOCASE`, so correcting "meeting" to
    /// "Meeting" finds the row being renamed, and comparing ids is the only thing between that and the app refusing a
    /// name because the row already holds it. That correction still goes through the confirmation: it is a real write,
    /// and every rename is confirmed.
    ///
    /// - Parameters:
    ///   - current: the category being renamed.
    ///   - matching: asked for **every** category holding the normalised name, active one first (see
    ///     `CategoryStore.matching`).
    static func decision(
        rawName: String,
        current: CategoryRecord,
        matching: (String) -> [CategoryRecord]
    ) -> Decision {
        let name = CategoryCreateRules.normalise(rawName)
        guard !name.isEmpty, name != current.name else { return .ignore }

        let others = matching(name).filter { $0.id != current.id }
        guard let first = others.first else { return .confirm(name: name) }
        // At most one can be active, and the ordering puts it first.
        if first.isActive { return .refuse(activeNamesake: first) }
        return .confirmAgainstRetired(name: name, retired: others)
    }
}
