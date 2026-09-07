@testable import FacetCore
import Foundation
import Testing

/// Covers `ColourStore`: which rows of the palette a picker is offered, and in what order.
///
/// Run against the seeded `colour` table (`database/005_colour.sql`), because what is being tested is what those rows
/// mean: a *None* sentinel that is not a colour to choose, and a hex that has to parse before a square can be drawn.
@Suite @MainActor
final class ColourStoreTests {
    private let database: TemporaryDatabase
    private var colours: ColourStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        colours = ColourStore(connection: database.connection())
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    @Test func testTheSeededPaletteIsOffered() {
        let names = colours.all().map(\.name)

        #expect(names.contains("Red"))
        #expect(names.contains("Navy"))
    }

    @Test func testNoneIsNotOffered() {
        // `colour_id` 0 is how a category with no colour is stored, not a colour to pick. Clearing one is done by
        // re-clicking what is already set (`CategoryEditRules.colourSelection`).
        #expect(!(colours.all().contains { $0.id == 0 }))
        #expect(!(colours.all().contains { $0.name == "None" }))
    }

    @Test func testTheOrderIsThePalettesOwn() {
        // The ids are a wheel somebody arranged rather than an alphabet, so they come back in id order.
        let ids = colours.all().map(\.id)

        #expect(ids == ids.sorted())
        #expect(colours.all().first?.name == "Red")
    }

    @Test func testTheHexBecomesTheColourItNames() throws {
        let navy = try #require(colours.all().first { $0.name == "Navy" })

        let rgb = navy.colour
#expect(rgb.red.isApproximately(0))
        #expect(rgb.green.isApproximately(0))
        #expect(rgb.blue.isApproximately(128.0 / 255), "#000080")
    }

    @Test func testWhiteLinesComesStraightFromTheRow() throws {
        // What decides whether an icon drawn on this colour is white or black. Navy is dark enough to swallow a black
        // glyph; Yellow is not.
        #expect(try #require(colours.all().first { $0.name == "Navy" }).usesWhiteLines)
        #expect(try !(#require(colours.all().first { $0.name == "Yellow" }).usesWhiteLines))
    }

    @Test func testAColourWithNoUsableHexIsLeftOut() throws {
        // A palette entry that cannot say what colour it is has nothing to offer a picker, and guessing one would put
        // a colour on screen the device would never light.
        #expect(database.execute("UPDATE colour SET device_hex = NULL WHERE colour_name = 'Teal';"))
        #expect(database.execute("UPDATE colour SET device_hex = 'nonsense' WHERE colour_name = 'Olive';"))

        let names = colours.all().map(\.name)
        #expect(!(names.contains("Teal")))
        #expect(!(names.contains("Olive")))
        #expect(names.contains("Green"), "and the rest of the palette is unaffected")
    }
}
