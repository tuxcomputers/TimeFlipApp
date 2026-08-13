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

    func testASingleRetiredNamesakeIsBroughtBack() {
        let retired = category(4, "Reading", active: false)

        XCTAssertEqual(decide("Reading", against: [retired]), .reactivate(retired))
    }

    func testARetiredNamesakeIsFoundWhateverTheCasing() {
        // The unique index that bars a second active namesake is case-insensitive, so the check has to be.
        let retired = category(4, "Reading", active: false)

        XCTAssertEqual(decide("reading", against: [retired]), .reactivate(retired))
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

    func testSeveralRetiredNamesakesMeansCreateAlongsideThem() {
        // Which one to bring back is unanswerable here: each has its own history and nothing tells them
        // apart. Creating is still allowed, because only an active namesake bars a name.
        let rows = [category(4, "Reading", active: false), category(7, "Reading", active: false)]

        XCTAssertEqual(decide("Reading", against: rows), .insert(name: "Reading"))
    }
}
