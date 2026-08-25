import AppKit

/// A section of a Settings tab that folds away on its own tinted panel: a disclosure triangle and a heading, with
/// whatever the section holds under them.
///
/// **This is `CLAUDE.md`'s first case for a collapsible group**, and `DisclosureRow` is the second. The difference is
/// whether the group has a panel of its own to close. This one does, so its heading sits *on* that panel as the first
/// row of it and folding shuts the panel around the heading; a `DisclosureRow` is a line of a list that already has a
/// panel, so there is nothing of its own to close.
///
/// **The heading is on the panel, not above it**, which is what the archive drew: each section was a `Section` of a
/// `.formStyle(.grouped)` form, and a grouped form's box holds the disclosure label as its first row
/// (`Archive/TimeFlipApp/CategoriesSettingsView.swift`). SwiftUI drew that box; here the box is this section's, which
/// is also why the tint moved off `CategoryTable` -- content inside a panel cannot draw the panel, or the two tints
/// stack and the content reads darker than the heading over it.
///
/// **Two tabs draw it, at two different rhythms, which is what `Metrics` is for.** The Categories tab's lists are
/// inset from the panel by the same 8pt the heading is; the App tab's rows run the panel's full width and hold their
/// own labels off the edge, so their content inset is nothing and their heading is inset by the tab's own 20. A
/// section that hard-coded either would put one tab's spacing on the other, and the numbers are the tabs' to state.
///
/// Named for accessibility on the section itself rather than on its label. The archive measured why: a disclosure
/// group exposes only its triangle, which carries no name of its own, and labelling the group overwrote the label of
/// every descendant -- nine static texts all reading "Inactive" instead of the category names and dates.
///
/// **What that label says is the caller's**, because the title alone is not always enough to hear. "Active" and
/// "Inactive" mean nothing announced on their own, so the Categories tab says "Active categories"; "App settings" and
/// "Google" already say what they are, and appending a noun to them would only pad what VoiceOver reads.
@MainActor
final class PanelSection: NSView {
    let title: String

    /// Whether what sits under the heading is on show.
    private(set) var isExpanded: Bool

    /// What the section was built folded or open as, kept so opening Settings can put it back there
    /// (`CollapsibleSection`). Active opens and Inactive does not, and that difference is the caller's to state once.
    private let defaultExpanded: Bool

    private let toggle = NSButton()
    /// Behind the triangle and the title, spanning the row, so the whole line is the target.
    private let headingButton = NSButton()
    private let content: NSView
    /// The tint, behind all of it. Exposed so a test can measure what the window sees rather than inferring it from
    /// the content inside.
    private(set) var panel = NSBox()

    /// The two ways the section ends: under its content, or under its heading. Swapped rather than relying on the
    /// hidden content to take no room -- Auto Layout does not care that a view is hidden, so **hiding it alone left
    /// its full height behind**: a folded section measured 150pt open and 150pt shut, which on a plain background
    /// looked like a gap and on a tint would be an empty box.
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var collapsedConstraint: NSLayoutConstraint!

    /// The spacing this section draws at, handed in by the tab.
    private let metrics: Metrics

    /// What accessibility announces for the section and every control on its heading line.
    private let label: String

