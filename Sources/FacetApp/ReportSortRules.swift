import Foundation

/// How the Report tab's totals are ordered, and what clicking a column heading does to it.
///
/// **Two questions, and the headings are how you say which one you are asking.** "Which category is this" is answered
/// by the list being in the same order as the Categories and Faces tabs, so a category sits in the same place
/// everywhere. "What did the time go on" is answered by the biggest figure being at the top. Neither order answers
/// both, and picking one as the only order makes the other question something you do by eye.
///
/// **The tab opens on the second question**, largest figure first. It opened on the category order until 2026-08-16,
/// on the reasoning that a report should agree with the tabs somebody had just come from. That reasoning was about
/// consistency between tabs rather than about what a report is for: nobody opens a report to find out that a category
/// exists, they open it to see where the time went, and the category order makes that the one thing they have to
/// click for.
///
/// **A click on the column you are already on reverses it; a click on the other one adopts that column's own default.**
/// The defaults differ on purpose, because the columns mean different things: a name list starts at the beginning, and
/// asking about time means asking what most of it went on. Anything else would be consistent and wrong -- a first click
/// on Time that showed the smallest figure would take two clicks to answer the question it was clicked to answer.
enum ReportSortRules {
    enum Column: Equatable {
        case category
        case time
    }

    struct Order: Equatable {
        var sortColumnState: Column
        var isSortAscending: Bool

        /// What the tab opens on: the biggest figure first, which is the question a report is opened to ask.
        ///
        /// The same answer `defaultIsSortAscending(for: .time)` gives, and deliberately not written twice: opening on one
        /// direction and clicking Time into another would make the heading's first click do nothing visible, which
        /// reads as a dead control.
        static let initial = Order(sortColumnState: .time, isSortAscending: defaultIsSortAscending(for: .time))
    }

    /// Where a column starts when it is first clicked.
    static func defaultIsSortAscending(for sortColumnState: Column) -> Bool {
        switch sortColumnState {
        case .category:
            // A to Z, which is the shared `CategoryOrder` read forwards.
            return true
        case .time:
            // Largest first. See the note above: this is the question the column is clicked to ask.
            return false
        }
    }

    /// The order a click produces, given the order in force.
    static func next(after current: Order, clicking sortColumnState: Column) -> Order {
        guard current.sortColumnState == sortColumnState else {
            return Order(sortColumnState: sortColumnState, isSortAscending: defaultIsSortAscending(for: sortColumnState))
        }
        return Order(sortColumnState: sortColumnState, isSortAscending: !current.isSortAscending)
    }

    /// The totals in that order.
    ///
    /// **Time ties break on the category order**, and the category order breaks on the id inside `CategoryOrder`, so
    /// the result is fully determined however many categories share a figure. Two rows swapping places between two
    /// draws of the same data would read as the list being unreliable.
    static func sorted(_ totals: [CategoryTotal], by order: Order) -> [CategoryTotal] {
        totals.sorted { lhs, rhs in
            let ascending: Bool
            switch order.sortColumnState {
            case .category:
                ascending = CategoryOrder.isBefore(lhs.name, id: lhs.categoryID, than: rhs.name, id: rhs.categoryID)
            case .time:
                if lhs.seconds != rhs.seconds {
                    ascending = lhs.seconds < rhs.seconds
                } else {
                    // A tie on the figure falls back to the category order, in that order's own direction, so the
                    // grouping a reader sees is the one they would get from the other column.
                    return CategoryOrder.isBefore(lhs.name, id: lhs.categoryID, than: rhs.name, id: rhs.categoryID)
                }
            }
            return order.isSortAscending ? ascending : !ascending
        }
    }

    /// What a heading is called, with the arrow when the list is on that column.
    ///
    /// **Only the active column carries an arrow.** Two arrows would say the list is sorted by both, and a column with
    /// no arrow is the honest way to say "not this one, click to use it".
    static func heading(_ title: String, sortColumnState: Column, order: Order) -> String {
        guard order.sortColumnState == sortColumnState else { return title }
        return order.isSortAscending ? "\(title) \u{25B2}" : "\(title) \u{25BC}"
    }
}
