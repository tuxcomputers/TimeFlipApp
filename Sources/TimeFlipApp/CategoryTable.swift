import AppKit

/// The Categories tab's list: a caption row naming the columns, then one row per category, on a rounded panel.
///
/// **A different list from the Faces tab's** ([CategoryListView]), deliberately, because the two answer different
/// questions. That one is a pick list -- a colour swatch with the icon on it, the name beside it, the whole row a
/// button -- and this one is a record of what each category *is*, in columns that line up down the tab so one
/// property can be read across every category at a glance. The previous app drew them as two different things for
/// the same reason, and this keeps its measurements: a 160pt name column so the colour after it starts at the same
/// x on every row whatever the name's length, and a 46pt colour column, wide enough for the caption above it
/// (`Archive/TimeFlipApp/SettingsLayoutConstants.CategoryList`).
///
/// **The columns are the archive's five**: Active, icon, name, colour, daily limit. All but the name are live -- the
/// box retires a category, the icon and the swatch each open a picker, and the limit writes `category.daily_limit`.
/// The inline rename behind the name is its own piece of work.
@MainActor
final class CategoryTable: NSView {
    enum Identifier {
        static let table = "category-table"
        static let header = "category-table-header"
        /// A row is named for the category it shows, since that is what a script would look for. Distinct from the
        /// Faces tab's `category-row-<id>`, so a step cannot press one believing it pressed the other.
        static func row(_ category: CategoryRecord) -> String { "category-detail-row-\(category.id)" }
    }

    enum Layout {
        /// The archive's own column widths, and its reason for fixing them at all: a label sized to its own content
        /// would put the next column at a different x on every row.
        static let nameColumnWidth: CGFloat = 160
        static let colourColumnWidth: CGFloat = 46
        /// Exactly one number field wide, since that is what fills it, and wide enough for the caption over it.
        static let limitColumnWidth: CGFloat = SteppedNumberField.Layout.fieldWidth
            + SteppedNumberField.Layout.suffixWidth + 2 * SteppedNumberField.Layout.spacing + 16
        /// A checkbox is narrower than the word "Active" above it, so the column is fixed to the caption's width.
        static let activeColumnWidth: CGFloat = 44
        /// The icon, which has no caption over it because there is nothing useful to call it.
        static let iconSize: CGFloat = 20
        /// Between the columns of a row, and between the rows.
        static let columnSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 8
        /// Inside the panel, around the whole list.
        static let padding: CGFloat = 8
        static let cornerRadius: CGFloat = 8
        /// The colour swatch, and how visible its outline is against a colour of its own.
        static let swatchSize: CGFloat = 14
        static let swatchCornerRadius: CGFloat = 3
        static let swatchStrokeOpacity: CGFloat = 0.2
    }

    private let panel = NSBox()
    private let rows = NSStackView()

    private(set) var shownCategories: [CategoryRecord] = []

    /// Called with a category and its new daily limit, in minutes, already inside the allowed range.
    var onSetDailyLimit: ((CategoryRecord, Int) -> Void)?

    /// Called when a category's Active box is unticked. Ticking is not possible here, this being the active list, so
    /// there is one direction rather than a flag.
    var onRetire: ((CategoryRecord) -> Void)?

    /// Which faces hold a category, and whether they are locked, which is what decides whether its Active box can be
    /// unticked at all. Asked per row as the row is built, so it is read when it is needed rather than passed in
    /// alongside the categories and going stale between the two.
    var facesHolding: ((CategoryRecord) -> [(face: Int, isLocked: Bool)])?

    /// Called when a category's icon is clicked, with the view the picker should hang from. What opens there is the
    /// window's to decide, as every other write on this tab is.
    var onPickIcon: ((CategoryRecord, NSView) -> Void)?

    /// Called when a category's colour swatch is clicked, with the view the picker should hang from.
    var onPickColour: ((CategoryRecord, NSView) -> Void)?

