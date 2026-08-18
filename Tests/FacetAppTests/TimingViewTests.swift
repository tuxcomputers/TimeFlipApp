@testable import FacetApp
import AppKit
import XCTest

/// Covers `TimingView`: what the Timing column draws for each state, and that its control reports rather
/// than acts.
@MainActor
final class TimingViewTests: XCTestCase {
    private func category(
        colour: NSColor? = .red,
        whiteLines: Bool = false,
        iconName: String? = "ic_admin"
    ) -> CategoryRecord {
        CategoryRecord(
            id: 7, name: "Deep Work", iconName: iconName,
            colourID: 0, colour: colour, usesWhiteLines: whiteLines, dailyLimitMinutes: 0, isActive: true
        )
    }

    /// 384pt wide, which is what the left column comes to in a 640pt window.
    private func view(width: CGFloat = 384) -> TimingView {
        let view = TimingView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: width + 100)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testIdleDrawsNothing() {
        let view = view()

        view.show(category: nil, state: .idle, elapsed: 0)

        XCTAssertFalse(view.playPauseButton.isEnabled, "nothing to click at")
        XCTAssertTrue(view.categoryNameLabel.isHidden)
        // The glyph and the clock go together, so hiding their stack hides both.
        XCTAssertTrue(view.playPauseButton.superview?.isHidden ?? false, "an empty column is the honest picture")
    }

    func testRunningShowsTheCategoryItsColourAndTheClock() {
        let view = view()

        view.show(category: category(), state: .running, elapsed: 3_723)

        XCTAssertTrue(view.playPauseButton.isEnabled)
        XCTAssertEqual(view.playPauseButton.contentTintColor, .red, "the glyph is the category's colour")
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
        XCTAssertEqual(view.elapsedLabel.stringValue, "1:02:03")
    }

    // MARK: - the geometry, which is all ratios of the column's width

