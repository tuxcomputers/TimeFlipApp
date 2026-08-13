import AppKit

/// A number in a box, a suffix naming its unit, and a pair of arrows: the previous app's control for every typeable
/// value in this window, and the shape its daily-limit column expects.
///
/// **One width for all of them**, which is the archive's reason for fixing it rather than letting each field size to
/// its own digits: the boxes read as a column instead of as five different sizes. The same goes for the suffix slot,
/// sized to the longest unit there is, so every row's arrows land in the same place whatever word sits in front of
/// them.
///
/// Reports a value only when it changes, and only inside the range it was given: a typed figure out of range is
/// brought back in rather than refused, because a number box has no other way to say no, and the nearest allowed
/// value is what somebody typing 9999 into a minutes field meant.
///
/// **Typing commits on Return or on losing focus, never per keystroke**, which is the archive's finding and its
/// reason: a keystroke-by-keystroke commit clamps "1" on the way to "15" and fights the user.
///
/// **An arrow steps from the number on screen, not from the number in storage.** Type 20 into a field holding 5,
/// click up without pressing Return, and the answer is 21. Also the archive's, with its reasoning: the visible text
/// is what somebody believes the value to be, so treating it as the waypoint is the only reading that matches the
/// screen.
///
/// **Holding an arrow accelerates**: ticks of 1 until the value passes the second multiple of 5 beyond where the hold
/// began, then ticks of 5 at a slower cadence. `StepperHoldRules` is that sequence, copied from the archive and
/// tested on its own. The arrows are a hand-built pair rather than an `NSStepper` precisely because of it: a stock
/// stepper repeats at one fixed increment, and on a range as wide as a day of minutes stepping by 1 the whole way is
/// what makes somebody give up and type instead.
@MainActor
final class SteppedNumberField: NSView {
    enum Layout {
        /// The archive's measurements. The field is wider than the digits need so that every value field in the
        /// window can share one width.
        static let fieldWidth: CGFloat = 90
        static let suffixWidth: CGFloat = 34
        static let spacing: CGFloat = 4
        /// The arrow pair: two chevrons stacked, at the sizes the archive drew them.
        static let arrowsWidth: CGFloat = 16
        static let arrowHeight: CGFloat = 10
        static let arrowSpacing: CGFloat = 1
        static let arrowPointSize: CGFloat = 8
    }

    /// Called with the new value once it has changed, already inside the range.
    var onChange: ((Int) -> Void)?

    private let field = NSTextField()
    private let suffix: NSTextField
    private let range: ClosedRange<Int>
    private var upArrow: HoldArrow!
    private var downArrow: HoldArrow!

    /// What is on show. Setting it does not call `onChange`: this is how the value is put there, not how it is
    /// changed.
    var value: Int {
        didSet {
            field.integerValue = value
        }
    }

