@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers what the status item says, which is decided apart from the drawing so it can be asserted without a
/// status item in the tester's own menu bar.
///
/// Worth testing because this is the one line the app shows all day with no window open, and every piece of it is
/// conditional: an icon a category may not have, a glyph that depends on the clock, a figure whose format is a
/// setting, and a spoken label that has to say all of it in words.
@MainActor
final class StatusItemTitleTests: XCTestCase {
    private let appLabel = "TimeFlip"

    private func category(name: String = "Meeting", icon: String? = "meeting") -> CategoryRecord {
        CategoryRecord(id: 2, name: name, iconName: icon, colour: .systemBlue, usesWhiteLines: false, isActive: true)
    }

    private func title(
        _ reading: TimingReadout.Reading,
        showingSeconds: Bool = true,
        badge: String? = nil
    ) -> StatusItemTitle {
        StatusItemTitle.make(
            appLabel: appLabel,
            badgeDescription: badge,
            reading: reading,
            showingSeconds: showingSeconds
        )
    }

    // MARK: - nothing being timed

    func testIdleIsTheAppsNameAndNothingElse() {
        let title = title(.idle)

        XCTAssertEqual(title.text, appLabel)
        XCTAssertNil(title.iconName)
        XCTAssertNil(title.glyphName)
        // Not "0:00": a figure with nothing behind it reads as a session that started and got nowhere.
        XCTAssertNil(title.duration)
        XCTAssertEqual(title.spoken, appLabel)
    }

    func testACategoryWithNoStateToDrawIsStillIdle() {
        // Half a session, which the readout never produces -- but the item has to draw something either way, and
        // the app's name is the honest answer to "nothing is being timed".
        let title = title(TimingReadout.Reading(category: category(), state: .idle, seconds: 900))

        XCTAssertEqual(title.text, appLabel)
        XCTAssertNil(title.duration)
    }

    // MARK: - a session

    func testRunningReadsIconCategoryPlayAndTheTime() {
        let title = title(TimingReadout.Reading(category: category(), state: .running, seconds: 3_725))

        XCTAssertEqual(title.text, "Meeting")
        XCTAssertEqual(title.iconName, "meeting")
        // The glyph says what is happening, not what clicking does, which is `ManualTimerRules`' rule and not a
        // second opinion of it.
        XCTAssertEqual(title.glyphName, ManualTimerRules.symbolName(for: .running))
        XCTAssertEqual(title.duration, "1:02:05")
    }

    func testPausedKeepsTheFigureAndSwapsTheGlyph() {
        let title = title(TimingReadout.Reading(category: category(), state: .paused, seconds: 3_725))

        // The category's time today does not go away because the clock stopped; only the glyph changes.
        XCTAssertEqual(title.duration, "1:02:05")
        XCTAssertEqual(title.glyphName, ManualTimerRules.symbolName(for: .paused))
    }

    func testACategoryWithNoIconDrawsNone() {
        let title = title(TimingReadout.Reading(category: category(icon: nil), state: .running, seconds: 60))

        XCTAssertNil(title.iconName)
        XCTAssertEqual(title.text, "Meeting", "the name still shows without artwork beside it")
    }

    func testTheFigureIsTruncatedRatherThanRounded() {
        // 59.6 seconds is not a minute yet. A live figure that rounded up would read ahead of the time actually
        // recorded, which is the one thing a clock must not do.
        let title = title(TimingReadout.Reading(category: category(), state: .running, seconds: 59.6))

        XCTAssertEqual(title.duration, "0:00:59")
    }

    // MARK: - display_seconds

    func testWithSecondsOffTheFigureIsHoursAndMinutes() {
        let title = title(
            TimingReadout.Reading(category: category(), state: .running, seconds: 3_725),
            showingSeconds: false
        )

        XCTAssertEqual(title.duration, "1:02")
    }

    // MARK: - the colour

    func testASessionIsGreen() {
        let title = title(TimingReadout.Reading(category: category(), state: .running, seconds: 60))

        // The previous app's live colour, and the reason its menu bar could be believed at a glance: green says
        // there is a reading behind the figure.
        XCTAssertEqual(title.colour, .systemGreen)
    }

    func testAStoppedClockIsStillGreen() {
        // Paused is not stale. The figure is still this category's time today, and it is still the app's own
        // reading -- what changed is the glyph. Yellow belonged to a reading that could no longer be confirmed,
        // which needs a device to be possible at all.
        XCTAssertEqual(title(TimingReadout.Reading(category: category(), state: .paused, seconds: 60)).colour, .systemGreen)
    }

    func testWithNothingBeingTimedItIsTheOrdinaryTextColour() {
        // Green is a claim about a reading, and there is none to make it about.
        XCTAssertEqual(title(.idle).colour, .labelColor)
    }

    // MARK: - what VoiceOver reads

    func testTheSpokenLabelSaysWhatTheGlyphAndTheBadgeCannot() {
        let title = title(
            TimingReadout.Reading(category: category(), state: .running, seconds: 3_725),
            badge: "test database"
        )

        // The glyph is an image and the badge's warning is a colour: neither reaches a screen reader, so both are
        // spelled out. The name leads, because that is the answer to what the item is showing.
        XCTAssertEqual(title.spoken, "Meeting, running, 1:02:05, TimeFlip, test database")
    }

    func testTheSpokenLabelSaysWhenTheClockIsStopped() {
        let title = title(TimingReadout.Reading(category: category(), state: .paused, seconds: 60))

        XCTAssertEqual(title.spoken, "Meeting, paused, 0:01:00, TimeFlip")
    }

    func testIdleStillNamesTheDatabase() {
        // The state the app sits in before anything is timed, which is exactly when somebody is most likely to be
        // wondering which database this launch opened.
        XCTAssertEqual(title(.idle, badge: "test database").spoken, "TimeFlip, test database")
    }
}
