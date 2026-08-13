import AppKit

/// The Timing column: what is being timed, whether the clock is running, and for how long.
///
/// Laid out as the previous app laid it out. The column's width defines a square -- the space the device
/// graphic occupies when there is a cube to draw -- and everything inside is sized from that square rather
/// than in fixed points, so the whole group stays in proportion as the window is resized. Centred in the
/// square: the play/pause glyph, with the elapsed time under it. Under the square: the category's name, set
/// large enough to fill the space the squared-off graphic leaves at the bottom of the column.
///
/// **The glyph takes the category's colour; nothing behind it does.** It stands where the lit device would
/// be, and the device is what carries colour as a body -- a filled tile here would be inventing an object
/// that is not in the design.
///
/// Draws what it is told. Whether the clock is running is `TimingReadout`'s to answer, what the icons mean is
/// `ManualTimerRules`', and the click goes back out to whoever wired it.
@MainActor
final class TimingView: NSView {
    enum Identifier {
        static let playPause = "timing-play-pause"
        static let elapsed = "timing-elapsed"
        static let categoryName = "timing-category-name"
    }

    enum Layout {
        /// The glyph, as a fraction of the square. The device's centre face is a regular pentagon, and the
        /// largest centred square that fits inside it is about 0.297 of the artwork's width -- the limit
        /// comes from the two upper edges meeting at the point -- so this stays just inside.
        static let glyphScale: CGFloat = 0.29
        /// The elapsed time and the gap above it, both sized off the glyph so the pair stays in proportion:
        /// a fixed point size crowds the glyph at one width and looks stranded at another.
        static let elapsedFontScale: CGFloat = 0.3
        static let elapsedGapScale: CGFloat = 0.12
        /// The category name under the square. Sized to fill the space the square leaves rather than to any
        /// system text style, and shrinking rather than wrapping, since a name has no length limit.
        static let nameFontSize: CGFloat = 56
        static let nameMinimumScale: CGFloat = 0.4
        /// Between the square and the name.
        static let nameSpacing: CGFloat = 12
    }

    /// Called when the control is clicked, which is only possible while something is being timed.
    var onTogglePause: (() -> Void)?

    let playPauseButton = NSButton()
    let elapsedLabel = NSTextField(labelWithString: "")
    let categoryNameLabel = NSTextField(labelWithString: "")

    /// The square the glyph and the clock are centred in: as wide as the column, and as tall as it is wide.
    private let squareArea = NSView()
    private let centred = NSStackView()
    private var glyphWidth: NSLayoutConstraint!
    private var glyphHeight: NSLayoutConstraint!
    private var symbolName: String?

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
        symbolName = ManualTimerRules.symbolName(for: state)
        let isHidden = symbolName == nil
        centred.isHidden = isHidden
        categoryNameLabel.isHidden = isHidden
        // Not merely inert: an idle control is not drawn at all, so there is nothing to click at.
        playPauseButton.isEnabled = ManualTimerRules.isClickable(state)

