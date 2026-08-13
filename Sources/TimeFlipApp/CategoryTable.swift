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
/// **Read-only so far.** In the previous app every cell here was a control: the icon opened a picker, the swatch
/// opened another, the name became a field on a right-click, and there were two more columns after these, a daily
/// limit and an Active checkbox. Each of those is its own piece of work, and a column drawn dead invites the reader
/// to try it -- which is the reason the archive gave for dropping three columns from its retired list rather than
/// disabling them.
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
                rows.addView(CategoryTableRow(category: category), in: .top)
            }
        }
        shownCategories = categories
    }

    private func addPanel() {
        translatesAutoresizingMaskIntoConstraints = false
        // An NSBox rather than a layer with a background colour, as on the Faces tab: it keeps the fill a dynamic
        // colour, so the panel follows the appearance instead of freezing whichever one it was built under.
        panel.boxType = .custom
        panel.fillColor = .textBackgroundColor
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
            spacer(width: Layout.iconSize),
            caption("Name", width: Layout.nameColumnWidth),
            caption("Colour", width: Layout.colourColumnWidth),
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

/// One category as a row of columns: its icon, its name, its colour.
///
/// Not a button. Nothing here is clickable yet, and an `NSButton` would announce itself to the keyboard and to
/// accessibility as something to press -- which the Faces tab's row genuinely is, and this is not.
@MainActor
final class CategoryTableRow: NSStackView {
    let category: CategoryRecord

    init(category: CategoryRecord) {
        self.category = category
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

    private func addViews() {
        addView(icon(), in: .leading)
        addView(name(), in: .leading)
        addView(swatch(), in: .leading)
    }

    /// The category's artwork, or a "no sign" glyph for one that has none -- the archive's answer, and better than a
    /// gap, which reads as a column that failed to draw rather than as a category nobody has dressed yet.
    private func icon() -> NSView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyUpOrDown
        if let iconName = category.iconName, let image = ActivityIcon.image(named: iconName, pointSize: CategoryTable.Layout.iconSize) {
            view.image = image
            // The previous app drew this black, which it could: its form was white in every appearance. This panel
            // is a dynamic colour, so black would disappear into it in dark mode. `.labelColor` is the same intent
            // -- the colour text is drawn in -- resolved as it draws.
            view.contentTintColor = .labelColor
        } else {
            view.image = NSImage(systemSymbolName: "nosign", accessibilityDescription: "No icon")
            view.contentTintColor = .secondaryLabelColor
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.iconSize),
            view.heightAnchor.constraint(equalToConstant: CategoryTable.Layout.iconSize),
        ])
        return view
    }

    private func name() -> NSTextField {
        let label = NSTextField(labelWithString: category.name)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.nameColumnWidth).isActive = true
        return label
    }

    private func swatch() -> NSView {
        let swatch = ColourSwatch(colour: category.colour)
        // The swatch is 14pt in a 46pt column, left-aligned, so the column's own width comes from its caption
        // rather than from the square: what has to line up is where the *next* column starts.
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(swatch)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: CategoryTable.Layout.colourColumnWidth),
            cell.heightAnchor.constraint(equalToConstant: CategoryTable.Layout.swatchSize),
            swatch.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            swatch.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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
