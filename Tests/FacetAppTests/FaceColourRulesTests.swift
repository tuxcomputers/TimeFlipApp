@testable import FacetApp
import AppKit
import XCTest

/// Covers what `0x11` carries: the eight bytes, the scaling into them, and what a face with no colour is sent.
///
/// **The scaling is the part worth pinning.** The palette stores eight bits a channel and the command takes sixteen,
/// so a colour sent un-scaled lights a face at roughly nothing rather than at the colour asked for, and nothing on the
/// device side would report it: there is no read-back for this command at all.
@MainActor
final class FaceColourRulesTests: XCTestCase {
    private func wanted(_ face: Int, _ hex: String?) -> FaceColour {
        FaceColour(face: face, categoryName: nil, colour: hex.flatMap(NSColor.init(hex:)))
    }

    func testTheCommandIsTheVendorsEightBytes() {
        // `0x11 NN RR RR GG GG BB BB`, high byte of each channel first. The archive's `setFaceColor` writes exactly
        // these eight, and the spec's Tab. 1 names them.
        XCTAssertEqual(
            FaceColourRules.command(for: wanted(3, "#ff0000")),
            Data([0x11, 3, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(
            FaceColourRules.command(for: wanted(12, "#0000ff")),
            Data([0x11, 12, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        )
    }

    func testEightBitsPerChannelBecomesSixteen() {
        // 0xFF scales to 0xFFFF rather than to 0x00FF, which is the whole of what the scaling is for. Half brightness
        // is the case that catches a shift used where a multiply was meant: 0x80 is 128/255, which is 0x8080.
        XCTAssertEqual(FaceColourRules.channels(of: NSColor(hex: "#ffffff")).red, 65_535)
        XCTAssertEqual(FaceColourRules.channels(of: NSColor(hex: "#808080")).green, 0x8080)
        XCTAssertEqual(FaceColourRules.channels(of: NSColor(hex: "#000000")).blue, 0)
    }

    func testAFaceWithNoColourIsSentBlack() {
        // The archive's rule and its reasoning: `0x11` takes an RGB triple with no separate enable, so all-zero is the
        // only way to say off. Leaving the last colour lit would make clearing one mean nothing on the cube.
        XCTAssertEqual(
            FaceColourRules.command(for: wanted(5, nil)),
            Data([0x11, 5, 0, 0, 0, 0, 0, 0])
        )
    }

    func testTheFacesAreTheOnesACubeHas() {
        // The same 1 to 12 the cube reports, not a second copy of the number. Manual mode's faces are above it
        // deliberately, being faces that exist because no cube does.
        XCTAssertEqual(FaceColourRules.faces, DeviceFaceRules.reported)
        XCTAssertFalse(FaceColourRules.faces.contains(ManualFace.all[0]))
    }

    func testARowSaysBothFormsOfTheColour() {
        // The hex to compare against the palette, and the triple that actually went out, so a scaling problem is
        // visible rather than inferred. The archive logged both for that reason.
        let described = FaceColourRules.describe(
            FaceColour(face: 2, categoryName: "Meeting", colour: NSColor(hex: "#ff0000"))
        )

        XCTAssertEqual(described, "face 2 Meeting #ff0000 as rgb16 ffff,0000,0000")
    }

    func testARowForAFaceHoldingNothingSaysSo() {
        // Both halves are absent and both are named: a blank would read as a row that failed to fill itself in.
        XCTAssertEqual(
            FaceColourRules.describe(FaceColour(face: 7, categoryName: nil, colour: nil)),
            "face 7 no category off as rgb16 0000,0000,0000"
        )
    }

}
