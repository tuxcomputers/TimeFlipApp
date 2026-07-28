import CoreGraphics

enum SettingsLayoutConstants {
    static let minimumWindowWidth: CGFloat = 560
    static let defaultWindowWidth: CGFloat = 640

    // The Device tab (Info + Settings + TimeFlip sections, every disclosure group collapsed,
    // paired -- its shortest state) measured at ~660pt: at the previous 520pt default, the
    // TimeFlip/pairing section was clipped below the fold, needing a scroll to reach it.
    static let deviceTabMinimumContentHeight: CGFloat = 660
    static let defaultWindowHeight: CGFloat = deviceTabMinimumContentHeight + 20

    static let facetRowHeight: CGFloat = 36
    static let facetDividerHeight: CGFloat = 1
    static let paneVerticalPadding: CGFloat = Pane.verticalPadding
    static let columnHeaderHeight: CGFloat = 22
    static let columnHeaderSpacing: CGFloat = 12

    enum Pane {
        static let columnSpacing: CGFloat = 24
        static let horizontalPadding: CGFloat = 20
        static let verticalPadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 12
        static let emptyStateVerticalPadding: CGFloat = 8
        static let leftColumnRatio: CGFloat = 2.0 / 3.0
        static let rightColumnRatio: CGFloat = 1.0 / 3.0
    }

    enum IconGrid {
        static let minIconSize: CGFloat = 40
        static let maxIconSize: CGFloat = 48
        static let columnSpacing: CGFloat = 10
        static let gridVerticalPadding: CGFloat = 4
        static let cellSize: CGFloat = 40
        static let cellCornerRadius: CGFloat = 6
        static let cellPadding: CGFloat = 8
        static let selectionStrokeWidth: CGFloat = 2
        static let unselectedStrokeWidth: CGFloat = 1
        static let unselectedStrokeOpacity: CGFloat = 0.2
        static let iconPointSize: CGFloat = 24
    }

    enum ColorPicker {
        static let swatchStrokeOpacity: CGFloat = 0.2
        static let rowSwatchSize: CGFloat = 14
        static let rowSwatchCornerRadius: CGFloat = 3
        static let rowSpacing: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 4
        static let rowHorizontalPadding: CGFloat = 8
        static let listPadding: CGFloat = 6
    }

    enum DeviceFace {
        // The drawn device's centre face is a regular pentagon centred on the artwork, so an icon
        // placed at the middle of the frame lands on it. The largest centred square that fits
        // inside that pentagon is ~0.297 of the artwork's width -- the limit comes from the two
        // upper edges meeting at the point, not the flat bottom one -- so this stays just inside.
        static let centreIconScale: CGFloat = 0.29
        // The size the device artwork is rendered at, independent of how large it is drawn. The
        // artwork is a vector and re-renders at draw size, so this only has to be generous enough
        // that nothing downstream is ever upscaling a too-small raster.
        static let renderPointSize: CGFloat = 512
        // The lock control in the corner of the device graphic.
        static let lockSize: CGFloat = 40
        // The assigned category's name under the device. Sized to fill the space the squared-off
        // device leaves at the bottom of the column rather than to any system text style.
        static let nameFontSize: CGFloat = 56
        // Long names shrink rather than wrap or clip -- the column is only two thirds of the
        // window, and a category name has no length limit.
        static let nameMinimumScale: CGFloat = 0.4
    }

    /// `SteppedNumberField`'s own geometry. Here rather than as statics on that view because a view's
    /// statics are main-actor isolated, and the layout arithmetic below is nonisolated -- and because
    /// a caller working backwards from where it wants the arrows needs these numbers as much as the
    /// control does.
    enum Stepper {
        /// The stacked arrow pair's width, and the gaps between the field, the suffix and the arrows.
        static let arrowsWidth: CGFloat = 16
        static let itemSpacing: CGFloat = 4
        /// Each chevron's height; two of them plus `arrowSpacing` make the pair.
        static let arrowHeight: CGFloat = 10
        static let arrowSpacing: CGFloat = 1
        static let arrowPointSize: CGFloat = 8
    }

