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
