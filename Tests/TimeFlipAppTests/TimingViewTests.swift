@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers `TimingView`: what the Timing column draws for each state, and that its control reports rather
/// than acts.
@MainActor
final class TimingViewTests: XCTestCase {
    private func category(colour: NSColor? = .red, whiteLines: Bool = false) -> CategoryRecord {
        CategoryRecord(
            id: 7, name: "Deep Work", iconName: "ic_admin",
            colour: colour, usesWhiteLines: whiteLines, isActive: true
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
            colour: .red, usesWhiteLines: false, isActive: true
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
    }
}
