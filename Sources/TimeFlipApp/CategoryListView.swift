import AppKit

/// The list of categories, drawn the way the previous app drew it: one row each, a colour swatch holding
/// the icon, the name beside it, hairlines between rows, all on a rounded panel.
///
/// **Nothing here responds to a click.** The rows are what a face is assigned from, so each one becomes a
/// control -- but not yet.
@MainActor
final class CategoryListView: NSView {
    enum Identifier {
        static let list = "category-list"
        /// A row is named for the category it shows, since that is what a script would look for.
        static func row(_ category: CategoryRecord) -> String { "category-row-\(category.id)" }
    }

    enum Layout {
        /// Copied from the previous app, where each of these was arrived at against real artwork: a 36pt
        /// row, a 28pt swatch sized to clear the 20pt icon while still fitting the row, and 12pt between
        /// the swatch and the name.
        static let rowHeight: CGFloat = 36
        static let iconSize: CGFloat = 20
        static let swatchSize: CGFloat = 28
        static let swatchCornerRadius: CGFloat = 6
        static let rowSpacing: CGFloat = 12
        static let horizontalPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 8
        static let dividerHeight: CGFloat = 1
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
    /// Rebuilt rather than diffed. The list is read from the database every time it is shown, so it
    /// arrives whole, and reconciling it against what is on screen would be work in service of nothing.
    func show(_ categories: [CategoryRecord]) {
        for view in rows.views {
            rows.removeView(view)
        }
        for (index, category) in categories.enumerated() {
            if index > 0 {
                add(divider())
            }
            add(CategoryRowView(category: category))
        }
        shownCategories = categories
    }

    /// Adds a row or a divider, spanning the panel's full width.
    ///
    /// The width constraint has to be activated **after** the view is in the stack, not while building it:
    /// an anchor pair with no common ancestor yet is not a constraint that waits, it is an exception at the
    /// moment of activation.
    private func add(_ view: NSView) {
        rows.addView(view, in: .top)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
        ])
    }

    private func addPanel() {
        translatesAutoresizingMaskIntoConstraints = false
        // An NSBox rather than a layer with a background colour: it keeps the fill a dynamic colour, so
        // the panel follows the appearance instead of freezing whichever one it was built under.
        panel.boxType = .custom
        panel.fillColor = .textBackgroundColor
        panel.borderWidth = 0
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(Identifier.list)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.distribution = .fill
        rows.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.contentView?.addSubview(rows)
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.topAnchor.constraint(equalTo: content.topAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func divider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: Layout.dividerHeight).isActive = true
        return divider
    }
}

/// One category: its colour swatch with the icon on it, then its name.
@MainActor
final class CategoryRowView: NSView {
    let category: CategoryRecord

    init(category: CategoryRecord) {
        self.category = category
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(CategoryListView.Identifier.row(category))
        setAccessibilityLabel(category.name)
        addContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func addContent() {
        let swatch = makeSwatch()
        let name = NSTextField(labelWithString: category.name)
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(swatch)
        addSubview(name)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CategoryListView.Layout.rowHeight),

            swatch.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: CategoryListView.Layout.horizontalPadding
            ),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),

            name.leadingAnchor.constraint(
                equalTo: swatch.trailingAnchor,
                constant: CategoryListView.Layout.rowSpacing
            ),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -CategoryListView.Layout.horizontalPadding
            ),
        ])
    }

    /// The colour swatch, with the category's icon drawn on it.
    ///
    /// A category with no icon still fills the slot, as a hollow outline -- so it reads as "nothing set"
    /// rather than as a gap, and every name in the list lines up either way. The outline replaces the
    /// colour rather than sitting on it, which is how the previous app drew it too: with no glyph to see
    /// through, a filled swatch would just be a coloured square meaning nothing.
    private func makeSwatch() -> NSView {
        let swatch = NSBox()
        swatch.boxType = .custom
        swatch.cornerRadius = CategoryListView.Layout.swatchCornerRadius
        swatch.contentViewMargins = .zero
        swatch.titlePosition = .noTitle
        swatch.translatesAutoresizingMaskIntoConstraints = false

        guard let iconName = category.iconName,
              let icon = ActivityIcon.image(named: iconName, pointSize: CategoryListView.Layout.iconSize)
        else {
            swatch.fillColor = .clear
            swatch.borderWidth = 1
            swatch.borderColor = .labelColor
            return swatch
        }

        swatch.borderWidth = 0
        // No colour set falls back to the control background, so the icon still has something to sit on.
        swatch.fillColor = category.colour ?? .controlBackgroundColor
        let iconView = NSImageView(image: icon)
        // The icon takes the colour of the swatch it is on: white where the colour is dark enough to
        // swallow a black glyph, which is what the colour's own `white_lines` column is for.
        iconView.contentTintColor = category.usesWhiteLines ? .white : .black
        iconView.translatesAutoresizingMaskIntoConstraints = false
        swatch.contentView?.addSubview(iconView)
        if let content = swatch.contentView {
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: CategoryListView.Layout.iconSize),
                iconView.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.iconSize),
            ])
        }
        return swatch
    }
}
