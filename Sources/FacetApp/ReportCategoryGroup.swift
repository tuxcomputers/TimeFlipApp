import AppKit

/// One category on the Report tab: a heading line carrying its icon, its name and its total, with the stretches that
/// make up that total folded away behind it.
///
/// **Closed by default**, every one of them. The totals are the answer to the range; the entries are the working, and
/// nobody wants twelve categories' working on screen at once. Opening one is what asks for it -- and it is also when
/// the entries are read, so a closed group costs no query at all.
///
/// **The whole heading line folds it**, per the rule in `CLAUDE.md`: the triangle, the swatch, the name, the total and
/// the space between them. The line *is* the button, with all of that as its subviews, because a click on a label goes
/// up the responder chain to the label's own superview -- a button merely sitting behind them is never reached, which
/// has shipped twice in this app already.
///
/// Its own type rather than `CategorySection`, which folds the Categories tab's two lists: that one draws a bold
/// heading on a tinted panel and this is a row of a list, carrying a swatch and a figure. What they share is the
/// pattern, not the drawing.
@MainActor
final class ReportCategoryGroup: NSView {
    enum Identifier {
        static func group(_ categoryID: Int) -> String { "report-total-\(categoryID)" }
        static func heading(_ categoryID: Int) -> String { "report-total-\(categoryID)-heading" }
        static func toggle(_ categoryID: Int) -> String { "report-total-\(categoryID)-toggle" }
        static func duration(_ categoryID: Int) -> String { "report-total-\(categoryID)-duration" }
        static func entry(_ timeEntryID: Int) -> String { "report-entry-\(timeEntryID)" }
    }

    enum Layout {
        /// The heading line, at the same height as every other list row in the app.
        static let rowHeight = CategoryListView.Layout.rowHeight
        /// A stretch's line, shorter than the heading: it is a reading rather than a control, and a run of them should
        /// read as detail under the row above rather than as more rows of the same list.
        static let entryHeight: CGFloat = 24
        /// The triangle's column, ahead of the swatch.
        static let toggleWidth: CGFloat = 16
        /// Where an entry's first column starts: under the category's name, so the working lines up with what it is the
        /// working for.
        static let entryIndent = toggleWidth + CategoryListView.Layout.horizontalPadding
            + CategoryListView.Layout.swatchSize + CategoryListView.Layout.rowSpacing
        /// The date column, and the two clock columns. Fixed, so the digits line up down the list however many rows
        /// there are; wide enough for `HH:mm:ss`, which is the longer of the two forms either can take.
        static let dateWidth: CGFloat = 52
        static let clockWidth: CGFloat = 68
        static let clockSpacing: CGFloat = 6
    }

    let total: CategoryTotal

    private(set) var isExpanded = false

    /// Called when the group is opened, and answered with what to draw: the entries are read at that moment rather than
    /// handed over with the total, because until it is opened nobody has asked the question.
    var entries: (() -> [TimeEntryRecord])?

    /// Called when the group is opened or closed, so the window can record it.
    var onToggle: ((Bool) -> Void)?

    private let showingSeconds: Bool
    private let calendar: Calendar
    private let toggle = NSButton()
    private let heading = NSButton()
    private let list = NSStackView()
    private var openConstraint: NSLayoutConstraint!
    private var shutConstraint: NSLayoutConstraint!
    /// The height of the open list, stated as a number of rows rather than left to the stack view holding them.
    ///
    /// **A stack view given more height than its views need spreads the slack between them**, and this group's bottom is
    /// what an open group's height is measured from -- so without this the list was elastic, the group kept whatever
    /// height it was handed, and 12pt rows sat 60pt apart. The same fault as the Report tab's calendars, one level down.
    private var listHeight: NSLayoutConstraint!

