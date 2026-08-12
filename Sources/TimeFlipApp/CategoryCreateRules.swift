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
        /// A single retired category holds the name, so bring that one back rather than making a second
        /// row with the same name and none of its history.
        case reactivate(CategoryRecord)
        /// An active category already holds the name. There is nothing to decide, only something to say.
        case alreadyActive(CategoryRecord)
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
        if first.isActive { return .alreadyActive(first) }
        // Several retired namesakes, each with its own history: bringing one back would mean picking
        // blind, since nothing distinguishes them here. Creating alongside them is still allowed -- only
        // an *active* namesake bars a name.
        if matches.count > 1 { return .insert(name: name) }
        return .reactivate(first)
    }
}
