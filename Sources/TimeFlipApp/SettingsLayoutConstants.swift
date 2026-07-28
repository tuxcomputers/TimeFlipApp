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
        // The assigned category's name under the device. Sized to fill the space the squared-off
        // device leaves at the bottom of the column rather than to any system text style.
        static let nameFontSize: CGFloat = 56
        // Long names shrink rather than wrap or clip -- the column is only two thirds of the
        // window, and a category name has no length limit.
        static let nameMinimumScale: CGFloat = 0.4
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
