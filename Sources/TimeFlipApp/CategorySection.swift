import AppKit

/// A titled section of the Categories tab: a disclosure triangle and a heading, with a list under it that folds
/// away.
///
/// **The fold is the archive's, and it only means anything now there are two sections.** Active is the one somebody
/// works in, so it starts open; Inactive is an archive to go looking in occasionally, so it starts closed. A single
/// section had nothing to fold away *from*, which is why the triangles waited for this list rather than arriving
/// with the first one.
///
/// Named for accessibility on the section itself rather than on its label. The archive measured why: a disclosure
/// group exposes only its triangle, which carries no name of its own, and labelling the group overwrote the label of
/// every descendant -- nine static texts all reading "Inactive" instead of the category names and dates.
@MainActor
final class CategorySection: NSView {
    let title: String

    /// Whether the list under the heading is on show.
    private(set) var isExpanded: Bool

    private let toggle = NSButton()
    private let content: NSView

    init(title: String, identifier: String, isExpanded: Bool, content: NSView) {
        self.title = title
        self.isExpanded = isExpanded
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

    /// Shows or hides the list. Hidden rather than removed, since a stack view collapses a hidden arranged view and
    /// the section then takes only the height of its heading.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggle.state = expanded ? .on : .off
        content.isHidden = !expanded
    }

    private func addContent(identifier: String) {
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

        addSubview(toggle)
        addSubview(heading)
        addSubview(content)
        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: topAnchor),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),

            heading.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: Layout.titleSpacing),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heading.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),

            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.headingSpacing),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private enum Layout {
        /// Between the triangle and the word beside it, and between the heading and the list under it.
        static let titleSpacing: CGFloat = 4
        static let headingSpacing: CGFloat = 12
    }

    @objc
    private func toggled() {
        setExpanded(toggle.state == .on)
        onToggle?(isExpanded)
    }

    /// Called when the section is folded or unfolded, so the window can record it.
    var onToggle: ((Bool) -> Void)?
}