    init(value: Int, range: ClosedRange<Int>, suffix unit: String, identifier: String) {
        self.value = range.clamped(to: value)
        self.range = range
        self.suffix = NSTextField(labelWithString: unit)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addContent(identifier: identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func addContent(identifier: String) {
        field.integerValue = value
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(fieldChanged)
        // Fires when the field loses focus as well as on Enter, so a typed value is not lost by clicking elsewhere.
        field.isContinuous = false
        field.setAccessibilityIdentifier(identifier)

        suffix.textColor = .secondaryLabelColor
        suffix.translatesAutoresizingMaskIntoConstraints = false

        upArrow = arrow(direction: 1, symbol: "chevron.up", identifier: "\(identifier)-up")
        downArrow = arrow(direction: -1, symbol: "chevron.down", identifier: "\(identifier)-down")
        let arrows = NSStackView(views: [upArrow, downArrow])
        arrows.orientation = .vertical
        arrows.spacing = Layout.arrowSpacing
        arrows.translatesAutoresizingMaskIntoConstraints = false

        addSubview(field)
        addSubview(suffix)
        addSubview(arrows)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),

            suffix.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Layout.spacing),
            suffix.centerYAnchor.constraint(equalTo: centerYAnchor),
            suffix.widthAnchor.constraint(equalToConstant: Layout.suffixWidth),

            arrows.leadingAnchor.constraint(equalTo: suffix.trailingAnchor, constant: Layout.spacing),
            arrows.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrows.trailingAnchor.constraint(equalTo: trailingAnchor),

            topAnchor.constraint(lessThanOrEqualTo: field.topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: field.bottomAnchor),
        ])
    }

    private func arrow(direction: Int, symbol: String, identifier: String) -> HoldArrow {
        let arrow = HoldArrow(direction: direction, symbol: symbol)
        arrow.identifier = NSUserInterfaceItemIdentifier(identifier)
        arrow.setAccessibilityIdentifier(identifier)
        arrow.setAccessibilityLabel(direction > 0 ? "Increase" : "Decrease")
        arrow.onStep = { [weak self] in self?.step(direction) }
        arrow.onHoldStep = { [weak self] in self?.holdStep(direction) }
        return arrow
    }

    // MARK: - stepping

    /// The value the hold in progress began at, which is fixed for its whole duration: it is what the
    /// step-1-then-step-5 boundary is measured from, not wherever the value has since reached.
    private var holdStartValue = 0

    /// One step, from what is on screen. Also the first step of a hold, since a hold begins with a press.
    private func step(_ direction: Int) {
        // Taken from the field's text rather than from storage, so a hold begun after typing accelerates from where
        // the number can be seen to start.
        holdStartValue = onScreenValue
        report(holdStartValue + direction)
    }

    /// One more tick of a held arrow, and how long to wait before the next one. `nil` stops the hold.
    private func holdStep(_ direction: Int) -> TimeInterval? {
        let next = StepperHoldRules.nextValue(current: value, holdStartValue: holdStartValue, direction: direction)
        let allowed = range.clamped(to: next)
        // Clamped back to where it already was means the end of the range: nothing more can happen, so the hold
        // stops rather than ticking against a value that cannot move.
        guard allowed != value else { return nil }
        report(allowed)
        return StepperHoldRules.tickInterval(
            current: value,
            holdStartValue: holdStartValue,
            direction: direction
        )
    }

    /// The number somebody can see, which is the field's text when that parses and the stored value when it does
    /// not. Garbage falls back to the last number actually chosen rather than to zero, which is the archive's rule
    /// and the same one its typed commit follows.
    private var onScreenValue: Int {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return range.clamped(to: Int(typed) ?? value)
    }

    @objc
    private func fieldChanged() {
        report(field.integerValue)
    }

    /// Puts the value inside the range, shows it, and reports it if it actually moved.
    ///
    /// The redraw happens either way, including when nothing moved: a typed 9999 that clamps back to 1440 has to
    /// show 1440, or the box would keep claiming a value nothing agreed to.
    private func report(_ requested: Int) {
        let allowed = range.clamped(to: requested)
        let changed = allowed != value
        value = allowed
        if changed {
            onChange?(allowed)
        }
    }
}

/// One chevron that steps once when clicked and keeps stepping while held.
///
/// A button rather than a drawn glyph, so it is pressable by the keyboard, by a screen reader and by a script, and
/// so a single press is one step with no hold machinery involved at all.
///
/// **`mouseDown` is taken over rather than extended.** A button's own tracking sends its action on mouse *up*, which
/// is the wrong moment for something that has to repeat while down, and calling both would step twice for one click.
/// So the press path is here and the action path is left for `performClick`, which is what accessibility uses.
@MainActor
final class HoldArrow: NSButton {
    let direction: Int

    /// One step. Called on the press, and by `performClick` for a script or a screen reader.
    var onStep: (() -> Void)?

    /// One more step while held, answering with how long to wait before the next one. `nil` ends the hold, which is
    /// what the end of a range reports.
    var onHoldStep: (() -> TimeInterval?)?

    init(direction: Int, symbol: String) {
        self.direction = direction
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        let configuration = NSImage.SymbolConfiguration(
            pointSize: SteppedNumberField.Layout.arrowPointSize,
            weight: .bold
        )
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(pressed)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SteppedNumberField.Layout.arrowsWidth),
            heightAnchor.constraint(equalToConstant: SteppedNumberField.Layout.arrowHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc
    private func pressed() {
        onStep?()
    }

    /// Steps once, then keeps stepping until the button is let go.
    ///
    /// An explicit event-tracking loop rather than a timer and a `mouseUp` override, which is AppKit's own idiom for
    /// press-and-hold and avoids the question of whether a release can even be delivered to a view that is still
    /// inside its own `mouseDown`. `nextEvent` returning `nil` **is** the tick: it means the wait ran out with no
    /// release, so the next step is due.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // The first step lands immediately, so a click is a step rather than a wait.
        onStep?()
        // Then a pause before anything repeats, so an ordinary click cannot become a run of them.
        var wait = StepperHoldRules.initialHoldDelay
        while true {
            let released = window?.nextEvent(
                matching: [.leftMouseUp],
                until: Date().addingTimeInterval(wait),
                inMode: .eventTracking,
                dequeue: true
            )
            guard released == nil, let next = onHoldStep?() else { return }
            wait = next
        }
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(to value: Int) -> Int {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
