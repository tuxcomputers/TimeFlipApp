@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers `CategoryStore`: which categories the list gets, in what order, what is drawn against them,
/// and what the two writes do.
///
/// Run against the seeded categories in `database/007_category.sql`, because the three rules being tested
/// are about what those rows mean -- an *Unassigned* placeholder that is not a choice, retirement that
/// hides a category without deleting it, and insertion order.
@MainActor
final class CategoryStoreTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var categories: CategoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        categories = CategoryStore(connection: database.connection())
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

    func testNumericNamesSortAsNumbersAndComeFirst() {
        for name in ["11", "Acme", "2", "10", "1", "3"] {
            XCTAssertTrue(database.execute("INSERT INTO category (category_name) VALUES ('\(name)');"))
        }

        let names = categories.activeCategories().map(\.name)
        XCTAssertEqual(
            Array(names.prefix(5)), ["1", "2", "3", "10", "11"],
            "a plain text sort interleaves these as 1, 10, 11, 2, 3, which reads as broken"
        )
        XCTAssertTrue(names.dropFirst(5).allSatisfy { Int($0) == nil }, "then the text names: \(names)")
    }

    func testANumberInsideANameSortsAsANumberToo() throws {
        for name in ["Acme-11", "Acme-2"] {
            XCTAssertTrue(database.execute("INSERT INTO category (category_name) VALUES ('\(name)');"))
        }

        let names = categories.activeCategories().map(\.name)
        XCTAssertLessThan(
            try XCTUnwrap(names.firstIndex(of: "Acme-2")), try XCTUnwrap(names.firstIndex(of: "Acme-11")),
            "Finder-style comparison, not a character-by-character one"
        )
    }

    func testCaseDoesNotDecideTheOrder() {
        XCTAssertTrue(database.execute("INSERT INTO category (category_name) VALUES ('admin');"))

        XCTAssertEqual(
            categories.activeCategories().map(\.name).first, "admin",
            "lowercase must not sort after every capitalised name"
        )
    }

    func testTwoRowsSharingANameAreBrokenOnID() {
        // Legitimate: a category created alongside retired namesakes. Left to an unstable sort, the list
        // could come back in a different order each time it was read.
        let first = CategoryRecord(id: 4, name: "Reading", iconName: nil, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true)
        let second = CategoryRecord(id: 9, name: "Reading", iconName: nil, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true)

        XCTAssertTrue(CategoryRecord.displayOrder(first, second))
        XCTAssertFalse(CategoryRecord.displayOrder(second, first))
    }

    func testTheSameNumberWrittenTwoWaysStillOrdersStably() {
        let padded = CategoryRecord(id: 9, name: "01", iconName: nil, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true)
        let plain = CategoryRecord(id: 4, name: "1", iconName: nil, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true)

        // Equal as numbers and equal to localizedStandardCompare, so the id decides.
        XCTAssertTrue(CategoryRecord.displayOrder(plain, padded))
        XCTAssertFalse(CategoryRecord.displayOrder(padded, plain))
    }

    func testANewCategoryLandsInItsPlaceRatherThanAtTheBottom() {
        // The behaviour this replaced: the old list appended, so a new category arrived below everything
        // whatever it was called.
        XCTAssertTrue(database.execute("INSERT INTO category (category_name) VALUES ('Aardvark');"))

        XCTAssertEqual(categories.activeCategories().first?.name, "Aardvark")
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

    // MARK: - looking a name up

    func testMatchingFindsEveryCategoryHoldingAName() {
        XCTAssertTrue(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))
        XCTAssertTrue(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))

        XCTAssertEqual(categories.matching(name: "Reading").count, 2, "both retired namesakes, not just the first")
    }

    func testMatchingIsCaseInsensitive() {
        // Same collation as the unique index that bars a second active namesake, so the check cannot pass
        // a name the insert then refuses.
        XCTAssertEqual(categories.matching(name: "break").map(\.name), ["Break"])
        XCTAssertEqual(categories.matching(name: "BREAK").map(\.name), ["Break"])
    }

    func testMatchingPutsTheActiveOneFirst() throws {
        XCTAssertTrue(database.execute("INSERT INTO category (category_name, active) VALUES ('Break', 0);"))

        // What the rules rely on to decide from `matches.first` alone.
        let matches = categories.matching(name: "Break")
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(try XCTUnwrap(matches.first).isActive)
    }

    func testMatchingNothingFindsNothing() {
        XCTAssertTrue(categories.matching(name: "Nonexistent").isEmpty)
        XCTAssertTrue(categories.matching(name: "").isEmpty)
    }

    // MARK: - writing

    func testInsertCreatesAnActiveCategoryWithNoIconOrColour() throws {
        let id = try XCTUnwrap(categories.insert(name: "Deep Work"))

        let created = try XCTUnwrap(categories.activeCategories().first { $0.id == id })
        XCTAssertEqual(created.name, "Deep Work")
        XCTAssertNil(created.iconName, "named first, dressed later")
        XCTAssertNil(created.colour)
        XCTAssertTrue(created.isActive)
    }

    func testInsertIsRefusedForANameAnActiveCategoryHolds() {
        // The unique index over active names, which is the last thing standing between a typo and two
        // identical categories. The rules check first, but the index is what actually enforces it.
        XCTAssertNil(categories.insert(name: "Break"))
        XCTAssertEqual(categories.activeCategories().filter { $0.name == "Break" }.count, 1)
    }

    func testInsertIsAllowedAlongsideARetiredNamesake() throws {
        XCTAssertTrue(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))

        XCTAssertNotNil(categories.insert(name: "Reading"), "only an active namesake bars a name")
    }

    func testReactivateBringsARetiredCategoryBack() {
        XCTAssertTrue(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))
        let retired = categories.matching(name: "Break")
        XCTAssertEqual(retired.count, 1, "precondition")

        XCTAssertTrue(categories.reactivate(id: retired[0].id))

        XCTAssertTrue(categories.activeCategories().contains { $0.name == "Break" })
    }

    func testReactivateIsRefusedWhenAnActiveCategoryHasTakenTheName() throws {
        // Retire Break, then create a new active Break. The retired row cannot come back under a name
        // that is now in use -- and being refused is the point, not a crash and not a silent success.
        XCTAssertTrue(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))
        let retiredID = try XCTUnwrap(categories.matching(name: "Break").first?.id)
        XCTAssertNotNil(categories.insert(name: "Break"))

        XCTAssertFalse(categories.reactivate(id: retiredID))
    }

    // MARK: - retiring

    func testRetiringTakesACategoryOutOfTheActiveList() throws {
        let id = try XCTUnwrap(categories.activeCategories().first { $0.name == "Break" }?.id)

        XCTAssertTrue(categories.setActive(id: id, false))

        XCTAssertFalse(categories.activeCategories().contains { $0.name == "Break" })
        // The row stays, which is the point of the column rather than a delete: every `time_entry` recorded against
        // it still has to resolve.
        XCTAssertEqual(categories.category(id: id)?.isActive, false)
        XCTAssertEqual(categories.category(id: id)?.name, "Break")
    }

    func testRetiringACategoryThatIsNotThereIsRefused() {
        XCTAssertFalse(categories.setActive(id: 9_999, false))
    }

    // MARK: - the daily limit

    func testEveryCategoryStartsWithNoDailyLimit() throws {
        // Zero is the seeded value and means no limit at all, rather than a limit of nothing.
        XCTAssertEqual(categories.activeCategories().map(\.dailyLimitMinutes).allSatisfy { $0 == 0 }, true)
    }

    func testSettingTheDailyLimitIsReadBack() throws {
        let id = try XCTUnwrap(categories.activeCategories().first?.id)

        XCTAssertTrue(categories.setDailyLimit(id: id, minutes: 90))

        XCTAssertEqual(categories.category(id: id)?.dailyLimitMinutes, 90)
    }

    func testSettingTheDailyLimitOfACategoryThatIsNotThereIsRefused() {
        XCTAssertFalse(categories.setDailyLimit(id: 9_999, minutes: 30))
    }
}