    init(total: CategoryTotal, showingSeconds: Bool, calendar: Calendar = .current) {
        self.total = total
        self.showingSeconds = showingSeconds
        self.calendar = calendar
        super.init(frame: .zero)
        addContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Opens or closes the group. Opening reads the entries; closing throws the rows away rather than hiding them, so
    /// re-opening reads again -- the range's figures can have changed while it was shut.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggle.state = expanded ? .on : .off
        for view in list.views {
            list.removeView(view)
        }
        if expanded {
            let records = entries?() ?? []
            if records.isEmpty {
                // Only reachable if the entries went away between the total being summed and the group being opened --
                // a range that has moved on, or a row deleted elsewhere. Saying so beats an empty gap.
                list.addView(missingLabel(), in: .top)
            }
            for record in records {
                list.addView(row(record), in: .top)
            }
        }
        list.isHidden = !expanded
        listHeight.constant = CGFloat(list.views.count) * Layout.entryHeight
        applyFold()
    }

    /// Deactivates before activating: both pin this view's own bottom, so an instant where they are both active is an
    /// unsatisfiable pair and a broken layout in the log.
    private func applyFold() {
        if isExpanded {
            shutConstraint.isActive = false
            openConstraint.isActive = true
        } else {
            openConstraint.isActive = false
            shutConstraint.isActive = true
        }
    }

    @objc
    private func toggled() {
        setExpanded(!isExpanded)
        onToggle?(isExpanded)
    }

    private func addContent() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Identifier.group(total.categoryID))
        setAccessibilityLabel(total.name)

        // A disclosure button draws the triangle and nothing else. It sits in front of the heading line and keeps
        // working on its own, which is what a triangle should do; the line behind it is what makes the rest of the row
        // a target.
        toggle.setButtonType(.onOff)
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.state = .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityIdentifier(Identifier.toggle(total.categoryID))
        toggle.setAccessibilityLabel("\(total.name) entries")

        heading.title = ""
        heading.isBordered = false
        heading.bezelStyle = .inline
        heading.setButtonType(.momentaryChange)
        heading.imagePosition = .noImage
        heading.target = self
        heading.action = #selector(toggled)
        heading.focusRingType = .none
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(Identifier.heading(total.categoryID))
        heading.setAccessibilityLabel(
            "\(total.name), \(ReportEntryText.duration(total.seconds, showingSeconds: showingSeconds))"
        )

        let swatch = ReportSwatch.make(total)
        let name = NSTextField(labelWithString: total.name)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let duration = figure(ReportEntryText.duration(total.seconds, showingSeconds: showingSeconds))
        duration.setAccessibilityIdentifier(Identifier.duration(total.categoryID))

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.isHidden = true
        list.translatesAutoresizingMaskIntoConstraints = false

        addSubview(heading)
        // Inside the button, all of it: the words, the swatch and the figure. See the class comment.
        heading.addSubview(swatch)
        heading.addSubview(name)
        heading.addSubview(duration)
        addSubview(toggle)
        addSubview(list)

        let padding = CategoryListView.Layout.horizontalPadding
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.heightAnchor.constraint(equalToConstant: Layout.rowHeight),

            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.widthAnchor.constraint(equalToConstant: Layout.toggleWidth),
            toggle.centerYAnchor.constraint(equalTo: heading.centerYAnchor),

            swatch.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: padding),
            swatch.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: CategoryListView.Layout.swatchSize),

            name.leadingAnchor.constraint(
                equalTo: swatch.trailingAnchor,
                constant: CategoryListView.Layout.rowSpacing
            ),
            name.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            // The name gives way before the figure does: a narrow window truncates a long category name rather than
            // cutting the number the row exists to show.
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: duration.leadingAnchor,
                constant: -CategoryListView.Layout.rowSpacing
            ),

            duration.trailingAnchor.constraint(equalTo: heading.trailingAnchor, constant: -padding),
            duration.centerYAnchor.constraint(equalTo: heading.centerYAnchor),

            list.topAnchor.constraint(equalTo: heading.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        listHeight = list.heightAnchor.constraint(equalToConstant: 0)
        listHeight.isActive = true
        openConstraint = bottomAnchor.constraint(equalTo: list.bottomAnchor)
        shutConstraint = bottomAnchor.constraint(equalTo: heading.bottomAnchor)
        applyFold()
    }

    /// One stretch: the day, the clock times it ran between, and how long that was.
    private func row(_ entry: TimeEntryRecord) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityIdentifier(Identifier.entry(entry.timeEntryID))
        row.setAccessibilityLabel(
            ReportEntryText.spoken(entry, showingSeconds: showingSeconds, calendar: calendar)
        )

        let date = figure(ReportEntryText.date(entry.start, calendar: calendar), alignment: .left)
        let from = figure(
            ReportEntryText.clock(entry.start, showingSeconds: showingSeconds, calendar: calendar),
            alignment: .left
        )
        // An en dash rather than a hyphen: it is a range, and it is what reads as "to" between two times.
        let between = figure("\u{2013}", alignment: .center)
        let to = figure(
            ReportEntryText.clock(entry.end, showingSeconds: showingSeconds, calendar: calendar),
            alignment: .left
        )
        let length = figure(ReportEntryText.duration(entry.seconds, showingSeconds: showingSeconds))
        for label in [date, from, between, to, length] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            row.addSubview(label)
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Layout.entryHeight),

            date.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.entryIndent),
            date.widthAnchor.constraint(equalToConstant: Layout.dateWidth),

            from.leadingAnchor.constraint(equalTo: date.trailingAnchor),
            from.widthAnchor.constraint(equalToConstant: Layout.clockWidth),
            between.leadingAnchor.constraint(equalTo: from.trailingAnchor),
            to.leadingAnchor.constraint(equalTo: between.trailingAnchor, constant: Layout.clockSpacing),
            to.widthAnchor.constraint(equalToConstant: Layout.clockWidth),

            length.trailingAnchor.constraint(
                equalTo: row.trailingAnchor,
                constant: -CategoryListView.Layout.horizontalPadding
            ),
            length.leadingAnchor.constraint(greaterThanOrEqualTo: to.trailingAnchor),
        ])
        return row
    }

    private func figure(_ text: String, alignment: NSTextAlignment = .right) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        // Monospaced digits, so a colon sits in the same place down every column and the figures can be compared by eye
        // rather than read one at a time.
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func missingLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "No entries left in this range.")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: Layout.entryHeight).isActive = true
        return label
    }
}

