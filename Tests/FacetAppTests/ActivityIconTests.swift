@testable import FacetApp
import AppKit
import XCTest

/// Covers loading the bundled artwork, and recolouring the one piece of it that is recoloured.
///
/// **The substitution is a string match, and that is the fragile part worth pinning.** `colouredImage` reaches inside
/// the SVG by replacing two placeholder colours, so artwork resaved from a drawing tool that moves `fill="..."` into
/// a `style` attribute would stop being recoloured -- with no error anywhere, just a magenta-lined cube on the Faces
/// tab. These tests fail at the moment the artwork stops carrying what the code looks for, which is a good deal
/// earlier than somebody noticing the colour.
@MainActor
final class ActivityIconTests: XCTestCase {
    private func svg(named name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "svg")
                ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/UI"),
            "\(name).svg is not in the bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheDeviceArtworkStillCarriesBothPlaceholders() throws {
        let artwork = try svg(named: TimingView.deviceArtwork)

        XCTAssertEqual(
            artwork.components(separatedBy: ActivityIcon.Placeholder.fill).count - 1, 1,
            "the body is what takes the face's colour, and it is substituted by exact text"
        )
        XCTAssertEqual(
            artwork.components(separatedBy: ActivityIcon.Placeholder.ink).count - 1, 1,
            "the inner lines are what takes the ink, and they are substituted by exact text"
        )
    }

    func testTheOutlineAndTheRingAreNotRecoloured() throws {
        let artwork = try svg(named: TimingView.deviceArtwork)

        // The two colours the artwork keeps whatever face is up: the outline stays black so the shape reads against
        // the window, and the ring stays the app's own red. Neither is a placeholder, which is the whole of what
        // stops them being substituted.
        XCTAssertTrue(artwork.contains("stroke=\"#000000\""), "the outer outline is authored black")
        XCTAssertTrue(artwork.contains("#e83a43"), "the ring is authored in the app icon's red")
    }

    func testRecolouringProducesAnImage() throws {
        // Renders through AppKit, which is the half of this that no amount of string checking covers: the
        // substituted text still has to parse as an SVG.
        let image = try XCTUnwrap(
            ActivityIcon.colouredImage(
                named: TimingView.deviceArtwork, pointSize: 128, fill: .systemBlue, ink: .white
            )
        )

        XCTAssertEqual(image.size, NSSize(width: 128, height: 128))
        XCTAssertTrue(image.isValid)
    }

    func testRecolouringIsNotTemplateRendering() throws {
        // The distinction the whole method exists for: a template keeps only the alpha and floods the shape with one
        // tint, which would swallow the lines and the ring. This has to come back as real artwork.
        let coloured = try XCTUnwrap(
            ActivityIcon.colouredImage(named: TimingView.deviceArtwork, pointSize: 64, fill: .red)
        )
        let template = try XCTUnwrap(ActivityIcon.image(named: TimingView.deviceArtwork, pointSize: 64))

        XCTAssertFalse(coloured.isTemplate)
        XCTAssertTrue(template.isTemplate)
    }

    func testArtworkThatIsNotThereIsNil() {
        XCTAssertNil(ActivityIcon.colouredImage(named: "ic_not_a_real_icon", pointSize: 64, fill: .red))
        XCTAssertNil(ActivityIcon.colouredImage(named: "  ", pointSize: 64, fill: .red))
    }
}
