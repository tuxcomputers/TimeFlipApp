import AppKit

/// A name that becomes a field when it is clicked, and goes back to being a name when the edit ends.
///
/// **Clicking the name is the way in.** The previous app hid this behind a right-click menu offering *Edit*, which is
/// a gesture nobody finds and a menu with one item in it. A name is the thing being renamed, so it is the thing to
/// click, and a tooltip says so for anybody who has not tried.
///
/// How an edit ends, all three ways:
///
/// - **Return commits it**, which is what raises the confirmation. The name on screen does not change here; it
///   changes when the table has been written and read back.
/// - **A click anywhere else abandons it**, which is what a click outside an editor means everywhere else on this
///   platform: the click was aimed at something else, and it lands on that something else as well as closing this.
/// - **Escape abandons it too**, so a name opened by mistake costs one key rather than a trip through a dialogue.
///
/// Abandoning rather than committing on the way out is deliberate. A rename is confirmed, so committing on a stray
/// click would raise a dialogue about a change nobody asked for, in front of whatever they were actually clicking.
@MainActor
final class EditableNameCell: NSView {
    /// Called when Return commits an edit, with what was typed. Whether that becomes the name is the window's to
    /// decide: it confirms, writes, and the row is read back.
    var onCommit: ((String) -> Void)?

    /// Called as an edit opens and closes, so the window can log it and can lend Escape to the field -- a key
    /// equivalent is dispatched before the focused field ever sees the key, so the Close button would otherwise win
    /// and shut the window instead.
    var onEditingChanged: ((Bool) -> Void)?

    private(set) var isEditing = false

    /// Whether the name can be edited. Off, the name is drawn exactly as before and clicking it does nothing: it is
    /// still a name to read, and the tooltip is what says why it will not open.
    ///
    /// The button is left *enabled* on purpose. A disabled `NSButton` draws its contents grey, which would grey the
    /// name itself and make a locked row look like a retired one; and macOS does not show a tooltip for a disabled
    /// control, so the explanation would go with it. What is switched off is the edit, not the button.
    var isEnabled: Bool = true

    /// What the name says when it will not open, or `nil` when it will.
    ///
    /// It replaces the tooltip **and** the spoken label, since "click to rename" on something that will not open is a
    /// lie told to whoever cannot see that nothing happened.
    var disabledHelp: String? {
        didSet {
            button.toolTip = disabledHelp ?? Self.hint
            button.setAccessibilityLabel(disabledHelp.map { "\(name), \($0)" } ?? "\(name), \(Self.hint.lowercased())")
        }
    }

    /// The one hint that this is a control at all.
    private static let hint = "Click to rename"

    let name: String

    /// How the name sits in the cell. Kept as a property because it is the one thing the two uses differ by, so it is
    /// worth being able to ask rather than infer from a frame.
    let alignment: NSTextAlignment

    private let button = NSButton()
    private let label: NSTextField
    private let field = NSTextField()
    /// Watches for the click that lands somewhere else. Held in its own object so it is removed even if this cell is
    /// thrown away mid-edit, which the list rebuilding under it would do.
    private let outsideClick = OutsideClickMonitor()

