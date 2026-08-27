@testable import FacetApp
import XCTest

/// Covers `CategoryRenameRules`: what a typed name means, and what the dialogue about it offers.
///
/// The edges are the point, as they are for creating: a name that only differs by case matches the row being renamed
/// and is not a collision, and a name held by a retired category is allowed while one held by an active category is
/// not.
final class CategoryRenameRulesTests: XCTestCase {
    private func category(_ id: Int, _ name: String, active: Bool = true) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: nil,
            colourID: 0,
            colour: nil,
            usesWhiteLines: false,
            dailyLimitMinutes: 0,
            isCategoryActive: active
        )
    }

    private func decision(_ typed: String, current: CategoryRecord, matches: [CategoryRecord] = []) -> CategoryRenameRules.Decision {
        CategoryRenameRules.decision(rawName: typed, current: current, matching: { _ in matches })
    }

    // MARK: - nothing to do

    func testAnEmptyNameChangesNothing() {
        XCTAssertEqual(decision("   ", current: category(1, "Break")), .ignore)
    }

    func testTheSameNameChangesNothing() {
        // Not a rename, and so not a dialogue: the field was opened and closed again.
        XCTAssertEqual(decision("Break", current: category(1, "Break")), .ignore)
    }

    func testSpacingIsTidiedBeforeAnythingIsDecided() {
        // The same normalising the create control uses, so the two ways a name reaches the table cannot disagree
        // about what counts as the same name.
        XCTAssertEqual(decision("  Break  ", current: category(1, "Break")), .ignore)
        XCTAssertEqual(decision(" Deep  work ", current: category(1, "Break")), .confirm(name: "Deep work"))
    }

    // MARK: - a free name

    func testAFreeNameIsStillConfirmed() {
        // Every rename is confirmed, because of what it does to what is already recorded.
        XCTAssertEqual(decision("Admin", current: category(1, "Break")), .confirm(name: "Admin"))
    }

    func testTheWarningSaysBothHalvesOfWhatARenameDoes() throws {
        let message = try XCTUnwrap(
            CategoryRenameRules.message(for: .confirm(name: "Admin"), currentName: "Break")
        )

        XCTAssertTrue(message.contains("keeps all of its history"), "nothing recorded is lost")
        XCTAssertTrue(message.contains("before the rename"), "and old reports change too")
        XCTAssertTrue(message.contains("Break"))
        XCTAssertTrue(message.contains("Admin"))
    }

    func testCorrectingTheCaseOfItsOwnNameIsARenameRatherThanACollision() {
        // The lookup is COLLATE NOCASE, so this finds the row being renamed. Comparing ids is the only thing between
        // that and the app refusing a name because the row already holds it.
        let current = category(1, "meeting")

        XCTAssertEqual(
            decision("Meeting", current: current, matches: [current]),
            .confirm(name: "Meeting")
        )
    }

    // MARK: - a name somebody else holds

    func testAnActiveNamesakeIsADeadEnd() {
        let other = category(9, "Admin")

        XCTAssertEqual(
            decision("Admin", current: category(1, "Break"), matches: [other]),
            .refuse(activeNamesake: other)
        )
    }

    func testTheDeadEndOffersNothingButCancel() throws {
        let decision = CategoryRenameRules.Decision.refuse(activeNamesake: category(9, "Admin"))

        XCTAssertEqual(CategoryRenameRules.choices(for: decision), [.cancel])
        let message = try XCTUnwrap(CategoryRenameRules.message(for: decision, currentName: "Break"))
        XCTAssertTrue(message.contains("Admin"), "the row in the way is named, since a refusal cannot say which")
    }

    // MARK: - renaming a retired category

    func testARetiredRowMayTakeAnActiveNameBecauseTheIndexOnlyCoversActiveOnes() {
        // `UN1_category` is `WHERE active = 1`, so this write is one the table accepts. Refusing it would be the app
        // inventing a constraint the database does not have -- and inventing it exactly where somebody is most likely
        // to be untangling two rows that read the same.
        let holder = category(9, "Admin")

        XCTAssertEqual(
            decision("Admin", current: category(1, "Old", active: false), matches: [holder]),
            .confirmAgainstActive(name: "Admin", activeNamesake: holder)
        )
    }

    func testTheSameNameFromAnActiveRowIsStillADeadEnd() {
        // The one difference between this and the case above is which row is being renamed, and it is the whole
        // difference: the index throws this write out and takes the other.
        let holder = category(9, "Admin")

        XCTAssertEqual(
            decision("Admin", current: category(1, "Old", active: true), matches: [holder]),
            .refuse(activeNamesake: holder)
        )
    }

    func testTakingAnActiveNameSaysWhatItCostsAndOffersAWayOut() throws {
        let decision = CategoryRenameRules.Decision.confirmAgainstActive(
            name: "Admin", activeNamesake: category(9, "Admin")
        )

        // Two buttons, not one: this is a decision, where `refuse` is only an announcement.
        XCTAssertEqual(CategoryRenameRules.choices(for: decision), [.cancel, .renameAnyway])

        let message = try XCTUnwrap(CategoryRenameRules.message(for: decision, currentName: "Old"))
        XCTAssertTrue(message.contains("Admin"), "the active row holding the name is named")
        // The consequence, which is the only reason this is confirmed rather than simply done: the row cannot come
        // back while it shares the name.
        XCTAssertTrue(message.contains("brought back"), "says reinstating is what this blocks")
        XCTAssertTrue(message.contains("Renaming either of them"), "and how to undo it")
        // The history caveat rides along, as it does on every other rename: a retired category's entries are still in
        // the reports, so they change name too.
        XCTAssertTrue(message.contains("history"), "the history warning is not dropped for a retired row")
    }

    func testTakingAnActiveNameIsNotDescribedAsTaken() throws {
        // The refusal's wording would be a lie here. Worth pinning, because the two dialogues are one word apart and
        // the wrong one reads as the app having refused something it in fact did.
        let decision = CategoryRenameRules.Decision.confirmAgainstActive(
            name: "Admin", activeNamesake: category(9, "Admin")
        )

        let title = try XCTUnwrap(CategoryRenameRules.title(for: decision))
        XCTAssertNotEqual(title, CategoryRenameRules.title(for: .refuse(activeNamesake: category(9, "Admin"))))
        let message = try XCTUnwrap(CategoryRenameRules.message(for: decision, currentName: "Old"))
        XCTAssertFalse(message.contains("this name is taken"))
    }

    func testARetiredRowRenamedToAFreeNameIsAnOrdinaryConfirmation() {
        // Nothing about being retired makes a rename special on its own. The dialogue only changes when something
        // else holds the name.
        XCTAssertEqual(
            decision("Reading", current: category(1, "Old", active: false)),
            .confirm(name: "Reading")
        )
    }

    func testARetiredRowRenamedOntoOtherRetiredOnesIsTheSameAsAnywhereElse() {
        // Which is the case this feature is really for: several retired rows share a name and one of them is being
        // given its own.
        let others = [category(9, "Timer 1", active: false), category(12, "Timer 1", active: false)]

        XCTAssertEqual(
            decision("Timer 1", current: category(1, "Old", active: false), matches: others),
            .confirmAgainstRetired(name: "Timer 1", retired: others)
        )
    }

    func testARetiredNamesakeIsAllowedAndSaidOutLoud() {
        let retired = category(9, "Admin", active: false)

        XCTAssertEqual(
            decision("Admin", current: category(1, "Break"), matches: [retired]),
            .confirmAgainstRetired(name: "Admin", retired: [retired])
        )
    }

    func testSeveralRetiredNamesakesAreCounted() throws {
        let retired = [category(9, "Admin", active: false), category(12, "Admin", active: false)]

        let decision = decision("Admin", current: category(1, "Break"), matches: retired)
        XCTAssertEqual(decision, .confirmAgainstRetired(name: "Admin", retired: retired))

        let message = try XCTUnwrap(CategoryRenameRules.message(for: decision, currentName: "Break"))
        XCTAssertTrue(message.contains("There are 2 inactive categories"), message)
        // The history warning rides along rather than following in a second dialogue: both facts are about one
        // decision.
        XCTAssertTrue(message.contains("keeps all of its history"))
    }

    func testOneRetiredNamesakeReadsAsOne() throws {
        let message = try XCTUnwrap(
            CategoryRenameRules.message(
                for: .confirmAgainstRetired(name: "Admin", retired: [category(9, "Admin", active: false)]),
                currentName: "Break"
            )
        )

        XCTAssertTrue(message.contains("There is one inactive category"), message)
    }

    // MARK: - the buttons

    func testEveryDialogueCanBeCancelled() {
        for decision in [
            CategoryRenameRules.Decision.confirm(name: "Admin"),
            .confirmAgainstRetired(name: "Admin", retired: [category(9, "Admin", active: false)]),
            .refuse(activeNamesake: category(9, "Admin")),
        ] {
            XCTAssertEqual(
                CategoryRenameRules.choices(for: decision).first, .cancel,
                "and it leads, so Return dismisses the question rather than agreeing with it"
            )
        }
    }

    func testCancelLeadsAndTheRenameButtonSaysWhatItIsAgreeingTo() {
        // Cancel first, so it is the rightmost and default button: the answer that changes nothing is the one to
        // arrive at by accident.
        XCTAssertEqual(
            CategoryRenameRules.choices(for: .confirm(name: "Admin")).map(\.buttonTitle),
            ["Cancel", "Rename"]
        )
        // "anyway", because this one is agreeing to two categories with one name.
        XCTAssertEqual(
            CategoryRenameRules.choices(
                for: .confirmAgainstRetired(name: "Admin", retired: [category(9, "Admin", active: false)])
            ).map(\.buttonTitle),
            ["Cancel", "Rename anyway"]
        )
    }

    func testOnlyCancelWritesNothing() {
        XCTAssertTrue(CategoryRenameRules.Choice.rename.isRename)
        XCTAssertTrue(CategoryRenameRules.Choice.renameAnyway.isRename)
        XCTAssertFalse(CategoryRenameRules.Choice.cancel.isRename)
    }

    func testAnAnswerIsTurnedBackIntoTheChoiceThatWasOffered() {
        let choices = CategoryRenameRules.choices(for: .confirm(name: "Admin"))

        XCTAssertEqual(CategoryRenameRules.choice(forButtonIndex: 0, offering: choices), .cancel)
        XCTAssertEqual(CategoryRenameRules.choice(forButtonIndex: 1, offering: choices), .rename)
        XCTAssertNil(CategoryRenameRules.choice(forButtonIndex: 2, offering: choices), "no button of ours")
    }

    func testNothingIsAskedWhenThereIsNothingToDo() {
        XCTAssertNil(CategoryRenameRules.title(for: .ignore))
        XCTAssertNil(CategoryRenameRules.message(for: .ignore, currentName: "Break"))
        XCTAssertTrue(CategoryRenameRules.choices(for: .ignore).isEmpty)
    }
}
