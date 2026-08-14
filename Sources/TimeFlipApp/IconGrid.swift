import AppKit

/// The grid of icons a category's artwork is picked from, shown in a popover under its icon.
///
/// **Six wide, at the archive's measurements**, and that number is a finding rather than a preference: 42 icons are
/// seeded (`database/004_icon.sql`), so six columns lay them out as an even 6 by 7 with no partial last row and
/// nothing to scroll.
///
/// **There is no None cell.** Clearing an icon is done by clicking the one already chosen, which is
/// `CategoryEditRules.iconSelection` -- the same rule the previous app used, and the reason a grid of artwork does
/// not need a cell containing nothing.
@MainActor
final class IconGrid: NSView {
    enum Identifier {
        static let grid = "icon-grid"
        /// A cell is named for the icon it offers, since that is what a script would look for.
        static func cell(_ icon: IconRecord) -> String { "icon-cell-\(icon.fileName)" }
    }

    enum Layout {
        /// The archive's numbers, every one of them.
        static let columns = 6
        static let cellSize: CGFloat = 40
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 4
        static let cellCornerRadius: CGFloat = 6
        static let cellPadding: CGFloat = 8
        static let iconPointSize: CGFloat = 24
        static let selectedStrokeWidth: CGFloat = 2
        static let strokeWidth: CGFloat = 1
        static let strokeOpacity: CGFloat = 0.2
    }

    /// Called with the `icon_id` to store, which `CategoryEditRules` has already decided -- so the same click that
    /// picks an icon is the one that clears it when it was already chosen.
    var onPick: ((Int) -> Void)?

    private(set) var icons: [IconRecord] = []
    private let selectedIconName: String?
    private let rows = NSStackView()

    /// - Parameter selected: the icon the category currently has, by filename, since that is what a `CategoryRecord`
    ///   carries. `nil` for a category with none.
    init(icons: [IconRecord], selected selectedIconName: String?) {
        self.icons = icons
        self.selectedIconName = selectedIconName
        super.init(frame: .zero)
        setAccessibilityIdentifier(Identifier.grid)
        addCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The id a click on `icon` should store, given what the category already has.
    func selection(clicking icon: IconRecord) -> Int {
        CategoryEditRules.iconSelection(
            clicked: icon.id,
            selected: icons.first { $0.fileName == selectedIconName }?.id ?? CategoryEditRules.noIcon
        )
    }

    private func addCells() {
        translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Layout.spacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        for row in stride(from: 0, to: icons.count, by: Layout.columns) {
            let line = NSStackView(views: icons[row ..< min(row + Layout.columns, icons.count)].map(cell))
            line.orientation = .horizontal
            line.spacing = Layout.spacing
            rows.addView(line, in: .top)
        }

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.padding),
        ])
    }

    private func cell(_ icon: IconRecord) -> NSView {
        let cell = IconGridCell(icon: icon, isSelected: icon.fileName == selectedIconName)
        cell.onClick = { [weak self] in
            guard let self else { return }
            onPick?(selection(clicking: icon))
        }
        return cell
    }
}

/// One icon in the grid: the artwork on a rounded tile, outlined when it is the one the category has.
///
/// A button, so it is pressable by the keyboard, by a screen reader and by a script, and named for its icon.
@MainActor
final class IconGridCell: NSButton {
    let icon: IconRecord
    let isSelected: Bool

    var onClick: (() -> Void)?

    init(icon: IconRecord, isSelected: Bool) {
        self.icon = icon
        self.isSelected = isSelected
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        // The focus ring reads as a second selection sitting beside the real one, the first cell taking focus when
        // the popover opens. The archive turned it off for that reason and kept the cells reachable.
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(clicked)
        identifier = NSUserInterfaceItemIdentifier(IconGrid.Identifier.cell(icon))
        setAccessibilityIdentifier(IconGrid.Identifier.cell(icon))
        setAccessibilityLabel(icon.name)
        // The filename is not a thing to show anybody, so the readable name is what a hover says.
        toolTip = icon.name

        wantsLayer = true
        layer?.cornerRadius = IconGrid.Layout.cellCornerRadius
        layer?.borderWidth = isSelected ? IconGrid.Layout.selectedStrokeWidth : IconGrid.Layout.strokeWidth
        layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(IconGrid.Layout.strokeOpacity).cgColor

        if let artwork = ActivityIcon.image(named: icon.fileName, pointSize: IconGrid.Layout.iconPointSize) {
            artwork.isTemplate = true
            image = artwork
            imageScaling = .scaleProportionallyDown
        } else {
            // A cell that cannot draw its artwork is a packaging mistake rather than a cell to leave out: reporting
            // it beats pretending the icon is absent, which is the archive's reasoning for checking the bundle
            // rather than a list in Swift.
            image = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: icon.name)
        }
        // Drawn in the ordinary text colour rather than the black the archive could hardcode: its grid sat on a
        // white popover in every appearance, and this one follows the system's.
        contentTintColor = .labelColor

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: IconGrid.Layout.cellSize),
            heightAnchor.constraint(equalToConstant: IconGrid.Layout.cellSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Redraws the outline when the appearance changes, the border being a `CGColor` and so resolved once when it is
    /// set rather than each time it is drawn.
    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(IconGrid.Layout.strokeOpacity).cgColor
    }

    @objc
    private func clicked() {
        onClick?()
    }
}
