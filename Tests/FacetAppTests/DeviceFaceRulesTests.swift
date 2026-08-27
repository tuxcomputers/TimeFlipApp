@testable import FacetApp
import AppKit
import XCTest

/// Covers what a value on the `faces` characteristic means, and what colours a face is drawn in.
///
/// **The sample values are the cube's own.** `02` and `08` are what this hardware has actually sent
/// (`docs/timeflip2-firmware-evidence.sqlite`: the read answered `faces -> 02`, and the flips logged beside it),
/// which is why they appear here rather than a made-up 5.
final class DeviceFaceRulesTests: XCTestCase {
    private func category(colour: NSColor?, whiteLines: Bool = false) -> CategoryRecord {
        CategoryRecord(
            id: 7, name: "Deep Work", iconName: "ic_admin",
            colourID: 3, colour: colour, usesWhiteLines: whiteLines, dailyLimitMinutes: 0, isCategoryActive: true
        )
    }

    // MARK: - which face

    func testARealAnswerIsRead() {
        XCTAssertEqual(DeviceFaceRules.face(from: Data([0x02])), 2)
        XCTAssertEqual(DeviceFaceRules.face(from: Data([0x08])), 8)
    }

    func testBothEndsOfTheCubeAreFaces() {
        XCTAssertEqual(DeviceFaceRules.face(from: Data([0x01])), 1)
        XCTAssertEqual(DeviceFaceRules.face(from: Data([0x0C])), 12)
    }

    func testAValueOutsideTheCubeIsRefusedRatherThanClamped() {
        // 13 and 14 are the app's own faces and never come from a device, so a cube claiming one is not to be
        // believed -- and clamping it into range would put a category on screen for a face nobody named.
        XCTAssertNil(DeviceFaceRules.face(from: Data([0x00])))
        XCTAssertNil(DeviceFaceRules.face(from: Data([0x0D])))
        XCTAssertNil(DeviceFaceRules.face(from: Data([0xFF])))
    }

    func testNothingToReadIsNoFace() {
        XCTAssertNil(DeviceFaceRules.face(from: nil))
        XCTAssertNil(DeviceFaceRules.face(from: Data()))
    }

    func testTrailingBytesDoNotSpoilIt() {
        // The characteristic is declared as one byte. Whatever is behind it belongs to somebody else.
        XCTAssertEqual(DeviceFaceRules.face(from: Data([0x02, 0xFF, 0xFF])), 2)
    }

    func testTheCubeStopsWhereTheAppsOwnFacesBegin() {
        // The two halves of one fact, asserted together: the ceiling here is `ManualFace`'s floor, so a change to
        // either without the other shows up rather than quietly overlapping.
        XCTAssertEqual(DeviceFaceRules.reported.upperBound, ManualFace.highestDeviceFace)
        XCTAssertFalse(ManualFace.all.contains { DeviceFaceRules.reported.contains($0) })
    }

    // MARK: - what it is drawn in

    func testTheBodyTakesTheCategorysColour() {
        XCTAssertEqual(DeviceFaceRules.bodyColour(for: category(colour: .red)), .red)
    }

    func testAnUnlitFaceIsWhitePlastic() {
        // Both ways of having no colour, and they draw the same: a face holding nothing, and a category with no
        // colour of its own. Neither is lit, and an unlit cube is white.
        XCTAssertEqual(DeviceFaceRules.bodyColour(for: nil), .white)
        XCTAssertEqual(DeviceFaceRules.bodyColour(for: category(colour: nil)), .white)
    }

    func testTheLinesFlipToWhiteOnlyWhereTheRowSaysSo() {
        // Straight from `colour.white_lines`, so which colours flip is retuned by editing a row rather than by
        // changing code.
        XCTAssertEqual(DeviceFaceRules.lineColour(for: category(colour: .black, whiteLines: true)), .white)
        XCTAssertEqual(DeviceFaceRules.lineColour(for: category(colour: .yellow, whiteLines: false)), .black)
    }

    func testAnUnlitFaceKeepsItsBlackLines() {
        // White body, black lines: the fallbacks have to be legible *together*, and this is the pair that is drawn
        // most often -- eleven of the twelve faces are unassigned in a fresh database.
        XCTAssertEqual(DeviceFaceRules.lineColour(for: nil), .black)
        XCTAssertEqual(DeviceFaceRules.bodyColour(for: nil), .white)
    }
}
