import Foundation

/// Every decision the Categories tab makes, with none of the SwiftUI it makes them in.
///
/// These all used to be `private` methods and `private enum`s on `CategoriesSettingsView`,
/// `CategoryRow` and `CategoryCreateControl`. They were already pure -- name in, decision out, no
/// view state read or written -- but nothing outside those views could call them, so the tab's most
/// error-prone logic (which of three collision outcomes a name produces) had no test that could
/// reach it. Lifting them here changes no behaviour; it only makes them addressable.
///
/// What stayed behind in the views is everything that is genuinely about presentation: raising the
/// alert, the debug lines, writing to the store, leaving edit mode. A rule here decides *what*
/// should happen and the view carries it out.
enum CategoryEditRules {

    // MARK: - Creating

    /// What a Save on the create control should do.
    ///
    /// The name is normalised before the lookup, so a trailing space cannot slip a duplicate past
    /// the collision check.
    ///
    /// Takes every match rather than the first, because how many there are changes the answer. One
    /// retired namesake can be offered back; several cannot, since nothing on screen says which is
    /// which and picking for the user would mean reinstating whichever the query happened to sort
    /// first. That case sends them to the Inactive list, where the rows are individually tickable.
    static func createDecision(
        rawName: String,
        findCategories: (String) -> [CategoryRecord]
    ) -> CategoryCreateDecision {
        let name = ActivityLibrary.normalizeCategoryName(rawName)
        guard !name.isEmpty else { return .ignore }
        let matches = findCategories(name)
        guard let first = matches.first else { return .insert(name: name) }
        // At most one match can be active, and `findCategories` sorts it first.
        if first.isActive { return .conflict(.active(existing: first, name: name)) }
        if matches.count > 1 { return .conflict(.ambiguousInactive(retired: matches, name: name)) }
        return .conflict(.inactive(existing: first, name: name))
    }

    // MARK: - Renaming

    /// What a Save on an inline rename should do.
    ///
    /// A name matching the row being renamed is not a collision: `findCategory` matches
    /// `COLLATE NOCASE`, so correcting "meeting" to "Meeting" finds the row itself, and the id
    /// comparison is the only thing standing between that and the app refusing a name because the
    /// row already holds it.
    static func renameDecision(
        rawName: String,
        currentName: String,
        currentID: Int,
        findCategory: (String) -> CategoryRecord?
    ) -> CategoryRenameDecision {
        let name = ActivityLibrary.normalizeCategoryName(rawName)
        guard !name.isEmpty, name != currentName else { return .ignore }
        if let existing = findCategory(name), existing.id != currentID {
            return .confirm(
                existing.isActive
                    ? .activeCollision(existing: existing, newName: name)
                    : .inactiveCollision(existing: existing, newName: name)
            )
        }
        return .confirm(.plain(newName: name))
    }

    // MARK: - Row edits

    /// The `icon_id` a click on the icon grid should store. Re-clicking the selected icon clears it
    /// to 0, which is how a grid with no None cell still lets an icon be unset.
    static func iconSelection(clicked iconID: Int, selected selectedIconID: Int) -> Int {
        iconID == selectedIconID ? 0 : iconID
    }

    /// The daily limit a typed value should store, or `nil` when there is nothing to write.
    ///
    /// Negatives clamp to 0 rather than being rejected, and a value equal to what is already stored
    /// writes nothing -- otherwise every visit to the field would log a change that did not happen.
    static func dailyLimitWrite(typed: Int, current: Int) -> Int? {
        let clamped = max(0, typed)
        return clamped == current ? nil : clamped
    }

    // MARK: - The loaded list

    /// The two sections the tab draws, split from the one list it loads.
    static func partitioned(
        _ categories: [CategoryRecord]
    ) -> (active: [CategoryRecord], inactive: [CategoryRecord]) {
        (categories.filter(\.isActive), categories.filter { !$0.isActive })
    }

    /// The list with one row replaced, leaving every other row identical and order untouched. An id
    /// that is not in the list yields the list unchanged.
    ///
    /// Patching rather than re-reading is what moves a row between the Active and Inactive sections
    /// the instant its checkbox changes: the sections are `partitioned` from this one list, so
    /// rewriting the row re-partitions it.
    static func patching(
        _ categories: [CategoryRecord],
        id categoryID: Int,
        _ transform: (CategoryRecord) -> CategoryRecord
    ) -> [CategoryRecord] {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else {
            return categories
        }
        var patched = categories
        patched[index] = transform(patched[index])
        return patched
    }
}

// MARK: - Decisions

enum CategoryCreateDecision: Equatable {
    /// Nothing to do: the name is empty once normalised, so Save is a no-op.
    case ignore
    case insert(name: String)
    case conflict(CategoryNameConflict)
}

