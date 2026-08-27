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
        lowBattery: LowBatteryAlert = .none,
        isCubeLocked: Bool = false
    ) -> StatusItemTitle {
        StatusItemTitle.make(
            appLabel: appLabel,
            badgeDescription: badge,
            reading: reading,
            showingSeconds: showingSeconds,
            isLimitReached: isLimitReached,
            lowBattery: lowBattery,
            isCubeLocked: isCubeLocked
        )
    }

    private var running: TimingReadout.Reading {
        TimingReadout.Reading(category: category(), state: .running, seconds: 30)
    }

    private let flashOn = LowBatteryAlert(isBatteryLow: true, isBlinkOn: true)
    private let flashOff = LowBatteryAlert(isBatteryLow: true, isBlinkOn: false)

    // MARK: - a category over its daily limit

    func testTheFigureTurnsRedWhenTheLimitIsSpent() {
        // The archive's colour and its meaning: `MenuBarStatusStyle` drew `overLimit ? .systemRed : .systemGreen`.
        // The session colour is a claim that time is being recorded normally, and a limit that stopped the clock
        // ends that claim.
        let reading = TimingReadout.Reading(category: category(), state: .paused, seconds: 3600)

        XCTAssertEqual(title(reading, isLimitReached: true).colour, .systemRed)
        XCTAssertEqual(title(reading, isLimitReached: false).colour, .systemCyan)
    }

    func testTheNameStaysCyanWhenTheLimitIsSpent() {
        // Where this parts from the archive, which turned its whole line red. The figure is the thing that has
        // reached the number; the name is only which category it belongs to, and that has not changed.
        let reading = TimingReadout.Reading(category: category(), state: .paused, seconds: 3600)

        XCTAssertEqual(title(reading, isLimitReached: true).nameColour, .systemCyan)
        XCTAssertEqual(title(reading, isLimitReached: true).glyphColour, .labelColor)
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

    func testASessionThisAppIsTimingIsCyan() {
        let title = title(TimingReadout.Reading(category: category(), state: .running, seconds: 60))

        // The name and the figure both, which is what makes the line read as one thing. The previous app spent this
        // colour on saying the reading was live; here it says which of the two pictures is on show, a cube's face
        // being the other one.
        XCTAssertEqual(title.colour, .systemCyan)
        XCTAssertEqual(title.nameColour, .systemCyan)
    }

    func testAStoppedClockIsStillCyan() {
        // Paused is not a different picture. The figure is still this category's time today and this app is still
        // the one that measured it -- what changed is the glyph.
        let title = title(TimingReadout.Reading(category: category(), state: .paused, seconds: 60))

        XCTAssertEqual(title.colour, .systemCyan)
        XCTAssertEqual(title.nameColour, .systemCyan)
    }

    func testTheGlyphIsTheMenuBarsOwnTextColour() {
        // Not the line's cyan, and not literal white: the archive handed AppKit an untinted template image, so the
        // strip drew the indicator in whatever it draws text in. `.labelColor` is that spelled out, and it is the
        // one that survives a light menu bar -- which is what white would not, the strip tinting from the wallpaper
        // rather than from the appearance setting.
        for state in [TimingState.running, .paused] {
            let reading = TimingReadout.Reading(category: category(), state: state, seconds: 60)

            XCTAssertEqual(title(reading).glyphColour, .labelColor, "\(state)")
        }
    }

    func testWithNothingBeingTimedItIsTheOrdinaryTextColour() {
        // A session colour is a claim about a reading, and there is none to make it about.
        XCTAssertEqual(title(.idle).colour, .labelColor)
    }

    // MARK: - what the log says the colours were

    func testEachStateDescribesItsOwnColours() {
        // The words a scripted check matches on. They are pinned here because the accessibility tree carries no
        // colour, so a `debug_log` row is the only evidence there is that any of this reached the screen -- and a
        // rename here with no matching edit in `Tests/Scripted` is a check that goes on passing while matching
        // nothing.
        let byHand = TimingReadout.Reading(category: category(), state: .running, seconds: 60)
        let onACube = onCube(category: category(), isDevicePaused: true)
        let gone = onCube(category: category(), isDevicePaused: true, isReachable: false)

        XCTAssertEqual(title(byHand).colourDescription, "name cyan, glyph label, figure cyan")
        XCTAssertEqual(title(byHand, isLimitReached: true).colourDescription, "name cyan, glyph label, figure red")
        XCTAssertEqual(title(onACube).colourDescription, "name green, glyph label, figure green")
        XCTAssertEqual(title(onACube, isLimitReached: true).colourDescription, "name green, glyph label, figure red")
        XCTAssertEqual(title(gone).colourDescription, "name yellow, glyph label, figure yellow")
        XCTAssertEqual(title(.idle).colourDescription, "name label, glyph label, figure label")
    }

    func testTheFigureMovingIsNotAColourChange() {
        // What makes the row affordable. `MenuBarController` writes one when this description changes, and the
        // title itself changes every second the clock is going -- so a row per title would be a row per second for
        // the life of the launch, out of a redraw that `DebugLog` says would need a queue first.
        let at30 = title(TimingReadout.Reading(category: category(), state: .running, seconds: 30))
        let at31 = title(TimingReadout.Reading(category: category(), state: .running, seconds: 31))

        XCTAssertNotEqual(at30, at31, "the titles differ, so the item repaints")
        XCTAssertEqual(at30.colourDescription, at31.colourDescription, "and the colours do not, so nothing is logged")
    }

    func testTheFlashIsAColourChange() {
        // The one thing that does write a row twice a second, and it is meant to: a flat cube is the state the app
        // is trying hardest to be noticed in, and the log is where somebody reconstructs what was on screen.
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertNotEqual(
            title(reading, lowBattery: flashOn).colourDescription,
            title(reading, lowBattery: flashOff).colourDescription
        )
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
            XCTAssertEqual(title(reading, lowBattery: phase).colour, .systemCyan)
        }
    }

    func testAHealthyCubeLeavesTheNameTheColourOfTheLine() {
        let reading = TimingReadout.Reading(category: category(), state: .running, seconds: 60)

        XCTAssertEqual(title(reading).nameColour, title(reading).colour)
    }

    func testTheFlashIsVisibleAgainstAnOverLimitLine() {
        // Both states at once, and the flash still has somewhere to go: the figure has turned red for the limit,
        // and the name it alternates on has not.
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

    // MARK: - the cube being locked

    func testALockedCubeCarriesItsOwnGlyph() {
        let title = title(running, isCubeLocked: true)

        XCTAssertEqual(title.lockGlyphName, "lock.fill")
    }

    func testAnUnlockedCubeCarriesNone() {
        let title = title(running, isCubeLocked: false)

        XCTAssertNil(title.lockGlyphName)
    }

    func testTheLockIsSaidOutLoud() {
        // A badge is the whole of the signal on screen, so without this the state that explains why a cube is not
        // changing face would be invisible to anybody reading the item aloud.
        let title = title(running, isCubeLocked: true)

        XCTAssertTrue(title.spoken.contains("device locked"), title.spoken)
    }

    func testALockedCubeIsDrawnAndSaidWithNothingBeingTimed() {
        // A fact about the device rather than about the session, and the moment it matters most is when nothing is
        // running -- because being locked is why.
        let title = title(.idle, isCubeLocked: true)

        XCTAssertEqual(title.lockGlyphName, "lock.fill")
        XCTAssertTrue(title.spoken.contains("device locked"), title.spoken)
    }

    // MARK: - following a cube

    private func onCube(
        _ face: Int = 2,
        category: CategoryRecord?,
        isDevicePaused: Bool? = nil,
        isReachable: Bool = true
    ) -> TimingReadout.Reading {
        TimingReadout.Reading(
            category: category,
            state: .idle,
            seconds: 0,
            cubeFace: face,
            deviceIsPaused: isDevicePaused,
            isCubeConnected: isReachable
        )
    }

    func testFollowingACubeNamesTheFacesCategory() {
        // The bug this exists for: with a cube connected the Faces tab drew the face's category while the status item
        // drew the app's name, because each asked its own question. One reading now decides, and both draw it.
        let title = title(onCube(category: category(name: "Deep Work", icon: "ic_admin")))

        XCTAssertEqual(title.text, "Deep Work")
        XCTAssertEqual(title.iconName, "ic_admin")
    }

    func testFollowingACubeDrawsTheFigure() {
        let title = title(onCube(category: category()))

        XCTAssertEqual(title.duration, "0:00:00")
    }

    func testTheGlyphIsTheCubesOwnState() {
        // The archive's `showsPauseIcon` took the *device's* paused state, not the app's, which is what makes a glyph
        // mean anything here: this app runs no clock while it follows a cube, but the cube certainly is.
        XCTAssertEqual(title(onCube(category: category(), isDevicePaused: false)).glyphName, "play.fill")
        XCTAssertEqual(title(onCube(category: category(), isDevicePaused: true)).glyphName, "pause.fill")
    }

    func testACubeThatHasNotAnsweredGetsNoGlyph() {
        // Guessing "running" would be a claim about hardware on no evidence, which is the one thing the read-back
        // rule exists to stop.
        XCTAssertNil(title(onCube(category: category(), isDevicePaused: nil)).glyphName)
    }

    func testTheCubesStateIsSaidAloudAsWellAsDrawn() {
        XCTAssertTrue(title(onCube(category: category(), isDevicePaused: true)).spoken.contains("device paused"))
        XCTAssertTrue(title(onCube(category: category(), isDevicePaused: false)).spoken.contains("device running"))
    }

    func testFollowingACubeSaysTheFigureAloud() {
        // Said as well as drawn, for the reason the limit and the lock are: a duration is the one part of the line
        // that is never a colour, so it has to reach somebody reading it aloud.
        let title = title(onCube(category: category()))

        XCTAssertTrue(title.spoken.contains("0:00:00"), title.spoken)
    }

    func testFollowingACubeIsGreen() {
        // The previous app's colour and its meaning: green says this reading is live. Cyan would be a claim that
        // this app is the one recording, and here the cube is.
        let title = title(onCube(category: category(), isDevicePaused: true))

        XCTAssertEqual(title.colour, .systemGreen)
        XCTAssertEqual(title.nameColour, .systemGreen)
    }

    func testTheGlyphIsTheSameColourInBothPictures() {
        // The one piece of the line that does not change with which picture is on show, because what it reports --
        // whether a clock is going -- means the same in both.
        let onACube = title(onCube(category: category(), isDevicePaused: true))
        let byHand = title(TimingReadout.Reading(category: category(), state: .running, seconds: 60))

        XCTAssertEqual(onACube.glyphColour, .labelColor)
        XCTAssertEqual(byHand.glyphColour, .labelColor)
    }

    func testACubesFigureTurnsRedWhenTheLimitIsSpent() {
        // The limit is the cube's case as much as the app's -- `DailyLimitEnforcement` exists to pause a cube --
        // so the colour that goes with the pause has to reach this half of the line too.
        let reading = onCube(category: category(), isDevicePaused: true)

        XCTAssertEqual(title(reading, isLimitReached: true).colour, .systemRed)
        XCTAssertEqual(title(reading, isLimitReached: true).nameColour, .systemGreen)
    }

    func testACubeThatCannotBeHeardTurnsTheLineYellow() {
        // The archive's third answer: the last face is still worth drawing, and nothing about it can be confirmed
        // any more. The glyph is untouched, being the one colour that is the same in every state.
        let title = title(onCube(category: category(), isDevicePaused: true, isReachable: false))

        XCTAssertEqual(title.colour, .systemYellow)
        XCTAssertEqual(title.nameColour, .systemYellow)
        XCTAssertEqual(title.glyphColour, .labelColor)
    }

    func testYellowIsNotSharedWithTheLimitOrTheFlash() {
        // "A flat unknown yellow -- not a stale over-limit/low-battery color left over from before the drop." Both
        // of those are claims about a reading that has stopped being confirmable, so neither draws over it.
        let reading = onCube(category: category(), isDevicePaused: true, isReachable: false)

        XCTAssertEqual(title(reading, isLimitReached: true).colour, .systemYellow)
        XCTAssertEqual(title(reading, lowBattery: flashOn).nameColour, .systemYellow)
        XCTAssertEqual(title(reading, lowBattery: flashOff).nameColour, .systemYellow)
    }

    func testACubeThatCannotBeHeardSaysSoOutLoud() {
        // A colour is the whole of the signal on screen, so the state the yellow exists to report has to reach
        // somebody reading the item aloud. It is said where it is drawn: qualifying the cube's own state.
        let gone = title(onCube(category: category(), isDevicePaused: true, isReachable: false))

        XCTAssertEqual(gone.spoken, "Meeting, device paused, device unreachable, 0:00:00, Facet")
        XCTAssertFalse(title(onCube(category: category(), isDevicePaused: true)).spoken.contains("unreachable"))
    }

    func testALimitIsStillSaidWhileTheCubeIsOutOfReach() {
        // The yellow withdraws the claim that the cube's reading is current. It does not withdraw the limit, which
        // is a fact about `time_entry` -- so the red goes and the words stay.
        let gone = title(onCube(category: category(), isDevicePaused: true, isReachable: false), isLimitReached: true)

        XCTAssertTrue(gone.spoken.contains("daily limit reached"), gone.spoken)
    }

    func testACubesLimitIsSaidAloudAsWellAsColoured() {
        let title = title(onCube(category: category(), isDevicePaused: true), isLimitReached: true)

        XCTAssertTrue(title.spoken.contains("daily limit reached"), title.spoken)
    }

    func testAFaceWithNoCategoryFallsBackToTheAppsName() {
        // An unassigned face has nothing to name, so the item says whose it is rather than going blank.
        let title = title(onCube(category: nil))

        XCTAssertEqual(title.text, appLabel)
    }

    func testTheLockAndTheWarningStillShowWhileFollowingACube() {
        let title = title(onCube(category: category()), lowBattery: flashOn, isCubeLocked: true)

        XCTAssertEqual(title.lockGlyphName, "lock.fill")
        XCTAssertTrue(title.spoken.contains("device locked"), title.spoken)
        XCTAssertTrue(title.spoken.contains("low battery"), title.spoken)
    }
}
