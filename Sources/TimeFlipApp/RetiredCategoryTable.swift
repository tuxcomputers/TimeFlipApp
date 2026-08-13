import AppKit

/// The Categories tab's Inactive list: the categories that have been retired, with the name and when each last
/// recorded time.
///
/// **Its own type rather than the Active table with columns hidden**, which is also how the archive drew it: two
/// lists that answer different questions. The Active one is a record of what a category *is* -- its icon, its
/// colour, its budget, all of them editable. This one is a record of what it *was*, and the only question it
/// answers is which of them to bring back.
///
/// So the icon, the colour and the daily limit are absent rather than drawn dead. A retired category is kept only
/// so historical `time_entry` rows still resolve, so those three describe a past, and showing them invites an edit
/// that means nothing. Dropping them also keeps this list narrower than the Active one, which is what stops the
/// last-used column costing the window any width: the widest section sets the width, and that is the one being
/// worked in.
///
/// **No Active box yet.** In the archive that box led the row, being the only thing a retired row does; reinstating
/// is not built here, and a box that did nothing would be worse than no box at all.
///
/// The panel's own look -- the tint, the corner, the padding -- comes from `CategoryTable.Layout` rather than being
/// restated, since these two sit on one tab and cannot be allowed to drift apart.
@MainActor
final class RetiredCategoryTable: NSView {
    enum Identifier {
        static let table = "retired-category-table"
        static let header = "retired-category-table-header"
        /// Distinct from both the Faces tab's `category-row-<id>` and the Active list's
        /// `category-detail-row-<id>`, so a step cannot press one believing it addressed another.
        static func row(_ category: CategoryRecord) -> String { "retired-category-row-\(category.id)" }
    }

    private let panel = NSBox()
    private let rows = NSStackView()

    private(set) var shownCategories: [CategoryRecord] = []

    /// When a category last recorded time. Asked per row as the list is built, so it is read at the moment it is
    /// needed rather than arriving alongside the categories and going stale between the two.
    var lastUsed: ((CategoryRecord) -> Date?)?

    init() {
        super.init(frame: .zero)
        addPanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Replaces the list with `categories`, which are expected to be the retired ones.
    ///
    /// Rebuilt rather than diffed, for the reason every list here is: the rows are read from the database each time
    /// the tab is shown, so they arrive whole.
    func show(_ categories: [CategoryRecord]) {
        for view in rows.views {
            rows.removeView(view)
        }
        if categories.isEmpty {
            rows.addView(emptyLabel(), in: .top)
        } else {
            rows.addView(headerRow(), in: .top)
            for category in categories {
                rows.addView(RetiredCategoryRow(category: category, lastUsed: lastUsed?(category)), in: .top)
            }
        }
        shownCategories = categories
    }

    private func addPanel() {
        translatesAutoresizingMaskIntoConstraints = false
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = CategoryTable.Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(Identifier.table)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = CategoryTable.Layout.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.contentView?.addSubview(rows)
        guard let content = panel.contentView else { return }
        let padding = CategoryTable.Layout.padding
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),
        ])
    }

    /// Two captions, and the last-used one sized to its own text: it is the final column, so nothing after it has to
    /// line up.
    private func headerRow() -> NSView {
        let name = caption("Name")
        name.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.nameColumnWidth).isActive = true
        let row = NSStackView(views: [name, caption(CategoryLastUsedText.columnTitle)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CategoryTable.Layout.columnSpacing
        row.setAccessibilityIdentifier(Identifier.header)
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func emptyLabel() -> NSTextField {
        // Says what is missing rather than that something went wrong, and in the same shape as the Active list's.
        let label = NSTextField(labelWithString: "No inactive categories.")
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// One retired category: its name, and when it last recorded time.
///
/// Not a button, and nothing in it is: this row is a reading. What would make it a control is the Active box that
/// brings a category back, which is not built.
@MainActor
final class RetiredCategoryRow: NSStackView {
    let category: CategoryRecord

    /// When it last recorded time, or `nil` for a category that never has -- which the label turns into "Never"
    /// rather than a blank, an empty cell reading as something that failed to load.
    let lastUsed: Date?

    init(category: CategoryRecord, lastUsed: Date?) {
        self.category = category
        self.lastUsed = lastUsed
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = CategoryTable.Layout.columnSpacing
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(RetiredCategoryTable.Identifier.row(category))
        setAccessibilityRole(.group)
        setAccessibilityLabel(category.name)
        addView(nameLabel(), in: .leading)
        addView(lastUsedLabel(), in: .leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The same fixed width as the Active list's name column, so the two lists read as one tab rather than as two
    /// tables that happen to be stacked.
    private func nameLabel() -> NSTextField {
        let label = NSTextField(labelWithString: category.name)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.nameColumnWidth).isActive = true
        label.setAccessibilityIdentifier("retired-category-name-\(category.id)")
        return label
    }

    private func lastUsedLabel() -> NSTextField {
        let label = NSTextField(
            labelWithString: CategoryLastUsedText.label(isActive: category.isActive, lastUsed: lastUsed) ?? ""
        )
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("retired-category-last-used-\(category.id)")
        return label
    }
}
