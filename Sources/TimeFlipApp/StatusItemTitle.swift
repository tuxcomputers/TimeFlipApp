import Foundation

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
    static func make(
        appLabel: String,
        badgeDescription: String?,
        reading: TimingReadout.Reading,
        showingSeconds: Bool
    ) -> StatusItemTitle {
        // Idle keeps the app's name and nothing else, which is what the item has always shown before a session
        // starts. `guard` on both, though the readout only ever pairs them: a category with no state to draw, or a
        // state with no category to name, is half a session either way.
        guard let category = reading.category, let glyphName = ManualTimerRules.symbolName(for: reading.state) else {
            return StatusItemTitle(
                text: appLabel,
                iconName: nil,
                glyphName: nil,
                duration: nil,
                spoken: spoken([appLabel], badgeDescription: badgeDescription)
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
            spoken: spoken(
                // The name first, then what the glyph means, then the figure, then whose menu bar item this is.
                // Reading order, so the answer comes before the qualifications.
                [category.name, reading.state == .running ? "running" : "paused", duration, appLabel],
                badgeDescription: badgeDescription
            )
        )
    }

    private static func spoken(_ parts: [String], badgeDescription: String?) -> String {
        (parts + [badgeDescription].compactMap { $0 }).joined(separator: ", ")
    }
}