    /// `alignment` is how the name sits inside the cell, and it is the one thing that differs between the two places
    /// this is used. A category's name heads a column and reads from the left; the App tab's rows put every value
    /// against the right-hand edge, beside the account's name and email. Everything else -- the gesture, the tooltip,
    /// the field that appears, and how an edit ends -- is deliberately identical, because they are the same act.
    init(name: String, width: CGFloat, identifier: String, alignment: NSTextAlignment = .left) {
        self.name = name
        self.alignment = alignment
        label = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addContent(width: width, identifier: identifier, alignment: alignment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Turns the name into a field, focused, with the current name in it and selected, so typing replaces it and
    /// clicking puts a caret where it was clicked.
    func beginEditing() {
        guard isEnabled, !isEditing else { return }
        field.stringValue = name
        button.isHidden = true
        field.isHidden = false
        // **The flag is claimed after the responder changes, not before, and the order is the whole point.**
        // `makeFirstResponder` tears down whatever field editor is attached, and doing so delivers
        // `controlTextDidEndEditing` *synchronously* -- so calling it while `isEditing` is already true
        // re-enters this class through `endEditing`, which sets the flag back to false. `beginEditing` then
        // finishes on top of a state it no longer owns: the field is open and focused, characters type into
        // it, and Return commits nothing, because the guard in `controlTextDidEndEditing` sees `false`.
        //
        // It only bites when a stale editor is still attached, which is what a dismissed sheet leaves behind
        // (measured 2026-08-16: refuse a rename, dismiss the alert, click the name again, and the field
        // could be typed into but never committed). With the flag claimed afterwards, that reentrant call
        // sees a session that has not begun and does nothing.
        window?.makeFirstResponder(field)
        isEditing = true
        field.currentEditor()?.selectAll(nil)
        outsideClick.start { [weak self] event in
            self?.clickLanded(event)
            return event
        }
        onEditingChanged?(true)
    }

    /// Puts the name back. The name itself never changed: what a commit does is ask, and the row is rebuilt from the
    /// table afterwards if anything came of it.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        outsideClick.stop()
        field.isHidden = true
        button.isHidden = false
        // Focus goes nowhere in particular rather than to the next control, since nothing here was aimed at.
        if window?.firstResponder === field || window?.firstResponder is NSTextView {
            window?.makeFirstResponder(nil)
        }
        onEditingChanged?(false)
    }

    /// Whether a click at this window point is outside the field being edited. Separate from acting on it so the rule
    /// can be tested without a window to click in.
    func isOutsideField(windowPoint: NSPoint) -> Bool {
        !field.frame.contains(field.superview?.convert(windowPoint, from: nil) ?? .zero)
    }

    private func clickLanded(_ event: NSEvent) {
        // The event is returned unchanged either way, so the click still reaches whatever it was aimed at. Ending the
        // edit first is what makes that the same gesture rather than two.
        guard event.window === window, isOutsideField(windowPoint: event.locationInWindow) else { return }
        endEditing()
    }

    private func addContent(width: CGFloat, identifier: String, alignment: NSTextAlignment) {
        // The label lives *inside* the button, not beside it: a click on a label goes up the responder chain to the
        // label's own superview, so a button that is merely behind it is never pressed (see `Tests/Methods.md`).
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.target = self
        button.action = #selector(nameClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel("\(name), \(Self.hint.lowercased())")
        // The one hint that this is a control at all. It draws as a plain name on purpose: a column of buttons would
        // read as a row of controls, when what is wanted is a list that can be corrected.
        button.toolTip = Self.hint

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false

        field.alignment = alignment
        field.stringValue = name
        field.isHidden = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.identifier = NSUserInterfaceItemIdentifier("\(identifier)-field")
        field.setAccessibilityIdentifier("\(identifier)-field")
        field.setAccessibilityLabel("\(name), new name")

        button.addSubview(label)
        addSubview(button)
        addSubview(field)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),

            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),

            // Which edge the name is pinned to is what `alignment` actually means here: a label only sized to its text
            // has nowhere to align *within*, so a right-aligned name pinned on the left would still draw on the left.
            alignment == .right
                ? label.trailingAnchor.constraint(equalTo: button.trailingAnchor)
                : label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            alignment == .right
                ? label.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor)
                : label.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor),
            label.topAnchor.constraint(equalTo: button.topAnchor),
            label.bottomAnchor.constraint(equalTo: button.bottomAnchor),

            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: field.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor),
        ])
    }

    @objc
    private func nameClicked() {
        beginEditing()
    }
}

extension EditableNameCell: NSTextFieldDelegate {
    /// The end of an edit, whichever way it ended.
    ///
    /// **Which way is `NSTextMovement`**, and it has to be asked: an `NSTextField`'s action and this notification both
    /// fire on Return *and* on losing focus, so without the distinction a click elsewhere would commit -- raising a
    /// dialogue about a rename nobody asked for, on top of whatever they were reaching for.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let typed = field.stringValue
        endEditing()
        guard movement == NSTextMovement.return.rawValue else { return }
        onCommit?(typed)
    }

    /// Escape, which the field only sees because the window lends it (see `onEditingChanged`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endEditing()
        return true
    }
}

/// Holds a local mouse monitor and takes it away again.
///
/// Its own object, and not `@MainActor`, for the reason `DebugLog` and `DatabaseConnection` have one: a `@MainActor`
/// class cannot touch its own properties in `deinit`, and a monitor that outlives the view it was watching for is a
/// closure the app keeps calling forever.
private final class OutsideClickMonitor {
    private var token: Any?

    @MainActor
    func start(_ handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
    }

    func stop() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    deinit {
        stop()
    }
}
