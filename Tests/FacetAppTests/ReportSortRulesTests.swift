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

    func testItOpensOnTheBiggestFigureFirst() {
        // **Changed 2026-08-16.** It opened on the shared category order, so the Report tab agreed with the tabs
        // somebody had just come from. That was consistency between tabs rather than what a report is for: nobody
        // opens one to find out a category exists, they open it to see where the time went, and the category order
        // made that the one thing they had to click for.
        XCTAssertEqual(ReportSortRules.Order.initial, .init(sortColumnState: .time, isSortAscending: false))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: .initial).map(\.seconds), [1_800, 1_800, 600, 60])
    }

    func testOpeningMatchesWhatClickingTimeWouldGive() {
        // Otherwise the first click on Time does nothing visible, which reads as a dead heading. The default is
        // written once for this reason, and this is the assertion that keeps the two from drifting apart.
        XCTAssertEqual(
            ReportSortRules.Order.initial.isSortAscending,
            ReportSortRules.defaultIsSortAscending(for: .time)
        )
    }

    // MARK: - what a click does
    //
    // **Started from an explicit order rather than from `.initial`.** These are about what a click does to the order
    // in force, and taking that from the opening default made them silently change meaning when the default did:
    // "clicking Time" became "clicking the column already in force", which is the other branch entirely.

    /// The shared category order, which the tab no longer opens on but a click still reaches.
    private var byCategory: ReportSortRules.Order {
        ReportSortRules.Order(sortColumnState: .category, isSortAscending: true)
    }

    func testClickingTimeAsksForTheBiggestFirst() {
        // The question "what did the time go on" is what the column is clicked to ask, and a first click that showed
        // the smallest figure would take two clicks to answer it.
        let order = ReportSortRules.next(after: byCategory, clicking: .time)
        XCTAssertEqual(order, .init(sortColumnState: .time, isSortAscending: false))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: order).map(\.seconds), [1_800, 1_800, 600, 60])
    }

    func testClickingTimeAgainTurnsItRoundTheOtherWay() {
        let twice = ReportSortRules.next(after: .initial, clicking: .time)
        XCTAssertEqual(twice, .init(sortColumnState: .time, isSortAscending: true))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: twice).map(\.seconds), [60, 600, 1_800, 1_800])
    }

    func testClickingCategoryFromTimeGoesToTheSharedOrder() {
        // Straight from the opening order now, which is the path somebody actually takes: open the tab, then ask
        // which category is which.
        let back = ReportSortRules.next(after: .initial, clicking: .category)
        XCTAssertEqual(back, byCategory)
        XCTAssertEqual(ReportSortRules.sorted(sample, by: back).map(\.name), ["2", "Admin", "Break", "Meeting"])
    }

    func testClickingCategoryAgainReversesIt() {
        let reversed = ReportSortRules.next(after: byCategory, clicking: .category)
        XCTAssertEqual(reversed, .init(sortColumnState: .category, isSortAscending: false))
        XCTAssertEqual(ReportSortRules.sorted(sample, by: reversed).map(\.name), ["Meeting", "Break", "Admin", "2"])
    }

    func testAThirdClickIsTheFirstClickAgain() {
        // Two states per column, so a heading somebody keeps clicking flips rather than walking through a cycle
        // nobody can predict.
        var order = byCategory
        for _ in 0 ..< 3 {
            order = ReportSortRules.next(after: order, clicking: .time)
        }
        XCTAssertEqual(order, .init(sortColumnState: .time, isSortAscending: false))
    }

    // MARK: - ties

    func testTwoCategoriesWithTheSameTimeKeepTheCategoryOrder() {
        // "Break" and "Meeting" both hold 1800s. Left to an unstable sort they could swap places between two draws of
        // the same data, which reads as the list being unreliable.
        let byTime = ReportSortRules.Order(sortColumnState: .time, isSortAscending: false)
        XCTAssertEqual(Array(ReportSortRules.sorted(sample, by: byTime).map(\.name).prefix(2)), ["Break", "Meeting"])

        let ascending = ReportSortRules.Order(sortColumnState: .time, isSortAscending: true)
        XCTAssertEqual(Array(ReportSortRules.sorted(sample, by: ascending).map(\.name).suffix(2)), ["Break", "Meeting"])
    }

    func testSortingIsStableEnoughToRepeat() {
        let byTime = ReportSortRules.Order(sortColumnState: .time, isSortAscending: false)
        let once = ReportSortRules.sorted(sample, by: byTime).map(\.categoryID)
        let twice = ReportSortRules.sorted(ReportSortRules.sorted(sample, by: byTime), by: byTime).map(\.categoryID)
        XCTAssertEqual(once, twice, "re-sorting an already-sorted list must not move anything")
    }

    // MARK: - what the heading says

    func testOnlyTheColumnInForceCarriesAnArrow() {
        // Two arrows would claim the list is sorted by both. A bare title is the honest "not this one".
        let byTime = ReportSortRules.Order(sortColumnState: .time, isSortAscending: false)
        XCTAssertEqual(ReportSortRules.heading("Time", sortColumnState: .time, order: byTime), "Time \u{25BC}")
        XCTAssertEqual(ReportSortRules.heading("Category", sortColumnState: .category, order: byTime), "Category")

        let up = ReportSortRules.Order(sortColumnState: .category, isSortAscending: true)
        XCTAssertEqual(ReportSortRules.heading("Category", sortColumnState: .category, order: up), "Category \u{25B2}")
    }

    // MARK: - the list itself

    func testTheListReordersWhatItIsShowingWithoutBeingGivenItAgain() {
        // A heading click rearranges the rows already on screen. Going back to the database for an order the app can
        // work out would be a read in service of nothing, and would make sorting depend on the range still being valid.
        let list = ReportTotalsList()
        list.show(sample, showingSeconds: true)
        // Opens on the biggest figure, so the click under test is the one that leaves it.
        XCTAssertEqual(list.shownTotals.map(\.seconds), [1_800, 1_800, 600, 60])

        var reported: [ReportSortRules.Order] = []
        list.onSort = { reported.append($0) }
        list.press(ReportTotalsList.Identifier.sortByCategory)

        XCTAssertEqual(list.order, .init(sortColumnState: .category, isSortAscending: true))
        XCTAssertEqual(list.shownTotals.map(\.name), ["2", "Admin", "Break", "Meeting"])
        XCTAssertEqual(reported, [.init(sortColumnState: .category, isSortAscending: true)])
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
