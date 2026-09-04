import AppKit

/// What the status item spells out: the pieces, in the order they are drawn, decided apart from the drawing.
///
/// Separate from `MenuBarController` for the reason `Archive/TimeFlipApp/MenuBarStatusStyle` was separate from the
/// previous app's: what the item says can then be asserted without a status item, a menu bar, or a rendered line of
/// text. It is `Equatable` for a second reason as well -- it is what tells a redraw that nothing has changed.
///
/// **The order is the previous app's**, and the reason for it survives: the category's icon rides *inside* the title
/// rather than as the button's own image, which would draw it to the left of everything and outside the run of text
/// the rest of the line is.
struct StatusItemTitle: Equatable {
    /// The words: the category being timed, or the app's own name when nothing is.
    let text: String

    /// The category's artwork, drawn ahead of the words. `nil` for a category with no icon, and while nothing is
    /// being timed.
    let iconName: String?

    /// The play/pause glyph between the name and the figure, from `ManualTimerRules`, so the menu bar and the
    /// Faces tab cannot come to draw a pause differently. `nil` while nothing is being timed.
    let glyphName: String?

    /// The lock badge, drawn in red before the play/pause glyph while the cube is locked. `nil` otherwise.
    ///
    /// **Beside the glyph rather than in place of it**, which is the archive's rule and its reasoning: whether the
    /// cube is still timing or stopped stays worth seeing while it is locked, and one badge replacing the other would
    /// answer a different question from the one it looks like it is answering.
    ///
    /// **Red, and it keeps its own colour** -- not the line's, unlike the icon and the glyph. Those take the colour
    /// of the text beside them because they say the same thing it does; this says something the rest of the line
    /// cannot, which is that the cube will not change face until somebody unlocks it.
    ///
    /// **Drawn whether or not anything is being timed**, for the reason the flat-battery flash is: it is a fact about
    /// the device rather than about the session, and a locked cube with nothing running is exactly the state somebody
    /// needs to be told about -- it is why nothing is running.
    let lockGlyphName: String?

    /// The figure, already formatted. `nil` while nothing is being timed: a "0:00" with nothing behind it reads as
    /// a session that has started and got nowhere.
    let duration: String?

    /// What the line's own text is drawn in: the figure, and the spaces between the pieces. The database badge keeps
    /// its own colour, it being a tag naming which file this launch writes to rather than part of the sentence; the
    /// name and its icon take `nameColour`, and the play/pause glyph takes `glyphColour`.
    ///
    /// **Green while a cube is doing the timing, cyan while this app is.** Green is the previous app's
    /// (`Archive/TimeFlipApp/MenuBarStatusStyle`, `overLimit ? .systemRed : .systemGreen`) and it said one thing
    /// there: this reading is live. It is still what green says here. What is new is a second kind of live reading
    /// the archive never had, one this app takes itself with no cube on the other end, and cyan is that -- so the
    /// pair of them answer between them which of the app's two pictures is on show.
    ///
    /// **Yellow once the cube cannot be heard**, which is the archive's third answer, copied with its reasoning. A
    /// paired cube that has dropped goes on showing its last face out of `device_event` and the figure is still
    /// worth drawing, but nothing about it can be confirmed any more. It takes the whole line rather than sharing
    /// it: "a flat unknown yellow -- not a stale over-limit/low-battery color left over from before the drop", so a
    /// spent limit does not draw its red over the top of a figure nobody can stand behind.
    ///
    /// **Red once the category has spent its `daily_limit`**, which is the archive's colour and the archive's
    /// meaning: the limit stops the clock, so the figure and the pause are two faces of one fact. It lands on the
    /// figure alone, the name keeping the session's own colour -- see `nameColour`.
    ///
    /// A dynamic colour, resolved as it draws: the menu bar tints from the wallpaper rather than from the
    /// appearance setting, so anything resolved earlier than the draw is one of the two answers frozen (see
    /// `MenuBarController.attachment(of:colour:size:font:)`).
    let colour: NSColor