    init() {
        super.init(frame: .zero)
        addPanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Replaces the list with `categories`.
    ///
    /// Rebuilt rather than diffed, for the reason the Faces list is: the rows are read from the database every time
    /// the tab is shown, so they arrive whole, and reconciling them against what is on screen would be work in
    /// service of nothing.
    func show(_ categories: [CategoryRecord]) {
        for view in rows.views {
            rows.removeView(view)
        }
        // The caption row goes with the categories rather than above them permanently: columns with nothing under
        // them are a table pretending to be empty for a reason, when the truth is there is nothing to show.
        if categories.isEmpty {
            rows.addView(emptyLabel(), in: .top)
        } else {
            rows.addView(headerRow(), in: .top)
            for category in categories {
                let row = CategoryTableRow(
                    category: category,
                    retireRefusal: CategoryEditRules.retireRefusal(facesHolding: facesHolding?(category) ?? [])
                )
                row.onSetDailyLimit = { [weak self] minutes in self?.onSetDailyLimit?(category, minutes) }
                row.onRetire = { [weak self] in self?.onRetire?(category) }
                row.onPickIcon = { [weak self] anchor in self?.onPickIcon?(category, anchor) }
                row.onPickColour = { [weak self] anchor in self?.onPickColour?(category, anchor) }
                rows.addView(row, in: .top)
            }
        }
        shownCategories = categories
    }

    private func addPanel() {
        translatesAutoresizingMaskIntoConstraints = false
        // An NSBox rather than a layer with a background colour, as on the Faces tab: it keeps the fill a dynamic
        // colour, so the panel follows the appearance instead of freezing whichever one it was built under.
        panel.boxType = .custom
        // Tinted, which the previous app's grouped form did for every panel on this tab (see
        // `image/preferences-device.png`, the same style). A translucent fill rather than a fixed grey, so it darkens
        // the page it is on whichever appearance that page is in.
        //
        // The Faces tab's list is deliberately *not* tinted, and that is the archive's own split rather than an
        // inconsistency: `image/preferences-faces.png` shows its pick list on plain white with only hairlines. A pick
        // list is part of the page; a panel of settings is a thing on it.
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(Identifier.table)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Layout.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.contentView?.addSubview(rows)
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.padding),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.padding),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Layout.padding),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Layout.padding),
        ])
    }

    /// The column captions, at the same widths as the row under them so each sits over its own column.
    private func headerRow() -> NSView {
        let row = NSStackView(views: [
            caption("Active", width: Layout.activeColumnWidth),
            spacer(width: Layout.iconSize),
            caption("Name", width: Layout.nameColumnWidth),
            caption("Colour", width: Layout.colourColumnWidth),
            // The caption says what 0 means, because a limit of nothing and no limit at all are opposites and the
            // field cannot tell them apart on its own. The archive's wording.
            caption("Daily limit (0 = disabled)", width: Layout.limitColumnWidth),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Layout.columnSpacing
        row.setAccessibilityIdentifier(Identifier.header)
        return row
    }

    private func caption(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// Holds the icon column's width open with nothing in it.
    private func spacer(width: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalToConstant: width),
            spacer.heightAnchor.constraint(equalToConstant: 1),
        ])
        return spacer
    }

    private func emptyLabel() -> NSTextField {
        // The previous app's wording, which says what is missing rather than that something went wrong.
        let label = NSTextField(labelWithString: "No active categories.")
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// One category as a row of columns: whether it is active, its icon, its name, its colour, its daily limit.
///
/// **The row itself is not a button**, though several things in it are. The Faces tab's row genuinely is one -- the
/// whole line picks that category -- and this one is a record with controls along it, so a button here would announce
/// a press that does nothing to the keyboard and to accessibility.
@MainActor
final class CategoryTableRow: NSStackView {
    let category: CategoryRecord

    /// Why this category cannot be retired, or `nil` when it can. Decided by `CategoryEditRules` and handed in, so
    /// the row draws the answer rather than working it out.
    let retireRefusal: CategoryEditRules.RetireRefusal?

    /// Called with the new limit in minutes, already inside the allowed range.
    var onSetDailyLimit: ((Int) -> Void)?

    /// Called when the Active box is unticked.
    var onRetire: (() -> Void)?

    /// Called when the icon is clicked, with the button itself: a popover has to be anchored to something, and the
    /// row is the only thing that knows which view that is.
    var onPickIcon: ((NSView) -> Void)?

    /// Called when the colour swatch is clicked, with the button itself, for the same reason.
    var onPickColour: ((NSView) -> Void)?

    /// Held so the pickers can be anchored to them after the click.
    private var iconButton: NSButton?
    private var colourButton: NSButton?

    init(category: CategoryRecord, retireRefusal: CategoryEditRules.RetireRefusal? = nil) {
        self.category = category
        self.retireRefusal = retireRefusal
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = CategoryTable.Layout.columnSpacing
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(CategoryTable.Identifier.row(category))
        // A row is a group holding three readings rather than one control, and the name is what identifies it in
        // the tree.
        setAccessibilityRole(.group)
        setAccessibilityLabel(category.name)
        addViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// **The Active box leads, matching the Inactive list.**
    ///
    /// The archive put it last here and first there, reasoning that in a row full of settings the toggle belongs at
    /// the far end, while a retired row has no settings for it to be the end of. That is true of either list read on
    /// its own, and wrong once they are stacked on one tab: the box means the same thing in both, so it reads as one
    /// column running down the tab rather than as two controls that happen to share a name.
    private func addViews() {
        addView(activeBox(), in: .leading)
        addView(icon(), in: .leading)
        addView(name(), in: .leading)
        addView(swatch(), in: .leading)
        addView(dailyLimitField(), in: .leading)
    }

    /// The category's budget for a day, in minutes, with 0 meaning no limit.
    private func dailyLimitField() -> NSView {
        let field = SteppedNumberField(
            value: category.dailyLimitMinutes,
            range: CategoryEditRules.disabledDailyLimit ... CategoryEditRules.maximumDailyLimitMinutes,
            suffix: "min",
            identifier: "category-limit-\(category.id)"
        )
        field.onChange = { [weak self] minutes in self?.onSetDailyLimit?(minutes) }
        return column(field, width: CategoryTable.Layout.limitColumnWidth)
    }

    /// Ticked, this being the active list. Unticking retires the category.
    ///
    /// **Disabled rather than refused when a locked face holds it**, which is the archive's decision and its
    /// reasoning: retiring takes a category off every face it is on, and a locked face is one the user has said keeps
    /// what it has, so the two instructions contradict each other and the app does not get to choose. A box that
    /// offered the edit and then bounced back would be worse than one that says it is not on offer, and the tooltip
    /// names the face, since the row gives no clue which one is in the way.
    private func activeBox() -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(activeChanged))
        box.state = .on
        box.isEnabled = retireRefusal == nil
        box.toolTip = CategoryEditRules.retireRefusalHelp(retireRefusal, categoryName: category.name)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.identifier = NSUserInterfaceItemIdentifier("category-active-\(category.id)")
        box.setAccessibilityIdentifier("category-active-\(category.id)")
        box.setAccessibilityLabel("\(category.name) active")
        return column(box, width: CategoryTable.Layout.activeColumnWidth)
    }

    @objc
    private func activeChanged() {
        onRetire?()
    }

    /// Holds a control's column open at a fixed width, left-aligned inside it, so the column after it starts at the
    /// same x on every row.
    private func column(_ view: NSView, width: CGFloat) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: width),
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.topAnchor.constraint(lessThanOrEqualTo: view.topAnchor),
            cell.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor),
        ])
        return cell
    }

    /// The category's artwork, or a "no sign" glyph for one that has none -- the archive's answer, and better than a
    /// gap, which reads as a column that failed to draw rather than as a category nobody has dressed yet.
    ///
    /// **A button, because it opens the picker**, which is what the archive's was too. It stays borderless and shows
    /// only the artwork: a bordered button here would read as a control in a column of readings.
    private func icon() -> NSView {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(pickIcon)
        button.identifier = NSUserInterfaceItemIdentifier("category-icon-\(category.id)")
        button.setAccessibilityIdentifier("category-icon-\(category.id)")
        if let iconName = category.iconName, let image = ActivityIcon.image(named: iconName, pointSize: CategoryTable.Layout.iconSize) {
            button.image = image
            // The previous app drew this black, which it could: its form was white in every appearance. This panel
            // is a dynamic colour, so black would disappear into it in dark mode. `.labelColor` is the same intent
            // -- the colour text is drawn in -- resolved as it draws.
            button.contentTintColor = .labelColor
            button.setAccessibilityLabel("\(category.name) icon, \(IconStore.displayName(for: iconName))")
        } else {
            button.image = NSImage(systemSymbolName: "nosign", accessibilityDescription: "No icon")
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel("\(category.name) icon, none")
        }
        iconButton = button
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.iconSize),
            button.heightAnchor.constraint(equalToConstant: CategoryTable.Layout.iconSize),
        ])
        return button
    }

    @objc
    private func pickIcon() {
        guard let iconButton else { return }
        onPickIcon?(iconButton)
    }

    private func name() -> NSTextField {
        let label = NSTextField(labelWithString: category.name)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.nameColumnWidth).isActive = true
        return label
    }

    /// The swatch is 14pt in a 46pt column, left-aligned, so the column's own width comes from its caption rather
    /// than from the square: what has to line up is where the *next* column starts.
    ///
    /// **A button, because it opens the palette**, as the archive's was. The swatch sits inside it and draws itself:
    /// an `NSView` handles no mouse event of its own, so a click on the square goes up the responder chain to the
    /// button holding it -- the same arrangement the folding headings use, and the reason the square can stay a thing
    /// that only knows how to draw a colour.
    private func swatch() -> NSView {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .noImage
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(pickColour)
        button.identifier = NSUserInterfaceItemIdentifier("category-colour-\(category.id)")
        button.setAccessibilityIdentifier("category-colour-\(category.id)")
        // Named for what it is rather than for the shade, which the row cannot know: the colour's own name lives in
        // the `colour` table and the record carries only the colour itself.
        button.setAccessibilityLabel(category.colour == nil ? "\(category.name) colour, none" : "\(category.name) colour")

        let square = ColourSwatch(colour: category.colour)
        button.addSubview(square)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalTo: square.widthAnchor),
            button.heightAnchor.constraint(equalTo: square.heightAnchor),
            square.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            square.topAnchor.constraint(equalTo: button.topAnchor),
        ])
        colourButton = button
        return column(button, width: CategoryTable.Layout.colourColumnWidth)
    }

    @objc
    private func pickColour() {
        guard let colourButton else { return }
        onPickColour?(colourButton)
    }
}

