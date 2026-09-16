import Foundation

/// The SF Symbol names the core answers in, as characters a font on this desktop has.
///
/// **Rendering, and every decision behind it was made elsewhere.** `ManualTimerRules.symbolName`,
/// `CubePauseState.symbolName` and `StatusItemTitle.lockGlyphName` all answer in Apple's symbol names, which mean
/// nothing to GTK. What is decided here is only what to draw instead -- which is exactly the kind of thing a
/// platform adapter is for.
///
/// **In one place because two surfaces draw them.** The menu bar had this privately until the Faces tab needed the
/// same three; a second copy is how a play glyph comes to be an arrow in the bar and a triangle on the tab.
///
/// **Anything unrecognised draws nothing rather than its own name**, which is the same judgement the trace makes
/// the other way: a log row falls back to a bare UUID because a reader can look one up, and a control cannot show
/// `play.fill` to somebody without it reading as a fault.
enum SymbolGlyph {
    static func character(for symbolName: String?) -> String? {
        switch symbolName {
        case "play.fill": return "\u{25B6}"
        case "pause.fill": return "\u{23F8}"
        case "lock.fill": return "\u{1F512}"
        case "lock.open.fill": return "\u{1F513}"
        default: return nil
        }
    }

    /// The padlock the menu bar's line carries, which `StatusItemTitle` answers for by name.
    static let locked = "lock.fill"
    /// Its open twin, which only the Faces tab draws: a face that can still be reassigned.
    static let unlocked = "lock.open.fill"
}