        guard !isHidden else { return }
        // No colour set falls back to the ordinary label colour, which is what the previous app drew for a
        // category without one.
        playPauseButton.contentTintColor = category?.colour ?? .labelColor
        elapsedLabel.stringValue = DurationFormat.hoursMinutesSeconds(
            elapsed,
            // Truncated, not rounded: a ticking clock must never read ahead of the time actually recorded.
            rounding: .truncate,
            showingSeconds: true
        )
        playPauseButton.setAccessibilityLabel(state == .running ? "Running, click to pause" : "Paused, click to resume")
        categoryNameLabel.stringValue = category?.name ?? ""
        // Applied here as well as in `layout()`: the fitted size depends on the text, which only changes
        // here, and a view with no window may not be asked to lay out again just because it wants to.
        apply(nameFontFitting: bounds.width)
        needsLayout = true
    }

    /// Sizes everything from the square, which is what the column's width makes it.
    ///
    /// The AppKit equivalent of the `GeometryReader` the previous app sized this from: the numbers are ratios
    /// rather than points, so they have to be applied once the view knows how wide it is.
    override func layout() {
        super.layout()
        let side = bounds.width
        guard side > 0 else { return }
        let glyphSize = (side * Layout.glyphScale).rounded()
        if glyphWidth.constant != glyphSize {
            glyphWidth.constant = glyphSize
            glyphHeight.constant = glyphSize
        }
        centred.spacing = (glyphSize * Layout.elapsedGapScale).rounded()
        apply(glyphSize: glyphSize)
        apply(elapsedFontSize: (glyphSize * Layout.elapsedFontScale).rounded())
        apply(nameFontFitting: side)
    }

    private func apply(glyphSize: CGFloat) {
        guard let symbolName else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.isTemplate = true
        // Sized to the box and scaled into it, so the glyph fills the space rather than sitting inside it: a
        // symbol's point size sets its cap height, which draws a play triangle appreciably smaller than the
        // square it was given. The previous app scaled the artwork to fit, and this is that.
        image.size = NSSize(width: glyphSize, height: glyphSize)
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        playPauseButton.image = image
    }

    private func apply(elapsedFontSize: CGFloat) {
        guard elapsedLabel.font?.pointSize != elapsedFontSize else { return }
        // Monospaced digits: this ticks once a second, and proportional figures change width as they go, so a
        // centred line would twitch on every tick.
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: elapsedFontSize, weight: .medium)
    }

    /// Shrinks the name to fit the column rather than wrapping or clipping it, down to a floor -- past which
    /// it truncates, because a name shrunk indefinitely stops being readable before it stops being long.
    private func apply(nameFontFitting width: CGFloat) {
        guard width > 0, !categoryNameLabel.stringValue.isEmpty else { return }
        let floor = (Layout.nameFontSize * Layout.nameMinimumScale).rounded()
        var size = Layout.nameFontSize
        while size > floor {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let measured = (categoryNameLabel.stringValue as NSString)
                .size(withAttributes: [.font: font]).width
            if measured <= width { break }
            size -= 1
        }
        guard categoryNameLabel.font?.pointSize != size else { return }
        categoryNameLabel.font = .systemFont(ofSize: size, weight: .semibold)
    }

    private func addContent() {
        squareArea.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.isBordered = false
        playPauseButton.bezelStyle = .inline
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePause)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.identifier = NSUserInterfaceItemIdentifier(Identifier.playPause)
        playPauseButton.setAccessibilityIdentifier(Identifier.playPause)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: Layout.nameFontSize / 2, weight: .medium)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .center
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.setAccessibilityIdentifier(Identifier.elapsed)

        categoryNameLabel.font = .systemFont(ofSize: Layout.nameFontSize, weight: .semibold)
        categoryNameLabel.alignment = .center
        categoryNameLabel.lineBreakMode = .byTruncatingTail
        categoryNameLabel.maximumNumberOfLines = 1
        categoryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        categoryNameLabel.setAccessibilityIdentifier(Identifier.categoryName)

        centred.orientation = .vertical
        centred.alignment = .centerX
        centred.translatesAutoresizingMaskIntoConstraints = false
        centred.addView(playPauseButton, in: .top)
        centred.addView(elapsedLabel, in: .top)

        addSubview(squareArea)
        squareArea.addSubview(centred)
        addSubview(categoryNameLabel)

        glyphWidth = playPauseButton.widthAnchor.constraint(equalToConstant: 1)
        glyphHeight = playPauseButton.heightAnchor.constraint(equalToConstant: 1)

        NSLayoutConstraint.activate([
            squareArea.topAnchor.constraint(equalTo: topAnchor),
            squareArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            squareArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            // As tall as it is wide: the space the device graphic occupies, kept whether or not anything is
            // drawn in it, so the name below does not move when a session starts.
            squareArea.heightAnchor.constraint(equalTo: squareArea.widthAnchor),

            centred.centerXAnchor.constraint(equalTo: squareArea.centerXAnchor),
            centred.centerYAnchor.constraint(equalTo: squareArea.centerYAnchor),
            centred.leadingAnchor.constraint(greaterThanOrEqualTo: squareArea.leadingAnchor),
            centred.trailingAnchor.constraint(lessThanOrEqualTo: squareArea.trailingAnchor),
            glyphWidth,
            glyphHeight,

            categoryNameLabel.topAnchor.constraint(equalTo: squareArea.bottomAnchor, constant: Layout.nameSpacing),
            categoryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryNameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc
    private func togglePause() {
        onTogglePause?()
    }
}
