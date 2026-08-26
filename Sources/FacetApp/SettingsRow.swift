import AppKit

/// A row of a Settings list: the height every row on every tab keeps, and the label-and-value shape two of the
/// three tabs draw.
///
/// **Two things, because the tabs share one of them and not the other.** The App and Device tabs draw the same row
/// -- words on the left, a control or a reading pinned to the right -- and drew it twice, in two files, from two
/// near-identical functions. That is `make`. The Categories tab draws something genuinely different: a table row of
/// fixed-width columns lined up under a header, with no label-and-value split in it at all, so a shared builder
/// there would be an abstraction fitting neither.
///
/// What all three *do* share is `settle`, and it is the more important half. Until it existed the Categories tab's
/// rows were 24pt because the number field inside them is 24pt, and nothing on that tab read `rowHeight` at all --
/// so `SettingsMetrics.rowHeight` moved the App and Device tabs and left the tab the numbers came from where it was.
/// The claim that one value governs the look of all three was not true, and `settle` is what makes it true.
enum SettingsRow {
    /// Gives a row a height that is **decided**, not merely bounded.
    ///
    /// **This is the fault the Device tab kept producing, three times over**, and the comment it left is kept here
    /// because the fault is not that tab's: a row is a bare `NSView`, which has no intrinsic content size, so
    /// `heightAnchor >= rowHeight` is the only thing saying how tall it is -- and a minimum is not a value. Auto
    /// Layout is then free to pick anything at or above it, and inside a `.fill` stack pinned to the panel on all
    /// four sides it picks bigger: the auto-pause row drew several times its height, and once that was pinned down
    /// the slack moved to the scan controls row and did it again.
    ///
    /// The low-priority equality is what decides it. Anything real -- a taller control, a wrapped label -- outranks
    /// it and the row grows properly; with nothing pushing, the row sits at the rhythm of the list.
    ///
    /// **Every row on every tab ends here**, which is the point. Applying it per builder is what let the third one
    /// be written without it, and what let the Categories tab never have it at all.
    @discardableResult
    static func settle(_ row: NSView) -> NSView {
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsMetrics.rowHeight).isActive = true
        let preferred = row.heightAnchor.constraint(equalToConstant: SettingsMetrics.rowHeight)
        preferred.priority = .defaultLow
        preferred.isActive = true
        return row
    }

    /// The label-and-value row the App and Device tabs are both made of.
    ///
    /// **The control is pinned to the trailing edge rather than following the label**, which is what the archive's
    /// form did and what lines the controls up down the right-hand side however long the words in front of them
    /// are. A fixed label column would line them up too, and park them in the middle of the panel with dead space
    /// beyond, which is not what that tab looked like.
    ///
    /// **The label gives way before the control does.** A window narrow enough to squeeze one of these truncates
    /// the words rather than the answer, or the field somebody types into.
    ///
    /// **No inset of its own.** The panel insets the list, exactly as it does on the Categories tab, so a row that
    /// inset itself as well would indent every row twice over. Both tabs used to do that, back when they drew their
    /// own hairlines between rows and had to place the ends of them.
    static func make(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: control.leadingAnchor, constant: -SettingsMetrics.columnSpacing
            ),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])
        // A control with a width constraint and no height -- `SteppedNumberField` is exactly that -- has nothing of
        // its own to stop it stretching and taking the row with it. `settle` decides the row; this stops the control
        // arguing with it.
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        return settle(row)
    }
}
