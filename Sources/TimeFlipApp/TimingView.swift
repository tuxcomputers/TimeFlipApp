import AppKit

/// The Timing column: what is being timed, whether the clock is running, and for how long.
///
/// Three things, top to bottom: the play/pause control in the category's own colour, the elapsed time
/// under it, and the category's name under that. Empty when nothing is being timed -- an empty column is
/// the honest picture of a session that has not started.
///
/// Draws what it is told. Whether the clock is running is `TimingSession`'s to know, what the icons mean is
/// `ManualTimerRules`', and the click goes back out to whoever wired it.
@MainActor
final class TimingView: NSView {
    enum Identifier {
        static let playPause = "timing-play-pause"
        static let elapsed = "timing-elapsed"
        static let categoryName = "timing-category-name"
    }

    private enum Layout {
        /// The control, sized to be the thing your eye lands on in an otherwise empty column, and to be a
        /// comfortable click target.
        static let controlSize: CGFloat = 96
        static let symbolSize: CGFloat = 44
        static let spacing: CGFloat = 12
        static let cornerRadius: CGFloat = 12
    }

    /// Called when the control is clicked, which is only possible while something is being timed.
    var onTogglePause: (() -> Void)?

    let playPauseButton = NSButton()
    let elapsedLabel = NSTextField(labelWithString: "")
    let categoryNameLabel = NSTextField(labelWithString: "")

    private let swatch = NSBox()
    private(set) var state: TimingState = .idle

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addContent()
        show(category: nil, state: .idle, elapsed: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Draws a session, or the absence of one.
    ///
    /// Given the category rather than fetching it: which category the manual face holds lives in the
    /// database, and reading it is the window's job (see `SettingsWindowController`), so this cannot show
    /// something the table no longer says.
    func show(category: CategoryRecord?, state: TimingState, elapsed: TimeInterval) {
        self.state = state
        let symbolName = ManualTimerRules.symbolName(for: state)
        let isHidden = symbolName == nil
        swatch.isHidden = isHidden
        playPauseButton.isHidden = isHidden
        elapsedLabel.isHidden = isHidden
        categoryNameLabel.isHidden = isHidden
        // Not merely inert: an idle control is not drawn at all, so there is nothing to click at.
        playPauseButton.isEnabled = ManualTimerRules.isClickable(state)

        guard let symbolName else { return }
        swatch.fillColor = category?.colour ?? .controlBackgroundColor
        playPauseButton.image = symbol(symbolName)
        // The glyph takes the same white-on-dark decision the category's icon takes in the list, from the
        // colour's own `white_lines` column.
        playPauseButton.contentTintColor = (category?.usesWhiteLines ?? false) ? .white : .labelColor
        playPauseButton.setAccessibilityLabel(state == .running ? "Running, click to pause" : "Paused, click to resume")
        elapsedLabel.stringValue = DurationFormat.hoursMinutesSeconds(
            elapsed,
            // Truncated, not rounded: a ticking clock must never read ahead of the time actually recorded.
            rounding: .truncate,
            showingSeconds: true
        )
        categoryNameLabel.stringValue = category?.name ?? ""
    }

    private func addContent() {
        swatch.boxType = .custom
        swatch.borderWidth = 0
        swatch.cornerRadius = Layout.cornerRadius
        swatch.contentViewMargins = .zero
        swatch.titlePosition = .noTitle
        swatch.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.isBordered = false
        playPauseButton.bezelStyle = .inline
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePause)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.identifier = NSUserInterfaceItemIdentifier(Identifier.playPause)
        playPauseButton.setAccessibilityIdentifier(Identifier.playPause)

        // Monospaced digits: this ticks once a second, and proportional figures change width as they go, so
        // a centred line would twitch on every tick.
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .center
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.setAccessibilityIdentifier(Identifier.elapsed)

        categoryNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        categoryNameLabel.alignment = .center
        categoryNameLabel.lineBreakMode = .byTruncatingTail
        categoryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        categoryNameLabel.setAccessibilityIdentifier(Identifier.categoryName)

        addSubview(swatch)
        swatch.contentView?.addSubview(playPauseButton)
        addSubview(elapsedLabel)
        addSubview(categoryNameLabel)

        NSLayoutConstraint.activate([
            swatch.topAnchor.constraint(equalTo: topAnchor),
            swatch.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatch.widthAnchor.constraint(equalToConstant: Layout.controlSize),
            swatch.heightAnchor.constraint(equalToConstant: Layout.controlSize),

            elapsedLabel.topAnchor.constraint(equalTo: swatch.bottomAnchor, constant: Layout.spacing),
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            elapsedLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            categoryNameLabel.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: Layout.spacing / 2),
            categoryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryNameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let content = swatch.contentView {
            NSLayoutConstraint.activate([
                playPauseButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                playPauseButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                playPauseButton.widthAnchor.constraint(equalToConstant: Layout.symbolSize),
                playPauseButton.heightAnchor.constraint(equalToConstant: Layout.symbolSize),
            ])
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Layout.symbolSize, weight: .bold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    @objc
    private func togglePause() {
        onTogglePause?()
    }
}