    /// What the category's name and its icon are drawn in, which is `colour` except while the cube is flat and
    /// except while a limit is spent.
    ///
    /// **Only this much of the line flashes, which is the archive's choice and worth keeping**
    /// (`Archive/TimeFlipApp/MenuBarStatusStyle`): the figure beside it is a clock somebody reads, and a duration
    /// changing colour twice a second is harder to read at the exact moment the app is asking for attention.
    ///
    /// **The off phase is `.labelColor`, where the archive used `.white`.** That is the one thing not copied, and it
    /// is a correction rather than a preference: the menu bar tints from the wallpaper rather than from the appearance
    /// setting (see `MenuBarController.attachment(of:colour:size:font:)`), so white against a light strip is a name
    /// that disappears for half of every second instead of one that flashes.
    ///
    /// **A spent limit leaves this alone**, where the archive turned its whole line red. The two say different
    /// things and only one of them has changed: the name is which category is on show, and reaching a limit does not
    /// make it a different category, while the figure is the thing that has hit the number. Red on the figure alone
    /// also leaves the flash something to alternate against, which a wholly red line does not.
    ///
    /// **A cube that cannot be heard takes this too, flash and all**, which is the archive's rule rather than an
    /// oversight: yellow is the statement that nothing here can be confirmed, and a name still alternating about a
    /// charge last read before the link went is the stale colour that rule exists to rule out. `LowBatteryWatch`
    /// stops the flash itself when the link goes ("the flash stops with the link, the warning does not"), so this
    /// is that decision drawn rather than a second one: without it a latched warning would leave the name in a
    /// steady `.labelColor` off phase, against a yellow figure, flashing at nobody. The warning is still *said*.
    let nameColour: NSColor

    /// What the play/pause glyph is drawn in, which is the one piece of the line that is neither the name nor the
    /// figure -- and which says something about neither: it reports whether a clock is going.
    ///
    /// **The menu bar's own text colour, which is what the archive drew it in.** Its indicator was a template image
    /// handed to AppKit untinted (`Archive/TimeFlipApp/MenuBarController.statusIndicatorImage`), so it came out in
    /// whatever the strip draws text in -- white on a dark menu bar, black on a light one -- rather than in the
    /// line's green. Naming `.labelColor` here is that behaviour spelled out rather than inherited, since this app
    /// tints its own attachments and would otherwise have to pick something.
    ///
    /// **Not literal white**, for the reason the flash's off phase is not: the menu bar tints from the wallpaper
    /// rather than from the appearance setting, so a white glyph on a light strip is not a pale glyph, it is no
    /// glyph at all.
    ///
    /// **The one colour on the line that is the same in every state**, which is the point of it rather than a
    /// simplification: cyan, green and yellow are each a claim about the reading, and whether a clock is going is
    /// not a claim about the reading. A glyph that changed with them would be saying something it does not know.
    let glyphColour: NSColor

    /// What VoiceOver reads. Spelled out, because a glyph says nothing to a screen reader and neither does the
    /// badge's colour -- and the item's own title would otherwise read as "0:07", which is not a description of
    /// anything.
    let spoken: String