enum CategoryRenameDecision: Equatable {
    /// Nothing to do: the name is empty once normalised, or unchanged.
    case ignore
    case confirm(CategoryRenameConfirmation)
}

/// What a Save on the create control collided with, and everything its alert needs to describe it.
enum CategoryNameConflict: Equatable, Identifiable {
    /// The name is already in use by a category still in the Active list. Nothing to decide, it is
    /// simply there to be found.
    case active(existing: CategoryRecord, name: String)
    /// The name belongs to a retired category. Reinstating it keeps every historical `time_entry`
    /// attached to the name; creating a second one does not.
    case inactive(existing: CategoryRecord, name: String)
    /// The name belongs to *several* retired categories. Creating another is still allowed, since
    /// only one active row per name is barred, but reinstating cannot be offered here: the alert
    /// has nothing to tell the rows apart by, so choosing one would mean choosing blind.
    case ambiguousInactive(retired: [CategoryRecord], name: String)

    /// The row the typed name collided with, when there is a single one to name. `nil` for
    /// `ambiguousInactive`, which is that case precisely because there is not.
    var existing: CategoryRecord? {
        switch self {
        case .active(let existing, _), .inactive(let existing, _): return existing
        case .ambiguousInactive: return nil
        }
    }

    /// What was typed, normalised. Not the same as `existing.name`: the lookup is `COLLATE NOCASE`,
    /// so "meeting" can collide with "Meeting". The alerts name the row that already exists, the
    /// debug lines record what was actually typed.
    var attemptedName: String {
        switch self {
        case .active(_, let name), .inactive(_, let name), .ambiguousInactive(_, let name):
            return name
        }
    }

    var id: String {
        switch self {
        case .active(let existing, _): return "active:\(existing.name)"
        case .inactive(_, let name): return "inactive:\(name)"
        case .ambiguousInactive(let retired, let name): return "ambiguous:\(name):\(retired.count)"
        }
    }

    var message: String {
        switch self {
        case .active(let existing, _):
            return """
            "\(existing.name)" is already in the Active list. Scroll up -- it is right there.
            """
        case .inactive(_, let name):
            return """
            "\(name)" already exists but has been made inactive.

            Reactivating it keeps all of its history attached. Creating a second category \
            with the same name leaves you two rows that look identical in reports, and \
            sorting that out later is on you.
            """
        case .ambiguousInactive(let retired, let name):
            return """
            \(retired.count) inactive categories are called "\(name)", each with its own history, \
            so this cannot offer to bring one back without guessing which you meant.

            To reinstate a particular one, tick its Active box in the Inactive list. Creating a \
            new category with this name is still fine.
            """
        }
    }
}

/// What a Save on an inline rename raised. Mirrors the create flow's collision handling: a name
/// already in use by an active category is a dead end, an inactive one is an "are you sure", with
/// the plain history warning when the name is free.
enum CategoryRenameConfirmation: Equatable, Identifiable {
    case plain(newName: String)
    case activeCollision(existing: CategoryRecord, newName: String)
    case inactiveCollision(existing: CategoryRecord, newName: String)

    /// What was typed, normalised. As with `CategoryNameConflict.attemptedName`, this differs from
    /// `existing.name` whenever the `COLLATE NOCASE` lookup matched on case alone.
    var attemptedName: String {
        switch self {
        case .plain(let name), .activeCollision(_, let name), .inactiveCollision(_, let name):
            return name
        }
    }

    var id: String {
        switch self {
        case .plain(let name): return "plain:\(name)"
        case .activeCollision(let existing, _): return "active:\(existing.name)"
        case .inactiveCollision(_, let name): return "inactive:\(name)"
        }
    }

    var title: String {
        switch self {
        case .plain: return "Rename this category?"
        case .activeCollision, .inactiveCollision: return "That category already exists"
        }
    }

    /// The history caveat rides along with the inactive case rather than following it in a second
    /// dialog: both facts are about the same single decision, and stacking two alerts to agree to
    /// one rename is worse than one alert that says both.
    func message(currentName: String) -> String {
        switch self {
        case .plain(let newName):
            return Self.historyWarning(currentName: currentName, newName: newName)
        case .activeCollision(let existing, _):
            return """
            "\(existing.name)" is already in the Active list, so this name is taken.
            """
        case .inactiveCollision(_, let newName):
            return """
            "\(newName)" already exists as an inactive category. Renaming to it leaves two \
            categories with that name, and sorting them apart in reports later is on you. Do \
            you really want to do this?

            \(Self.historyWarning(currentName: currentName, newName: newName))
            """
        }
    }

    private static func historyWarning(currentName: String, newName: String) -> String {
        """
        "\(currentName)" keeps all of its history -- nothing recorded against it is lost.

        But everything links to this category by id rather than by name, so reports covering \
        time before the rename will show "\(newName)" too, not the name that was in use then.
        """
    }
}
