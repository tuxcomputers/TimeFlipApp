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
        static let swatchButtonSize: CGFloat = 20
        static let swatchStrokeWidth: CGFloat = 1
        static let swatchStrokeOpacity: CGFloat = 0.2
        static let rowSwatchSize: CGFloat = 14
        static let rowSwatchCornerRadius: CGFloat = 3
        static let rowSpacing: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 4
        static let rowHorizontalPadding: CGFloat = 8
        static let listPadding: CGFloat = 6
    }

    enum FacetList {
        static let rowSpacing: CGFloat = 12
        static let iconSize: CGFloat = 20
        static let horizontalPadding: CGFloat = 8
        static let selectionOpacity: CGFloat = 0.12
        static let cornerRadius: CGFloat = 8
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
