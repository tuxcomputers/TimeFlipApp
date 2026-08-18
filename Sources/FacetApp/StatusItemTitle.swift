import AppKit

/// What the status item spells out: the pieces, in the order they are drawn, decided apart from the drawing.
///
/// Separate from `MenuBarController` for the reason `Archive/TimeFlipApp/MenuBarStatusStyle` was separate from the
/// previous app's: what the item says can then be asserted without a status item, a menu bar, or a rendered line of
/// text. It is `Equatable` for a second reason as well -- it is what tells a redraw that nothing has changed.
///
/// **The order is the previous app's**, and the reason for it survives: the database badge is first because it
/// qualifies everything to its right, and the category's icon rides *inside* the title rather than as the button's
/// own image, which would draw it to the left of the badge (see `DatabaseBadge`).
struct StatusItemTitle: Equatable {
    /// The words: the category being timed, or the app's own name when nothing is.
    let text: String

    /// The category's artwork, drawn ahead of the words. `nil` for a category with no icon, and while nothing is
    /// being timed.
    let iconName: String?

    /// The play/pause glyph between the name and the figure, from `ManualTimerRules`, so the menu bar and the
    /// Faces tab cannot come to draw a pause differently. `nil` while nothing is being timed.
    let glyphName: String?

    /// The figure, already formatted. `nil` while nothing is being timed: a "0:00" with nothing behind it reads as
    /// a session that has started and got nowhere.
    let duration: String?

    /// What the whole line is drawn in, images included. The database badge keeps its own colour: it names which
    /// file this launch writes to, which is a different question from what the app is doing.
    ///
    /// **Green means there is a live reading behind the figure**, which is the previous app's rule
    /// (`Archive/TimeFlipApp/MenuBarStatusStyle`) and the reason its menu bar could be believed at a glance. Every
    /// reading here is live, the app itself being the source while no cube is paired, so the other two answers it
    /// had are absent rather than reinterpreted: yellow for a reading gone stale when the device dropped, red for a
    /// category over its `daily_limit`. Both come back as further answers *here* when there is a device and a limit
    /// to report, which is why this is a field on the title rather than a constant at the drawing.
    ///
    /// A dynamic colour, resolved as it draws: the menu bar tints from the wallpaper rather than from the
    /// appearance setting, so anything resolved earlier than the draw is one of the two answers frozen (see
    /// `MenuBarController.attachment(of:colour:size:font:)`).
    let colour: NSColor

    /// What the category's name and its icon are drawn in, which is `colour` except while the cube is flat.
    ///
    /// **Only this much of the line flashes, which is the archive's choice and worth keeping**
    /// (`Archive/TimeFlipApp/MenuBarStatusStyle`): the figure beside it is a clock somebody reads, and a duration
    /// changing colour twice a second is harder to read at the exact moment the app is asking for attention.
    ///
    /// **The off phase is `.labelColor`, where the archive used `.white`.** That is the one thing not copied, and it
    /// is a correction rather than a preference: the menu bar tints from the wallpaper rather than from the appearance
    /// setting (see `MenuBarController.attachment(of:colour:size:font:)`), so white against a light strip is a name
    /// that disappears for half of every second instead of one that flashes.
    let nameColour: NSColor

    /// What VoiceOver reads. Spelled out, because a glyph says nothing to a screen reader and neither does the
    /// badge's colour -- and the item's own title would otherwise read as "0:07", which is not a description of
    /// anything.
    let spoken: String

    /// - Parameters:
    ///   - appLabel: the app's own name, which is the whole title while nothing is being timed.
    ///   - badgeDescription: the database badge spelled out, or `nil` in a build without one. The badge's *text*
    ///     is drawn separately, carrying its own colour and weight.
    ///   - reading: the session, read at the moment this is being composed.
    ///   - showingSeconds: whether the figure carries seconds, from `display_seconds`.
    /// - Parameter lowBattery: the warning and which half of its flash is up, asked for as the item is drawn.
    static func make(
        appLabel: String,
        badgeDescription: String?,
        reading: TimingReadout.Reading,
        showingSeconds: Bool,
        isLimitReached: Bool = false,
        lowBattery: LowBatteryAlert = .none
    ) -> StatusItemTitle {
        // The flash, and what it flashes against. Red on one phase and the ordinary text colour on the other, so the
        // name alternates rather than vanishing -- and `nil` when there is nothing to warn about, which leaves the
        // name drawn in whatever the line's own colour turns out to be.
        let flash: NSColor? = lowBattery.isLow ? (lowBattery.isBlinkOn ? .systemRed : .labelColor) : nil
        // Idle keeps the app's name and nothing else, which is what the item has always shown before a session
        // starts. `guard` on both, though the readout only ever pairs them: a category with no state to draw, or a
        // state with no category to name, is half a session either way.
        guard let category = reading.category, let glyphName = ManualTimerRules.symbolName(for: reading.state) else {
            return StatusItemTitle(
                text: appLabel,
                iconName: nil,
                glyphName: nil,
                duration: nil,
                // The ordinary text colour, as the previous app's own no-device placeholder drew it: green is a
                // claim about a reading, and there is no reading here to make it about.
                colour: .labelColor,
                // **The warning still flashes with nothing being timed**, on the app's own name. A flat cube is a
                // fact about the device rather than about the session, and the moment somebody is most likely to
                // miss it is the moment nothing is running.
                nameColour: flash ?? .labelColor,
                spoken: spoken(
                    [appLabel] + (lowBattery.isLow ? ["low battery"] : []),
                    badgeDescription: badgeDescription
                )
            )
        }
        let duration = DurationFormat.hoursMinutesSeconds(
            reading.seconds,
            // A live figure, so truncated rather than rounded: what is shown must never be ahead of the time
            // actually recorded.
            rounding: .truncate,
            showingSeconds: showingSeconds
        )
        return StatusItemTitle(
            text: category.name,
            iconName: category.iconName,
            glyphName: glyphName,
            duration: duration,
            // **Red once the category has spent its `daily_limit`**, which is the archive's colour and its meaning:
            // `MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen` on the same line. Green is a claim
            // that time is being recorded normally, and once a limit has stopped the clock that claim is no longer
            // true -- so the colour and the pause are two faces of one fact, drawn from the same answer
            // (`DailyLimitEnforcement.isReached`) rather than from two comparisons that could disagree by a second.
            colour: isLimitReached ? .systemRed : .systemGreen,
            nameColour: flash ?? (isLimitReached ? .systemRed : .systemGreen),
            spoken: spoken(
                // The name first, then what the glyph means, then the figure, then whose menu bar item this is.
                // Reading order, so the answer comes before the qualifications.
                //
                // **The limit is said, not just coloured.** A colour is the whole of the signal on screen, so
                // without this the one state the item exists to warn about would be the one state it did not
                // mention to anybody reading it aloud.
                // **The warning is said, not just flashed**, for the same reason the limit is: a colour is the whole
                // of the signal on screen, so without this the one state worth interrupting somebody for would be
                // invisible to anybody reading the item aloud.
                [category.name, reading.state == .running ? "running" : "paused", duration]
                    + (isLimitReached ? ["daily limit reached"] : [])
                    + (lowBattery.isLow ? ["low battery"] : [])
                    + [appLabel],
                badgeDescription: badgeDescription
            )
        )
    }

    private static func spoken(_ parts: [String], badgeDescription: String?) -> String {
        (parts + [badgeDescription].compactMap { $0 }).joined(separator: ", ")
    }
}
