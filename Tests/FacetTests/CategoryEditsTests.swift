@testable import FacetCore
import Foundation
import Testing

/// What the Categories tab does when one of its controls is used, with no window at all.
///
/// **None of it was testable before.** Every one of these sequences lived in `SettingsWindowController`, behind a
/// real `NSAlert` and a real pane, so a suite reaching them needed AppKit and is excluded on Linux -- which means
/// the orderings below have never had a test on either platform, exactly as `DeviceSettingWrite`'s had not until
/// it came out of the same file.
///
/// **The orderings are what these pin, because none of them is visible from the outside**: the table is written
/// before the cube is told, a face is cleared only after the retire succeeded, and a refused write still reads the
/// row back so that nothing is left on screen that the table never took.
///
/// **Run against the seeded categories**, which `database/007_category.sql` puts there -- *Unassigned*, *Break* and
/// *Meeting*. So nothing here asserts on the size of the list and no fixture is named after a seed: a test that
/// inserted *Break* would be refused by `UN1_category` and would be testing the index rather than the sequence.
@Suite @MainActor
final class CategoryEditsTests {
    private let database: TemporaryDatabase
    private var categories: CategoryStore!
    private var faces: FaceStore!
    private var dialogues: RecordingDialogues!
    private var edits: CategoryEdits!
    private var redraws = 0
    private var timingRedraws = 0
    private var started: [CategoryRecord] = []

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        categories = CategoryStore(connection: connection)
        faces = FaceStore(connection: connection)
        dialogues = RecordingDialogues()
        edits = CategoryEdits(categories: categories, faces: faces, dialogues: dialogues, debugLog: nil)
        edits.changed = { [self] in redraws += 1 }
        edits.timingChanged = { [self] in timingRedraws += 1 }
        edits.startTiming = { [self] record in started.append(record) }
    }

    deinit {
        database.remove()
    }

    /// A category in the table, read back rather than assembled: every method here takes the record a row was drawn
    /// from, and one built in the test would not be one the table ever answered with.
    private func make(_ name: String) throws -> CategoryRecord {
        let id = try #require(categories.insert(name: name), "\(name) has to be a category before it can be edited")
        return try #require(categories.category(id: id))
    }

    /// The row the table now holds for `id`, which is what every assertion here asks: a record the test is still
    /// holding is only what was true when the row was drawn.
    private func stored(_ id: Int) -> CategoryRecord? {
        categories.category(id: id)
    }

    /// The active categories called `name`, which is how a list is asserted on without counting the seeds.
    private func active(named name: String) -> [CategoryRecord] {
        categories.activeCategories().filter { $0.name == name }
    }

    // MARK: - the icon and the colour

    @Test func testSettingAnIconStoresItAndReadsTheRowBack() throws {
        let category = try make("Admin")

        edits.setIcon(3, on: category)

        #expect(stored(category.id)?.iconName != nil)
        #expect(redraws == 1, "the row draws what the table now says rather than what was clicked")
    }

    @Test func testReClickingTheIconAlreadySetIsWhatClearsIt() throws {
        let category = try make("Admin")
        edits.setIcon(3, on: category)
        let withIcon = try #require(stored(category.id))

        // The grid has no None cell, so this is the only way back to no icon at all. The decision is
        // `CategoryEditRules.iconSelection`'s; what is checked here is that the write it answers with lands.
        edits.setIcon(CategoryEditRules.iconSelection(clicked: 3, selected: 3), on: withIcon)

        #expect(stored(category.id)?.iconName == nil)
    }

    @Test func testRecolouringPicksOutOnlyTheFacesWearingTheCategory() throws {
        let category = try make("Admin")
        let other = try make("Study")
        // Faces 3 and 5, because faces 2 and 8 are seeded **locked** (holding Meeting and Break) and a locked face
        // refuses a category -- `FaceStore.assign` is where that is decided, and it is right to refuse.
        #expect(faces.assign(categoryID: category.id, toFace: 3))
        #expect(faces.assign(categoryID: other.id, toFace: 5))

        edits.setColour(4, on: category)

        // **Which faces get the new colour is the store's answer rather than the caller's**, which is the whole of
        // what is checked here: `faceColours` is left unset, a cube being a device run rather than a suite, so the
        // assertion is on the list the sequence would hand it -- face 3 and not face 5.
        #expect(stored(category.id)?.colourID == 4)
        #expect(faces.facesHolding(categoryID: category.id).map(\.face) == [3])
        #expect(redraws == 1)
    }

    @Test func testRecolouringACategoryOnNoFaceStillStoresTheColour() throws {
        let category = try make("Admin")

        edits.setColour(2, on: category)

        #expect(stored(category.id)?.colourID == 2)
        #expect(faces.facesHolding(categoryID: category.id).isEmpty, "a swatch in a list and nothing on the cube")
        #expect(redraws == 1)
    }

    // MARK: - the daily limit

    @Test func testALimitIsClampedToWhatADayHolds() throws {
        let category = try make("Deep Work")

        edits.setDailyLimit(9_000, on: category)

        #expect(stored(category.id)?.dailyLimitMinutes == CategoryEditRules.maximumDailyLimitMinutes)
    }

    @Test func testANegativeLimitBecomesNoLimitRatherThanARefusal() throws {
        let category = try make("Deep Work")

        edits.setDailyLimit(-30, on: category)

        #expect(stored(category.id)?.dailyLimitMinutes == CategoryEditRules.disabledDailyLimit)
    }

    @Test func testStoringALimitTellsWhateverIsDrawnFromIt() throws {
        let category = try make("Deep Work")

        edits.setDailyLimit(45, on: category)

        // **The limit just edited may be the one the app is refusing against**, and `DailyLimitWatch` has stood
        // itself down by then, so nothing else would notice this.
        #expect(timingRedraws == 1)
        #expect(redraws == 0, "a write that took leaves the field alone rather than rebuilding the row under it")
    }

    // MARK: - retiring

    @Test func testRetiringTakesTheCategoryOffEveryFaceHoldingIt() throws {
        let category = try make("Admin")
        #expect(faces.assign(categoryID: category.id, toFace: 1))
        #expect(faces.assign(categoryID: category.id, toFace: 6))

        edits.retire(category)

        #expect(stored(category.id)?.isCategoryActive == false)
        #expect(faces.categoryID(forFace: 1) == nil)
        #expect(faces.categoryID(forFace: 6) == nil)
        #expect(faces.facesHolding(categoryID: category.id).isEmpty)
    }

    @Test func testRetiringReadsTheListsAgainAndTellsTheClock() throws {
        let category = try make("Admin")

        edits.retire(category)

        #expect(redraws == 1, "retiring changes which list the row belongs in")
        #expect(timingRedraws == 1, "a face this cleared may be the one being timed")
    }

    @Test func testARetiredCategoryIsGoneFromTheActiveList() throws {
        let category = try make("Admin")

        edits.retire(category)

        #expect(active(named: "Admin").isEmpty)
        #expect(categories.inactiveCategories().map(\.id).contains(category.id))
    }

    // MARK: - bringing one back

    @Test func testARetiredCategoryComesBackWhenNothingActiveHoldsItsName() throws {
        let category = try make("Admin")
        edits.retire(category)
        let retired = try #require(stored(category.id))

        edits.reinstate(retired)

        #expect(stored(category.id)?.isCategoryActive == true)
        #expect(dialogues.told.isEmpty)
    }

    @Test func testReinstatingIsRefusedWhenAnActiveCategoryHoldsTheNameAndSaysWhich() throws {
        let category = try make("Admin")
        edits.retire(category)
        let retired = try #require(stored(category.id))
        _ = try make("Admin")
        // After the retire, which redrew once itself.
        let before = redraws

        edits.reinstate(retired)

        #expect(stored(category.id)?.isCategoryActive == false)
        #expect(dialogues.told.count == 1)
        #expect(dialogues.told.first?.title == "That name is already in use")
        // **Redrawn before the notice**, so the box the click ticked is back to unticked behind the dialogue rather
        // than still claiming something the table refused.
        #expect(redraws == before + 1)
    }

    // MARK: - creating one

    @Test func testANameNothingHoldsIsInsertedAndTheListIsReadAgain() {
        edits.create("Reading")

        #expect(active(named: "Reading").count == 1)
        #expect(redraws == 1)
        #expect(dialogues.asked.isEmpty, "a name nothing holds is not a question")
    }

    @Test func testNothingTypedWritesNothingAndAsksNothing() {
        let before = categories.activeCategories().count

        edits.create("   ")

        #expect(categories.activeCategories().count == before)
        #expect(redraws == 0)
        #expect(dialogues.asked.isEmpty)
        #expect(dialogues.told.isEmpty)
    }

    @Test func testANameAnActiveCategoryHoldsIsADeadEndRatherThanAQuestion() throws {
        _ = try make("Reading")

        edits.create("reading")

        #expect(active(named: "Reading").count == 1, "the index is not the only thing standing in the way")
        #expect(dialogues.asked.isEmpty)
        #expect(dialogues.told.first?.title == "That category already exists")
    }

    @Test func testARetiredNamesakeIsAskedAboutAndReactivatingBringsThatRowBack() throws {
        let category = try make("Reading")
        edits.retire(category)
        dialogues.answersWith = try #require(
            CategoryCreateRules.choices(retiredNamesakes: 1).firstIndex(of: .reactivate)
        )

        edits.create("Reading")

        #expect(dialogues.asked.count == 1)
        #expect(active(named: "Reading").map(\.id) == [category.id], "the old row, with its history")
    }

    @Test func testCreatingANewOneLeavesTheRetiredNamesakeRetired() throws {
        let category = try make("Reading")
        edits.retire(category)
        dialogues.answersWith = try #require(
            CategoryCreateRules.choices(retiredNamesakes: 1).firstIndex(of: .createNew)
        )

        edits.create("Reading")

        let reading = active(named: "Reading")
        #expect(reading.count == 1)
        #expect(reading.first?.id != category.id, "a name being reused deliberately, which the database allows")
        #expect(stored(category.id)?.isCategoryActive == false)
    }

    @Test func testCancellingTheRetiredNamesakeQuestionWritesNothing() throws {
        let category = try make("Reading")
        edits.retire(category)
        let before = redraws
        dialogues.answersWith = try #require(
            CategoryCreateRules.choices(retiredNamesakes: 1).firstIndex(of: .cancel)
        )

        edits.create("Reading")

        #expect(active(named: "Reading").isEmpty)
        #expect(redraws == before, "nothing was written, so there is nothing to read back")
    }

    @Test func testADialogueDismissedRatherThanAnsweredMeansCancel() throws {
        let category = try make("Reading")
        edits.retire(category)
        // A position no button of ours occupies, which is what a dialogue closed by the window manager answers with.
        dialogues.answersWith = 99

        edits.create("Reading")

        #expect(active(named: "Reading").isEmpty)
        #expect(stored(category.id)?.isCategoryActive == false)
    }

    @Test func testTwoRetiredNamesakesAreNotOfferedReactivateAtAll() throws {
        let first = try make("Reading")
        edits.retire(first)
        let second = try make("Reading")
        edits.retire(second)

        edits.create("Reading")

        let offered = try #require(dialogues.asked.first).choices
        #expect(!offered.contains(CategoryCreateRules.RetiredNamesakeChoice.reactivate.buttonTitle))
        #expect(offered.contains(CategoryCreateRules.RetiredNamesakeChoice.createNew.buttonTitle))
    }

    // MARK: - the clock a created category may start

    @Test func testACategoryCreatedFromTheFacesTabIsStartedFromTheRowTheTableAnswersWith() {
        edits.create("Reading", startsTiming: true)

        let created = active(named: "Reading").first
        #expect(started.count == 1)
        #expect(started.first == created, "the row as the table holds it, not one assembled from the typed name")
    }

    @Test func testTheCategoriesTabsOwnCreateControlStartsNothing() {
        edits.create("Reading")

        #expect(active(named: "Reading").count == 1)
        #expect(started.isEmpty)
    }

    @Test func testReactivatingAnOldRowStartsItTooWhenTheControlAsksForThat() throws {
        let category = try make("Reading")
        edits.retire(category)
        dialogues.answersWith = try #require(
            CategoryCreateRules.choices(retiredNamesakes: 1).firstIndex(of: .reactivate)
        )

        edits.create("Reading", startsTiming: true)

        // "Created" is not what they did, but it is what they got: all three outcomes come from one press of one
        // button, so a name that happens to collide with a retired one must not behave differently.
        #expect(started.map(\.id) == [category.id])
    }

    // MARK: - renaming

    @Test func testEveryRenameIsConfirmedEvenToANameNothingHolds() throws {
        let category = try make("Admin")
        dialogues.leavesUnanswered = true

        edits.rename(category, to: "Paperwork")

        #expect(dialogues.asked.count == 1, "a report covering last month will show the new name too")
        #expect(stored(category.id)?.name == "Admin", "nothing is written until it is answered")
    }

    @Test func testAConfirmedRenameWritesItAndTellsWhatIsDrawnFromIt() throws {
        let category = try make("Admin")
        dialogues.answersWith = try #require(
            CategoryRenameRules.choices(for: .confirm(name: "Paperwork")).firstIndex(of: .rename)
        )

        edits.rename(category, to: "Paperwork")

        #expect(stored(category.id)?.name == "Paperwork")
        #expect(redraws == 1, "a rename re-sorts the list")
        #expect(timingRedraws == 1, "the name may be the one on the status item")
    }

    @Test func testCancellingARenameWritesNothingAndRedrawsNothing() throws {
        let category = try make("Admin")
        dialogues.answersWith = try #require(
            CategoryRenameRules.choices(for: .confirm(name: "Paperwork")).firstIndex(of: .cancel)
        )

        edits.rename(category, to: "Paperwork")

        #expect(stored(category.id)?.name == "Admin")
        #expect(redraws == 0)
    }

    @Test func testANameThatReadsTheSameIsIgnoredRatherThanAsked() throws {
        let category = try make("Admin")

        edits.rename(category, to: "  Admin  ")

        #expect(dialogues.asked.isEmpty, "a dialogue saying nothing happened is worse than nothing happening")
        #expect(redraws == 0)
    }

    @Test func testAnActiveNamesakeIsADeadEndWithNothingButCancelInIt() throws {
        let category = try make("Admin")
        dialogues.answersWith = 0

        // *Break* is seeded and active, so this is the one case the index would throw out.
        edits.rename(category, to: "Break")

        let asked = try #require(dialogues.asked.first)
        #expect(asked.choices == [CategoryRenameRules.Choice.cancel.buttonTitle])
        #expect(stored(category.id)?.name == "Admin")
        #expect(redraws == 0, "there is something to say and nothing to decide")
    }

    @Test func testARetiredCategoryRenamesThroughTheSameSequence() throws {
        let category = try make("Admin")
        edits.retire(category)
        let retired = try #require(stored(category.id))
        dialogues.answersWith = try #require(
            CategoryRenameRules.choices(for: .confirm(name: "Old admin")).firstIndex(of: .rename)
        )

        edits.rename(retired, to: "Old admin")

        #expect(stored(category.id)?.name == "Old admin")
    }

    @Test func testARetiredCategoryMayTakeANameAnActiveOneHoldsBecauseTheIndexAllowsIt() throws {
        let namesake = try #require(categories.activeCategories().first { $0.name == "Break" })
        let category = try make("Admin")
        edits.retire(category)
        let retired = try #require(stored(category.id))
        dialogues.answersWith = try #require(
            CategoryRenameRules
                .choices(for: .confirmAgainstActive(name: "Break", activeNamesake: namesake))
                .firstIndex(of: .renameAnyway)
        )

        edits.rename(retired, to: "Break")

        // `UN1_category` is unique over `active = 1` only, so this is a write the index has no opinion about --
        // and refusing it would have the app enforcing a constraint the database does not have.
        #expect(stored(category.id)?.name == "Break")
    }
}
