import AppKit

/// A row that folds open to more rows underneath it, drawn as a row of the panel it sits in rather than as a panel of
/// its own.
///
/// **This is `CLAUDE.md`'s second case for a collapsible group.** `PanelSection` is the first: a group with its own
/// tinted panel, where the heading is the panel's first row and folding closes the panel around it. The Device tab's
/// *More*, *LED* and *Double tap* are the other kind -- they are lines of a list that already has a panel, so there is
/// nothing of their own to close. What carries over is the part that is really the rule: **the whole heading line is
/// the target**, and folding takes the space back rather than merely hiding what was in it.
///
/// Both of those have already gone wrong once each in this codebase, so both are built the way that cannot:
///
/// - **The words sit inside the button**, not beside it. A click on an `NSTextField` goes up the responder chain to
///   the label's own superview, so a button that is merely behind a sibling label is never pressed. That shipped on
///   the Categories headings: they drew correctly and folded when the space *after* the words was clicked, while a
///   click on the word itself did nothing at all.
/// - **The bottom edge moves**, rather than the content merely being hidden. Auto Layout does not care that a view is
///   hidden, so hiding alone leaves the full height behind -- a folded group measuring exactly as tall as an open one.
@MainActor
final class DisclosureRow: NSView {
    let title: String

    private(set) var isExpanded: Bool

    /// What the row was built folded or open as, kept so opening Settings can put it back there
    /// (`CollapsibleSection`). Held rather than looked up, because the caller's argument is the only place this is
    /// ever stated and a copy anywhere else would be a second answer to what "default" means.
    private let defaultExpanded: Bool

    /// Called when the row is folded or unfolded, so the window can record it.
    var onToggle: ((Bool) -> Void)?

    private let toggle = NSButton()
    /// Behind the triangle and the title, spanning the row, so the whole line presses.
    private let headingButton = NSButton()
    private let content: NSView

    /// The two ways the row ends: under its content, or under its own heading line. Swapped rather than relying on a
    /// hidden view to take no room -- see the note above.
    private var expandedConstraint: NSLayoutConstraint!
    private var collapsedConstraint: NSLayoutConstraint!

    /// - Parameters:
    ///   - content: the rows that fold away. Laid out by the caller; this only decides whether they are on show.
    ///   - separated: whether a hairline closes the heading line off from the row under it, as the plain rows do.
    init(title: String, identifier: String, isExpanded: Bool, content: NSView, separated: Bool = false) {
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
        setAccessibilityLabel(title)
        addContent(identifier: identifier, separated: separated)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggle.state = expanded ? .on : .off
        content.isHidden = !expanded
        applyFold()
    }

    /// Deactivates before activating, always: both pin the same bottom edge, so the moment they overlap is an
    /// unsatisfiable pair and a broken layout in the log.
    private func applyFold() {
        if isExpanded {
            collapsedConstraint.isActive = false
            expandedConstraint.isActive = true
        } else {
            expandedConstraint.isActive = false
            collapsedConstraint.isActive = true
        }
    }

    private func addContent(identifier: String, separated: Bool) {
        // A disclosure button draws the triangle and nothing else, so the word beside it is a label of ours: the
        // button's own title would sit in the system's small control font rather than the row font this list uses.
        toggle.setButtonType(.onOff)
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.state = isExpanded ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityIdentifier("\(identifier)-toggle")
        toggle.setAccessibilityLabel(title)

        let heading = NSTextField(labelWithString: title)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier("\(identifier)-heading")

        headingButton.title = ""
        headingButton.isBordered = false
        headingButton.bezelStyle = .inline
        headingButton.imagePosition = .noImage
        headingButton.target = self
        headingButton.action = #selector(headingClicked)
        headingButton.translatesAutoresizingMaskIntoConstraints = false
        headingButton.setAccessibilityIdentifier("\(identifier)-heading-button")
        headingButton.setAccessibilityLabel(title)

        content.isHidden = !isExpanded

        addSubview(headingButton)
        headingButton.addSubview(heading)
        addSubview(toggle)
        addSubview(content)

        // The heading line is a row of the list, so it carries the list's own inset and minimum height: a folding row
        // that sat tighter than the rows around it would read as a different kind of thing.
        NSLayoutConstraint.activate([
            headingButton.topAnchor.constraint(equalTo: topAnchor),
            headingButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headingButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headingButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumRowHeight),

            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.rowInset),
            toggle.centerYAnchor.constraint(equalTo: headingButton.centerYAnchor),

            heading.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: Layout.titleSpacing),
            heading.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.rowInset),

            // Indented past the triangle, so what folds out reads as belonging to the line that opened it.
            content.topAnchor.constraint(equalTo: headingButton.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        if separated {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.rowInset),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.rowInset),
                separator.bottomAnchor.constraint(equalTo: headingButton.bottomAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        expandedConstraint = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.rowPadding)
        collapsedConstraint = headingButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        applyFold()
    }

    /// A click anywhere on the heading line. It flips the row rather than reading the triangle, since the triangle has
    /// not moved: it is the button underneath that was pressed.
    @objc
    private func headingClicked() {
        setExpanded(!isExpanded)
        onToggle?(isExpanded)
    }

    @objc
    private func toggled() {
        setExpanded(toggle.state == .on)
        onToggle?(isExpanded)
    }

    private enum Layout {
        static let titleSpacing: CGFloat = 4
        static let rowInset = DevicePane.Layout.rowInset
        static let rowPadding = DevicePane.Layout.rowPadding
        static let minimumRowHeight = DevicePane.Layout.minimumRowHeight
        /// What folds out is indented past the triangle rather than starting where the heading does.
        static let contentInset = DevicePane.Layout.rowInset + 16
    }
}

extension DisclosureRow: CollapsibleSection {
    func restoreDefaultState() { setExpanded(defaultExpanded) }
}
