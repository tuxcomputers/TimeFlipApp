@testable import FacetApp
import AppKit
import XCTest

/// What clicking a column heading on the Report tab does, and what order comes out of it.
@MainActor
final class ReportSortRulesTests: XCTestCase {
    private func total(_ name: String, id: Int, seconds: TimeInterval) -> CategoryTotal {
        CategoryTotal(categoryID: id, name: name, iconName: nil, colour: nil, usesWhiteLines: false, seconds: seconds)
    }

    private var sample: [CategoryTotal] {
        [
            total("Admin", id: 3, seconds: 600),
            total("Break", id: 1, seconds: 1_800),
            total("2", id: 4, seconds: 60),
            total("Meeting", id: 2, seconds: 1_800),
        ]
    }

    // MARK: - where it starts

    func testItOpensOnTheOrderTheOtherTabsUse() {
        // The Categories and Faces tabs list categories in `CategoryOrder`. A Report tab that opened on something else
        // would put a category somewhere new for anybody arriving from either of them.
        XCTAssertEqual(ReportSortRules.Order.initial, .init(column: .category, direction: .ascending))
        XCTAssertEqual(
            ReportSortRules.sorted(sample, by: .initial).map(\.name),
            ["2", "Admin", "Break", "Meeting"],
            "entirely-numeric names first, then text, which is the shared rule"
        )
    }

    // MARK: - what a click does

    func testClickingTimeAsksForTheBiggestFirst() {
        // The question "what did the time go on" is what the column is clicked to ask, and a first click that showed
        // the smallest figure would take two clicks to answer it.
        let order = ReportSortRules.next(after: .initial, clicking: .time)
        XCTAssertEqual(order, .init(column: .time, direction: .descending))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: order).map(\.seconds), [1_800, 1_800, 600, 60])
    }

    func testClickingTimeAgainTurnsItRoundTheOtherWay() {
        let once = ReportSortRules.next(after: .initial, clicking: .time)
        let twice = ReportSortRules.next(after: once, clicking: .time)
        XCTAssertEqual(twice, .init(column: .time, direction: .ascending))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: twice).map(\.seconds), [60, 600, 1_800, 1_800])
    }

    func testClickingCategoryFromTimeGoesBackToTheSharedOrder() {
        let onTime = ReportSortRules.next(after: .initial, clicking: .time)
        let back = ReportSortRules.next(after: onTime, clicking: .category)
        XCTAssertEqual(back, .init(column: .category, direction: .ascending))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: back).map(\.name), ["2", "Admin", "Break", "Meeting"])
    }

    func testClickingCategoryAgainReversesIt() {
        let reversed = ReportSortRules.next(after: .initial, clicking: .category)
        XCTAssertEqual(reversed, .init(column: .category, direction: .descending))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: reversed).map(\.name), ["Meeting", "Break", "Admin", "2"])
    }

    func testAThirdClickIsTheFirstClickAgain() {
        // Two states per column, so a heading somebody keeps clicking flips rather than walking through a cycle
        // nobody can predict.
        var order = ReportSortRules.Order.initial
        for _ in 0 ..< 3 {
            order = ReportSortRules.next(after: order, clicking: .time)
        }
        XCTAssertEqual(order, .init(column: .time, direction: .descending))
    }

    // MARK: - ties

    func testTwoCategoriesWithTheSameTimeKeepTheCategoryOrder() {
        // "Break" and "Meeting" both hold 1800s. Left to an unstable sort they could swap places between two draws of
        // the same data, which reads as the list being unreliable.
        let byTime = ReportSortRules.Order(column: .time, direction: .descending)
        XCTAssertEqual(Array(ReportSortRules.sorted(sample, by: byTime).map(\.name).prefix(2)), ["Break", "Meeting"])

        let ascending = ReportSortRules.Order(column: .time, direction: .ascending)
        XCTAssertEqual(Array(ReportSortRules.sorted(sample, by: ascending).map(\.name).suffix(2)), ["Break", "Meeting"])
    }

    func testSortingIsStableEnoughToRepeat() {
        let byTime = ReportSortRules.Order(column: .time, direction: .descending)
        let once = ReportSortRules.sorted(sample, by: byTime).map(\.categoryID)
        let twice = ReportSortRules.sorted(ReportSortRules.sorted(sample, by: byTime), by: byTime).map(\.categoryID)
        XCTAssertEqual(once, twice, "re-sorting an already-sorted list must not move anything")
    }

    // MARK: - what the heading says

    func testOnlyTheColumnInForceCarriesAnArrow() {
        // Two arrows would claim the list is sorted by both. A bare title is the honest "not this one".
        let byTime = ReportSortRules.Order(column: .time, direction: .descending)
        XCTAssertEqual(ReportSortRules.heading("Time", column: .time, order: byTime), "Time \u{25BC}")
        XCTAssertEqual(ReportSortRules.heading("Category", column: .category, order: byTime), "Category")

        let up = ReportSortRules.Order(column: .category, direction: .ascending)
        XCTAssertEqual(ReportSortRules.heading("Category", column: .category, order: up), "Category \u{25B2}")
    }

    // MARK: - the list itself

    func testTheListReordersWhatItIsShowingWithoutBeingGivenItAgain() {
        // A heading click rearranges the rows already on screen. Going back to the database for an order the app can
        // work out would be a read in service of nothing, and would make sorting depend on the range still being valid.
        let list = ReportTotalsList()
        list.show(sample, showingSeconds: true)
        XCTAssertEqual(list.shownTotals.map(\.name), ["2", "Admin", "Break", "Meeting"])

        var reported: [ReportSortRules.Order] = []
        list.onSort = { reported.append($0) }
        list.press(ReportTotalsList.Identifier.sortByTime)

        XCTAssertEqual(list.order, .init(column: .time, direction: .descending))
        XCTAssertEqual(list.shownTotals.map(\.seconds), [1_800, 1_800, 600, 60])
        XCTAssertEqual(reported, [.init(column: .time, direction: .descending)])
    }

    func testTheHeadingsAreClickableByName() {
        // The scripted tests press these by AXIdentifier, so their names are part of the contract rather than a detail.
        let list = ReportTotalsList()
        list.show(sample, showingSeconds: true)
        XCTAssertNotNil(list.button(ReportTotalsList.Identifier.sortByCategory))
        XCTAssertNotNil(list.button(ReportTotalsList.Identifier.sortByTime))
    }
}

private extension ReportTotalsList {
    /// The heading button with that identifier, found the way a script's accessibility query would.
    func button(_ identifier: String) -> NSButton? {
        subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier }
    }

    func press(_ identifier: String) {
        guard let button = button(identifier) else { return XCTFail("no button named \(identifier)") }
        button.performClick(nil)
    }
}
