@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers `ColourStore`: which rows of the palette a picker is offered, and in what order.
///
/// Run against the seeded `colour` table (`database/005_colour.sql`), because what is being tested is what those rows
/// mean: a *None* sentinel that is not a colour to choose, and a hex that has to parse before a square can be drawn.
@MainActor
final class ColourStoreTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var colours: ColourStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        colours = ColourStore(connection: database.connection())
    }

    override func tearDown() {
        colours = nil
        database.remove()
        super.tearDown()
    }

    func testTheSeededPaletteIsOffered() {
        let names = colours.all().map(\.name)

        XCTAssertTrue(names.contains("Red"))
        XCTAssertTrue(names.contains("Navy"))
    }

    func testNoneIsNotOffered() {
        // `colour_id` 0 is how a category with no colour is stored, not a colour to pick. Clearing one is done by
        // re-clicking what is already set (`CategoryEditRules.colourSelection`).
        XCTAssertFalse(colours.all().contains { $0.id == 0 })
        XCTAssertFalse(colours.all().contains { $0.name == "None" })
    }

    func testTheOrderIsThePalettesOwn() {
        // The ids are a wheel somebody arranged rather than an alphabet, so they come back in id order.
        let ids = colours.all().map(\.id)

        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(colours.all().first?.name, "Red")
    }

    func testTheHexBecomesTheColourItNames() throws {
        let navy = try XCTUnwrap(colours.all().first { $0.name == "Navy" })

        let rgb = try XCTUnwrap(navy.colour.usingColorSpace(.sRGB))
        XCTAssertEqual(rgb.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(rgb.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(rgb.blueComponent, 128.0 / 255, accuracy: 0.001, "#000080")
    }

    func testWhiteLinesComesStraightFromTheRow() throws {
        // What decides whether an icon drawn on this colour is white or black. Navy is dark enough to swallow a black
        // glyph; Yellow is not.
        XCTAssertTrue(try XCTUnwrap(colours.all().first { $0.name == "Navy" }).usesWhiteLines)
        XCTAssertFalse(try XCTUnwrap(colours.all().first { $0.name == "Yellow" }).usesWhiteLines)
    }

    func testAColourWithNoUsableHexIsLeftOut() throws {
        // A palette entry that cannot say what colour it is has nothing to offer a picker, and guessing one would put
        // a colour on screen the device would never light.
        XCTAssertTrue(database.execute("UPDATE colour SET device_hex = NULL WHERE colour_name = 'Teal';"))
        XCTAssertTrue(database.execute("UPDATE colour SET device_hex = 'nonsense' WHERE colour_name = 'Olive';"))

        let names = colours.all().map(\.name)
        XCTAssertFalse(names.contains("Teal"))
        XCTAssertFalse(names.contains("Olive"))
        XCTAssertTrue(names.contains("Green"), "and the rest of the palette is unaffected")
    }
}
