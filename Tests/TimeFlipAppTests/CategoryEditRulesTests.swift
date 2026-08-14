@testable import TimeFlipApp
import XCTest

/// Covers `CategoryEditRules`: the bounds on a daily limit, what a click on a picker stores, and when a category
/// cannot be edited at all.
///
/// All of them are here rather than inside the row that draws them, because each has an edge that matters more than
/// the common case: a limit above a day is unreachable rather than generous, re-picking is how a picker clears, and a
/// locked face is two instructions contradicting each other.
final class CategoryEditRulesTests: XCTestCase {
    // MARK: - the daily limit

    func testALimitInsideTheRangeIsLeftAlone() {
        XCTAssertEqual(CategoryEditRules.dailyLimitMinutes(45), 45)
    }

    func testZeroIsAllowedBecauseItMeansNoLimit() {
        // Not the same as a limit of nothing, which is why the caption over the column says so.
        XCTAssertEqual(CategoryEditRules.dailyLimitMinutes(0), 0)
    }

    func testALimitLongerThanADayIsBroughtBackToADay() {
        // A budget for time tracked in one day, so a day is the most that can be spent against it and anything above
        // is unreachable rather than merely generous.
        XCTAssertEqual(CategoryEditRules.dailyLimitMinutes(5_000), 1_440)
        XCTAssertEqual(CategoryEditRules.maximumDailyLimitMinutes, 24 * 60)
    }

    func testANegativeLimitIsBroughtBackToZero() {
        XCTAssertEqual(CategoryEditRules.dailyLimitMinutes(-30), 0)
    }

    // MARK: - picking an icon

    func testPickingAnIconStoresIt() {
        XCTAssertEqual(CategoryEditRules.iconSelection(clicked: 7, selected: 4), 7)
    }

    func testPickingTheIconAlreadyChosenClearsIt() {
        // The whole of how a grid with no None cell unsets an icon: id 0 is a sentinel row rather than artwork, so
        // there is nothing to draw in a cell for it.
        XCTAssertEqual(CategoryEditRules.iconSelection(clicked: 7, selected: 7), CategoryEditRules.noIcon)
        XCTAssertEqual(CategoryEditRules.noIcon, 0)
    }

    func testPickingOneWhenThereIsNoneStoresIt() {
        XCTAssertEqual(CategoryEditRules.iconSelection(clicked: 7, selected: CategoryEditRules.noIcon), 7)
    }

    // MARK: - picking a colour

    func testPickingAColourStoresIt() {
        XCTAssertEqual(CategoryEditRules.colourSelection(clicked: 14, selected: 4), 14)
    }

    func testPickingTheColourAlreadyChosenClearsIt() {
        // The same rule as the icon column, and for the same reason: `colour_id` 0 is a sentinel row with no hex, so
        // there is nothing to draw in a list row for it, and a list that could only ever set a colour would make "no
        // colour" a state a category could leave but never return to.
        XCTAssertEqual(CategoryEditRules.colourSelection(clicked: 14, selected: 14), CategoryEditRules.noColour)
        XCTAssertEqual(CategoryEditRules.noColour, 0)
    }

    func testPickingOneWhenThereIsNoColourStoresIt() {
        XCTAssertEqual(CategoryEditRules.colourSelection(clicked: 14, selected: CategoryEditRules.noColour), 14)
    }

    // MARK: - bringing one back

    private func category(_ id: Int, _ name: String, isActive: Bool) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: nil,
            colourID: 0,
            colour: nil,
            usesWhiteLines: false,
            dailyLimitMinutes: 0,
            isActive: isActive
        )
    }

    func testACategoryWhoseNameIsFreeComesBack() {
        let retired = category(3, "Reading", isActive: false)

        XCTAssertEqual(
            CategoryEditRules.reinstateDecision(for: retired, matching: [retired]),
            .reinstate,
            "a retired row always matches its own name, and it is not in its own way"
        )
    }

    func testAnActiveNamesakeStopsIt() {
        let retired = category(3, "Reading", isActive: false)
        let active = category(9, "Reading", isActive: true)

        XCTAssertEqual(
            CategoryEditRules.reinstateDecision(for: retired, matching: [active, retired]),
            .refuse(activeNamesake: active),
            "the one in the way is named, since a refused write could not say which it was"
        )
    }

    func testAnotherRetiredNamesakeIsNoBar() {
        // Any number of retired categories may share a name: only one *active* one may hold it.
        let retired = category(3, "Reading", isActive: false)
        let alsoRetired = category(9, "Reading", isActive: false)

        XCTAssertEqual(
            CategoryEditRules.reinstateDecision(for: retired, matching: [retired, alsoRetired]),
            .reinstate
        )
    }

    func testNoMatchesAtAllComesBack() {
        // Which the store never produces -- a row always matches its own name -- but the rule should not depend on
        // being handed itself.
        XCTAssertEqual(
            CategoryEditRules.reinstateDecision(for: category(3, "Reading", isActive: false), matching: []),
            .reinstate
        )
    }

    // MARK: - a locked face

    func testACategoryOnNoFaceCanBeEdited() {
        XCTAssertNil(CategoryEditRules.editRefusal(facesHolding: []))
    }

    func testACategoryOnUnlockedFacesCanBeEdited() {
        XCTAssertNil(
            CategoryEditRules.editRefusal(facesHolding: [(face: 13, isLocked: false), (face: 14, isLocked: false)])
        )
    }

    func testALockedFaceHoldingItStopsEveryEdit() {
        let refusal = CategoryEditRules.editRefusal(
            facesHolding: [(face: 2, isLocked: false), (face: 8, isLocked: true)]
        )

        // Only the locked ones are named: the others are no reason for anything.
        XCTAssertEqual(refusal, .lockedFaces([8]))
    }

    func testTheExplanationNamesEveryLockedFaceAndTheCategory() throws {
        let refusal = CategoryEditRules.editRefusal(
            facesHolding: [(face: 4, isLocked: true), (face: 8, isLocked: true)]
        )

        let help = try XCTUnwrap(CategoryEditRules.editRefusalHelp(refusal, categoryName: "Break"))
        XCTAssertTrue(help.contains("Faces 4, 8"), "the row gives no clue which face is in the way")
        XCTAssertTrue(help.contains("Break"))
        XCTAssertTrue(help.contains("Unlock them"), "it has to say what to do about it")
        XCTAssertTrue(help.contains("change this category"), "the whole row is held, not only the Active box")
    }

    func testOneLockedFaceReadsAsOneFace() throws {
        let help = try XCTUnwrap(
            CategoryEditRules.editRefusalHelp(.lockedFaces([8]), categoryName: "Break")
        )

        XCTAssertTrue(help.contains("Face 8 is"), "not \"Faces 8 are\"")
        XCTAssertTrue(help.contains("Unlock it"), "and \"it\", not \"them\"")
    }

    func testNothingToExplainWhenTheEditIsAllowed() {
        XCTAssertNil(CategoryEditRules.editRefusalHelp(nil, categoryName: "Break"))
    }
}
