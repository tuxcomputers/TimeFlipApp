/// One of the five colours the menu bar's title is drawn in, named rather than valued.
///
/// **A name, because a name is what the decision actually is.** `StatusItemTitle` picks between five meanings:
/// this is the app's own clock, this is a cube, this cube is out of reach, this budget is spent, this is ordinary
/// text. Which pixels those are is the platform's answer to the question, not the question, and on a Mac it is not
/// even a fixed answer: `labelColor` and the four system colours resolve against the appearance as they draw, so a
/// value captured here would be the wrong one the moment somebody switched to dark.
///
/// **It replaces an `NSColor` that was mapped straight back to a word.** `StatusItemTitle` used to hold three
/// `NSColor` fields and carry a `name(of:)` that turned each of them into "cyan", "green", "red" and so on, because
/// the word is what `debug_log` records and what the scripted checks read: the accessibility tree carries no colour
/// at all, so a row saying what was drawn is the only evidence there is. So the word was the answer all along and
/// the `NSColor` was a detour, which is why moving this into the core deletes code rather than relocating it.
///
/// The Mac's mapping is `StatusColour+AppKit.swift` in `FacetMac`, beside `ColourDrawing`, which does the same job
/// for the category colours.
package enum StatusColour: String, Equatable, CaseIterable {
    /// A session this app is timing itself.
    ///
    /// **Cyan, and deliberately not the `Cyan` in `database/005_colour.sql`.** That one is `#00ffff` and answers a
    /// different question: what a category may be given and what a cube may be told to light its face, both fixed
    /// hexes because a cube has no idea what appearance a Mac is in. This is a colour a menu bar is drawn in.
    case byHand = "cyan"
    /// A cube being followed, with budget in hand.
    case cube = "green"
    /// A cube this launch has stopped being able to reach.
    case unreachable = "yellow"
    /// A spent daily limit, and the low-battery flash.
    case spent = "red"
    /// Ordinary text, whatever that is in the appearance the Mac is in.
    case ordinary = "label"

    /// The word `debug_log` records and the scripted checks read.
    ///
    /// **Every colour has one, which is the point of an enum here.** The `NSColor` version ended in a `default`
    /// returning "unnamed", because a colour is an open set and a switch over it can always fall through. Five
    /// cases cannot, so the row can no longer say a thing the tests would have to allow for.
    package var name: String { rawValue }
}
