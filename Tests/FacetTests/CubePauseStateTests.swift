@testable import FacetCore
import Testing

/// How the cube's pause state is drawn and spoken, which is now decided once.
///
/// **It was decided twice, identically, in two files.** `StatusItemTitle` and `TimingView` each held the same
/// switch over `CubePauseState` producing the same two SF Symbols, and each held its own wording. That is the
/// hazard `docs/state-reference.md` opens with: one fact asked in two places, taught something in one of them,
/// and nothing failing when they part. The menu bar and the Faces tab are drawing the same cube.
///
/// **These strings are interface rather than decoration.** `Tests/Scripted/57-cube-pause` reads `Device running`
/// off the Faces tab's glyph, because a symbol is one character to anything reading the accessibility tree and
/// "which one is showing" is exactly what a screen reader and a scripted check are both there to ask.
@Suite
struct CubePauseStateTests {
    @Test func testTheGlyphIsThePlayPausePair() {
        #expect(CubePauseState.paused.symbolName == "pause.fill")
        #expect(CubePauseState.running.symbolName == "play.fill")
    }

    @Test func testACubeThatHasNotSaidIsDrawnAsNothingAtAll() {
        // **Not a third glyph.** A picture for "we have not asked" would be a picture of a cube doing something,
        // and a reader cannot tell a guess from a reading once it is a symbol.
        #expect(CubePauseState.unknown.symbolName == nil)
        #expect(CubePauseState.unknown.spokenLabel == nil)
        #expect(CubePauseState.unknown.spokenFragment == nil)
    }

    @Test func testTheTwoSpokenFormsDifferOnlyInWhereTheySit() {
        // One is an accessibility label on its own control and starts a sentence; the other is joined into the
        // status item's longer description and does not. Same fact, two renderings, named so neither drifts.
        #expect(CubePauseState.paused.spokenLabel == "Device paused")
        #expect(CubePauseState.running.spokenLabel == "Device running")
        #expect(CubePauseState.paused.spokenFragment == "device paused")
        #expect(CubePauseState.running.spokenFragment == "device running")
    }

    @Test func testWhatTheCubeReportedBecomesTheState() {
        // The byte the cube answers with is a `Bool?`: absent means it has not said.
        #expect(CubePauseState(reported: true) == .paused)
        #expect(CubePauseState(reported: false) == .running)
        #expect(CubePauseState(reported: nil) == .unknown)
    }
}