    /// - Parameters:
    ///   - appLabel: the app's own name, which is the whole title while nothing is being timed.
    ///     is drawn separately, carrying its own colour and weight.
    ///   - reading: the session, read at the moment this is being composed.
    ///   - showingSeconds: whether the figure carries seconds, from `display_seconds`.
    /// - Parameter lowBattery: the warning and which half of its flash is up, asked for as the item is drawn.
    static func make(
        appLabel: String,
        reading: TimingReadout.Reading,
        showingSeconds: Bool,
        isLimitReached: Bool = false,
        lowBattery: LowBatteryAlert = .none,
        cubeLockState: CubeLockState = .unknown
    ) -> StatusItemTitle {
        // The flash, and what it flashes against. Red on one phase and the ordinary text colour on the other, so the
        // name alternates rather than vanishing -- and `nil` when there is nothing to warn about, which leaves the
        // name drawn in whatever the line's own colour turns out to be.
        let flash: NSColor? = lowBattery.isBatteryLow ? (lowBattery.isBlinkOn ? .systemRed : .labelColor) : nil
        let lockGlyphName = cubeLockState == .locked ? "lock.fill" : nil
        // **Following a cube: the face's category and what it has recorded today.**
        //
        // The figure is the archive's, copied: its menu bar drew the same day total in device mode, out of the same
        // per-category durations. So is the glyph, and out of the same answer -- `MenuBarStatusStyle.showsPauseIcon`
        // took the *device's* paused state, not the app's, which is the distinction that makes a glyph mean anything
        // here: the app is running no clock while it follows a cube, but the cube certainly is.
        //
        // **No glyph until the cube has answered.** `nil` is a cube that has not been asked yet or would not say, and
        // guessing "running" would be the app making a claim about hardware on no evidence -- the one thing
        // `CLAUDE.md`'s read-back rule exists to stop.
        if reading.cubeFace != nil, let category = reading.category {
            // Formatted once and used twice, drawn and spoken, so the two cannot come to read differently.
            let onTheFace = DurationFormat.hoursMinutesSeconds(
                reading.seconds,
                // Truncated like the session's, for the same reason: a figure shown must never be ahead of the time
                // actually recorded.
                rounding: .truncate,
                showingSeconds: showingSeconds
            )
            // **The spoken line is assembled a piece at a time rather than as one `+` chain of arrays**, and that is a
            // compiler constraint rather than a style. Six array terms with an optional map and three ternaries in
            // them, all inside a call argument, is more than Swift's type checker will do in reasonable time: this
            // compiled here and failed the CI build outright on 2026-08-22 ("unable to type-check this expression in
            // reasonable time"). A local build passing is not evidence about this, since the limit is a time budget
            // and a slower machine has less of it. Appending in order also puts the reading order in the code.
            var spokenParts: [String] = [category.name]
            switch reading.cubePauseState {
            case .paused: spokenParts.append("device paused")
            case .running: spokenParts.append("device running")
            case .unknown: break
            }
            // **Said where it is drawn, which is right after what it qualifies.** The yellow below is the whole of
            // this on screen, and what it says is that the paused-or-running just spoken is the cube's last word
            // rather than its current one.
            if !reading.isCubeConnected { spokenParts.append("device unreachable") }
            spokenParts.append(onTheFace)
            if cubeLockState == .locked { spokenParts.append("device locked") }
            // **Said even where the yellow has taken the red off the figure.** The limit is a fact about
            // `time_entry` and this machine's clock, so it does not stop being true when a cube goes out of range;
            // what the yellow withdraws is the claim that the *cube's* reading is current, and that is said in its
            // own words just above.
            if isLimitReached { spokenParts.append("daily limit reached") }
            if lowBattery.isBatteryLow { spokenParts.append("low battery") }
            spokenParts.append(appLabel)
            // **Green while the cube can be heard, yellow once it cannot**, and the second one takes the name as
            // well as the figure. See `colour` and `nameColour`: a reading nobody can confirm is not the place for
            // a limit's red or a battery's flash, both of which would be colours left over from before the drop.
            //
            // Worked out here rather than in the call below because the two of them are one decision made twice,
            // and because a `guard`-shaped ternary inside a call argument is what the note on the spoken parts
            // above is about: this file has already failed CI once for asking Swift to type-check too much at once.
            let lineColour: NSColor
            let cubeNameColour: NSColor
            if reading.isCubeConnected {
                lineColour = isLimitReached ? .systemRed : .systemGreen
                cubeNameColour = flash ?? .systemGreen
            } else {
                lineColour = .systemYellow
                cubeNameColour = .systemYellow
            }
            let cubeGlyphName: String? = switch reading.cubePauseState {
            case .paused: "pause.fill"
            case .running: "play.fill"
            case .unknown: nil
            }
            return StatusItemTitle(
                text: category.name,
                iconName: category.iconName,
                glyphName: cubeGlyphName,
                lockGlyphName: lockGlyphName,
                duration: onTheFace,
                // Not the by-hand cyan: that colour is a claim that this app is doing the timing, and here it is
                // the cube doing it.
                colour: lineColour,
                nameColour: cubeNameColour,
                // The menu bar's own text colour, exactly as in a session this app is timing. What the glyph
                // reports -- whether a clock is going -- is the one thing on this line that means the same in both
                // pictures, so it is the one thing that does not change colour between them.
                glyphColour: .labelColor,
                // The figure is said as well as drawn, for the reason the limit and the lock are: what is on the line
                // has to reach somebody reading it aloud, and a duration is the one part of it that is never a colour.
                spoken: spoken(spokenParts)
            )
        }
        // Idle keeps the app's name and nothing else, which is what the item has always shown before a session
        // starts. `guard` on both, though the readout only ever pairs them: a category with no state to draw, or a
        // state with no category to name, is half a session either way.
        guard let category = reading.category, let glyphName = ManualTimerRules.symbolName(for: reading.timingState) else {
            // Built up rather than chained, for the reason given at the first of these.
            var idleParts: [String] = [appLabel]
            if cubeLockState == .locked { idleParts.append("device locked") }
            if lowBattery.isBatteryLow { idleParts.append("low battery") }
            return StatusItemTitle(
                text: appLabel,
                iconName: nil,
                glyphName: nil,
                lockGlyphName: lockGlyphName,
                duration: nil,
                // The ordinary text colour, as the previous app's own no-device placeholder drew it: a session
                // colour is a claim about a reading, and there is no reading here to make it about.
                colour: .labelColor,
                // **The warning still flashes with nothing being timed**, on the app's own name. A flat cube is a
                // fact about the device rather than about the session, and the moment somebody is most likely to
                // miss it is the moment nothing is running.
                nameColour: flash ?? .labelColor,
                // Nothing is drawn in it, `glyphName` being `nil` here, and it is still answered rather than
                // defaulted: a field with no answer is a field somebody later picks one for by accident.
                glyphColour: .labelColor,
                spoken: spoken(idleParts)
            )
        }
        let duration = DurationFormat.hoursMinutesSeconds(
            reading.seconds,
            // A live figure, so truncated rather than rounded: what is shown must never be ahead of the time
            // actually recorded.
            rounding: .truncate,
            showingSeconds: showingSeconds
        )
        // The name first, then what the glyph means, then the figure, then whose menu bar item this is. Reading order,
        // so the answer comes before the qualifications -- and built up rather than chained, for the reason given at
        // the first of these.
        //
        // **The limit is said, not just coloured.** A colour is the whole of the signal on screen, so without this the
        // one state the item exists to warn about would be the one state it did not mention to anybody reading it
        // aloud.
        // **The warning is said, not just flashed**, for the same reason the limit is: a colour is the whole of the
        // signal on screen, so without this the one state worth interrupting somebody for would be invisible to
        // anybody reading the item aloud.
        // **The lock is said, not just drawn**, for the same reason the limit and the warning are: a badge is the
        // whole of the signal on screen, so without this the state that explains why a cube is not changing face
        // would be invisible to anybody reading the item aloud.
        var sessionParts: [String] = [category.name, reading.timingState == .running ? "running" : "paused", duration]
        if cubeLockState == .locked { sessionParts.append("device locked") }
        if isLimitReached { sessionParts.append("daily limit reached") }
        if lowBattery.isBatteryLow { sessionParts.append("low battery") }
        sessionParts.append(appLabel)
        return StatusItemTitle(
            text: category.name,
            iconName: category.iconName,
            glyphName: glyphName,
            lockGlyphName: lockGlyphName,
            duration: duration,
            // **Red once the category has spent its `daily_limit`**, which is the archive's colour and its meaning:
            // `MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen` on the same line. The session colour
            // is a claim that time is being recorded normally, and once a limit has stopped the clock that claim is
            // no longer true -- so the colour and the pause are two faces of one fact, drawn from the same answer
            // (`DailyLimitEnforcement.isLimitReached`) rather than from two comparisons that could disagree by a second.
            //
            // **On the figure and not on the whole line**, which is where this parts from the archive: the figure is
            // what has reached the number, and the name is only which category it belongs to.
            colour: isLimitReached ? .systemRed : Self.byHand,
            nameColour: flash ?? Self.byHand,
            glyphColour: .labelColor,
            spoken: spoken(sessionParts)
        )
    }

