import AppKit

/// A titled section of the Categories tab: a disclosure triangle and a heading, with a list under it that folds
/// away, all on one tinted panel.
///
/// **The fold is the archive's, and it only means anything now there are two sections.** Active is the one somebody
/// works in, so it starts open; Inactive is an archive to go looking in occasionally, so it starts closed. A single
/// section had nothing to fold away *from*, which is why the triangles waited for this list rather than arriving
/// with the first one.
///
/// **The heading is on the panel with its list, not above it**, which is what the archive drew: each section was a
/// `Section` of a `.formStyle(.grouped)` form, and a grouped form's box holds the disclosure label as its first row
/// (`Archive/TimeFlipApp/CategoriesSettingsView.swift`). SwiftUI drew that box; here the box is this section's, which
/// is also why the tint moved off `CategoryTable` -- a list inside a panel cannot draw the panel, or the two tints
/// stack and the list reads darker than the heading over it.
///
/// Named for accessibility on the section itself rather than on its label. The archive measured why: a disclosure
/// group exposes only its triangle, which carries no name of its own, and labelling the group overwrote the label of
/// every descendant -- nine static texts all reading "Inactive" instead of the category names and dates.
@MainActor
final class CategorySection: NSView {
    let title: String

    /// Whether the list under the heading is on show.
    private(set) var isExpanded: Bool

    /// What the section was built folded or open as, kept so opening Settings can put it back there
    /// (`CollapsibleSection`). Active opens and Inactive does not, and that difference is the caller's to state once.
    private let defaultExpanded: Bool

    private let toggle = NSButton()
    /// Behind the triangle and the title, spanning the row, so the whole line is the target.
    private let headingButton = NSButton()
    private let content: NSView
    /// The tint, behind all of it. Exposed so a test can measure what the window sees rather than inferring it from
    /// the list inside.
    private(set) var panel = NSBox()

    /// The two ways the section ends: under its list, or under its heading. Swapped rather than relying on the
    /// hidden list to take no room -- Auto Layout does not care that a view is hidden, so **hiding the list alone
    /// left its full height behind**: a folded section measured 150pt open and 150pt shut, which on a plain
    /// background looked like a gap and on a tint would be an empty box.
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var collapsedConstraint: NSLayoutConstraint!

    init(title: String, identifier: String, isExpanded: Bool, content: NSView) {
        self.title = title
        self.isExpanded = isExpanded
        self.defaultExpanded = isExpanded
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Named and made an element, or it is absent from the tree entirely: an ordinary `NSView` is not an
        // accessibility element, so its role and identifier are never asked for.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel("\(title) categories")
        addContent(identifier: identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows or hides the list. Hidden rather than removed, so the list keeps what it is showing and the fold costs
    /// no rebuild, with the section's own bottom moved up to the heading so the panel closes around it.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggle.state = expanded ? .on : .off
        content.isHidden = !expanded
        applyFold()
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
        panel.cornerRadius = Layout.cornerRadius
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
        toggle.setAccessibilityLabel("\(title) categories")

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
        headingButton.setAccessibilityLabel("\(title) categories")

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

            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),

            heading.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: Layout.titleSpacing),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.padding),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),

            // Spanning the row: the words, the triangle, and the space after them -- and out to the panel's own
            // edges rather than stopping at the padding, so the corner of the tinted row folds it too.
            headingButton.topAnchor.constraint(equalTo: topAnchor),
            headingButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headingButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headingButton.bottomAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.padding),

            // The list is inset by the panel's padding; the heading line is not, being the thing that presses. Its
            // top stays pinned either way -- only where the *section* ends changes, so a folded list has a position
            // rather than an ambiguous one.
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.headingSpacing),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
        ])

        expandedConstraints = [content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.padding)]
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

    private enum Layout {
        /// Between the triangle and the word beside it, and between the heading and the list under it.
        static let titleSpacing: CGFloat = 4
        static let headingSpacing: CGFloat = 12
        /// Inside the panel, around the heading and around the list. The list's own former inset, taken over whole:
        /// the tint moved out here and the spacing it produced has not.
        static let padding = CategoryTable.Layout.padding
        static let cornerRadius = CategoryTable.Layout.cornerRadius
    }

    @objc
    private func toggled() {
        setExpanded(toggle.state == .on)
        onToggle?(isExpanded)
    }

    /// Called when the section is folded or unfolded, so the window can record it.
    var onToggle: ((Bool) -> Void)?
}

extension CategorySection: CollapsibleSection {
    func restoreDefaultState() { setExpanded(defaultExpanded) }
}
