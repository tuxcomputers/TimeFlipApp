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
            colourID: 0, colour: colour, usesWhiteLines: whiteLines, dailyLimitMinutes: 0, isCategoryActive: true
        )
    }

    /// Hosts, kept alive for the length of a test: a superview does the retaining, so a container dropped on the way
    /// out of the helper would take the constraints holding the view's width with it.
    private var hosts: [NSView] = []

    /// 384pt wide, which is what the left column comes to in a 640pt window.
    ///
    /// **In a container, pinned the way the pane pins it**, rather than by setting the view's own frame. `TimingView`
    /// turns autoresizing off in its initialiser, so a frame set on it is advisory: with nothing holding its width,
    /// Auto Layout is free to shrink the whole view until its contents fit, and it does. That went unnoticed while the
    /// only thing under the square was the name -- the frame was generous enough that nothing had to give -- and
    /// showed up the moment a second row appeared, as a 400pt column reporting a 374pt square.
    ///
    /// `bottom <= host.bottom` is `FacesPane`'s own constraint, so the column here can grow with its contents exactly
    /// as it does in the window.
    private func view(width: CGFloat = 384) -> TimingView {
        let view = TimingView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: width + 200))
        hosts.append(host)
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return view
    }

    func testIdleDrawsNothing() {
        let view = view()

        view.show(category: nil, timingState: .idle, elapsed: 0)

        XCTAssertFalse(view.playPauseButton.isEnabled, "nothing to click at")
        XCTAssertTrue(view.categoryNameLabel.isHidden)
        // The glyph and the clock go together, so hiding their stack hides both.
        XCTAssertTrue(view.playPauseButton.superview?.isHidden ?? false, "an empty column is the honest picture")
    }

    func testRunningShowsTheCategoryItsColourAndTheClock() {
        let view = view()

        view.show(category: category(), timingState: .running, elapsed: 3_723)

        XCTAssertTrue(view.playPauseButton.isEnabled)
        XCTAssertEqual(view.playPauseButton.contentTintColor, .red, "the glyph is the category's colour")
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
        XCTAssertEqual(view.elapsedLabel.stringValue, "1:02:03")
    }

    // MARK: - the geometry, which is all ratios of the column's width

    func testTheSquareIsAsTallAsTheColumnIsWide() {
        let view = view(width: 384)
        view.show(category: category(), timingState: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        // The space the device graphic occupies when there is a cube to draw.
        let square = view.playPauseButton.superview?.superview
        XCTAssertEqual(square?.frame.width, 384)
        XCTAssertEqual(square?.frame.height, 384)
    }

    func testTheGlyphAndTheClockAreSizedFromTheSquare() {
        let view = view(width: 384)
        view.show(category: category(), timingState: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        // 0.29 of the square, and the clock 0.3 of the glyph -- the ratios the previous app used.
        XCTAssertEqual(view.playPauseButton.frame.width, (384 * 0.29).rounded(), accuracy: 0.5)
        XCTAssertEqual(view.elapsedLabel.font?.pointSize, ((384 * 0.29).rounded() * 0.3).rounded())
    }

    func testEverythingGrowsWithTheColumn() {
        let narrow = view(width: 300)
        narrow.show(category: category(), timingState: .running, elapsed: 0)
        narrow.layoutSubtreeIfNeeded()
        let wide = view(width: 600)
        wide.show(category: category(), timingState: .running, elapsed: 0)
        wide.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(wide.playPauseButton.frame.width, narrow.playPauseButton.frame.width)
        XCTAssertGreaterThan(
            wide.elapsedLabel.font?.pointSize ?? 0, narrow.elapsedLabel.font?.pointSize ?? 0,
            "a fixed point size crowds the glyph at one width and looks stranded at another"
        )
    }

    func testTheNameIsTheSizeTheConstantSaysWhateverItSays() {
        // **One size, decided by `nameFontSize` and by nothing else.** It used to be fitted -- stepped down from the
        // constant until the name fit the column, floored at 0.4 of it -- so what a category was drawn at depended on
        // how long a name somebody had typed, and the same column drew at 56 for one and 22 for the next. A name too
        // long for the column is truncated now, which is what `lineBreakMode` is for.
        let view = view()
        let long = CategoryRecord(
            id: 8, name: "Quarterly planning and review workshop that will not fit", iconName: nil,
            colourID: 0, colour: .red, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true
        )

        for category in [category(), long] {
            view.show(category: category, timingState: .running, elapsed: 0)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                view.categoryNameLabel.font?.pointSize, TimingView.Layout.nameFontSize,
                "\(category.name) is drawn at some other size, so the constant is not what decides it"
            )
        }
        XCTAssertEqual(view.categoryNameLabel.maximumNumberOfLines, TimingView.Layout.nameMaximumLines)
    }

    func testALongNameWrapsRatherThanBeingCutAtOneLine() throws {
        // **`.byTruncatingTail` does not wrap on macOS**, whatever `maximumNumberOfLines` says, which is the trap
        // this pins. Measured on an `NSTextFieldCell` holding this name at 40pt in a 380pt column: 47pt for
        // truncating tail, 94pt for word wrapping. So a line-break mode that looks like the one asking for an
        // ellipsis quietly buys a single line, and the name loses two thirds of itself with room to spare below.
        let view = view()

        view.show(category: category(), timingState: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()
        let oneLine = view.categoryNameLabel.frame.height

        let long = CategoryRecord(
            id: 9, name: "When there is a long category it makes the windows wider", iconName: nil,
            colourID: 0, colour: .red, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true
        )
        view.show(category: long, timingState: .running, elapsed: 0)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            view.categoryNameLabel.frame.height, oneLine * 2, accuracy: 2,
            "a long name is drawn on two lines, and Break on one"
        )
        XCTAssertEqual(view.categoryNameLabel.lineBreakMode, .byWordWrapping, "the only mode that wraps")
        XCTAssertTrue(
            view.categoryNameLabel.cell?.truncatesLastVisibleLine ?? false,
            "so a name too long even for the lines it is allowed ends in an ellipsis rather than mid-sentence"
        )
    }

    func testTheNameIsTheSameSizeHoweverWideTheColumnIs() {
        // A wider window draws the glyph and the clock bigger, both being fractions of the square. The name is not:
        // it is a point size, so it stays where it is set while everything around it grows.
        let narrow = view(width: 320)
        let wide = view(width: 900)

        for view in [narrow, wide] {
            view.show(category: category(), timingState: .running, elapsed: 0)
            view.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(narrow.categoryNameLabel.font?.pointSize, TimingView.Layout.nameFontSize)
        XCTAssertEqual(wide.categoryNameLabel.font?.pointSize, TimingView.Layout.nameFontSize)
        XCTAssertGreaterThan(
            wide.playPauseButton.frame.width, narrow.playPauseButton.frame.width,
            "precondition: the rest of the column does scale, which is what makes the name not scaling deliberate"
        )
    }

    func testALongNameCannotWidenTheWindow() {
        // **The fault this pins, measured on the running app**: a category named "When there is a long category it
        // makes the windows wider" drew the Settings window 1295pt wide. The name label asked for 1436pt at 56pt
        // semibold, and a label holds out for its intrinsic width at `.defaultHigh`.
        //
        // It cannot be asserted from the frame: in a fixed-width host the label is squeezed either way, which is
        // why the test above passed throughout. The window is what obliges, and no hermetic container does.
        //
        // The shrink-to-fit above depends on this: a label that is never short of room has nothing to shrink for.
        let view = view()

        view.show(category: category(), timingState: .running, elapsed: 0)

        XCTAssertEqual(
            view.categoryNameLabel.contentCompressionResistancePriority(for: .horizontal), .defaultLow,
            "the name may still insist on its own width, which is what widened the window"
        )
    }

    func testTheElapsedFigureIsTruncatedNotRounded() {
        let view = view()

        view.show(category: category(), timingState: .running, elapsed: 59.9)

        XCTAssertEqual(view.elapsedLabel.stringValue, "0:00:59", "a clock must never read ahead of itself")
    }

    func testACategoryWithNoColourDrawsInTheOrdinaryLabelColour() {
        let view = view()

        view.show(category: category(colour: nil), timingState: .running, elapsed: 0)

        // Nothing sits behind the glyph, so there is no dark background for it to be swallowed by and no
        // white-on-dark decision to make -- unlike the icon in the list, which sits on the colour.
        XCTAssertEqual(view.playPauseButton.contentTintColor, .labelColor)
    }

    func testPausedStillShowsTheSessionAndStaysClickable() {
        let view = view()

        view.show(category: category(), timingState: .paused, elapsed: 45)

        XCTAssertTrue(view.playPauseButton.isEnabled, "clicking is how it starts again")
        XCTAssertEqual(view.elapsedLabel.stringValue, "0:00:45")
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
    }

    func testTheControlSaysOutLoudWhichStateItIsIn() {
        let view = view()

        view.show(category: category(), timingState: .running, elapsed: 0)
        XCTAssertEqual(view.playPauseButton.accessibilityLabel(), "Running, click to pause")

        view.show(category: category(), timingState: .paused, elapsed: 0)
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
        view.show(category: category(), timingState: .running, elapsed: 0)
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
        XCTAssertEqual(view.deviceView.accessibilityIdentifier(), TimingView.Identifier.cubeFace)
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

        view.show(category: category(), timingState: .running, elapsed: 60)

        XCTAssertTrue(view.deviceView.isHidden)
        XCTAssertNil(view.deviceView.image)
        XCTAssertTrue(view.centreIconView.isHidden)
        XCTAssertNil(view.centreIconView.image)
        XCTAssertTrue(view.playPauseButton.isEnabled, "the manual control is back")
    }

    // MARK: - the lock in the corner

    /// The lock's size as Auto Layout sees it.
    ///
    /// **Its alignment rect, not its frame.** Constraints act on the alignment rect, and this button's frame is
    /// noticeably larger than it: measured at a 53pt lock, the frame came back 53.5 x 73.5 while the alignment rect was
    /// exactly 53 x 53. The extra is AppKit's own insets for a symbol image whose bounding box is taller than its point
    /// size -- which is the same fact the archive recorded about lock glyphs, seen from the other side. Asserting on
    /// the frame reads as a broken constraint when nothing is broken.
    private func lockSize(of view: TimingView) -> NSRect {
        view.lockButton.alignmentRect(forFrame: view.lockButton.frame)
    }

    func testThereIsNoLockWithoutACube() {
        // Manual mode's face is meant to be reassigned, so a lock there could only get in the way. Hidden rather than
        // drawn open: there is no lock to offer, not one that happens to be unlocked.
        let view = view()

        view.show(category: nil, timingState: .idle, elapsed: 0)

        XCTAssertTrue(view.lockButton.isHidden)
    }

    func testFollowingACubeDrawsTheLock() {
        let view = view()

        view.show(face: 5, category: nil, isFaceLocked: false)

        XCTAssertFalse(view.lockButton.isHidden)
    }

    func testTheLockSaysWhichWayItIsInBothWords() {
        // What it is called has to say what pressing it does. "Lock" on a locked face reads as a label for the state
        // it is already in.
        let view = view()

        view.show(face: 5, category: nil, isFaceLocked: true)
        XCTAssertEqual(view.lockButton.accessibilityLabel(), "Unlock face")

        view.show(face: 5, category: nil, isFaceLocked: false)
        XCTAssertEqual(view.lockButton.accessibilityLabel(), "Lock face")
    }

    func testTheColourSaysWhetherTheFaceWillTakeACategory() {
        // Red and green, matching the list going dead beside it -- so the two are one fact drawn twice rather than two
        // that have to be read together.
        let view = view()

        view.show(face: 5, category: nil, isFaceLocked: true)
        XCTAssertEqual(view.lockButton.contentTintColor, .systemRed)

        view.show(face: 5, category: nil, isFaceLocked: false)
        XCTAssertEqual(view.lockButton.contentTintColor, .systemGreen)
    }

    func testTheLockSitsInTheCornerOutsideTheRing() {
        // The band of square the ring leaves empty, which is the whole reason it can sit on the artwork without
        // landing on any of it.
        let view = view(width: 400)
        view.show(face: 5, category: nil, isFaceLocked: false)
        view.layoutSubtreeIfNeeded()

        let expected = (400 * TimingView.Layout.lockScale).rounded()
        XCTAssertEqual(lockSize(of: view).width, expected, accuracy: 0.5)
        XCTAssertEqual(lockSize(of: view).height, expected, accuracy: 0.5)
        XCTAssertEqual(lockSize(of: view).minX, 0, accuracy: 0.5, "not against the leading edge")
    }

    func testTheLockIsSizedFromTheSquareRatherThanFixed() {
        // The archive's 40 points was right for one window width and nothing else. Everything in this column follows
        // the square, and a lock that did not would swamp a narrow window and vanish in a wide one.
        let narrow = view(width: 200)
        narrow.show(face: 5, category: nil, isFaceLocked: false)
        narrow.layoutSubtreeIfNeeded()
        let wide = view(width: 600)
        wide.show(face: 5, category: nil, isFaceLocked: false)
        wide.layoutSubtreeIfNeeded()

        XCTAssertLessThan(lockSize(of: narrow).width, lockSize(of: wide).width)
    }

    func testTheLockGoesWhenTheCubeDoes() {
        // A link that drops must not leave a lock behind on a face nobody is holding.
        let view = view()
        view.show(face: 5, category: nil, isFaceLocked: true)
        XCTAssertFalse(view.lockButton.isHidden, "precondition")

        view.show(category: nil, timingState: .idle, elapsed: 0)

        XCTAssertTrue(view.lockButton.isHidden)
    }

    func testPressingTheLockReportsIt() {
        let view = TimingView()
        // In a window, because that is what a click needs -- the same reason `testTheControlReportsItsClick` hosts it.
        let window = OffscreenWindow.host(view)
        var pressed = 0
        view.onToggleLock = { pressed += 1 }
        view.show(face: 5, category: nil, isFaceLocked: false)
        view.layoutSubtreeIfNeeded()

        view.lockButton.performClick(nil)
        _ = window

        XCTAssertEqual(pressed, 1)
    }

    // MARK: - the figure under the name

    func testFollowingACubeDrawsTheFigureUnderTheName() {
        // Under the name rather than in the square, because with a cube the square *is* the cube: a figure on the
        // artwork would be writing over the picture.
        let view = view(width: 400)

        view.show(face: 5, category: category(), isFaceLocked: false, elapsed: 3661)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.faceElapsedLabel.stringValue, "1:01:01")
        // AppKit's y grows upward, so the bottom of the column is `minY == 0` and "under the name" is a smaller y
        // than the name's.
        XCTAssertEqual(view.faceElapsedLabel.frame.minY, 0, accuracy: 0.5, "not at the bottom of the column")
        XCTAssertLessThanOrEqual(
            view.faceElapsedLabel.frame.maxY, view.categoryNameLabel.frame.minY + 0.5,
            "the figure is not under the name"
        )
    }

    func testTheFigureIsTruncatedNotRounded() {
        // What is shown must never be ahead of the time actually recorded, which is the rule every figure the app
        // draws follows.
        let view = view()

        view.show(face: 5, category: category(), elapsed: 59.9)

        XCTAssertEqual(view.faceElapsedLabel.stringValue, "0:00:59")
    }

    func testTheFigureFollowsTheSecondsSetting() {
        let view = view()

        view.show(face: 5, category: category(), elapsed: 3661, showingSeconds: false)

        XCTAssertEqual(view.faceElapsedLabel.stringValue, "1:01")
    }

    func testAFaceWithNoCategoryDrawsNoFigure() {
        // An unlit cube with a number under it would be a total about a category that is not there.
        let view = view()

        view.show(face: 5, category: nil, elapsed: 500)

        XCTAssertEqual(view.faceElapsedLabel.stringValue, "")
    }

    func testTheFigureGoesWithTheCube() {
        let view = view()
        view.show(face: 5, category: category(), elapsed: 500)
        XCTAssertFalse(view.faceElapsedLabel.stringValue.isEmpty, "precondition")

        view.show(category: category(), timingState: .paused, elapsed: 90)

        XCTAssertEqual(view.faceElapsedLabel.stringValue, "", "a figure left over from a cube that has gone")
    }

    func testAnEmptyFigureTakesNoHeightSoTheSquareIsUnchanged() {
        // An empty text field is not a field of no height -- it sizes to its font regardless -- so this is driven
        // rather than left alone. Without it the square lost four points to a label showing nothing.
        let withCube = view(width: 400)
        withCube.show(face: 5, category: category(), elapsed: 500)
        withCube.layoutSubtreeIfNeeded()
        let manual = view(width: 400)
        manual.show(category: category(), timingState: .paused, elapsed: 500)
        manual.layoutSubtreeIfNeeded()

        XCTAssertEqual(manual.faceElapsedLabel.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(
            withCube.squareSide, manual.squareSide, accuracy: 0.5,
            "the square changed size depending on whether a figure was under the name"
        )
    }
}

extension TimingViewTests {
    // MARK: - the glyph beside the figure

    func testTheGlyphSaysWhetherTheCubeIsRunning() {
        let view = view()

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .running)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.faceGlyphView.isHidden)
        let running = view.faceGlyphView.image

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .paused)
        view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(running)
        XCTAssertNotEqual(view.faceGlyphView.image?.size, .zero)
    }

    func testTheGlyphSaysInWordsWhichOneItIs() {
        // A symbol is one character to anything reading the accessibility tree, so without this nothing outside the
        // app can tell a running cube from a paused one on this tab -- which is what both a screen reader and a
        // scripted check are here to ask.
        let view = view()

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .running)
        XCTAssertEqual(view.faceGlyphView.accessibilityLabel(), "Device running")

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .paused)
        XCTAssertEqual(view.faceGlyphView.accessibilityLabel(), "Device paused")
    }

    func testACubeThatHasNotAnsweredSaysNothingEither() {
        // Nothing drawn and nothing said. A label left behind from the last draw would be the tree reporting a state
        // the cube has not claimed.
        let view = view()

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .unknown)

        XCTAssertNil(view.faceGlyphView.accessibilityLabel())
    }

    func testACubeThatHasNotAnsweredDrawsNoGlyph() {
        let view = view()

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .unknown)

        XCTAssertTrue(view.faceGlyphView.isHidden)
    }

    func testTheGlyphGoesWithTheFigure() {
        // Nothing to qualify means nothing to draw beside it: a glyph alone under an unlit cube would be a note on a
        // figure that is not there.
        let view = view()

        view.show(face: 5, category: nil, elapsed: 60, cubePauseState: .running)

        XCTAssertTrue(view.faceGlyphView.isHidden)
        XCTAssertEqual(view.faceElapsedLabel.stringValue, "")
    }

    func testTheGlyphGoesWhenTheCubeDoes() {
        let view = view()
        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .running)
        XCTAssertFalse(view.faceGlyphView.isHidden, "precondition")

        view.show(category: category(), timingState: .paused, elapsed: 90)

        XCTAssertTrue(view.faceGlyphView.isHidden)
    }

    func testTheGlyphIsDrawnBesideTheFigureRatherThanInTheSquare() {
        // The square is the cube, and its centre face already carries the category's icon: a second glyph there would
        // be two symbols on one picture answering different questions.
        let view = view(width: 400)

        view.show(face: 5, category: category(), elapsed: 60, cubePauseState: .running)
        view.layoutSubtreeIfNeeded()

        // Both converted into the view's own space: the figure lives inside the row's stack now, so its `frame` is in
        // the stack's coordinates and comparing it with anything outside would be comparing two different origins.
        let glyph = view.faceGlyphView.convert(view.faceGlyphView.bounds, to: view)
        let figure = view.faceElapsedLabel.convert(view.faceElapsedLabel.bounds, to: view)
        // Centres rather than edges, for the reason the lock test gives: a text field's frame is larger than the box
        // Auto Layout positioned, so edges from two different kinds of view do not compare cleanly. Which is above
        // which is the claim, and centres say it exactly.
        XCTAssertLessThan(glyph.midY, view.categoryNameLabel.frame.midY, "not under the name")
        XCTAssertLessThan(glyph.midX, figure.midX, "not to the left of the figure")
    }
}

private extension TimingView {
    /// The square the column reserves for the device, whichever picture is in it.
    var squareSide: CGFloat { deviceView.superview?.frame.width ?? 0 }
}