    /// - Parameters:
    ///   - label: what accessibility announces for the section, its triangle and its heading line, when the title on
    ///     its own would not be enough to hear. Defaults to the title, which is what a self-describing heading wants.
    ///   - metrics: the spacing this tab draws sections at. Defaults to the Categories tab's.
    init(
        title: String,
        identifier: String,
        isExpanded: Bool,
        content: NSView,
        label: String? = nil,
        metrics: Metrics = Metrics()
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.defaultExpanded = isExpanded
        self.content = content
        self.metrics = metrics
        self.label = label ?? title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Named and made an element, or it is absent from the tree entirely: an ordinary `NSView` is not an
        // accessibility element, so its role and identifier are never asked for.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(self.label)
        addContent(identifier: identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows or hides the content. Hidden rather than removed, so it keeps what it is showing and the fold costs no
    /// rebuild, with the section's own bottom moved up to the heading so the panel closes around it.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggle.state = expanded ? .on : .off
        content.isHidden = !expanded
        applyFold()
        onExpandedChanged?(expanded)
    }

    /// Deactivates before activating, always: both sets pin the same bottom edge, so the moment they overlap is an
    /// unsatisfiable pair and a broken layout in the log.
    private func applyFold() {
        if isExpanded {
            collapsedConstraint.isActive = false
            NSLayoutConstraint.activate(expandedConstraints)
        } else {
            NSLayoutConstraint.deactivate(expandedConstraints)
            collapsedConstraint.isActive = true
        }
    }

    private func addContent(identifier: String) {
        // An `NSBox` rather than a layer with a background colour, as everywhere else on this tab: it keeps the fill a
        // dynamic colour, so the panel follows the appearance instead of freezing whichever one it was built under.
        //
        // **Behind everything rather than around it.** The heading, the triangle and the list stay direct subviews of
        // the section, so a click still lands on the heading button in front rather than on a box that would swallow
        // it -- AppKit hit-tests later subviews first, and the panel is added first.
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = metrics.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier("\(identifier)-panel")

        // A disclosure button draws the triangle and nothing else, so the heading beside it is a label of ours. Its
        // own title would sit in the system's small control font rather than the heading style the tab uses.
        toggle.setButtonType(.onOff)
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.state = isExpanded ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityIdentifier("\(identifier)-toggle")
        toggle.setAccessibilityLabel(label)

        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier("\(identifier)-heading")

        content.isHidden = !isExpanded

        // **The whole line folds the section, not just the triangle** (see `CLAUDE.md`). A triangle is a small
        // target for a gesture the heading beside it is obviously about, and every other list on this platform
        // opens on its title too. The button spans the row; the triangle keeps drawing itself in front of it.
        //
        // **The words go *inside* the button**, which is the part that cannot be got wrong: a click on a label goes
        // up the responder chain to the label's own superview, so a button that is merely behind a sibling label is
        // never reached. This shipped with the label as a sibling and the heading looked right while a click on the
        // word did nothing at all -- found by clicking one on the running app and getting no `debug_log` row.
        headingButton.title = ""
        headingButton.isBordered = false
        headingButton.bezelStyle = .inline
        headingButton.imagePosition = .noImage
        headingButton.target = self
        headingButton.action = #selector(headingClicked)
        headingButton.translatesAutoresizingMaskIntoConstraints = false
        headingButton.setAccessibilityIdentifier("\(identifier)-heading-button")
        headingButton.setAccessibilityLabel(label)

        addSubview(panel)
        addSubview(headingButton)
        headingButton.addSubview(heading)
        addSubview(toggle)
        addSubview(content)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.headingInset),

            heading.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: metrics.titleSpacing),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -metrics.headingInset),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: metrics.headingInset),

            // Spanning the row: the words, the triangle, and the space after them -- and out to the panel's own
            // edges rather than stopping at the padding, so the corner of the tinted row folds it too.
            headingButton.topAnchor.constraint(equalTo: topAnchor),
            headingButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headingButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headingButton.bottomAnchor.constraint(equalTo: heading.bottomAnchor, constant: metrics.headingInset),

            // The list is inset by the panel's padding; the heading line is not, being the thing that presses. Its
            // top stays pinned either way -- only where the *section* ends changes, so a folded list has a position
            // rather than an ambiguous one.
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: metrics.headingSpacing),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.contentInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.contentInset),
        ])

        expandedConstraints = [content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.contentInset)]
        // Shut, the panel ends where the heading line does: the list is still there, hidden, and pinned by nothing
        // that reaches the bottom.
        collapsedConstraint = headingButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        applyFold()
    }

    /// A click anywhere on the heading line. It flips the section rather than reading the triangle, since the
    /// triangle has not moved: it is the button underneath that was pressed.
    @objc
    private func headingClicked() {
        setExpanded(!isExpanded)
        onToggle?(isExpanded)
    }

    /// The spacing a tab draws its sections at.
    ///
    /// **Defaulted to the Categories tab's numbers**, which are `CategoryTable`'s: that tab is where this shape was
    /// built and its lists are inset from the panel by the same amount the heading is. The App tab overrides two of
    /// them, because its rows run the panel's full width so that a separator's ends land where the archive's do, and
    /// hold their own labels off the edge with an inset of their own.
    struct Metrics {
        /// Between the triangle and the word beside it.
        var titleSpacing: CGFloat = 4
        /// Between the heading line and what folds away under it.
        var headingSpacing = SettingsMetrics.headingSpacing
        /// Inside the panel, around the heading line.
        var headingInset = SettingsMetrics.panelPadding
        /// Inside the panel, to the left of the content, to the right of it, and under it.
        ///
        /// **Every tab takes this one now.** The App tab used to pass 0 here and inset each row itself instead, so
        /// that the hairlines it drew between rows ended where the archive's did. With no hairlines to place there
        /// is nothing left for that exception to buy, and one inset for all three tabs is what makes a row start at
        /// the same x on each of them.
        var contentInset = SettingsMetrics.panelPadding
        var cornerRadius = SettingsMetrics.cornerRadius
    }

    @objc
    private func toggled() {
        setExpanded(toggle.state == .on)
        onToggle?(isExpanded)
    }

    /// Called when somebody folds or unfolds the section, so the window can record it. **A gesture, not a state**:
    /// `restoreDefaultState` deliberately never reaches this, because a reset is not a fold anybody made and a
    /// `debug_log` full of folds nobody made is worse than no record at all.
    var onToggle: ((Bool) -> Void)?

    /// Called whenever the fold changes, **however it changed** -- a heading pressed, or the window putting the
    /// section back to what it was built as.
    ///
    /// **This is the hook for anything drawn from the fold**, and it is a different question from `onToggle`. The App
    /// tab's Google footnote sits outside the panel and so cannot fold with it; hanging it off `onToggle` left it
    /// showing under a section the window had folded, because a reset is silent by design. Anything derived from
    /// `isExpanded` has to follow every path that sets it, or it is a second copy of the fold that can disagree with
    /// the fold -- the fault the first rule in `CLAUDE.md` is about.
    var onExpandedChanged: ((Bool) -> Void)?
}

extension PanelSection: CollapsibleSection {
    func restoreDefaultState() { setExpanded(defaultExpanded) }
}