    enum AppSettings {
        // The App tab's value column. LabeledContent right-aligns whatever it is handed, which is all
        // the alignment these rows need now that every control comes out the same total width: a
        // shared right edge plus a shared width is a shared left edge, so the fields, suffixes and
        // arrows all line up in both directions with nothing pinning them into a fixed-width column.
        //
        // The daily-reset row sets the rhythm every other row matches: an hour field with arrows, a
        // gap, then AM/PM with its own arrows. Its total width is what the rows below stretch their
        // fields to reach, so all the arrows end up on one x.
        static let hourFieldWidth: CGFloat = 34
        static let meridiemLabelWidth: CGFloat = 30
        static let meridiemGap: CGFloat = 16
        // Fixed slots for the suffixes. Held here rather than left to size themselves, because the
        // field widths below are worked out from them -- a suffix that sized to its own text would
        // move the arrows after it by however wide that text rendered.
        static let percentSuffixWidth: CGFloat = 16
        static let minutesSuffixWidth: CGFloat = 34

        /// Where every row's arrows finish, measured from the column's left edge.
        static var stepperRowWidth: CGFloat {
            hourFieldWidth + Stepper.itemSpacing + Stepper.arrowsWidth
                + meridiemGap
                + meridiemLabelWidth + Stepper.itemSpacing + Stepper.arrowsWidth
        }

        /// The field width that leaves `suffixWidth` of suffix and a set of arrows finishing exactly at
        /// `stepperRowWidth`, so a row with a suffix still lines its arrows up with the AM/PM ones.
        static func fieldWidth(suffixWidth: CGFloat) -> CGFloat {
            stepperRowWidth
                - Stepper.arrowsWidth
                - Stepper.itemSpacing * 2
                - suffixWidth
        }
    }

    enum FacetList {
        static let rowSpacing: CGFloat = 12
        static let iconSize: CGFloat = 20
        static let horizontalPadding: CGFloat = 8
        static let selectionOpacity: CGFloat = 0.12
        static let cornerRadius: CGFloat = 8
        // The category-colour swatch behind a row's icon. Sized to clear the 20pt icon while still
        // fitting the 36pt row, rather than reusing the icon grid's 40pt cell, which would overflow
        // it.
        static let iconBackgroundSize: CGFloat = 28
        static let iconBackgroundCornerRadius: CGFloat = 6
    }

    enum CategoryList {
        // Fixed so every row's colour square lines up at the same x position regardless of how
        // long that row's category name is -- a plain Text(name) with no width sizes to its own
        // content, so the square right after it would otherwise drift per row.
        static let nameColumnWidth: CGFloat = 160
        // Matches the Device tab's disclosure groups, so the Active/Inactive groups sit at the
        // same rhythm as the LED/More ones they're modelled on.
        static let rowSpacing: CGFloat = 8
        static let sectionVerticalPadding: CGFloat = 4
        // Wide enough for the "Colour" caption above it, so the daily-limit column that follows
        // starts at the same x in both the header row and the category rows.
        static let colourColumnWidth: CGFloat = 46
        // Sized to the "Daily limit (0 = disabled)" caption rather than to the field itself: the
        // caption is the widest thing in the column, and the Active column after it has to start
        // clear of it in both rows.
        static let limitColumnWidth: CGFloat = 140
        static let limitFieldWidth: CGFloat = 50
        static let limitFieldSpacing: CGFloat = 4
        // 6 wide lays the 42 seeded icons out as an even 6x7 with no partial last row and no
        // scrolling -- see database/004_icon.sql.
        static let iconGridColumns = 6
        static let createFieldSpacing: CGFloat = 8
    }

    /// The Facets tab's own content height, floored at `deviceTabMinimumContentHeight` so the
    /// window's minimum never shrinks below what the Device tab (the default-opened tab) needs,
    /// even when there are few enough facets that the Facets tab alone would ask for less.
    static func fallbackMinimumContentHeight(facetCount: Int) -> CGFloat {
        let rows = CGFloat(facetCount) * facetRowHeight
        let dividers = CGFloat(max(0, facetCount - 1)) * facetDividerHeight
        let facetsHeight = paneVerticalPadding + columnHeaderHeight + columnHeaderSpacing + rows + dividers + paneVerticalPadding
        return max(facetsHeight, deviceTabMinimumContentHeight)
    }
}
