@testable import FacetCore
import Foundation
import Testing

/// Covers `CategoryStore`: which categories the list gets, in what order, what is drawn against them,
/// and what the two writes do.
///
/// Run against the seeded categories in `database/007_category.sql`, because the three rules being tested
/// are about what those rows mean -- an *Unassigned* placeholder that is not a choice, retirement that
/// hides a category without deleting it, and insertion order.
@Suite @MainActor
final class CategoryStoreTests {
    private let database: TemporaryDatabase
    private var categories: CategoryStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        categories = CategoryStore(connection: database.connection())
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    // MARK: - which rows

    @Test func testTheSeededCategoriesAreListed() {
        let names = categories.activeCategories().map(\.name)

        #expect(!(names.isEmpty))
        #expect(names.contains("Break"))
        #expect(names.contains("Meeting"))
    }

    @Test func testUnassignedIsNotOffered() {
        // Category 0 is what a face points at when it has no category: a placeholder, not something to
        // choose from a list.
        #expect(!(categories.activeCategories().contains { $0.name == "Unassigned" }))
        #expect(!(categories.activeCategories().contains { $0.id == 0 }))
    }

    @Test func testARetiredCategoryDropsOut() {
        #expect(categories.activeCategories().contains { $0.name == "Break" }, "precondition")

        #expect(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))

        // Still in the table, so old time entries keep resolving; just not offered any more.
        #expect(!(categories.activeCategories().contains { $0.name == "Break" }))
        #expect(
            database.string("SELECT category_name FROM category WHERE category_name = 'Break';") == "Break",
            "retiring must hide the row, not delete it"
        )
    }

    @Test func testNumericNamesSortAsNumbersAndComeFirst() {
        for name in ["11", "Acme", "2", "10", "1", "3"] {
            #expect(database.execute("INSERT INTO category (category_name) VALUES ('\(name)');"))
        }

        let names = categories.activeCategories().map(\.name)
        #expect(
            Array(names.prefix(5)) == ["1", "2", "3", "10", "11"],
            "a plain text sort interleaves these as 1, 10, 11, 2, 3, which reads as broken"
        )
        #expect(names.dropFirst(5).allSatisfy { Int($0) == nil }, "then the text names: \(names)")
    }

    @Test func testANumberInsideANameSortsAsANumberToo() throws {
        for name in ["Acme-11", "Acme-2"] {
            #expect(database.execute("INSERT INTO category (category_name) VALUES ('\(name)');"))
        }

        let names = categories.activeCategories().map(\.name)
let acme2 = try #require(names.firstIndex(of: "Acme-2"))
        let acme11 = try #require(names.firstIndex(of: "Acme-11"))
        // Hoisted rather than written inline: `try` may not sit to the right of an operator, so
        // `#expect(a < try #require(b))` is refused where the XCTest form was fine.
        #expect(acme2 < acme11, "Finder-style comparison, not a character-by-character one")
    }

    @Test func testCaseDoesNotDecideTheOrder() {
        #expect(database.execute("INSERT INTO category (category_name) VALUES ('admin');"))

        #expect(
            categories.activeCategories().map(\.name).first == "admin",
            "lowercase must not sort after every capitalised name"
        )
    }

    @Test func testTwoRowsSharingANameAreBrokenOnID() {
        // Legitimate: a category created alongside retired namesakes. Left to an unstable sort, the list
        // could come back in a different order each time it was read.
        let first = CategoryRecord(id: 4, name: "Reading", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)
        let second = CategoryRecord(id: 9, name: "Reading", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)

        #expect(CategoryRecord.displayOrder(first, second))
        #expect(!(CategoryRecord.displayOrder(second, first)))
    }

    @Test func testTheSameNumberWrittenTwoWaysStillOrdersStably() {
        let padded = CategoryRecord(id: 9, name: "01", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)
        let plain = CategoryRecord(id: 4, name: "1", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isCategoryActive: true)

        // Equal as numbers and equal to localizedStandardCompare, so the id decides.
        #expect(CategoryRecord.displayOrder(plain, padded))
        #expect(!(CategoryRecord.displayOrder(padded, plain)))
    }

    @Test func testANewCategoryLandsInItsPlaceRatherThanAtTheBottom() {
        // The behaviour this replaced: the old list appended, so a new category arrived below everything
        // whatever it was called.
        #expect(database.execute("INSERT INTO category (category_name) VALUES ('Aardvark');"))

        #expect(categories.activeCategories().first?.name == "Aardvark")
    }

    // MARK: - what is drawn against them

    @Test func testACategoryCarriesItsIconAndColour() throws {
        let meeting = try #require(categories.activeCategories().first { $0.name == "Meeting" })

        #expect(meeting.iconName == "ic_meeting", "the artwork's filename, joined from the icon table")
        #expect(meeting.colour != nil, "colour 13 has a hex, so it resolves")
    }

    @Test func testTheNoneIconAndNoneColourArriveAsNothingToDraw() throws {
        #expect(database.execute("INSERT INTO category (category_name, icon_id, colour_id) VALUES ('Bare', 0, 0);"))

        let bare = try #require(categories.activeCategories().first { $0.name == "Bare" })
        #expect(bare.iconName == nil, "icon 0 is the None sentinel, named \"None\" rather than left null")
        #expect(bare.colour == nil, "colour 0 has no hex of its own")
    }

    @Test func testAColourThatNeedsAWhiteGlyphSaysSo() throws {
        // Maroon (colour 2) is seeded with white_lines = 1: dark enough to swallow a black icon.
        #expect(database.execute("INSERT INTO category (category_name, icon_id, colour_id) VALUES ('Dark', 1, 2);"))

        let dark = try #require(categories.activeCategories().first { $0.name == "Dark" })
        #expect(dark.usesWhiteLines)
    }

    // MARK: - the design rule

    @Test func testARenamedCategoryIsSeenByTheNextRead() {
        #expect(database.execute("UPDATE category SET category_name = 'Standup' WHERE category_name = 'Meeting';"))

        #expect(
            categories.activeCategories().contains { $0.name == "Standup" },
            "read again rather than remembered, so an edit made elsewhere shows up"
        )
    }

    // MARK: - the hex parse

    @Test func testHexParsing() {
        #expect(Colour(hex: "#ff0000")?.red == 1)
        #expect(Colour(hex: "ff0000")?.red == 1, "the leading hash is optional")
        #expect(Colour(hex: "#00ff00")?.green == 1)
        #expect(Colour(hex: "") == nil, "which is what a NULL device_hex reads as")
        #expect(Colour(hex: "#fff") == nil, "three digits is not a form the colour table uses")
        #expect(Colour(hex: "#gggggg") == nil)
    }

    // MARK: - looking a name up

    @Test func testMatchingFindsEveryCategoryHoldingAName() {
        #expect(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))
        #expect(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))

        #expect(categories.matching(name: "Reading").count == 2, "both retired namesakes, not just the first")
    }

    @Test func testMatchingIsCaseInsensitive() {
        // Same collation as the unique index that bars a second active namesake, so the check cannot pass
        // a name the insert then refuses.
        #expect(categories.matching(name: "break").map(\.name) == ["Break"])
        #expect(categories.matching(name: "BREAK").map(\.name) == ["Break"])
    }

    @Test func testMatchingPutsTheActiveOneFirst() throws {
        #expect(database.execute("INSERT INTO category (category_name, active) VALUES ('Break', 0);"))

        // What the rules rely on to decide from `matches.first` alone.
        let matches = categories.matching(name: "Break")
        #expect(matches.count == 2)
        #expect(try #require(matches.first).isCategoryActive)
    }

    @Test func testMatchingNothingFindsNothing() {
        #expect(categories.matching(name: "Nonexistent").isEmpty)
        #expect(categories.matching(name: "").isEmpty)
    }

    // MARK: - writing

    @Test func testInsertCreatesAnActiveCategoryWithNoIconOrColour() throws {
        let id = try #require(categories.insert(name: "Deep Work"))

        let created = try #require(categories.activeCategories().first { $0.id == id })
        #expect(created.name == "Deep Work")
        #expect(created.iconName == nil, "named first, dressed later")
        #expect(created.colour == nil)
        #expect(created.isCategoryActive)
    }

    @Test func testInsertIsRefusedForANameAnActiveCategoryHolds() {
        // The unique index over active names, which is the last thing standing between a typo and two
        // identical categories. The rules check first, but the index is what actually enforces it.
        #expect(categories.insert(name: "Break") == nil)
        #expect(categories.activeCategories().filter { $0.name == "Break" }.count == 1)
    }

    @Test func testInsertIsAllowedAlongsideARetiredNamesake() throws {
        #expect(database.execute("INSERT INTO category (category_name, active) VALUES ('Reading', 0);"))

        #expect(categories.insert(name: "Reading") != nil, "only an active namesake bars a name")
    }

    @Test func testReactivateBringsARetiredCategoryBack() {
        #expect(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))
        let retired = categories.matching(name: "Break")
        #expect(retired.count == 1, "precondition")

        #expect(categories.reactivate(id: retired[0].id))

        #expect(categories.activeCategories().contains { $0.name == "Break" })
    }

    @Test func testReactivateIsRefusedWhenAnActiveCategoryHasTakenTheName() throws {
        // Retire Break, then create a new active Break. The retired row cannot come back under a name
        // that is now in use -- and being refused is the point, not a crash and not a silent success.
        #expect(database.execute("UPDATE category SET active = 0 WHERE category_name = 'Break';"))
        let retiredID = try #require(categories.matching(name: "Break").first?.id)
        #expect(categories.insert(name: "Break") != nil)

        #expect(!(categories.reactivate(id: retiredID)))
    }

    // MARK: - retiring

    @Test func testRetiringTakesACategoryOutOfTheActiveList() throws {
        let id = try #require(categories.activeCategories().first { $0.name == "Break" }?.id)

        #expect(categories.setActive(id: id, false))

        #expect(!(categories.activeCategories().contains { $0.name == "Break" }))
        // The row stays, which is the point of the column rather than a delete: every `time_entry` recorded against
        // it still has to resolve.
        #expect(categories.category(id: id)?.isCategoryActive == false)
        #expect(categories.category(id: id)?.name == "Break")
    }

    @Test func testARetiredCategoryMovesToTheInactiveList() throws {
        let id = try #require(categories.activeCategories().first { $0.name == "Break" }?.id)
        #expect(!(categories.inactiveCategories().contains { $0.id == id }), "precondition")

        #expect(categories.setActive(id: id, false))

        #expect(categories.inactiveCategories().map(\.name) == ["Break"])
        #expect(categories.inactiveCategories().first?.isCategoryActive == false)
    }

    @Test func testTheInactiveListLeavesUnassignedOutToo() throws {
        // Id 0 is the placeholder a face points at when it holds nothing, not a category anybody retired -- and it is
        // seeded inactive, so a list that only asked `active = 0` would show it.
        #expect(database.execute("UPDATE category SET active = 0 WHERE category_id = 0;"))

        #expect(!(categories.inactiveCategories().contains { $0.id == 0 }))
    }

    @Test func testRetiringACategoryThatIsNotThereIsRefused() {
        #expect(!(categories.setActive(id: 9_999, false)))
    }

    // MARK: - the daily limit

    @Test func testEveryCategoryStartsWithNoDailyLimit() throws {
        // Zero is the seeded value and means no limit at all, rather than a limit of nothing.
        #expect(categories.activeCategories().map(\.dailyLimitMinutes).allSatisfy { $0 == 0 } == true)
    }

    @Test func testSettingTheDailyLimitIsReadBack() throws {
        let id = try #require(categories.activeCategories().first?.id)

        #expect(categories.setDailyLimit(id: id, minutes: 90))

        #expect(categories.category(id: id)?.dailyLimitMinutes == 90)
    }

    @Test func testSettingTheDailyLimitOfACategoryThatIsNotThereIsRefused() {
        #expect(!(categories.setDailyLimit(id: 9_999, minutes: 30)))
    }

    @Test func testTheUnassignedSentinelCannotBeGivenADailyLimit() {
        // `category_id` 0 is what a face points at when it holds nothing, rather than a category anybody chose. A
        // budget on it would be a budget on the absence of an activity, and a hard limit reaching it would pause the
        // cube for not being used.
        //
        // Carried over from the archive, which guarded all five of its category writers this way and tested each one.
        // So does this app, as of 2026-08-16: `setName`, `setDailyLimit`, and the three below.
        #expect(!(categories.setDailyLimit(id: 0, minutes: 30)))
        #expect(categories.category(id: 0)?.dailyLimitMinutes == 0)
    }

    @Test func testTheUnassignedSentinelCannotBeRetired() {
        // Retiring it would take the empty answer out of the list every face needs to be able to fall back to, while
        // the row itself went on sitting under every face pointing at it.
        #expect(!(categories.setActive(id: 0, false)))
        #expect(categories.category(id: 0)?.isCategoryActive == true)
    }

    @Test func testTheUnassignedSentinelCannotBeGivenArtwork() {
        // A face holding nothing is drawn from this row, so an icon on it would put a picture on every empty face.
        #expect(!(categories.setIcon(id: 0, iconID: 1)))
        #expect(categories.category(id: 0)?.iconName == nil)
    }

    @Test func testTheUnassignedSentinelCannotBeGivenAColour() {
        // The same reason as the icon, and on a cube it is what an empty face would light its LED with.
        #expect(!(categories.setColour(id: 0, colourID: 1)))
        #expect(categories.category(id: 0)?.colourID == 0)
    }

    // MARK: - the name

    @Test func testRenamingIsReadBack() throws {
        let id = try #require(categories.activeCategories().first { $0.name == "Break" }?.id)

        #expect(categories.setName(id: id, name: "Rest"))

        #expect(categories.category(id: id)?.name == "Rest")
    }

    @Test func testRenamingOntoAnActiveNamesakeIsRefusedByTheIndex() throws {
        // The caller asks first, for a message that can say which category is in the way, and this is what has the
        // last word: `UN1_category` is unique over active names.
        let id = try #require(categories.activeCategories().first { $0.name == "Break" }?.id)

        #expect(!(categories.setName(id: id, name: "Meeting")))
        #expect(categories.category(id: id)?.name == "Break")
    }

    @Test func testRenamingOntoARetiredNamesakeIsAllowed() throws {
        // Only *active* names are unique, so two categories may share a name as long as one is retired. The dialogue
        // says so rather than the table refusing it.
        #expect(database.execute("INSERT INTO category (category_name, active) VALUES ('Rest', 0);"))
        let id = try #require(categories.activeCategories().first { $0.name == "Break" }?.id)

        #expect(categories.setName(id: id, name: "Rest"))

        #expect(categories.matching(name: "Rest").count == 2)
    }

    @Test func testUnassignedKeepsItsName() {
        // Id 0 is what a face points at when it holds nothing, and the code that recognises it recognises the name.
        #expect(!(categories.setName(id: 0, name: "Anything")))
        #expect(categories.category(id: 0)?.name == "Unassigned")
    }

    @Test func testAnEmptyNameIsRefusedRatherThanWritten() throws {
        let id = try #require(categories.activeCategories().first?.id)

        #expect(!(categories.setName(id: id, name: "")))
    }

    // MARK: - the colour

    @Test func testACategoryCreatedHereStartsWithNoColour() throws {
        // A category is named first and dressed afterwards, so the insert takes the None rows for both columns. The
        // two seeded ones arrive dressed (`database/007_category.sql` gives Break red and Meeting cyan), which is why
        // this asks about one it made rather than about the whole table.
        let id = try #require(categories.insert(name: "Admin"))

        let category = try #require(categories.category(id: id))
        #expect(category.colourID == 0)
        #expect(category.colour == nil)
    }

    @Test func testASeededColourIsReadBackAsTheColourItNames() throws {
        let meeting = try #require(categories.activeCategories().first { $0.name == "Meeting" })

        #expect(meeting.colourID == 13)
        let rgb = try #require(meeting.colour)
#expect(rgb.green.isApproximately(1), "Cyan, #00ffff")
        #expect(rgb.blue.isApproximately(1))
    }

    @Test func testSettingTheColourIsReadBackAsBothTheIDAndTheColour() throws {
        let id = try #require(categories.activeCategories().first?.id)

        #expect(categories.setColour(id: id, colourID: 15))

        let category = try #require(categories.category(id: id))
        // Both, because they answer different questions: which palette entry it is, for the picker to tick, and what
        // to draw, for the swatch.
        #expect(category.colourID == 15)
        let rgb = try #require(category.colour)
#expect(rgb.blue.isApproximately(128.0 / 255), "Navy, #000080")
    }

    @Test func testClearingTheColourGoesBackToNone() throws {
        let id = try #require(categories.activeCategories().first?.id)
        #expect(categories.setColour(id: id, colourID: 15))

        #expect(categories.setColour(id: id, colourID: CategoryEditRules.noColour))

        // The None row rather than a null, so the foreign key holds either way, and nothing to draw.
        #expect(categories.category(id: id)?.colourID == 0)
        #expect(categories.category(id: id)?.colour == nil)
    }

    @Test func testSettingTheColourOfACategoryThatIsNotThereIsRefused() {
        #expect(!(categories.setColour(id: 9_999, colourID: 15)))
    }
}