/// The category's colour with its icon on it, or a hollow square for one with no icon.
///
/// Pulled out of the row it used to be built in because two things draw it now, the heading line and nothing else yet
/// -- and because the Faces tab's list draws the same square from its own copy. One of those is worth folding in when
/// the next one appears; two is not yet a rule being broken twice.
enum ReportSwatch {
    @MainActor
    static func make(_ total: CategoryTotal) -> NSView {
        let swatch = NSBox()
        swatch.boxType = .custom
        swatch.cornerRadius = CategoryListView.Layout.swatchCornerRadius
        swatch.contentViewMargins = .zero
        swatch.titlePosition = .noTitle
        swatch.translatesAutoresizingMaskIntoConstraints = false

        guard let iconName = total.iconName,
              let icon = ActivityIcon.image(named: iconName, pointSize: CategoryListView.Layout.iconSize)
        else {
            // Hollow rather than a grey fill: grey is a colour in the palette, so filling with it would say the
            // category is grey when the truth is that nobody has chosen.
            swatch.fillColor = .clear
            swatch.borderWidth = 1
            swatch.borderColor = .labelColor
            return swatch
        }

        swatch.borderWidth = 0
        swatch.fillColor = total.colour ?? .controlBackgroundColor
        let iconView = NSImageView(image: icon)
        // White where the colour is dark enough to swallow a black glyph, which is what the colour's own `white_lines`
        // column is for.
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
}

/// **Its default is written here rather than taken from an initialiser**, unlike the other two, because that is where
/// it lives: a group is built folded every time (`isExpanded` is a stored `false`), the caller having no say in it.
extension ReportCategoryGroup: CollapsibleSection {
    func restoreDefaultState() { setExpanded(false) }
}
