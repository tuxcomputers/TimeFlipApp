@testable import TimeFlipApp
import XCTest

/// Covers `CategoryEditRules`: the bounds on a daily limit, and when retiring a category is not on offer.
///
/// Both are here rather than inside the row that draws them, because both have an edge that matters more than the
/// common case: a limit above a day is unreachable rather than generous, and a locked face is two instructions
/// contradicting each other.
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

    // MARK: - bringing one back

    private func category(_ id: Int, _ name: String, isActive: Bool) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconName: nil,
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

    // MARK: - retiring

    func testACategoryOnNoFaceCanBeRetired() {
        XCTAssertNil(CategoryEditRules.retireRefusal(facesHolding: []))
    }

    func testACategoryOnUnlockedFacesCanBeRetired() {
        XCTAssertNil(
            CategoryEditRules.retireRefusal(facesHolding: [(face: 13, isLocked: false), (face: 14, isLocked: false)])
        )
    }

    func testALockedFaceHoldingItStopsTheRetire() {
        let refusal = CategoryEditRules.retireRefusal(
            facesHolding: [(face: 2, isLocked: false), (face: 8, isLocked: true)]
        )

        // Only the locked ones are named: the others are no reason for anything.
        XCTAssertEqual(refusal, .lockedFaces([8]))
    }

    func testTheExplanationNamesEveryLockedFaceAndTheCategory() throws {
        let refusal = CategoryEditRules.retireRefusal(
            facesHolding: [(face: 4, isLocked: true), (face: 8, isLocked: true)]
        )

        let help = try XCTUnwrap(CategoryEditRules.retireRefusalHelp(refusal, categoryName: "Break"))
        XCTAssertTrue(help.contains("Faces 4, 8"), "the row gives no clue which face is in the way")
        XCTAssertTrue(help.contains("Break"))
        XCTAssertTrue(help.contains("Unlock"), "it has to say what to do about it")
    }

    func testOneLockedFaceReadsAsOneFace() throws {
        let help = try XCTUnwrap(
            CategoryEditRules.retireRefusalHelp(.lockedFaces([8]), categoryName: "Break")
        )

        XCTAssertTrue(help.contains("Face 8 is"), "not \"Faces 8 are\"")
    }

    func testNothingToExplainWhenTheRetireIsAllowed() {
        XCTAssertNil(CategoryEditRules.retireRefusalHelp(nil, categoryName: "Break"))
    }
}
