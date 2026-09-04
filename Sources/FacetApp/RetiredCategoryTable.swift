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
/// **The Active box leads the row rather than trailing it**, which is the archive's placement and its reasoning: in
/// the Active list that box is the last column, the far end of a row full of settings, and here there are no
/// settings, so putting it first makes it the point of the row rather than something to read past.
///
/// The panel it sits on is its section's, drawn around the Inactive heading and this list together, and its
/// measurements come from `CategoryTable.Layout` rather than being restated: these two lists sit on one tab and
/// cannot be allowed to drift apart.
@MainActor
final class RetiredCategoryTable: NSView {
    enum Identifier {
        static let table = "retired-category-table"
        static let header = "retired-category-table-header"
        /// Distinct from both the Faces tab's `category-row-<id>` and the Active list's
        /// `category-detail-row-<id>`, so a step cannot press one believing it addressed another.
        static func row(_ category: CategoryRecord) -> String { "retired-category-row-\(category.id)" }
    }

    private let rows = NSStackView()

    private(set) var shownCategories: [CategoryRecord] = []

    /// When a category last recorded time. Asked per row as the list is built, so it is read at the moment it is
    /// needed rather than arriving alongside the categories and going stale between the two.
    var lastUsed: ((CategoryRecord) -> Date?)?

    /// Called when a category's Active box is ticked. Unticking is not possible here, this being the retired list,
    /// so there is one direction rather than a flag.
    var onReinstate: ((CategoryRecord) -> Void)?

    /// Called with what was typed into a name, once Return commits it. The same signature the Active list's rename
    /// carries, and it reaches the same handler: what a committed edit *means* is the window's to decide.
    var onRename: ((CategoryRecord, String) -> Void)?

    /// Called as a name opens and closes for editing, so the window can lend Escape to the field.
    var onRenameEditingChanged: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        addRows()
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
                let row = RetiredCategoryRow(category: category, lastUsed: lastUsed?(category))
                row.onReinstate = { [weak self] in self?.onReinstate?(category) }
                row.onRename = { [weak self] typed in self?.onRename?(category, typed) }
                row.onRenameEditingChanged = { [weak self] isEditing in self?.onRenameEditingChanged?(isEditing) }
                rows.addView(row, in: .top)
            }
        }
        shownCategories = categories
    }

    /// The rows and nothing else: the tint and the padding around them belong to the section this sits in
    /// ([PanelSection]), which draws one panel for the heading and the list together.
    private func addRows() {
        translatesAutoresizingMaskIntoConstraints = false
        // An element, or the identifier is never asked for. The box used to carry it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Identifier.table)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = CategoryTable.Layout.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Three captions, and the last-used one sized to its own text: it is the final column, so nothing after it has
    /// to line up.
    private func headerRow() -> NSView {
        let active = caption("Active")
        active.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.activeColumnWidth).isActive = true
        let name = caption("Name")
        name.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.nameColumnWidth).isActive = true
        let row = NSStackView(views: [active, name, caption(CategoryLastUsedText.columnTitle)])
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

/// One retired category: the box that brings it back, its name, and when it last recorded time.
@MainActor
final class RetiredCategoryRow: NSStackView {
    let category: CategoryRecord

    /// When it last recorded time, or `nil` for a category that never has -- which the label turns into "Never"
    /// rather than a blank, an empty cell reading as something that failed to load.
    let lastUsed: Date?

    /// Called when the Active box is ticked.
    var onReinstate: (() -> Void)?

    /// Called with what was typed into the name, once Return commits it.
    var onRename: ((String) -> Void)?

    /// Called as the name opens and closes for editing.
    var onRenameEditingChanged: ((Bool) -> Void)?

    /// Exposed so a test can drive the rename without a window, the same way the Active list's row exposes its own.
    private(set) var nameCell: EditableNameCell?

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
        addView(activeBox(), in: .leading)
        addView(name(), in: .leading)
        addView(lastUsedLabel(), in: .leading)
    }

    /// Unticked, this being the retired list. Ticking it brings the category back.
    ///
    /// **Never disabled**, unlike its opposite number on the Active list. Retiring is barred while a locked face
    /// holds the category, because retiring clears faces; reinstating puts nothing on any face, so a locked face is
    /// no reason to stop it -- and a database written before that rule can hold exactly that case.
    ///
    /// It can still be refused, by the name: only one active category may hold one. That is a message rather than a
    /// disabled box, because the clash is with another row entirely and can be fixed by renaming either of them.
    private func activeBox() -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(activeChanged))
        box.state = .off
        box.translatesAutoresizingMaskIntoConstraints = false
        box.identifier = NSUserInterfaceItemIdentifier("retired-category-active-\(category.id)")
        box.setAccessibilityIdentifier("retired-category-active-\(category.id)")
        box.setAccessibilityLabel("\(category.name) active")

        // Held open at the Active list's own column width, so the two lists' boxes are the same size of target even
        // though they sit at opposite ends of their rows.
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.activeColumnWidth),
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.topAnchor.constraint(lessThanOrEqualTo: box.topAnchor),
            cell.bottomAnchor.constraint(greaterThanOrEqualTo: box.bottomAnchor),
        ])
        return cell
    }

    @objc
    private func activeChanged() {
        onReinstate?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The name, which becomes a field when it is clicked, exactly as the Active list's does.
    ///
    /// **A retired name is editable, and that is the archive's answer as well as this one.** `retiredRow` in
    /// `Archive/TimeFlipApp/CategoriesSettingsView.swift` drew the same `nameField` the active row drew, so the
    /// previous app allowed this too -- behind a right-click *Edit* nobody would find, which is the part not worth
    /// keeping.
    ///
    /// It is the one edit this list needs. Retired namesakes are allowed to pile up under one name (`UN1_category`
    /// covers active rows only), and the Last used column exists precisely because several rows can read identically;
    /// telling them apart is worth nothing if the answer cannot then be written down. It is also the only way out of
    /// a reinstate that an active namesake is blocking, short of renaming the active one instead.
    ///
    /// **Never disabled**, unlike the Active list's, where a locked face freezes the whole row. Renaming touches no
    /// face and no assignment, so there is nothing for a lock to protect here.
    ///
    /// The same fixed width as the Active list's name column, so the two lists read as one tab rather than as two
    /// tables that happen to be stacked. The identifier is unchanged from when this was a label: it is the button
    /// that carries it now, and a step that presses the name is the step that used to read it.
    private func name() -> NSView {
        let cell = EditableNameCell(
            name: category.name,
            width: CategoryTable.Layout.nameColumnWidth,
            identifier: "retired-category-name-\(category.id)"
        )
        cell.maximumLength = CategoryCreateRules.maximumLength
        cell.onCommit = { [weak self] typed in self?.onRename?(typed) }
        cell.onEditingChanged = { [weak self] isEditing in self?.onRenameEditingChanged?(isEditing) }
        nameCell = cell
        return cell
    }

    private func lastUsedLabel() -> NSTextField {
        let label = NSTextField(
            labelWithString: CategoryLastUsedText.label(isCategoryActive: category.isCategoryActive, lastUsed: lastUsed) ?? ""
        )
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("retired-category-last-used-\(category.id)")
        return label
    }
}
