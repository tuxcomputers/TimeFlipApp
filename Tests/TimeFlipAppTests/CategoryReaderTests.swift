@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers `CategoryReader`: which categories the list gets, in what order, and with what drawn against
/// them.
///
/// Run against the seeded categories in `database/007_category.sql`, because the three rules being tested
/// are about what those rows mean -- an *Unassigned* placeholder that is not a choice, retirement that
/// hides a category without deleting it, and insertion order.
@MainActor
final class CategoryReaderTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var categories: CategoryReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        categories = CategoryReader(connection: database.connection())
    }

    override func tearDown() {
        categories = nil
        database.remove()
        super.tearDown()
    }

    // MARK: - which rows

    func testTheSeededCategoriesAreListed() {
        let names = categories.activeCategories().map(\.name)

        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.contains("Break"))
        XCTAssertTrue(names.contains("Meeting"))
    }

    func testUnassignedIsNotOffered() {
        // Category 0 is what a face points at when it has no category: a placeholder, not something to
        // choose from a list.
        XCTAssertFalse(categories.activeCategories().contains { $0.name == "Unassigned" })
        XCTAssertFalse(categories.activeCategories().contains { $0.id == 0 })
    }

    func testARetiredCategoryDropsOut() {
        XCTAssertTrue(categories.activeCategories().contains { $0.name == "Break" }, "precondition")

        XCTAssertTrue(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))

        // Still in the table, so old time entries keep resolving; just not offered any more.
        XCTAssertFalse(categories.activeCategories().contains { $0.name == "Break" })
        XCTAssertEqual(
            database.string("SELECT category_name FROM category WHERE category_name = 'Break';"), "Break",
            "retiring must hide the row, not delete it"
        )
    }

    func testTheListIsInInsertionOrder() {
        let ids = categories.activeCategories().map(\.id)

        XCTAssertEqual(ids, ids.sorted(), "ordered by category_id, which is the order they were created in")
    }

    func testANewCategoryLandsAtTheEnd() {
        XCTAssertTrue(database.execute("INSERT INTO category (category_name) VALUES ('Zebra');"))

        // Alphabetically first of nothing, chronologically last: the order is the order they arrived, not
        // the order they sort in.
        XCTAssertEqual(categories.activeCategories().last?.name, "Zebra")
    }

    // MARK: - what is drawn against them

    func testACategoryCarriesItsIconAndColour() throws {
        let meeting = try XCTUnwrap(categories.activeCategories().first { $0.name == "Meeting" })

        XCTAssertEqual(meeting.iconName, "ic_meeting", "the artwork's filename, joined from the icon table")
        XCTAssertNotNil(meeting.colour, "colour 13 has a hex, so it resolves")
    }

    func testTheNoneIconAndNoneColourArriveAsNothingToDraw() throws {
        XCTAssertTrue(
            database.execute("INSERT INTO category (category_name, icon_id, colour_id) VALUES ('Bare', 0, 0);")
        )

        let bare = try XCTUnwrap(categories.activeCategories().first { $0.name == "Bare" })
        XCTAssertNil(bare.iconName, "icon 0 is the None sentinel, named \"None\" rather than left null")
        XCTAssertNil(bare.colour, "colour 0 has no hex of its own")
    }

    func testAColourThatNeedsAWhiteGlyphSaysSo() throws {
        // Maroon (colour 2) is seeded with white_lines = 1: dark enough to swallow a black icon.
        XCTAssertTrue(
            database.execute("INSERT INTO category (category_name, icon_id, colour_id) VALUES ('Dark', 1, 2);")
        )

        let dark = try XCTUnwrap(categories.activeCategories().first { $0.name == "Dark" })
        XCTAssertTrue(dark.usesWhiteLines)
    }

    // MARK: - the design rule

    func testARenamedCategoryIsSeenByTheNextRead() {
        XCTAssertTrue(
            database.execute("UPDATE category SET category_name = 'Standup' WHERE category_name = 'Meeting';")
        )

        XCTAssertTrue(
            categories.activeCategories().contains { $0.name == "Standup" },
            "read again rather than remembered, so an edit made elsewhere shows up"
        )
    }

    // MARK: - the hex parse

    func testHexParsing() {
        XCTAssertEqual(NSColor(hex: "#ff0000")?.redComponent, 1)
        XCTAssertEqual(NSColor(hex: "ff0000")?.redComponent, 1, "the leading hash is optional")
        XCTAssertEqual(NSColor(hex: "#00ff00")?.greenComponent, 1)
        XCTAssertNil(NSColor(hex: ""), "which is what a NULL device_hex reads as")
        XCTAssertNil(NSColor(hex: "#fff"), "three digits is not a form the colour table uses")
        XCTAssertNil(NSColor(hex: "#gggggg"))
    }
}