    func testTheSquareIsAsTallAsTheColumnIsWide() {
        let view = view(width: 384)
        view.show(category: category(), state: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        // The space the device graphic occupies when there is a cube to draw.
        let square = view.playPauseButton.superview?.superview
        XCTAssertEqual(square?.frame.width, 384)
        XCTAssertEqual(square?.frame.height, 384)
    }

    func testTheGlyphAndTheClockAreSizedFromTheSquare() {
        let view = view(width: 384)
        view.show(category: category(), state: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        // 0.29 of the square, and the clock 0.3 of the glyph -- the ratios the previous app used.
        XCTAssertEqual(view.playPauseButton.frame.width, (384 * 0.29).rounded(), accuracy: 0.5)
        XCTAssertEqual(view.elapsedLabel.font?.pointSize, ((384 * 0.29).rounded() * 0.3).rounded())
    }

    func testEverythingGrowsWithTheColumn() {
        let narrow = view(width: 300)
        narrow.show(category: category(), state: .running, elapsed: 0)
        narrow.layoutSubtreeIfNeeded()
        let wide = view(width: 600)
        wide.show(category: category(), state: .running, elapsed: 0)
        wide.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(wide.playPauseButton.frame.width, narrow.playPauseButton.frame.width)
        XCTAssertGreaterThan(
            wide.elapsedLabel.font?.pointSize ?? 0, narrow.elapsedLabel.font?.pointSize ?? 0,
            "a fixed point size crowds the glyph at one width and looks stranded at another"
        )
    }

    func testTheNameIsLargeAndShrinksRatherThanWrapping() {
        let view = view()
        view.show(category: category(), state: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.categoryNameLabel.font?.pointSize, TimingView.Layout.nameFontSize)
        XCTAssertEqual(view.categoryNameLabel.maximumNumberOfLines, 1)

        let long = CategoryRecord(
            id: 8, name: "Quarterly planning and review workshop", iconName: nil,
            colourID: 0, colour: .red, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
        )
        view.show(category: long, state: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        let size = try? XCTUnwrap(view.categoryNameLabel.font?.pointSize)
        XCTAssertLessThan(size ?? 0, TimingView.Layout.nameFontSize, "shrunk to fit")
        XCTAssertGreaterThanOrEqual(
            size ?? 0, (TimingView.Layout.nameFontSize * TimingView.Layout.nameMinimumScale).rounded(),
            "but not past the floor, below which it truncates instead"
        )
    }

    func testTheElapsedFigureIsTruncatedNotRounded() {
        let view = view()

        view.show(category: category(), state: .running, elapsed: 59.9)

        XCTAssertEqual(view.elapsedLabel.stringValue, "0:00:59", "a clock must never read ahead of itself")
    }

    func testACategoryWithNoColourDrawsInTheOrdinaryLabelColour() {
        let view = view()

        view.show(category: category(colour: nil), state: .running, elapsed: 0)

        // Nothing sits behind the glyph, so there is no dark background for it to be swallowed by and no
        // white-on-dark decision to make -- unlike the icon in the list, which sits on the colour.
        XCTAssertEqual(view.playPauseButton.contentTintColor, .labelColor)
    }

    func testPausedStillShowsTheSessionAndStaysClickable() {
        let view = view()

        view.show(category: category(), state: .paused, elapsed: 45)

        XCTAssertTrue(view.playPauseButton.isEnabled, "clicking is how it starts again")
        XCTAssertEqual(view.elapsedLabel.stringValue, "0:00:45")
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
    }

    func testTheControlSaysOutLoudWhichStateItIsIn() {
        let view = view()

        view.show(category: category(), state: .running, elapsed: 0)
        XCTAssertEqual(view.playPauseButton.accessibilityLabel(), "Running, click to pause")

        view.show(category: category(), state: .paused, elapsed: 0)
        XCTAssertEqual(
            view.playPauseButton.accessibilityLabel(), "Paused, click to resume",
            "the glyph carries the state visually, so the label has to carry it for a screen reader"
        )
    }

    func testTheControlReportsItsClick() {
        let view = TimingView()
        // In a window, because that is what a click needs -- see `OffscreenWindow`.
        let window = OffscreenWindow.host(view)
        var clicks = 0
        view.onTogglePause = { clicks += 1 }
        view.show(category: category(), state: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        view.playPauseButton.performClick(nil)
        _ = window

        XCTAssertEqual(clicks, 1)
    }

    func testEachPartIsNamedForAScript() {
        let view = view()

        XCTAssertEqual(view.playPauseButton.accessibilityIdentifier(), TimingView.Identifier.playPause)
        XCTAssertEqual(view.elapsedLabel.accessibilityIdentifier(), TimingView.Identifier.elapsed)
        XCTAssertEqual(view.categoryNameLabel.accessibilityIdentifier(), TimingView.Identifier.categoryName)
        XCTAssertEqual(view.deviceView.accessibilityIdentifier(), TimingView.Identifier.deviceFace)
        XCTAssertEqual(view.centreIconView.accessibilityIdentifier(), TimingView.Identifier.centreIcon)
    }

    // MARK: - the face the cube is resting on

    func testAFaceDrawsTheCubeWithItsCategoryOnIt() {
        let view = view()

        view.show(face: 2, category: category())

        XCTAssertFalse(view.deviceView.isHidden)
        XCTAssertNotNil(view.deviceView.image, "the cube, lit in the face's colour")
        XCTAssertFalse(view.centreIconView.isHidden)
        XCTAssertNotNil(view.centreIconView.image, "the category's icon, on the centre face")
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
    }

    func testTheCentreIconTakesTheInkTheLinesAreDrawnIn() {
        // Black on a light face, white on a dark one, and both from the colour row's own `white_lines` rather than
        // from anything decided here -- so the icon can never be drawn in a colour the lines around it are not.
        let light = view()
        light.show(face: 2, category: category(colour: .yellow, whiteLines: false))
        XCTAssertEqual(light.centreIconView.contentTintColor, .black)

        let dark = view()
        dark.show(face: 2, category: category(colour: .black, whiteLines: true))
        XCTAssertEqual(dark.centreIconView.contentTintColor, .white)
    }

    func testTheClockAndTheControlAreNotDrawnOnACube() {
        // The archive's arrangement: a face is a picture of where the cube is, and the cube's own timing is not
        // something a click on this window starts or stops.
        let view = view()

        view.show(face: 2, category: category())

        XCTAssertTrue(view.playPauseButton.superview?.isHidden ?? false, "no glyph and no clock")
        XCTAssertFalse(view.playPauseButton.isEnabled, "nothing to click at")
    }

    func testAFaceWithNoCategoryStillDrawsTheCube() {
        // An unassigned face is still a face the cube is resting on. It comes out unlit, with no icon on it, rather
        // than the column going blank -- and drawing a placeholder icon would read as artwork that failed to load.
        let view = view()

        view.show(face: 5, category: nil)

        XCTAssertFalse(view.deviceView.isHidden)
        XCTAssertTrue(view.centreIconView.isHidden)
        XCTAssertEqual(view.categoryNameLabel.stringValue, "")
    }

    func testACategoryWithNoIconLeavesTheCentreFaceBare() {
        let view = view()

        view.show(face: 5, category: category(iconName: nil))

        XCTAssertFalse(view.deviceView.isHidden, "the body is still lit")
        XCTAssertTrue(view.centreIconView.isHidden)
    }

    func testTheCentreIconIsSizedToTheCentreFace() {
        // Derived from the artwork rather than picked: the pentagon's inscribed square is 0.29 of the cube, and the
        // cube is drawn at `markScale` of the icon's box to leave room for the ring.
        let view = view(width: 400)

        view.show(face: 2, category: category())
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            view.centreIconView.frame.width,
            (400 * TimingView.Layout.centreIconScale).rounded(),
            accuracy: 0.5
        )
        XCTAssertEqual(view.centreIconView.frame.width, view.centreIconView.frame.height)
    }

    func testTheCubeFillsTheSquare() {
        let view = view(width: 400)

        view.show(face: 2, category: category())
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.deviceView.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(view.deviceView.frame.height, 400, accuracy: 0.5, "the square the column reserves for it")
    }

    func testTheCubeIsCentredOnTheSquareSoTheIconLandsOnItsCentreFace() {
        let view = view(width: 400)

        view.show(face: 2, category: category())
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.centreIconView.frame.midX, view.deviceView.frame.midX, accuracy: 0.5)
        XCTAssertEqual(view.centreIconView.frame.midY, view.deviceView.frame.midY, accuracy: 0.5)
    }

    func testGoingBackToTimingByHandTakesTheCubeAway() {
        // The link dropping is what does this, and the artwork is cleared rather than merely hidden: a face left in
        // memory could be shown again by a later resize, which would be a picture of hardware nobody is holding.
        let view = view()
        view.show(face: 2, category: category())

        view.show(category: category(), state: .running, elapsed: 60)

        XCTAssertTrue(view.deviceView.isHidden)
        XCTAssertNil(view.deviceView.image)
        XCTAssertTrue(view.centreIconView.isHidden)
        XCTAssertNil(view.centreIconView.image)
        XCTAssertTrue(view.playPauseButton.isEnabled, "the manual control is back")
    }
}
