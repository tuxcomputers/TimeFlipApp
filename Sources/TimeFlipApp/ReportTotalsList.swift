import AppKit

/// What the picked range came to, per category: the icon on its colour, the name, and the time on the right.
///
/// **Only the categories that recorded something**, biggest first, which is `TimeEntryStore.totals` doing the deciding.
/// A category with nothing in the range is absent rather than shown as `0:00`, and a range with nothing in it says so
/// in words rather than drawing an empty table.
///
/// The archive's row, and its measurements come from the Faces tab's list (`CategoryListView.Layout`) rather than being
/// restated, since the two are the same treatment: a 36pt row, a 28pt colour square holding a 20pt glyph, the name
/// beside it. A category with no icon still fills the slot as a hollow square, so every name lines up whether or not
/// one is set.
@MainActor
final class ReportTotalsList: NSView {
    enum Identifier {
        static let list = "report-totals"
        static let empty = "report-totals-empty"
        static func row(_ total: CategoryTotal) -> String { "report-total-\(total.categoryID)" }
        static func duration(_ total: CategoryTotal) -> String { "report-total-\(total.categoryID)-duration" }
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
        if totals.isEmpty {
            rows.addView(emptyLabel(), in: .top)
        } else {
            for (index, total) in totals.enumerated() {
                if index > 0 {
                    add(divider())
                }
                add(row(total, showingSeconds: showingSeconds))
            }
        }
        shownTotals = totals
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

    private func row(_ total: CategoryTotal, showingSeconds: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        // A group holding two readings rather than a control: nothing here is clickable, editing an entry being its own
        // piece of work.
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityIdentifier(Identifier.row(total))
        row.setAccessibilityLabel(total.name)

        let swatch = makeSwatch(total)
        let name = NSTextField(labelWithString: total.name)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let duration = NSTextField(
            labelWithString: DurationFormat.hoursMinutesSeconds(
                total.seconds,
                // Rounded rather than truncated, unlike the menu bar's live figure: this is a static historical sum,
                // so a 59.6-second total should read as a minute rather than one second short of what was logged.
                rounding: .round,
                showingSeconds: showingSeconds
            )
        )
        // Monospaced digits, so the colon sits in the same place down the column and the figures can be compared by
        // eye rather than read one at a time.
        duration.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        duration.alignment = .right
        duration.translatesAutoresizingMaskIntoConstraints = false
        duration.setAccessibilityIdentifier(Identifier.duration(total))

        row.addSubview(swatch)
        row.addSubview(name)
        row.addSubview(duration)
        let padding = CategoryListView.Layout.horizontalPadding
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.rowHeight),

            swatch.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: padding),
            swatch.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),

            name.leadingAnchor.constraint(
                equalTo: swatch.trailingAnchor,
                constant: CategoryListView.Layout.rowSpacing
            ),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // The name gives way before the figure does: a narrow window truncates a long category name rather than
            // cutting the number the row exists to show.
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: duration.leadingAnchor,
                constant: -CategoryListView.Layout.rowSpacing
            ),

            duration.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -padding),
            duration.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// The category's colour with its icon on it, or a hollow square for one with no icon -- the same swatch the Faces
    /// tab's list draws, for the same reason: the outline replaces the colour rather than sitting on it, because with
    /// no glyph to see through a filled square would just be a coloured box meaning nothing.
    private func makeSwatch(_ total: CategoryTotal) -> NSView {
        let swatch = NSBox()
        swatch.boxType = .custom
        swatch.cornerRadius = CategoryListView.Layout.swatchCornerRadius
        swatch.contentViewMargins = .zero
        swatch.titlePosition = .noTitle
        swatch.translatesAutoresizingMaskIntoConstraints = false

        guard let iconName = total.iconName,
              let icon = ActivityIcon.image(named: iconName, pointSize: CategoryListView.Layout.iconSize)
        else {
            swatch.fillColor = .clear
            swatch.borderWidth = 1
            swatch.borderColor = .labelColor
            return swatch
        }

        swatch.borderWidth = 0
        swatch.fillColor = total.colour ?? .controlBackgroundColor
        let iconView = NSImageView(image: icon)
        // White where the colour is dark enough to swallow a black glyph, which is what the colour's own
        // `white_lines` column is for.
        iconView.contentTintColor = total.usesWhiteLines ? .white : .black
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
