@testable import FacetApp
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
    private let appLabel = "Facet"

    private func category(name: String = "Meeting", icon: String? = "meeting") -> CategoryRecord {
        CategoryRecord(id: 2, name: name, iconName: icon, colourID: 0, colour: .systemBlue, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true)
    }

    private func title(
        _ reading: TimingReadout.Reading,
        showingSeconds: Bool = true,
        badge: String? = nil,
        isLimitReached: Bool = false,
        lowBattery: LowBatteryAlert = .none
    ) -> StatusItemTitle {
        StatusItemTitle.make(
            appLabel: appLabel,
            badgeDescription: badge,
            reading: reading,
            showingSeconds: showingSeconds,
            isLimitReached: isLimitReached,
            lowBattery: lowBattery
        )
    }

    private let flashOn = LowBatteryAlert(isLow: true, isBlinkOn: true)
    private let flashOff = LowBatteryAlert(isLow: true, isBlinkOn: false)

    // MARK: - a category over its daily limit

    func testTheLineTurnsRedWhenTheLimitIsSpent() {
        // The archive's colour and its meaning: `MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen`.
        // Green is a claim that time is being recorded normally, and a limit that stopped the clock ends that claim.
        let reading = TimingReadout.Reading(category: category(), state: .paused, seconds: 3600)

        XCTAssertEqual(title(reading, isLimitReached: true).colour, .systemRed)
        XCTAssertEqual(title(reading, isLimitReached: false).colour, .systemGreen)
    }

    func testTheLimitIsSaidAloudAndNotOnlyColoured() {
        // A colour is the whole of the signal on screen, so without this the one state the item exists to warn about
        // is the one state it never mentions to somebody reading it aloud.
        let reading = TimingReadout.Reading(category: category(), state: .paused, seconds: 3600)

        XCTAssertTrue(title(reading, isLimitReached: true).spoken.contains("daily limit reached"))
        XCTAssertFalse(title(reading, isLimitReached: false).spoken.contains("daily limit reached"))
    }

    func testTheLimitDoesNotColourAnIdleItem() {
        // Nothing being timed keeps the app's name in the ordinary colour. There is no reading for red to be a claim
        // about, which is the same reason idle is not green.
        XCTAssertEqual(title(.idle, isLimitReached: true).colour, .labelColor)
        XCTAssertFalse(title(.idle, isLimitReached: true).spoken.contains("daily limit reached"))
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
        XCTAssertEqual(title.spoken, "Meeting, running, 1:02:05, Facet, test database")
    }

    func testTheSpokenLabelSaysWhenTheClockIsStopped() {
        let title = title(TimingReadout.Reading(category: category(), state: .paused, seconds: 60))

        XCTAssertEqual(title.spoken, "Meeting, paused, 0:01:00, Facet")
    }

    func testIdleStillNamesTheDatabase() {
        // The state the app sits in before anything is timed, which is exactly when somebody is most likely to be
        // wondering which database this launch opened.
        XCTAssertEqual(title(.idle, badge: "test database").spoken, "Facet, test database")
    }

    // MARK: - a cube running out of charge

    func testTheNameAlternatesWhileTheCubeIsFlat() {
        // The archive's flash, on the archive's half of the line: red on one phase, and the ordinary text colour on
        // the other rather than its `.white`, which against a light menu bar is a name that vanishes rather than one
        // that flashes.
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertEqual(title(reading, lowBattery: flashOn).nameColour, .systemRed)
        XCTAssertEqual(title(reading, lowBattery: flashOff).nameColour, .labelColor)
    }

    func testTheFigureBesideItDoesNotFlash() {
        // Only the name and its icon alternate. The figure is a clock somebody reads, and a duration changing colour
        // twice a second is hardest to read at the exact moment the app is asking for attention.
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        for phase in [flashOn, flashOff] {
            XCTAssertEqual(title(reading, lowBattery: phase).colour, .systemGreen)
        }
    }

    func testAHealthyCubeLeavesTheNameTheColourOfTheLine() {
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertEqual(title(reading).nameColour, title(reading).colour)
        XCTAssertEqual(title(reading, isLimitReached: true).nameColour, .systemRed)
    }

    func testTheFlashIsVisibleAgainstAnOverLimitLine() {
        // Both states at once, which is the case a single colour cannot show: the line is already red for the limit,
        // so a flash that alternated red with red would not be a flash at all.
        let reading = TimingReadout.Reading(category: category(), state: .paused, seconds: 3600)

        XCTAssertEqual(title(reading, isLimitReached: true, lowBattery: flashOn).nameColour, .systemRed)
        XCTAssertEqual(title(reading, isLimitReached: true, lowBattery: flashOff).nameColour, .labelColor)
    }

    func testTheWarningFlashesOnTheAppNameWhileNothingIsTimed() {
        // A flat cube is a fact about the device rather than about the session, and the moment somebody is most
        // likely to miss it is the moment nothing is running.
        XCTAssertEqual(title(.idle, lowBattery: flashOn).nameColour, .systemRed)
        XCTAssertEqual(title(.idle, lowBattery: flashOff).nameColour, .labelColor)
    }

    func testEachPhaseIsADifferentTitle() {
        // What makes the item actually repaint: `MenuBarController` draws only when the title differs from the last
        // one it drew, so a flash that produced an equal title twice would be a warning that never blinks.
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertNotEqual(title(reading, lowBattery: flashOn), title(reading, lowBattery: flashOff))
        XCTAssertNotEqual(title(reading, lowBattery: flashOff), title(reading))
        XCTAssertNotEqual(title(.idle, lowBattery: flashOn), title(.idle, lowBattery: flashOff))
    }

    func testTheWarningIsSaidAloudAndNotOnlyFlashed() {
        // A colour is the whole of the signal on screen. Said on both phases, because the warning stands whichever
        // half of the flash the item happens to be drawing.
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertTrue(title(reading, lowBattery: flashOn).spoken.contains("low battery"))
        XCTAssertTrue(title(reading, lowBattery: flashOff).spoken.contains("low battery"))
        XCTAssertTrue(title(.idle, lowBattery: flashOn).spoken.contains("low battery"))
        XCTAssertFalse(title(reading).spoken.contains("low battery"))
    }
}
