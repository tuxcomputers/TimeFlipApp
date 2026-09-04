import AppKit

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
}