/// A category's colour as a small rounded square, and the absence of one as a hollow outline.
///
/// Hollow rather than a grey fill, which is the archive's distinction and worth keeping: grey is a colour in the
/// palette (`database/005_colour.sql`), so filling with it would say the category is grey when the truth is that
/// nobody has chosen.
@MainActor
final class ColourSwatch: NSView {
    private let colour: NSColor?

    init(colour: NSColor?) {
        self.colour = colour
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CategoryTable.Layout.swatchSize),
            heightAnchor.constraint(equalToConstant: CategoryTable.Layout.swatchSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Drawn rather than a layer with a background colour, for the reason the panel is an `NSBox`: `draw` runs in the
    /// appearance on screen, so the outline follows it instead of freezing the one it was built under.
    override func draw(_ dirtyRect: NSRect) {
        let square = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: square, xRadius: CategoryTable.Layout.swatchCornerRadius, yRadius: CategoryTable.Layout.swatchCornerRadius)
        if let colour {
            colour.setFill()
            path.fill()
            // A faint outline, so a swatch the same colour as the panel behind it still reads as a square.
            NSColor.secondaryLabelColor.withAlphaComponent(CategoryTable.Layout.swatchStrokeOpacity).setStroke()
        } else {
            NSColor.labelColor.setStroke()
        }
        path.stroke()
    }
}
