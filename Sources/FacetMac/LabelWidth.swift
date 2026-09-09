import AppKit
import FacetCore

/// Stops a label widening the window it is drawn in.
///
/// **A label asks for its whole string on one line, whatever it has been told about drawing.** `lineBreakMode`,
/// `maximumNumberOfLines` and a shrink-to-fit routine all decide how the text is *drawn*; the intrinsic width is
/// still the unwrapped string, and a label holds out for it at `.defaultHigh`, so the window is made wide enough
/// to suit. Measured on the running app: a 56-character category name asked for 1436pt at the Faces tab's 56pt
/// name font, and the Settings window drew itself 1295pt wide.
///
/// **Apply it to every label carrying text somebody typed.** A category name has no maximum length, so a label
/// showing one can demand any width at all; a label drawing a fixed string is safe only for as long as that string
/// stays short, which is why the App tab's two footnotes were the first place this showed.
///
/// The priority is the whole fix. It lets the label be squeezed to the width it is given, which is what makes tail
/// truncation and `TimingView`'s shrink-to-fit do anything: until the label can be squeezed, it is never given less
/// room than it asked for, so neither has anything to do. Nothing is lost where the label's width is already pinned
/// to its container.
@MainActor
enum LabelWidth {
    /// Lets `label` be squeezed below the width of its text.
    ///
    /// The caller must give the label a width from somewhere else -- pinned to a container, or bounded by the
    /// controls beside it -- and decide how the text handles being short of room. A squeezable label with no width
    /// of its own is drawn at nothing.
    static func mayGiveWay(_ label: NSTextField) {
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// How a label behaves when its text is longer than the room it has.
    ///
    /// **Four things have to be set together and only one place ever set all four**, which is why this exists.
    /// `TimingView` had the whole recipe and everywhere else had part of it, so a label told
    /// `maximumNumberOfLines = 2` and left on `.byTruncatingTail` drew one line and looked like the setting had no
    /// effect. Measured, and recorded at that call site: an `NSTextFieldCell` holding a 56-character name at 40pt
    /// in a 380pt column answers 47pt, one line, for truncating tail **whatever `maximumNumberOfLines` says**, and
    /// 94pt for word wrapping.
    ///
    /// The four: the break mode has to be `.byWordWrapping` or nothing wraps; `maximumNumberOfLines` says how far;
    /// `truncatesLastVisibleLine` puts the ellipsis on the last line the limit allows rather than stopping
    /// mid-sentence; and `mayGiveWay` is what lets the label be short of room at all, without which it demands its
    /// whole string on one line and widens the window instead of wrapping.
    enum Wrapping {
        /// One line, ellipsis at the end. For a row whose height is pinned and whose text is short by nature.
        case singleLine
        /// One line, ellipsis in the middle. For a path, where both ends carry more than the middle does.
        case singleLinePath
        /// Wraps as far as `lines`, with an ellipsis on the last. Two is the useful answer in a row that can grow
        /// a little; `0` is as far as it needs.
        case wraps(lines: Int)
    }

    /// Applies the whole recipe, so a caller cannot get three of the four right.
    static func set(_ wrapping: Wrapping, on label: NSTextField) {
        switch wrapping {
        case .singleLine:
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        case .singleLinePath:
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
        case let .wraps(lines):
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = lines
            label.cell?.truncatesLastVisibleLine = true
        }
        // Every case, including the single-line ones: tail truncation has nothing to do either until the label can
        // be given less room than it asked for.
        mayGiveWay(label)
    }
}
