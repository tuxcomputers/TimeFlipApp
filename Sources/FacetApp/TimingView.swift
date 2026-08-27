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
        static let cubeFace = "timing-device-face"
        static let centreIcon = "timing-centre-icon"
        static let faceLock = "timing-face-lock"
        /// The figure under the name while a cube is being followed. A different element from `elapsed`, because it is
        /// in a different place for a different reason -- see `faceElapsedLabel`.
        static let faceElapsed = "timing-face-elapsed"
        static let faceGlyph = "timing-face-glyph"
    }

    /// The device seen from above, which is the app's own mark: `ic_facet.svg`.
    static let deviceArtwork = "ic_facet"

    enum Layout {
        /// The glyph, as a fraction of the square. The device's centre face is a regular pentagon, and the
        /// largest centred square that fits inside it is about 0.297 of the artwork's width -- the limit
        /// comes from the two upper edges meeting at the point -- so this stays just inside.
        static let glyphScale: CGFloat = 0.29

        /// How much of `ic_facet.svg`'s box the cube itself takes up: its mark is drawn at
        /// `translate(67.44481,67.43981) scale(5.801852)` inside a `scale(0.126953125)` group, which comes to this.
        /// The rest of the box is the ring around it.
        static let markScale: CGFloat = 0.736487

        /// The category's icon on the device's centre face, as a fraction of the square.
        ///
        /// **`glyphScale` shrunk by the mark**, and not a number chosen by eye. 0.29 was measured against artwork
        /// whose cube filled the box; this artwork holds the same cube at `markScale` to leave room for the ring, so
        /// the same pentagon -- and the largest square inside it -- shrank by exactly that much with it. Deriving it
        /// rather than writing 0.21 means redrawing the ring moves the icon with it.
        static let centreIconScale: CGFloat = glyphScale * markScale

        /// The lock in the corner of the square, as a fraction of it.
        ///
        /// **The margin the ring leaves, derived rather than chosen.** The cube occupies `markScale` of the box and
        /// the rest is the ring, so `(1 - markScale) / 2` is exactly the band of empty square outside it -- which is
        /// where a lock can sit without landing on the artwork. Redrawing the ring moves and resizes the lock with it,
        /// the same way `centreIconScale` follows the mark. The archive wrote 40 points here, which was right for one
        /// window width and nothing else; everything in this column is sized off the square instead.
        static let lockScale: CGFloat = (1 - markScale) / 2

        /// The figure under the name, as a fraction of the name's own size. The same relationship the manual figure
        /// has to the glyph it sits under, so the pair reads the same way in both pictures.
        static let faceElapsedScale: CGFloat = 0.4

        /// Between the glyph and the figure it stands beside. A fixed gap rather than a scaled one: it is the space
        /// between two things on one short line, not a proportion of the picture.
        static let faceGlyphSpacing: CGFloat = 6

        /// The size the device artwork is rendered at, independent of how large it is drawn. A vector re-renders at
        /// draw size, so this only has to be generous enough that nothing downstream upscales a raster made too small.
        static let artworkPointSize: CGFloat = 512
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

    /// The cube, lit in the face's colour. Filled and hidden by `show(face:category:)`, and empty the rest of the
    /// time: with no cube to follow there is no device to draw, and a picture of one would be reporting hardware
    /// that is not there.
    /// The lock in the corner of the cube, red for locked and green for open.
    ///
    /// **The archive's control, massaged.** Its behaviour and its colours are kept whole -- see `showFaceLock` -- and
    /// what changes is that it is an `NSButton` sized off the square rather than a SwiftUI `Button` at a fixed 40
    /// points. The measured reason for sizing the glyph by symbol configuration rather than by scaling an image into a
    /// frame is the archive's, and still applies: the open lock's bounding box is the wider of the two, because its
    /// shackle swings out, so scaling both to fit one square drew the open one smaller and the lock appeared to change
    /// size as it toggled.
    let lockButton = NSButton()
    private var lockWidth: NSLayoutConstraint!
    private var lockHeight: NSLayoutConstraint!
    private var faceElapsedHeight: NSLayoutConstraint!
    private var faceGlyphWidth: NSLayoutConstraint!
    private var faceGlyphHeight: NSLayoutConstraint!

    /// Whether the face on show keeps what it has. Held only so `layout` can re-render the glyph at a new size without
    /// being told again which one to draw; `showFaceLock` is what decides it.
    private var isFaceLocked = false

    /// Pressing the lock. `nil` leaves it inert, which is what a view built without a window gets.
    var onToggleLock: (() -> Void)?

    /// The category's total for the day, under its name, while a cube is being followed.
    ///
    /// **Its own label, in its own place, and not `elapsedLabel` moved.** A manual session's figure sits inside the
    /// square under the play/pause glyph, because that is what the square holds; with a cube there the square is the
    /// cube, and putting a figure on the artwork would be writing over the picture. So this one goes under the name,
    /// which is where the column has room.
    ///
    /// **Going beyond the archive, deliberately.** Its Faces tab showed no figure in device mode at all -- the day
    /// total was in the menu bar only -- so there is no prior art to follow here, only the reason the menu bar had it:
    /// what a category has recorded today is the question somebody opens this tab to answer.
    let faceElapsedLabel = NSTextField(labelWithString: "")

    /// Whether the cube is running or paused, beside the figure it qualifies.
    ///
    /// **Beside rather than inside the square**, which is where the manual glyph goes: with a cube the square is the
    /// cube, and its centre face already carries the category's icon. Putting a second glyph there would be two
    /// symbols on one picture answering different questions. Under the name it reads as what it is -- a note on the
    /// figure next to it.
    ///
    /// An image view rather than a button, because there is nothing to press: the app cannot pause a cube from here.
    /// Pausing is the cube's own gesture and the dropdown's Lock, and a glyph that looked pressable would be offering
    /// a control this app does not have.
    let faceGlyphView = NSImageView()

    /// The row under the name: the glyph, then the figure.
    private let faceStatus = NSStackView()

    let deviceView = NSImageView()

    /// The face's category icon, on the device's centre face.
    let centreIconView = NSImageView()

    /// The square the glyph and the clock are centred in: as wide as the column, and as tall as it is wide.
    private let squareArea = NSView()
    private let centred = NSStackView()
    private var glyphWidth: NSLayoutConstraint!
    private var glyphHeight: NSLayoutConstraint!
    private var centreIconWidth: NSLayoutConstraint!
    private var centreIconHeight: NSLayoutConstraint!
    private var symbolName: String?
    /// Which glyph sits beside the figure, held so `layout` can re-render it at a new size.
    private var faceGlyphName: String?

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
    /// - Parameter isLimitReached: whether the category on show has spent its `daily_limit`. It greys the control
    ///   for the same reason the dropdown's Resume greys: `togglePause` refuses either way, and a control that looks
    ///   live and does nothing reads as broken rather than as one being deliberate.
    func show(
        category: CategoryRecord?,
        state: TimingState,
        elapsed: TimeInterval,
        isLimitReached: Bool = false
    ) {
        self.state = state
        // There is no cube in this picture. Clearing the artwork rather than merely hiding it means a link that drops
        // cannot leave a lit face behind it in memory, waiting to be shown again by a later resize.
        showDevice(nil, category: nil)
        showFaceLock(nil)
        // Emptied and collapsed, so the column's bottom comes back up to the name.
        faceElapsedLabel.stringValue = ""
        faceGlyphName = nil
        faceGlyphView.isHidden = true
        applyFigureHeight()
        symbolName = ManualTimerRules.symbolName(for: state)
        let isHidden = symbolName == nil
        centred.isHidden = isHidden
        categoryNameLabel.isHidden = isHidden
        // Not merely inert: an idle control is not drawn at all, so there is nothing to click at.
        playPauseButton.isEnabled = ManualTimerRules.isClickable(state, isLimitReached: isLimitReached)

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

    /// Draws the face the cube is resting on: the device lit in that face's category colour, with that category's
    /// icon on its centre face and its name underneath.
    ///
    /// Given the category rather than looking it up, for the same reason `show(category:state:elapsed:)` is: which
    /// category a face holds lives in `face`, and reading it belongs to whoever is about to draw (see
    /// `TimingReadout.read`). The face number is taken as well as the category so a face holding
    /// nothing is still a face -- the cube is drawn unlit rather than the column going blank.
    ///
    /// **No clock and no play/pause**, which is the archive's arrangement and its reasoning: this is a picture of
    /// where the cube is, and the cube's own timing is not something a click on this window starts or stops.
    /// - Parameter isLocked: whether this face keeps the category it has. Drawn as the lock in the corner, and the
    ///   same answer the category list is drawn live or dead from -- see `FacesTabRules`.
    /// - Parameter elapsed: the category's total for the day. Drawn under its name, since the square is the cube.
    ///   `0` with no category to total is drawn as `0:00:00` rather than left blank: a face that has recorded nothing
    ///   today is a real answer, and a gap where a figure belongs reads as one that failed to arrive.
    /// - Parameter isDevicePaused: whether the cube itself is paused, or `nil` for one that has not answered. Drawn
    ///   as the glyph beside the figure; nothing is drawn for `nil`, since a guess would be a claim about hardware on
    ///   no evidence.
    func show(
        face: Int,
        category: CategoryRecord?,
        isLocked: Bool = false,
        elapsed: TimeInterval = 0,
        showingSeconds: Bool = true,
        isDevicePaused: Bool? = nil
    ) {
        state = .idle
        centred.isHidden = true
        playPauseButton.isEnabled = false
        showDevice(face, category: category)
        showFaceLock(isLocked)
        // Nothing on the face means nothing to total, and an unlit cube with a figure under it would be a number
        // about a category that is not there.
        faceElapsedLabel.stringValue = category == nil ? "" : DurationFormat.hoursMinutesSeconds(
            elapsed,
            // Truncated, like every other figure the app draws: what is shown must never be ahead of what is recorded.
            rounding: .truncate,
            showingSeconds: showingSeconds
        )
        // Nothing to qualify means nothing to draw beside it, so the glyph goes with the figure rather than sitting
        // alone under an unlit cube.
        faceGlyphName = faceElapsedLabel.stringValue.isEmpty
            ? nil
            : isDevicePaused.map { $0 ? "pause.fill" : "play.fill" }
        faceGlyphView.isHidden = faceGlyphName == nil
        // **Said in words as well as drawn**, which is what the menu bar's own line already does for the same fact
        // (`StatusItemTitle` spells "device paused" into the spoken description). A symbol is one character to
        // anything reading the accessibility tree, so a glyph with no label cannot be told from any other -- and
        // "which one is showing" is exactly the question both a screen reader and a scripted check are here to ask.
        //
        // A readout, not an instruction: it says what the cube is doing, because that is all this is. Pressing it
        // does nothing -- see `faceGlyphView`.
        faceGlyphView.setAccessibilityLabel(isDevicePaused.map { $0 ? "Device paused" : "Device running" })
        applyFigureHeight()
        categoryNameLabel.isHidden = false
        categoryNameLabel.stringValue = category?.name ?? ""
        // Applied here as well as in `layout()`, for the reason the other `show` gives: the fitted size depends on the
        // text, and a view with no window may never be asked to lay out again.
        apply(nameFontFitting: bounds.width)
        needsLayout = true
    }

    /// Paints the cube for a face, or takes it away entirely when there is none.
    ///
    /// **Recoloured rather than tinted**: a template image keeps only the alpha and floods the whole shape with one
    /// colour, which would swallow the lines and the ring along with them. `ActivityIcon.colouredImage` substitutes
    /// the two placeholder colours the artwork is authored with, so the body takes the face's colour, the inner lines
    /// take whatever reads against it, and the outline and the ring keep the colours they were drawn in.
    private func showDevice(_ face: Int?, category: CategoryRecord?) {
        guard face != nil else {
            deviceView.image = nil
            deviceView.isHidden = true
            centreIconView.image = nil
            centreIconView.isHidden = true
            return
        }
        let ink = DeviceFaceRules.lineColour(for: category)
        deviceView.image = ActivityIcon.colouredImage(
            named: Self.deviceArtwork,
            pointSize: Layout.artworkPointSize,
            fill: DeviceFaceRules.bodyColour(for: category),
            ink: ink
        )
        deviceView.isHidden = deviceView.image == nil
        // A template, unlike the device under it: the icon is one shape in one colour, and the colour is the same ink
        // the lines it sits between are drawn in.
        centreIconView.image = category?.iconName.flatMap {
            ActivityIcon.image(named: $0, pointSize: Layout.artworkPointSize)
        }
        centreIconView.contentTintColor = ink
        // A face whose category has no icon draws none, rather than a placeholder: the lit body is already saying
        // which category it is, and a square-dashed stand-in would read as artwork that failed to load.
        centreIconView.isHidden = centreIconView.image == nil
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
        let centreIconSize = (side * Layout.centreIconScale).rounded()
        if centreIconWidth.constant != centreIconSize {
            centreIconWidth.constant = centreIconSize
            centreIconHeight.constant = centreIconSize
        }
        let lockSize = (side * Layout.lockScale).rounded()
        if lockWidth.constant != lockSize {
            lockWidth.constant = lockSize
            lockHeight.constant = lockSize
        }
        apply(lockSize: lockSize)
        centred.spacing = (glyphSize * Layout.elapsedGapScale).rounded()
        apply(glyphSize: glyphSize)
        apply(elapsedFontSize: (glyphSize * Layout.elapsedFontScale).rounded())
        apply(nameFontFitting: side)
        // Sized off the name it sits under rather than off the square, so the two move together as the name shrinks
        // to fit a long category.
        let figureSize = ((categoryNameLabel.font?.pointSize ?? Layout.nameFontSize) * Layout.faceElapsedScale).rounded()
        if faceElapsedLabel.font?.pointSize != figureSize {
            faceElapsedLabel.font = .monospacedDigitSystemFont(ofSize: figureSize, weight: .medium)
        }
        if faceGlyphWidth.constant != figureSize {
            faceGlyphWidth.constant = figureSize
            faceGlyphHeight.constant = figureSize
        }
        apply(faceGlyphSize: figureSize)
        applyFigureHeight()
    }

    /// Draws the glyph at the size of the figure it stands beside, so the pair reads as one line.
    private func apply(faceGlyphSize: CGFloat) {
        guard let faceGlyphName else {
            faceGlyphView.image = nil
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: faceGlyphSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: faceGlyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.isTemplate = true
        faceGlyphView.image = image
        // The secondary colour the figure is drawn in: the pair is one note under the name, not two things.
        faceGlyphView.contentTintColor = .secondaryLabelColor
    }

    /// Gives the figure its height, or takes it away entirely when there is nothing to show.
    private func applyFigureHeight() {
        let wanted = faceElapsedLabel.stringValue.isEmpty
            ? 0
            : ceil(faceElapsedLabel.intrinsicContentSize.height)

        guard faceElapsedHeight.constant != wanted else { return }
        faceElapsedHeight.constant = wanted
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
        // No focus ring. The glyph *is* the control and it is drawn at the column's width, so the ring is a large blue
        // rectangle round the middle of the tab that appears on the first click and stays until something else takes
        // focus -- it reads as the icon being selected rather than as anything having been pressed. The same reason
        // `IconGrid`, `ColourList` and the Report tab's calendar all switch it off: a control that draws its own
        // appearance does not want a second one drawn over it.
        playPauseButton.focusRingType = .none
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

        for view in [deviceView, centreIconView] {
            // Scaled into whatever frame it is given: both are vectors, rendered once at a generous size and drawn at
            // the column's, so the artwork stays crisp as the window is resized without being re-rendered on every
            // pass through `layout()`.
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            // **Neither of these gets a say in how big anything is.** An `NSImageView`'s intrinsic size is its
            // image's, and the artwork is rendered at `artworkPointSize` so it stays crisp at any width -- so left at
            // the default priorities a 512pt render pushes the square, the column and ultimately the window's minimum
            // width out to 512. Measured, not guessed: `testTheCubeFillsTheSquare` failed at exactly 512 before this.
            // The pinned edges below are what decides their size, and both are drawn scaled to fit whatever that is.
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                view.setContentHuggingPriority(.defaultLow, for: axis)
                view.setContentCompressionResistancePriority(.defaultLow, for: axis)
            }
        }
        faceElapsedLabel.font = .monospacedDigitSystemFont(ofSize: Layout.nameFontSize * Layout.faceElapsedScale, weight: .medium)
        faceElapsedLabel.textColor = .secondaryLabelColor
        faceElapsedLabel.alignment = .center
        faceElapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        faceElapsedLabel.setAccessibilityIdentifier(Identifier.faceElapsed)
        // **So the driven height wins.** A label resists being compressed below its font's height at `.defaultHigh`,
        // which is exactly the priority the height constraint holds -- and a tie is not a win, so an empty label went
        // on occupying 26 points of the column. Lowering this leaves the constraint deciding, while keeping the square
        // (required) able to win over both if a short window ever forces it.
        faceElapsedLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        faceGlyphView.imageScaling = .scaleProportionallyUpOrDown
        faceGlyphView.translatesAutoresizingMaskIntoConstraints = false
        faceGlyphView.setAccessibilityIdentifier(Identifier.faceGlyph)
        faceGlyphView.isHidden = true
        // No say in the row's size, like the artwork above: the glyph is rendered at whatever size the name decides
        // and drawn into it, so its own image must not push the column wider.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            faceGlyphView.setContentHuggingPriority(.defaultLow, for: axis)
            faceGlyphView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        faceStatus.orientation = .horizontal
        faceStatus.alignment = .centerY
        faceStatus.spacing = Layout.faceGlyphSpacing
        faceStatus.translatesAutoresizingMaskIntoConstraints = false
        faceStatus.addView(faceGlyphView, in: .leading)
        faceStatus.addView(faceElapsedLabel, in: .leading)

        lockButton.isBordered = false
        lockButton.bezelStyle = .inline
        lockButton.imagePosition = .imageOnly
        lockButton.title = ""
        // No focus ring, for the reason the play/pause glyph and the category rows give: a control that draws its own
        // appearance does not want a second one drawn over it, and here the ring would outline a corner of the cube.
        lockButton.focusRingType = .none
        lockButton.target = self
        lockButton.action = #selector(toggleLock)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.isHidden = true
        lockButton.identifier = NSUserInterfaceItemIdentifier(Identifier.faceLock)
        lockButton.setAccessibilityIdentifier(Identifier.faceLock)

        deviceView.identifier = NSUserInterfaceItemIdentifier(Identifier.cubeFace)
        deviceView.setAccessibilityIdentifier(Identifier.cubeFace)
        centreIconView.identifier = NSUserInterfaceItemIdentifier(Identifier.centreIcon)
        centreIconView.setAccessibilityIdentifier(Identifier.centreIcon)

        addSubview(squareArea)
        // Behind everything else in the square, in subview order: the cube is the ground the centre icon sits on.
        squareArea.addSubview(deviceView)
        squareArea.addSubview(centreIconView)
        squareArea.addSubview(centred)
        // Last, so it is above the artwork it sits on the corner of.
        squareArea.addSubview(lockButton)
        addSubview(categoryNameLabel)
        addSubview(faceStatus)

        glyphWidth = playPauseButton.widthAnchor.constraint(equalToConstant: 1)
        glyphHeight = playPauseButton.heightAnchor.constraint(equalToConstant: 1)
        centreIconWidth = centreIconView.widthAnchor.constraint(equalToConstant: 1)
        centreIconHeight = centreIconView.heightAnchor.constraint(equalToConstant: 1)
        lockWidth = lockButton.widthAnchor.constraint(equalToConstant: 1)
        lockHeight = lockButton.heightAnchor.constraint(equalToConstant: 1)
        // **Driven, because an empty label is not a label of no height.** A text field sizes itself to its font
        // whether or not it holds anything, so left to itself this took four points off the bottom of the column --
        // and the square, which is measured from the width the column has left, shrank by the same four. Measured:
        // `testTheCubeFillsTheSquare` came back 396 against a 400pt column.
        // Sized by constraint, not by its image: content priorities are `.defaultLow` above so the artwork cannot
        // push the column, which leaves nothing else to decide how big it is.
        faceGlyphWidth = faceGlyphView.widthAnchor.constraint(equalToConstant: 1)
        faceGlyphHeight = faceGlyphView.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([faceGlyphWidth, faceGlyphHeight])

        // **On the row, not on the label inside it.** The stack takes its own height from its contents, so driving the
        // label alone left the row a few points taller than the figure -- enough for the glyph, centred in it, to
        // reach up over the bottom of the name. The row is the thing that has to be exactly this tall or exactly
        // nothing.
        faceElapsedHeight = faceStatus.heightAnchor.constraint(equalToConstant: 0)
        // **The one constraint here that may give way.** (On the row above.) The column is allowed to be shorter than the space it sits
        // in but not taller, so on a short enough window something has to yield -- and of everything in this view the
        // figure is the piece that can be squeezed without the picture going wrong. The square staying square is what
        // the whole layout is measured from.
        faceElapsedHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            squareArea.topAnchor.constraint(equalTo: topAnchor),
            squareArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            squareArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            // As tall as it is wide: the space the device graphic occupies, kept whether or not anything is
            // drawn in it, so the name below does not move when a session starts.
            squareArea.heightAnchor.constraint(equalTo: squareArea.widthAnchor),

            // The cube fills the square exactly, which is what the square was reserved for.
            deviceView.topAnchor.constraint(equalTo: squareArea.topAnchor),
            deviceView.leadingAnchor.constraint(equalTo: squareArea.leadingAnchor),
            deviceView.trailingAnchor.constraint(equalTo: squareArea.trailingAnchor),
            deviceView.bottomAnchor.constraint(equalTo: squareArea.bottomAnchor),

            // The centre face is centred on the artwork, so centring the icon in the same square puts it on that face
            // without anything having to find the pentagon's corners.
            centreIconView.centerXAnchor.constraint(equalTo: squareArea.centerXAnchor),
            centreIconView.centerYAnchor.constraint(equalTo: squareArea.centerYAnchor),
            centreIconWidth,
            centreIconHeight,

            // The top-leading corner, which is the archive's placement: the band of square outside the ring, where it
            // lands on nothing the artwork is drawing.
            lockButton.topAnchor.constraint(equalTo: squareArea.topAnchor),
            lockButton.leadingAnchor.constraint(equalTo: squareArea.leadingAnchor),
            lockWidth,
            lockHeight,

            centred.centerXAnchor.constraint(equalTo: squareArea.centerXAnchor),
            centred.centerYAnchor.constraint(equalTo: squareArea.centerYAnchor),
            centred.leadingAnchor.constraint(greaterThanOrEqualTo: squareArea.leadingAnchor),
            centred.trailingAnchor.constraint(lessThanOrEqualTo: squareArea.trailingAnchor),
            glyphWidth,
            glyphHeight,

            categoryNameLabel.topAnchor.constraint(equalTo: squareArea.bottomAnchor, constant: Layout.nameSpacing),
            categoryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            // **Under the name, and it is the bottom of the column now.** With nothing to show its height is driven to
            // zero, so the name reaches the bottom exactly as it did before there was a figure to put here.
            faceStatus.topAnchor.constraint(equalTo: categoryNameLabel.bottomAnchor),
            faceStatus.centerXAnchor.constraint(equalTo: centerXAnchor),
            faceStatus.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            faceStatus.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            faceStatus.bottomAnchor.constraint(equalTo: bottomAnchor),
            faceElapsedHeight,
        ])
    }

    /// Draws the lock at the size the square currently gives it.
    ///
    /// **A template tinted red or green**, which is the archive's rule and its reasoning: the colour says whether the
    /// face will accept a new category, matching the list going dead beside it. So the two never have to be read
    /// together to be understood -- a red lock and a dead list are one fact drawn twice.
    private func apply(lockSize: CGFloat) {
        let name = isFaceLocked ? "lock.fill" : "lock.open.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: lockSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.isTemplate = true
        lockButton.image = image
        lockButton.contentTintColor = isFaceLocked ? .systemRed : .systemGreen
    }

    /// Shows or hides the lock, and says which way it is.
    ///
    /// **Hidden rather than switched off when there is no cube.** Manual mode's face is *meant* to be reassigned --
    /// every category picked lands on it -- so a lock there could only get in the way of the one gesture this tab has.
    /// The archive drew it the same way, and for the same reason: there is no lock to offer, not a lock that happens
    /// to be open.
    private func showFaceLock(_ isLocked: Bool?) {
        guard let isLocked else {
            lockButton.isHidden = true
            return
        }
        isFaceLocked = isLocked
        lockButton.isHidden = false
        // Both spelled out, rather than one name for the control: what it is called has to say what pressing it does,
        // and "Lock" on a locked face reads as a label for the state it is already in.
        lockButton.toolTip = isLocked
            ? "Unlock this face so its category can be changed"
            : "Lock this face to keep its category"
        lockButton.setAccessibilityLabel(isLocked ? "Unlock face" : "Lock face")
        apply(lockSize: lockWidth.constant)
    }

    @objc
    private func toggleLock() {
        onToggleLock?()
    }

    @objc
    private func togglePause() {
        onTogglePause?()
    }
}
