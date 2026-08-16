import AppKit

/// The palette a category's colour is picked from, shown in a popover under its swatch.
///
/// **A list rather than a grid, which is the archive's shape and its reasoning**: an icon is recognisable as a
/// picture, so a grid of them can go without labels, and a colour is not. Twenty squares with no names would be a
/// puzzle rather than a choice -- "Maroon" and "Brown" are one shade apart on screen and nothing but the word tells
/// them apart -- so each row carries its name, and the list runs in the palette's own order (`ColourStore.all`).
///
/// **There is no None row.** Clearing a colour is done by clicking the one already chosen, which is
/// `CategoryEditRules.colourSelection` -- the same rule the icon grid uses, and the reason a list of colours does not
/// need a row containing no colour.
@MainActor
final class ColourList: NSView {
    enum Identifier {
        static let list = "colour-list"
        /// A row is named for the colour it offers, since that is what a script would look for.
        static func row(_ colour: ColourRecord) -> String { "colour-option-\(colour.name)" }
    }

    enum Layout {
        /// The archive's numbers, every one of them (`SettingsLayoutConstants.ColorPicker`).
        static let rowSpacing: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 4
        static let rowHorizontalPadding: CGFloat = 8
        static let listPadding: CGFloat = 6
    }

    /// Called with the `colour_id` to store, which `CategoryEditRules` has already decided -- so the same click that
    /// picks a colour is the one that clears it when it was already chosen.
    var onPick: ((Int) -> Void)?

    private(set) var colours: [ColourRecord] = []
    private let selectedColourID: Int
    private let rows = NSStackView()

    /// - Parameter selected: the `colour_id` the category currently has, `CategoryEditRules.noColour` for one with no
    ///   colour set.
    init(colours: [ColourRecord], selected selectedColourID: Int) {
        self.colours = colours
        self.selectedColourID = selectedColourID
        super.init(frame: .zero)
        setAccessibilityIdentifier(Identifier.list)
        addRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The id a click on `colour` should store, given what the category already has.
    func selection(clicking colour: ColourRecord) -> Int {
        CategoryEditRules.colourSelection(clicked: colour.id, selected: selectedColourID)
    }

    private func addRows() {
        translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        // Every row is pinned to the stack's own width below, so a short name like "Red" still gives a row as wide as
        // the widest one: a click beside the word has to land on the row rather than in a gap.
        rows.distribution = .fill
        // No gap between rows: they are a list to run down rather than separate controls, and the padding inside each
        // row is what keeps them apart.
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        for colour in colours {
            let row = ColourListRow(colour: colour, isSelected: colour.id == selectedColourID)
            row.onClick = { [weak self] in
                guard let self else { return }
                onPick?(selection(clicking: colour))
            }
            rows.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: Layout.listPadding),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.listPadding),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.listPadding),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.listPadding),
        ])
    }
}

/// One colour in the list: its swatch, its name, and a tick when it is the one the category has.
///
/// **The whole row is the target**, not the square: a 14pt swatch is a small thing to hit for a choice the name
/// beside it is equally about.
///
/// **The row *is* the button**, with the swatch and the label as its own subviews, which is the Faces tab's row
/// pattern (`CategoryRowView`) and not a style choice. A button sitting *behind* two siblings does not work: a click
/// on the label goes up the responder chain to the label's superview, and the button is not that -- it is a sibling,
/// so the press reaches nobody. Measured, not reasoned: with the button behind, a real click on the word "Navy"
/// closed nothing and stored nothing, while the same click on a row built this way picks the colour (see
/// `Tests/Methods.md`).
@MainActor
final class ColourListRow: NSButton {
    let colour: ColourRecord
    let isSelected: Bool

    var onClick: (() -> Void)?

    init(colour: ColourRecord, isSelected: Bool) {
        self.colour = colour
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func addViews() {
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        // The first row takes focus when the popover opens and its focus ring then reads as a second selection
        // sitting beside the real one. The tick is what marks the current colour; the archive turned the ring off
        // here for the same reason it did on the icon grid.
        focusRingType = .none
        target = self
        action = #selector(clicked)
        identifier = NSUserInterfaceItemIdentifier(ColourList.Identifier.row(colour))
        setAccessibilityIdentifier(ColourList.Identifier.row(colour))
        setAccessibilityLabel(isSelected ? "\(colour.name), selected" : colour.name)

        let swatch = ColourSwatch(colour: colour.colour)
        let name = NSTextField(labelWithString: colour.name)
        name.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        addSubview(name)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ColourList.Layout.rowHorizontalPadding),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),

            name.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: ColourList.Layout.rowSpacing),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.topAnchor.constraint(equalTo: topAnchor, constant: ColourList.Layout.rowVerticalPadding),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ColourList.Layout.rowVerticalPadding),
        ])

        guard isSelected else {
            // Nothing on the right, and the name still has to reach it, or every row is only as wide as its word and
            // the list has a ragged edge to click at.
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -ColourList.Layout.rowHorizontalPadding
            ).isActive = true
            return
        }
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected") ?? NSImage())
        tick.contentTintColor = .secondaryLabelColor
        tick.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tick)
        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: ColourList.Layout.rowSpacing),
            tick.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ColourList.Layout.rowHorizontalPadding),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc
    private func clicked() {
        onClick?()
    }
}
