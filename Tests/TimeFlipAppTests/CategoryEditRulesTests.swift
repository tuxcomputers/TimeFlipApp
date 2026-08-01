@testable import TimeFlipApp
import XCTest

/// The Categories tab's decisions, tested without a window.
///
/// These were `private` on `CategoriesSettingsView`, `CategoryRow` and `CategoryCreateControl`
/// until they moved to `CategoryEditRules`. Nothing about what they decide changed in the move, so
/// these are the first tests the behaviour has ever had rather than a re-check of something already
/// covered elsewhere.
///
/// The lookups are closures on every rule, which is what makes them testable at all: the real ones
/// hit SQLite `COLLATE NOCASE`, and the stubs here match case-insensitively for the same reason.

/// Case-insensitive like the SQL, and ordered like `findCategories`: active first, then oldest.
private func matching(_ rows: [CategoryRecord], _ name: String) -> [CategoryRecord] {
    rows.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        .sorted { lhs, rhs in
            lhs.isActive == rhs.isActive ? lhs.id < rhs.id : lhs.isActive
        }
}

final class CategoryEditRulesTests: XCTestCase {
    private func category(
        id: Int,
        _ name: String,
        active: Bool = true,
        colourID: Int = 0,
        dailyLimitMinutes: Int = 0
    ) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconID: 0,
            colourID: colourID,
            isActive: active,
            dailyLimitMinutes: dailyLimitMinutes
        )
    }

    /// Stands in for `AppDataStore.findCategory(named:)`, matching case-insensitively as that does.
    private func lookup(_ rows: [CategoryRecord]) -> (String) -> CategoryRecord? {
        { name in matching(rows, name).first }
    }

    /// Stands in for `AppDataStore.findCategories(named:)`, in the same order: the active row
    /// first, then the retired ones oldest first.
    private func lookupAll(_ rows: [CategoryRecord]) -> (String) -> [CategoryRecord] {
        { name in matching(rows, name) }
    }

    private let findsNothing: (String) -> CategoryRecord? = { _ in nil }
    private let findsNone: (String) -> [CategoryRecord] = { _ in [] }

    // MARK: - Creating

    func testAFreeNameInserts() {
        let decision = CategoryEditRules.createDecision(rawName: "Deep work", findCategories: findsNone)

        XCTAssertEqual(decision, .insert(name: "Deep work"))
    }

    func testAnEmptyNameDoesNothing() {
        XCTAssertEqual(
            CategoryEditRules.createDecision(rawName: "   ", findCategories: findsNone),
            .ignore
        )
    }

    /// A dead end: the alert this raises offers no way to create anything, because the category the
    /// user is asking for is already in front of them.
    func testANameHeldByAnActiveCategoryIsADeadEnd() {
        let existing = category(id: 4, "Meeting")

        let decision = CategoryEditRules.createDecision(
            rawName: "Meeting",
            findCategories: lookupAll([existing])
        )

        XCTAssertEqual(decision, .conflict(.active(existing: existing, name: "Meeting")))
    }

    func testANameHeldByAnInactiveCategoryOffersTheReinstateChoice() {
        let existing = category(id: 7, "Standup", active: false)

        let decision = CategoryEditRules.createDecision(
            rawName: "Standup",
            findCategories: lookupAll([existing])
        )

        XCTAssertEqual(decision, .conflict(.inactive(existing: existing, name: "Standup")))
    }

    /// Normalisation happens before the lookup, so padding cannot walk a duplicate past the check.
    func testTheNameIsNormalisedBeforeTheCollisionCheck() {
        let existing = category(id: 4, "Meeting")

        let decision = CategoryEditRules.createDecision(
            rawName: "  Meeting  ",
            findCategories: lookupAll([existing])
        )

        XCTAssertEqual(decision, .conflict(.active(existing: existing, name: "Meeting")))
    }

    /// The alert names the row that exists, the debug line records what was typed. They differ
    /// whenever the case-insensitive lookup matched on case alone, so the decision carries both.
    func testACollisionCarriesBothTheMatchedRowAndTheTypedName() throws {
        let existing = category(id: 4, "Meeting")

        let decision = CategoryEditRules.createDecision(
            rawName: "meeting",
            findCategories: lookupAll([existing])
        )

        guard case .conflict(let conflict) = decision else {
            return XCTFail("expected a conflict, got \(decision)")
        }
        XCTAssertEqual(conflict.existing?.name, "Meeting")
        XCTAssertEqual(conflict.attemptedName, "meeting")
    }

    /// Several retired namesakes and no active one. Reinstating cannot be offered: the alert has
    /// nothing to tell the rows apart by, so a single "reactivate" button would bring back whichever
    /// the query sorted first without saying so.
    func testSeveralRetiredNamesakesCannotBeReinstatedFromHere() {
        let older = category(id: 7, "Email", active: false)
        let newer = category(id: 9, "Email", active: false)

        let decision = CategoryEditRules.createDecision(
            rawName: "Email",
            findCategories: lookupAll([older, newer])
        )

        XCTAssertEqual(decision, .conflict(.ambiguousInactive(retired: [older, newer], name: "Email")))
    }

    /// An active namesake outranks any number of retired ones: the name is simply taken, and that is
    /// the dead end, not the ambiguity.
    func testAnActiveNamesakeWinsOverRetiredOnes() {
        let active = category(id: 4, "Email")
        let retired = [category(id: 7, "Email", active: false), category(id: 9, "Email", active: false)]

        let decision = CategoryEditRules.createDecision(
            rawName: "Email",
            findCategories: lookupAll(retired + [active])
        )

        XCTAssertEqual(decision, .conflict(.active(existing: active, name: "Email")))
    }

    /// The ambiguous case has no single row to name, unlike the other two.
    func testTheAmbiguousConflictNamesNoSingleRow() {
        let retired = [category(id: 7, "Email", active: false), category(id: 9, "Email", active: false)]
        let conflict = CategoryNameConflict.ambiguousInactive(retired: retired, name: "Email")

        XCTAssertNil(conflict.existing)
        XCTAssertEqual(conflict.attemptedName, "Email")
        XCTAssertTrue(conflict.message.contains("2 inactive categories"), conflict.message)
        XCTAssertTrue(conflict.message.contains("Inactive list"), conflict.message)
    }

    // MARK: - Renaming

    func testRenamingToTheSameNameDoesNothing() {
        XCTAssertEqual(
            CategoryEditRules.renameDecision(
                rawName: "Meeting",
                currentName: "Meeting",
                currentID: 4,
                findCategory: findsNothing
            ),
            .ignore
        )
    }

    func testRenamingToAnEmptyNameDoesNothing() {
        XCTAssertEqual(
            CategoryEditRules.renameDecision(
                rawName: "  ",
                currentName: "Meeting",
                currentID: 4,
                findCategory: findsNothing
            ),
            .ignore
        )
    }

    /// The case correction that would otherwise collide with itself. `findCategory` is
    /// `COLLATE NOCASE`, so looking up "Meeting" from the row named "meeting" returns that same
    /// row, and only the id comparison stops the app refusing a name because it already holds it.
    func testFixingTheCapitalisationOfARowsOwnNameIsNotACollision() {
        let itself = category(id: 4, "meeting")

        let decision = CategoryEditRules.renameDecision(
            rawName: "Meeting",
            currentName: "meeting",
            currentID: 4,
            findCategory: lookup([itself])
        )

        XCTAssertEqual(decision, .confirm(.plain(newName: "Meeting")))
    }

    func testRenamingOntoAnActiveCategoryIsADeadEnd() {
        let other = category(id: 9, "Email")

        let decision = CategoryEditRules.renameDecision(
            rawName: "Email",
            currentName: "Meeting",
            currentID: 4,
            findCategory: lookup([other])
        )

        XCTAssertEqual(decision, .confirm(.activeCollision(existing: other, newName: "Email")))
    }

    func testRenamingOntoAnInactiveCategoryOffersRenameAnyway() {
        let other = category(id: 9, "Email", active: false)

        let decision = CategoryEditRules.renameDecision(
            rawName: "Email",
            currentName: "Meeting",
            currentID: 4,
            findCategory: lookup([other])
        )

        XCTAssertEqual(decision, .confirm(.inactiveCollision(existing: other, newName: "Email")))
    }

    func testAFreeNameRaisesThePlainHistoryWarning() throws {
        let decision = CategoryEditRules.renameDecision(
            rawName: "Client work",
            currentName: "Meeting",
            currentID: 4,
            findCategory: findsNothing
        )

        XCTAssertEqual(decision, .confirm(.plain(newName: "Client work")))
        guard case .confirm(let confirmation) = decision else {
            return XCTFail("expected a confirmation, got \(decision)")
        }
        XCTAssertEqual(confirmation.title, "Rename this category?")
        let message = confirmation.message(currentName: "Meeting")
        XCTAssertTrue(message.contains("keeps all of its history"), message)
        XCTAssertTrue(message.contains("Client work"), message)
    }

    /// The two collision titles are shared, and the inactive message has to carry the history
    /// caveat as well as the duplicate warning rather than deferring it to a second dialog.
    func testTheInactiveCollisionSaysBothThingsInOneAlert() {
        let other = category(id: 9, "Email", active: false)
        let confirmation = CategoryRenameConfirmation.inactiveCollision(existing: other, newName: "Email")

        let message = confirmation.message(currentName: "Meeting")

        XCTAssertEqual(confirmation.title, "That category already exists")
        XCTAssertTrue(message.contains("already exists as an inactive category"), message)
        XCTAssertTrue(message.contains("keeps all of its history"), message)
    }

    // MARK: - Icon grid

    func testClickingAnUnselectedIconSelectsIt() {
        XCTAssertEqual(CategoryEditRules.iconSelection(clicked: 12, selected: 3), 12)
    }

    /// The grid has no None cell, so re-clicking the selection is the only way to clear it.
    func testClickingTheSelectedIconClearsIt() {
        XCTAssertEqual(CategoryEditRules.iconSelection(clicked: 12, selected: 12), 0)
    }

    // MARK: - Daily limit

    func testANegativeDailyLimitClampsToZero() {
        XCTAssertEqual(CategoryEditRules.dailyLimitWrite(typed: -30, current: 45), 0)
    }

    func testANewDailyLimitIsWritten() {
        XCTAssertEqual(CategoryEditRules.dailyLimitWrite(typed: 90, current: 45), 90)
    }

    /// Nothing to write, and nothing to log: a debug line claiming a change that did not happen is
    /// worse than silence when reading back a run.
    func testAnUnchangedDailyLimitWritesNothing() {
        XCTAssertNil(CategoryEditRules.dailyLimitWrite(typed: 45, current: 45))
    }

    /// A negative typed against a limit already at 0 is still nothing to write, since the clamp
    /// lands on the value already stored.
    func testANegativeAgainstAnAlreadyZeroLimitWritesNothing() {
        XCTAssertNil(CategoryEditRules.dailyLimitWrite(typed: -5, current: 0))
    }

    // MARK: - Partition and patch

    func testPartitionSplitsActiveFromInactiveKeepingOrder() {
        let rows = [
            category(id: 1, "Alpha"),
            category(id: 2, "Beta", active: false),
            category(id: 3, "Gamma"),
        ]

        let split = CategoryEditRules.partitioned(rows)

        XCTAssertEqual(split.active.map(\.name), ["Alpha", "Gamma"])
        XCTAssertEqual(split.inactive.map(\.name), ["Beta"])
    }

    /// The move between sections with no re-read: patching the row re-partitions the one list both
    /// sections are drawn from.
    func testUntickingActiveMovesARowToTheInactiveSection() {
        let rows = [category(id: 1, "Alpha"), category(id: 2, "Beta")]

        let patched = CategoryEditRules.patching(rows, id: 2) { $0.with(isActive: false) }
        let split = CategoryEditRules.partitioned(patched)

        XCTAssertEqual(split.active.map(\.name), ["Alpha"])
        XCTAssertEqual(split.inactive.map(\.name), ["Beta"])
    }

    func testTickingActiveMovesARowBack() {
        let rows = [category(id: 1, "Alpha"), category(id: 2, "Beta", active: false)]

        let patched = CategoryEditRules.patching(rows, id: 2) { $0.with(isActive: true) }
        let split = CategoryEditRules.partitioned(patched)

        XCTAssertEqual(split.active.map(\.name), ["Alpha", "Beta"])
        XCTAssertTrue(split.inactive.isEmpty)
    }

    func testPatchingChangesOnlyTheNamedRowAndKeepsOrder() {
        let rows = [
            category(id: 1, "Alpha"),
            category(id: 2, "Beta"),
            category(id: 3, "Gamma"),
        ]

        let patched = CategoryEditRules.patching(rows, id: 2) { $0.with(dailyLimitMinutes: 60) }

        XCTAssertEqual(patched.map(\.id), [1, 2, 3])
        XCTAssertEqual(patched.map(\.dailyLimitMinutes), [0, 60, 0])
        XCTAssertEqual(patched[0], rows[0])
        XCTAssertEqual(patched[2], rows[2])
    }

    func testPatchingAnIDThatIsNotInTheListChangesNothing() {
        let rows = [category(id: 1, "Alpha")]

        XCTAssertEqual(CategoryEditRules.patching(rows, id: 99) { $0.with(name: "Nope") }, rows)
    }

    // MARK: - CategoryRecord.with

    /// Every edit on the tab funnels through this, and it had no test.
    func testWithReplacesOnlyTheFieldItIsGiven() {
        let original = category(id: 1, "Alpha", colourID: 2, dailyLimitMinutes: 30)

        XCTAssertEqual(original.with(name: "Renamed").name, "Renamed")
        XCTAssertEqual(original.with(name: "Renamed").colourID, 2)
        XCTAssertEqual(original.with(colourID: 5).colourID, 5)
        XCTAssertEqual(original.with(colourID: 5).name, "Alpha")
        XCTAssertEqual(original.with(iconID: 8).iconID, 8)
        XCTAssertEqual(original.with(isActive: false).isActive, false)
        XCTAssertEqual(original.with(dailyLimitMinutes: 0).dailyLimitMinutes, 0)
        XCTAssertEqual(original.with().id, 1, "the id is never replaceable")
    }
}
