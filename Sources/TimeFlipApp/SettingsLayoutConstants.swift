import CoreGraphics

enum SettingsLayoutConstants {
    static let minimumWindowWidth: CGFloat = 560
    static let defaultWindowWidth: CGFloat = 640

    // The Device tab (Info + Settings + TimeFlip sections, every disclosure group collapsed,
    // paired -- its shortest state) measured at ~660pt: at the previous 520pt default, the
    // TimeFlip/pairing section was clipped below the fold, needing a scroll to reach it.
    static let deviceTabMinimumContentHeight: CGFloat = 660
    static let defaultWindowHeight: CGFloat = deviceTabMinimumContentHeight + 20

    static let faceRowHeight: CGFloat = 36
    static let faceDividerHeight: CGFloat = 1
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

    /// Every stepper row in the Settings window: `SteppedNumberField`'s own geometry, and the
    /// arithmetic that makes rows of different content come out the same width.
    ///
    /// The geometry lives here rather than as statics on that view because a view's statics are
    /// main-actor isolated while this arithmetic is nonisolated, and because a caller working
    /// backwards from where it wants the arrows needs those numbers as much as the control does.
    ///
    /// `LabeledContent` right-aligns whatever it is handed, which is all the alignment these rows
    /// need once every control comes out the same total width: a shared right edge plus a shared
    /// width is a shared left edge, so the fields, suffixes and arrows line up in both directions
    /// with nothing pinning them into a fixed-width column.
    enum Stepper {
        /// The stacked arrow pair's width, and the gaps between the field, the suffix and the arrows.
        static let arrowsWidth: CGFloat = 16
        static let itemSpacing: CGFloat = 4
        /// Each chevron's height; two of them plus `arrowSpacing` make the pair.
        static let arrowHeight: CGFloat = 10
        static let arrowSpacing: CGFloat = 1
        static let arrowPointSize: CGFloat = 8

        /// Every typeable value field in the window is this wide, on both tabs: the daily-reset
        /// hour, the battery warning, the fetch interval, LED brightness and the blink interval.
        /// One width for all of them, so the boxes read as a column rather than as five sizes.
        ///
        /// Wider than the digits need, deliberately. It takes the space the daily-reset row's AM/PM
        /// label and its second pair of arrows used to occupy, which keeps `rowWidth` where it was
        /// so nothing else in the window moves.
        static let fieldWidth: CGFloat = 90

        /// The slot between a row's field and its arrows, holding the suffix. Sized to the longest
        /// suffix there is (`mins`), so every row's arrows land in the same column no matter which
        /// word sits in front of them.
        ///
        /// Fixed rather than sized to its own text: a suffix that sized itself would move the arrows
        /// after it by however wide that text rendered, and `min` vs `mins` would shift them as the
        /// value changed. Sized to the longest one rather than to whatever `rowWidth` had left over,
        /// which is what previously left `%` sitting 46pt away from its arrows.
        static let suffixWidth: CGFloat = 34

        /// Where every row's arrows finish, measured from the row's left edge. Every row is now the
        /// same shape -- field, suffix, arrows -- so this is just their sum.
        static var rowWidth: CGFloat {
            fieldWidth + itemSpacing + suffixWidth + itemSpacing + arrowsWidth
        }
    }

    enum FaceList {
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

    enum Report {
        // The gap between the two calendars, and around the tab's content. Matches the Faces tab's
        // section spacing so the two tabs sit at the same rhythm.
        static let pickerSpacing: CGFloat = 12
        static let padding: CGFloat = 12
        // Between a calendar's title and the grid under it.
        static let titleSpacing: CGFloat = 4
        // The hand-drawn month calendar (see ReportCalendarView). Its cell and font sizes are not
        // here: the calendars span the window, so they are derived from the width the tab is given
        // (ReportCalendarMetrics). Only what sits *around* the grids is fixed, since that is what
        // the derivation subtracts before dividing the rest into columns.
        static let monthTitleMinimumScale: CGFloat = 0.7
        static let calendarPadding: CGFloat = 8
        static let calendarRowSpacing: CGFloat = 4
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
        // The daily-limit control is a SteppedNumberField like every other typeable value in the
        // window, so the column is exactly one of those wide. That also clears the "Daily limit
        // (0 = disabled)" caption, which is the widest thing in the column and previously set this
        // width at 140.
        static var limitColumnWidth: CGFloat { Stepper.rowWidth }
        // 6 wide lays the 42 seeded icons out as an even 6x7 with no partial last row and no
        // scrolling -- see database/004_icon.sql.
        static let iconGridColumns = 6
        static let createFieldSpacing: CGFloat = 8
    }

    /// The Faces tab's own content height, floored at `deviceTabMinimumContentHeight` so the
    /// window's minimum never shrinks below what the Device tab (the default-opened tab) needs,
    /// even when there are few enough faces that the Faces tab alone would ask for less.
    static func fallbackMinimumContentHeight(faceCount: Int) -> CGFloat {
        let rows = CGFloat(faceCount) * faceRowHeight
        let dividers = CGFloat(max(0, faceCount - 1)) * faceDividerHeight
        let facesHeight = paneVerticalPadding + columnHeaderHeight + columnHeaderSpacing + rows + dividers + paneVerticalPadding
        return max(facesHeight, deviceTabMinimumContentHeight)
    }
}
