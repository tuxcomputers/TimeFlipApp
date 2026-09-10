#if canImport(CGtk)
import Foundation
import Testing
@testable import FacetCore
@testable import FacetLinux

/// What `FacetLinux.MenuBar` draws a `StatusItemTitle` as.
///
/// **The whole of what that file still decides.** Everything else about the line moved into `StatusItemReadout`
/// and `StatusItemTitle` on 2026-09-11; what is left is rendering, and it is rendering with two real decisions in
/// it: a Mac's SF Symbol is a character here, and a panel label is plain text so a category's icon and the line's
/// colour are simply not drawn.
///
/// **The colours are not lost, which is worth stating rather than implying.** They are still decided, and the
/// readout still writes them to `debug_log` -- which is the only way a scripted check has ever seen them on either
/// platform, the accessibility tree carrying no colour at all.
@Suite @MainActor
struct MenuBarLineTests {
    private func category(_ name: String = "Meeting") -> CategoryRecord {
        CategoryRecord(
            id: 2, name: name, iconName: "meeting", colourID: 0, colour: SampleColour.blue,
            usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true
        )
    }

    private func title(
        _ reading: TimingReadout.Reading,
        showingSeconds: Bool = true,
        cubeLockState: CubeLockState = .unknown,
        isConnecting: Bool = false
    ) -> StatusItemTitle {
        StatusItemTitle.make(
            appLabel: "Facet",
            reading: reading,
            showingSeconds: showingSeconds,
            isLimitReached: false,
            lowBattery: .none,
            cubeLockState: cubeLockState,
            isConnecting: isConnecting
        )
    }

    @Test func testNothingBeingTimedIsJustTheAppName() {
        // No figure, because a "0:00" with nothing behind it reads as a session that has started and got nowhere.
        #expect(MenuBar.line(title(.idle)) == "Facet")
    }

    @Test func testARunningSessionCarriesItsGlyphAndItsFigure() {
        let running = TimingReadout.Reading(category: category(), timingState: .running, seconds: 90)

        #expect(MenuBar.line(title(running)) == "\u{25B6} Meeting 0:01:30")
    }

    @Test func testAPausedSessionCarriesTheOtherGlyph() {
        let paused = TimingReadout.Reading(category: category(), timingState: .paused, seconds: 90)

        #expect(MenuBar.line(title(paused)).hasPrefix("\u{23F8} "))
    }

    @Test func testTheSecondsSettingIsHonouredBecauseTheCoreDecidedIt() {
        // Nothing here formats a duration: `StatusItemTitle` does, from the setting, and this only draws what it
        // answered. The check is that the answer travels rather than being re-derived.
        let running = TimingReadout.Reading(category: category(), timingState: .running, seconds: 90)

        #expect(MenuBar.line(title(running, showingSeconds: false)) == "\u{25B6} Meeting 0:01")
    }

    @Test func testALockedCubeGetsAPadlockInFrontOfEverything() {
        // **Beside the glyph rather than in place of it**, which is the archive's rule: whether the cube is still
        // timing or stopped stays worth seeing while it is locked.
        let running = TimingReadout.Reading(category: category(), timingState: .running, seconds: 90)

        let line = MenuBar.line(title(running, cubeLockState: .locked))

        #expect(line.hasPrefix("\u{1F512} "))
        #expect(line.contains("\u{25B6}"), "and the play glyph is still there")
    }

    @Test func testReachingForTheCubeSaysSoRatherThanLookingIdle() {
        // The one state that is on screen only until a cube answers, which is no time at all to be watching a
        // panel -- and the reason the readout writes a `reaching` row for it as well.
        #expect(MenuBar.line(title(.idle, isConnecting: true)) == StatusItemTitle.connecting)
    }

    @Test func testAGlyphThisPlatformHasNoCharacterForDrawsNothing() {
        // Rather than its own name. A log row falls back to a bare UUID because a reader can look one up; a panel
        // cannot show `play.fill` to somebody without it reading as a fault.
        let unknown = StatusItemTitle(
            text: "Meeting",
            iconName: nil,
            glyphName: "sparkles",
            lockGlyphName: nil,
            duration: "0:01",
            colour: .cube,
            nameColour: .cube,
            glyphColour: .cube,
            spoken: "Meeting"
        )

        #expect(MenuBar.line(unknown) == "Meeting 0:01")
    }
}
#endif
