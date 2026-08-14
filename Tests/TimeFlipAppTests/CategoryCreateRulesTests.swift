@testable import TimeFlipApp
import XCTest

/// Covers `CategoryCreateRules`: what a typed name should do about the categories already holding it.
///
/// No database and no view. This is the logic the previous app could not test at all, because it lived
/// inside a SwiftUI view -- and it is the logic where being wrong costs the most: the difference between
/// bringing a retired category back with its history and leaving two identical rows in every report.
final class CategoryCreateRulesTests: XCTestCase {
    private func category(_ id: Int, _ name: String, active: Bool) -> CategoryRecord {
        CategoryRecord(id: id, name: name, iconName: nil, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: active)
    }

    /// Stands in for `CategoryStore.matching`, including its guarantee that an active match sorts first.
    private func matcher(_ rows: [CategoryRecord]) -> (String) -> [CategoryRecord] {
        { name in
            rows.filter { $0.name.lowercased() == name.lowercased() }
                .sorted { $0.isActive && !$1.isActive }
        }
    }

    private func decide(_ typed: String, against rows: [CategoryRecord] = []) -> CategoryCreateRules.Decision {
        CategoryCreateRules.decision(rawName: typed, matching: matcher(rows))
    }

    // MARK: - the name itself

    func testWhitespaceIsCollapsedBeforeAnythingElse() {
        XCTAssertEqual(CategoryCreateRules.normalise("  Deep   Work "), "Deep Work")
        XCTAssertEqual(CategoryCreateRules.normalise("\tAdmin\n"), "Admin")
        XCTAssertEqual(CategoryCreateRules.normalise("   "), "")
    }

    func testANameIsCheckedInItsNormalisedForm() {
        // Otherwise a trailing space is a second category that looks identical in every list.
        XCTAssertEqual(decide("Break ", against: [category(1, "Break", active: true)]),
                       .alreadyActive(category(1, "Break", active: true)))
    }

    func testNothingTypedDoesNothing() {
        XCTAssertEqual(decide(""), .ignore)
        XCTAssertEqual(decide("   "), .ignore, "whitespace is nothing typed, not a category called space")
    }

    // MARK: - the three outcomes

    func testAFreeNameIsInserted() {
        XCTAssertEqual(decide("Deep Work", against: [category(1, "Break", active: true)]),
                       .insert(name: "Deep Work"))
    }

    func testASingleRetiredNamesakeIsAQuestionRatherThanAnAnswer() {
        // Bringing it back and creating a new one alongside it are both legitimate, and nothing here can tell which
        // was meant, so the decision names the row and stops.
        let retired = category(4, "Reading", active: false)

        XCTAssertEqual(decide("Reading", against: [retired]), .retiredNamesakes([retired]))
    }

    func testARetiredNamesakeIsFoundWhateverTheCasing() {
        // The unique index that bars a second active namesake is case-insensitive, so the check has to be.
        let retired = category(4, "Reading", active: false)

        XCTAssertEqual(decide("reading", against: [retired]), .retiredNamesakes([retired]))
    }

    // MARK: - what the dialogue about a retired namesake offers

    func testOneRetiredNamesakeOffersThreeButtonsInTheOrderTheyAreDrawn() {
        XCTAssertEqual(
            CategoryCreateRules.choices(retiredNamesakes: 1).map(\.buttonTitle),
            ["Reactivate", "Create new one", "Cancel"],
            "the first is the default and sits rightmost on this platform"
        )
    }

    func testSeveralRetiredNamesakesTakeReactivateAway() {
        // There is no answer to *which* one to bring back: they share a name, and nothing on a button distinguishes
        // them. Creating a new one is unaffected, only an active namesake barring a name.
        XCTAssertEqual(
            CategoryCreateRules.choices(retiredNamesakes: 3).map(\.buttonTitle),
            ["Create new one", "Cancel"]
        )
    }

    func testEachButtonMeansItsOwnChoice() {
        // The order on screen and the meaning of the answer are one list, so a button added in the middle cannot
        // silently repoint the others.
        let three = CategoryCreateRules.choices(retiredNamesakes: 1)
        XCTAssertEqual(CategoryCreateRules.choice(forButtonIndex: 0, offering: three), .reactivate)
        XCTAssertEqual(CategoryCreateRules.choice(forButtonIndex: 1, offering: three), .createNew)
        XCTAssertEqual(CategoryCreateRules.choice(forButtonIndex: 2, offering: three), .cancel)
    }

    func testTheShorterListMeansTheFirstButtonIsCreateRatherThanReactivate() {
        // The case this pairing exists for: the same index means a different thing depending on what was offered.
        let two = CategoryCreateRules.choices(retiredNamesakes: 2)
        XCTAssertEqual(CategoryCreateRules.choice(forButtonIndex: 0, offering: two), .createNew)
        XCTAssertEqual(CategoryCreateRules.choice(forButtonIndex: 1, offering: two), .cancel)
        XCTAssertNil(CategoryCreateRules.choice(forButtonIndex: 2, offering: two))
    }

    func testAnAnswerFromNoButtonOfOursIsNothing() {
        // A sheet dismissed by something else. The caller treats it as Cancel rather than guessing.
        let three = CategoryCreateRules.choices(retiredNamesakes: 1)
        XCTAssertNil(CategoryCreateRules.choice(forButtonIndex: 3, offering: three))
        XCTAssertNil(CategoryCreateRules.choice(forButtonIndex: -1, offering: three))
    }

    func testTheMessageNamesTheCategoryInQuotes() {
        XCTAssertEqual(
            CategoryCreateRules.retiredNamesakeMessage(name: "Reading"),
            "The category \"Reading\" already exists as a deactivated category"
        )
        // Quoted so a name with a space in it cannot be misread as part of the sentence.
        XCTAssertTrue(CategoryCreateRules.retiredNamesakeMessage(name: "Deep work").contains("\"Deep work\""))
    }

    func testTheDialogueSaysHowManyThereAre() {
        // Which is also why a button can be missing: a dialogue offering fewer choices than last time, with no reason
        // given, reads as a bug rather than as an answer nobody can give.
        XCTAssertEqual(CategoryCreateRules.retiredNamesakeCount(1), "There is one category with the same name.")
        XCTAssertEqual(CategoryCreateRules.retiredNamesakeCount(3), "There are 3 categories with the same name.")
    }

    func testAnActiveNamesakeIsADeadEnd() {
        let existing = category(2, "Meeting", active: true)

        XCTAssertEqual(decide("Meeting", against: [existing]), .alreadyActive(existing))
    }

    func testAnActiveNamesakeOutranksARetiredOne() {
        // Both exist under the name. Reactivating the retired one would be refused by the index anyway,
        // since its name is taken -- so the active one is the answer, and the ordering is what says so.
        let active = category(2, "Meeting", active: true)
        let retired = category(9, "Meeting", active: false)

        XCTAssertEqual(decide("Meeting", against: [retired, active]), .alreadyActive(active))
    }

    func testSeveralRetiredNamesakesAreAllCarried() {
        // Every one of them, because how many there are is what decides which buttons the dialogue can offer. This
        // used to insert outright, which made the decision silently on the user's behalf.
        let rows = [category(4, "Reading", active: false), category(7, "Reading", active: false)]

        XCTAssertEqual(decide("Reading", against: rows), .retiredNamesakes(rows))
    }
}