    /// What the three colours are called, for the one place they can be read back from: `debug_log`.
    ///
    /// **The accessibility tree carries no colour at all**, so a scripted check driving the real app has no way to
    /// see any of this. `12-daily-limit` says as much where it checks the spoken label instead of the red. So the app
    /// writes down what it drew, and the row is the evidence -- which is this suite's first principle rather than a
    /// convenience: a person watching the menu bar and saying it looked yellow is not evidence.
    ///
    /// **Named here rather than at the log**, because this is where the colours are decided. A second place turning
    /// an `NSColor` into a word is a second answer to what the line is, and it would be the one the tests read.
    var colourDescription: String {
        "name \(Self.name(of: nameColour)), glyph \(Self.name(of: glyphColour)), figure \(Self.name(of: colour))"
    }

    /// One colour as a word. Every colour this type can choose has one, and anything else says so rather than
    /// picking the nearest: a line described as green because the naming ran out is worse than one described as
    /// unnamed, since only the second sends somebody to look.
    private static func name(of colour: NSColor) -> String {
        switch colour {
        case .systemCyan: return "cyan"
        case .systemGreen: return "green"
        case .systemYellow: return "yellow"
        case .systemRed: return "red"
        case .labelColor: return "label"
        default: return "unnamed"
        }
    }

    /// What a session this app is measuring itself is drawn in.
    ///
    /// **`.systemCyan` rather than the `Cyan` in `database/005_colour.sql`**, which is `#00ffff` and belongs to a
    /// different question: that table holds what a category can be given and what a cube can be told to light its
    /// face, both of which are fixed hexes because a cube has no idea what appearance a Mac is in. This is a colour
    /// for text on a strip that tints from the wallpaper, so it has to be a dynamic one -- see `colour` for why
    /// anything resolved before the draw is a frozen answer.
    private static let byHand: NSColor = .systemCyan

    private static func spoken(_ parts: [String]) -> String {
        parts.joined(separator: ", ")
    }
}
