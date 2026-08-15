import AppKit

/// What the picked range came to, per category: the icon on its colour, the name, the time on the right, and the
/// stretches behind that time folded away underneath ([ReportCategoryGroup]).
///
/// **Only the categories that recorded something**, biggest first, which is `TimeEntryStore.totals` doing the deciding.
/// A category with nothing in the range is absent rather than shown as `0:00`, and a range with nothing in it says so
/// in words rather than drawing an empty table.
///
/// The heading measurements come from the Faces tab's list (`CategoryListView.Layout`) rather than being restated,
/// since they are the same treatment: a 36pt row, a 28pt colour square holding a 20pt glyph, the name beside it. A
/// category with no icon still fills the slot as a hollow square, so every name lines up whether or not one is set.
@MainActor
final class ReportTotalsList: NSView {
    enum Identifier {
        static let list = "report-totals"
        static let empty = "report-totals-empty"
    }

    private let rows = NSStackView()
    private let scroll = NSScrollView()
    /// What the scroll view scrolls, holding the rows.
    ///
    /// **Flipped**, which is the whole of why it exists: AppKit measures an ordinary view from its bottom edge, so a
    /// document view shorter than the space it sits in hangs at the *bottom* of it -- one row of totals sat at the
    /// bottom of the tab with a hand's width of nothing above it. Flipped, it grows downward from under the hairline,
    /// which is where a list starts.
    private let document = FlippedView()

    private(set) var shownTotals: [CategoryTotal] = []

    /// The stretches behind one category's total, asked for when its group is opened. **A read, at the moment of use**:
    /// the window owns the tables and the range, and a closed group asks nothing at all.
    var entries: ((CategoryTotal) -> [TimeEntryRecord])?

    /// Called when a group is opened or closed, so the window can record it.
    var onToggle: ((CategoryTotal, Bool) -> Void)?

    /// Which categories are open, by id, kept across a rebuild.
    ///
    /// A list rebuilt underneath somebody -- a pause elsewhere in the app turns a stretch into an entry, and the totals
    /// are re-read -- should not snap shut what they had opened. Ids rather than positions, since the order follows the
    /// figures and both can change; a category that drops out of the range drops out of here with it.
    private var expanded: Set<Int> = []

    /// Exposed so a test can reach a group without going through the view tree.
    private(set) var groups: [ReportCategoryGroup] = []

    init() {
        super.init(frame: .zero)
        addRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Replaces the list. Rebuilt rather than diffed, for the reason every list here is: the totals arrive whole from
    /// one read, so reconciling them against what is on screen would be work in service of nothing.
    ///
    /// `showingSeconds` is `display_seconds`, the same setting the menu bar's figure obeys, so a span never reads one
    /// way there and another way here. It earns its keep on this screen rather than merely being obeyed by it: at
    /// `H:MM` every total under a minute reads `0:00`, which is indistinguishable from a category that was opened and
    /// left.
    func show(_ totals: [CategoryTotal], showingSeconds: Bool) {
        for view in rows.views {
            rows.removeView(view)
        }
        groups = []
        if totals.isEmpty {
            rows.addView(emptyLabel(), in: .top)
        } else {
            for (index, total) in totals.enumerated() {
                if index > 0 {
                    add(divider())
                }
                add(group(total, showingSeconds: showingSeconds))
            }
        }
        shownTotals = totals
    }

    private func group(_ total: CategoryTotal, showingSeconds: Bool) -> ReportCategoryGroup {
        let group = ReportCategoryGroup(total: total, showingSeconds: showingSeconds)
        group.entries = { [weak self] in self?.entries?(total) ?? [] }
        group.onToggle = { [weak self] isExpanded in
            guard let self else { return }
            if isExpanded {
                self.expanded.insert(total.categoryID)
            } else {
                self.expanded.remove(total.categoryID)
            }
            self.onToggle?(total, isExpanded)
        }
        groups.append(group)
        // Opened again if it was open before the rebuild, which re-reads its entries: the figures above them have just
        // been re-read too, and the two have to agree.
        if expanded.contains(total.categoryID) {
            group.setExpanded(true)
        }
        return group
    }

    private func add(_ view: NSView) {
        rows.addView(view, in: .top)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
        ])
    }

    /// **Scrollable, because the list has no natural ceiling.** Twelve categories of tracked time is a taller list than
    /// the space under the calendars, and a range of a month can hold every category there is.
    private func addRows() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Identifier.list)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // The list is the page rather than a panel on it, as the Faces tab's list is, so it takes the window's own
        // background rather than a fill of its own.
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // **Pinned to the clip view on three sides**, which is what a document view laid out by constraints needs:
            // its height comes from the rows in it, and the other three edges come from the thing scrolling it. Pinning
            // the width alone left the horizontal position undecided, and the list drew off the side of the tab -- rows
            // that had been read correctly and could not be seen.
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func divider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.dividerHeight).isActive = true
        return divider
    }

    private func emptyLabel() -> NSTextField {
        // The archive's wording. It says what is missing rather than that something went wrong, and it is the honest
        // answer to a range nothing was recorded in -- which is a real answer, not a failure.
        let label = NSTextField(labelWithString: "No time recorded in this range.")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier(Identifier.empty)
        return label
    }
}

/// A view whose origin is its top-left corner, for the one place that needs it: a scroll view's document view, so a
/// short list starts under the hairline instead of hanging at the bottom of the space.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
