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

    private func view() -> TimingView {
        let view = TimingView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testIdleDrawsNothing() {
        let view = view()

        view.show(category: nil, state: .idle, elapsed: 0)

        XCTAssertTrue(view.playPauseButton.isHidden, "an empty column is the honest picture of no session")
        XCTAssertTrue(view.elapsedLabel.isHidden)
        XCTAssertTrue(view.categoryNameLabel.isHidden)
        XCTAssertFalse(view.playPauseButton.isEnabled, "and nothing to click at")
    }

    func testRunningShowsTheCategoryItsColourAndTheClock() {
        let view = view()

        view.show(category: category(), state: .running, elapsed: 3_723)

        XCTAssertFalse(view.playPauseButton.isHidden)
        XCTAssertTrue(view.playPauseButton.isEnabled)
        XCTAssertEqual(view.categoryNameLabel.stringValue, "Deep Work")
        XCTAssertEqual(view.elapsedLabel.stringValue, "1:02:03")
    }

    func testTheElapsedFigureIsTruncatedNotRounded() {
        let view = view()

        view.show(category: category(), state: .running, elapsed: 59.9)

        XCTAssertEqual(view.elapsedLabel.stringValue, "0:00:59", "a clock must never read ahead of itself")
    }

    func testTheGlyphGoesWhiteOnAColourThatNeedsIt() {
        let view = view()

        view.show(category: category(colour: .black, whiteLines: true), state: .running, elapsed: 0)
        XCTAssertEqual(view.playPauseButton.contentTintColor, .white)

        view.show(category: category(colour: .yellow, whiteLines: false), state: .running, elapsed: 0)
        XCTAssertEqual(view.playPauseButton.contentTintColor, .labelColor)
    }

    func testPausedStillShowsTheSessionAndStaysClickable() {
        let view = view()

        view.show(category: category(), state: .paused, elapsed: 45)

        XCTAssertFalse(view.playPauseButton.isHidden)
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
        let view = view()
        var clicks = 0
        view.onTogglePause = { clicks += 1 }
        view.show(category: category(), state: .running, elapsed: 0)

        view.playPauseButton.performClick(nil)

        XCTAssertEqual(clicks, 1)
    }

    func testEachPartIsNamedForAScript() {
        let view = view()

        XCTAssertEqual(view.playPauseButton.accessibilityIdentifier(), TimingView.Identifier.playPause)
        XCTAssertEqual(view.elapsedLabel.accessibilityIdentifier(), TimingView.Identifier.elapsed)
        XCTAssertEqual(view.categoryNameLabel.accessibilityIdentifier(), TimingView.Identifier.categoryName)
    }
}
