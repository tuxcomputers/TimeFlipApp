import CoreGraphics

/// **What a Settings tab looks like, in one place.** Every tab that draws a panel of rows measures itself from
/// here, so the three of them are one look drawn three times rather than three looks that happen to resemble each
/// other.
///
/// **The Categories tab is where these numbers come from**, because it is the one that was right: a list of rows
/// held apart by whitespace, on a panel that spans the tab, with nothing drawn between them. The App and Device
/// tabs were each measured against it by eye and each landed somewhere else -- App at a 46pt pitch and Device at
/// 24pt with no gap at all, both with hairlines the Categories tab never had. Numbers copied by eye drift, which
/// is what this exists to stop.
///
/// **`rowHeight` is the point of reference.** It is the number to change when the tabs should be roomier or
/// tighter, and changing it moves all three at once -- which is the whole reason it is a single value rather than
/// three that agree today.
///
/// Not a `PanelSection.Metrics`, which is a different question: that one is how a *panel* insets the thing inside
/// it, and this is what the rows on it are. `PanelSection.Metrics` reads its defaults from here.
enum SettingsMetrics {
    /// **The height of one row, and the point of reference for the look of every tab.**
    ///
    /// A floor rather than an exact height: a row holding something taller -- a `SteppedNumberField` is exactly 24,
    /// a button more -- is as tall as its contents. What this decides is the rhythm a list of plain rows reads at,
    /// which is what the eye follows down a tab.
    static let rowHeight: CGFloat = 24

    /// Between one row and the next. **Whitespace, and never a line**: the Categories tab has never drawn a
    /// separator and reads as a list regardless, so the hairlines the other two tabs drew were dividing rows that
    /// the gap had already divided.
    static let rowSpacing: CGFloat = 8

    /// Inside a panel, around the heading and the rows on it. What holds the content off the panel's own edge.
    static let panelPadding: CGFloat = 8

    /// The panel's corners.
    static let cornerRadius: CGFloat = 8

    /// Between the columns of a row that has several.
    static let columnSpacing: CGFloat = 12

    /// Between a heading and what sits under it.
    static let headingSpacing: CGFloat = 12

    /// Between one section's panel and the next section's heading. **The Categories tab's 16, not the 24 the other
    /// two had**: it still reads wider than `headingSpacing`, which is the reason that number was chosen for -- a
    /// heading belonging to the panel under it rather than to the one it follows -- and being the standard means
    /// being the standard even where the other two had settled somewhere defensible.
    static let sectionSpacing: CGFloat = 16

    /// Around the whole tab, between its content and the window. The one number all three tabs already agreed on,
    /// named here so they cannot stop agreeing.
    static let tabPadding: CGFloat = 20

    /// How far a fold's contents are indented past the heading that opens them, so a nested list reads as belonging
    /// to the row above it.
    static let nestedIndent: CGFloat = 16
}
