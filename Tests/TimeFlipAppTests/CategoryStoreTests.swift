@testable import TimeFlipApp
import Foundation
import SQLite3
import XCTest

/// The Categories tab's store contract: what `loadCategories` returns, what each writer changes,
/// and what every one of them refuses.
///
/// The `category_id >= 1` guard gets a test per writer rather than one shared test. It is the same
/// clause five times over, which is exactly why one of them going missing would be easy to miss:
/// nothing fails loudly when the `Unassigned` sentinel is renamed or retired, it just stops being
/// the thing every unassigned face resolves to.
///
/// `CategoryCreationAssignmentTests` already covers `createCategory`'s return value and the
/// duplicate-name case; this file does not repeat them.
final class CategoryStoreTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    /// The names `database/007_category.sql` seeds, sorted the way `loadCategories` returns them.
    /// Every test starts with exactly these two real categories plus the sentinel.
    private let seededNames = ["Break", "Meeting"]

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CategoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("appdata.sqlite")
        // Opened and dropped purely to lay the schema down -- see the same note in
        // CategoryCreationAssignmentTests for why this is a separate open from the tests' own.
        _ = AppDataStore(databaseURL: dbURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> AppDataStore {
        AppDataStore(databaseURL: dbURL)
    }

    /// The `Unassigned` sentinel, which `loadCategories` deliberately omits, so the guard tests can
    /// read it back. `findCategory` is the only app-level way to reach it.
    private func sentinel(_ store: AppDataStore) throws -> CategoryRecord {
        try XCTUnwrap(store.findCategory(named: "Unassigned"))
    }

    // MARK: - loadCategories

    func testLoadCategoriesExcludesTheUnassignedSentinel() throws {
        let store = makeStore()

        XCTAssertFalse(store.loadCategories().contains { $0.id == 0 })
        XCTAssertNotNil(store.findCategory(named: "Unassigned"), "the sentinel exists, it is only filtered out of the list")
    }

    func testLoadCategoriesReturnsInactiveRowsAsWellAsActiveOnes() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Retired thing"))

        store.updateCategoryActive(categoryID: id, isActive: false)

        let loaded = try XCTUnwrap(store.loadCategories().first { $0.id == id })
        XCTAssertFalse(loaded.isActive, "the tab draws both sections from this one read")
    }

    /// Seeded in reverse so insertion order and sorted order genuinely disagree: a store that
    /// returned rowid order would pass a test seeded alphabetically.
    func testLoadCategoriesReturnsRowsInDisplayOrderNotInsertionOrder() throws {
        let store = makeStore()
        _ = store.createCategory(name: "Zebra")
        _ = store.createCategory(name: "Alpha")

        let names = store.loadCategories().map(\.name)

        let alpha = try XCTUnwrap(names.firstIndex(of: "Alpha"))
        let zebra = try XCTUnwrap(names.firstIndex(of: "Zebra"))
        XCTAssertLessThan(alpha, zebra)
    }

    /// A fresh database is the seeds and nothing else. Pinned because the seeds are what the Faces
    /// tab's default assignments point at, so a change here silently changes a new install.
    func testAFreshDatabaseHoldsOnlyTheSeededCategories() {
        XCTAssertEqual(makeStore().loadCategories().map(\.name), seededNames)
    }

    // MARK: - The category_id >= 1 guard

    func testUpdateCategoryNameRefusesTheSentinel() throws {
        let store = makeStore()

        store.updateCategoryName(categoryID: 0, name: "Renamed")

        XCTAssertEqual(try sentinel(store).name, "Unassigned")
    }

    func testUpdateCategoryColourRefusesTheSentinel() throws {
        let store = makeStore()

        store.updateCategoryColour(categoryID: 0, colourID: 1)

        XCTAssertEqual(try sentinel(store).colourID, 0)
    }

    func testUpdateCategoryIconRefusesTheSentinel() throws {
        let store = makeStore()
        let iconID = try XCTUnwrap(store.loadIcons().first { $0.id >= 1 }?.id)

        store.updateCategoryIcon(categoryID: 0, iconID: iconID)

        XCTAssertEqual(try sentinel(store).iconID, 0)
    }

    /// The sentinel is what every unassigned face resolves to, so retiring it would leave those
    /// faces pointing at a category the tab no longer offers.
    func testUpdateCategoryActiveRefusesTheSentinel() throws {
        let store = makeStore()

        store.updateCategoryActive(categoryID: 0, isActive: false)

        XCTAssertTrue(try sentinel(store).isActive)
    }

    func testUpdateCategoryDailyLimitRefusesTheSentinel() throws {
        let store = makeStore()

        store.updateCategoryDailyLimit(categoryID: 0, minutes: 30)

        XCTAssertEqual(try sentinel(store).dailyLimitMinutes, 0)
    }

    // MARK: - Individual writers

    func testUpdateCategoryNameChangesOnlyTheName() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Before"))
        let iconID = try XCTUnwrap(store.loadIcons().first { $0.id >= 1 }?.id)
        store.updateCategoryIcon(categoryID: id, iconID: iconID)
        store.updateCategoryColour(categoryID: id, colourID: 1)
        store.updateCategoryDailyLimit(categoryID: id, minutes: 45)

        store.updateCategoryName(categoryID: id, name: "After")

        let row = try XCTUnwrap(store.loadCategories().first { $0.id == id })
        XCTAssertEqual(row.name, "After")
        XCTAssertEqual(row.iconID, iconID)
        XCTAssertEqual(row.colourID, 1)
        XCTAssertEqual(row.dailyLimitMinutes, 45)
        XCTAssertTrue(row.isActive)
    }

    func testUpdateCategoryNameRejectsAnEmptyName() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Keeps its name"))

        store.updateCategoryName(categoryID: id, name: "")

        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.name, "Keeps its name")
    }

    func testUpdateCategoryColourStoresTheColourIncludingNone() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Colourful"))

        store.updateCategoryColour(categoryID: id, colourID: 1)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.colourID, 1)

        store.updateCategoryColour(categoryID: id, colourID: 0)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.colourID, 0, "0 is the None colour, a real choice rather than a failed write")
    }

    /// Icon 0 is how the grid clears a selection, so it has to store like any other value. A writer
    /// that treated 0 as "nothing to do" would make an icon impossible to remove.
    func testUpdateCategoryIconStoresTheIconIncludingTheNoneSentinel() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Iconic"))
        let iconID = try XCTUnwrap(store.loadIcons().first { $0.id >= 1 }?.id)

        store.updateCategoryIcon(categoryID: id, iconID: iconID)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.iconID, iconID)

        store.updateCategoryIcon(categoryID: id, iconID: 0)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.iconID, 0)
    }

    func testUpdateCategoryActiveRoundTripsBothWays() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Comes and goes"))

        store.updateCategoryActive(categoryID: id, isActive: false)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.isActive, false)

        store.updateCategoryActive(categoryID: id, isActive: true)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.isActive, true)
    }

    func testUpdateCategoryDailyLimitStoresMinutesAndZeroMeansDisabled() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Budgeted"))

        store.updateCategoryDailyLimit(categoryID: id, minutes: 90)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.dailyLimitMinutes, 90)

        store.updateCategoryDailyLimit(categoryID: id, minutes: 0)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.dailyLimitMinutes, 0)
    }

    /// The clamp is in the SQL bind rather than only in the view, so it still holds for a caller
    /// that never went through `CategoryEditRules.dailyLimitWrite`.
    func testUpdateCategoryDailyLimitClampsANegativeToZero() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Negative"))

        store.updateCategoryDailyLimit(categoryID: id, minutes: -30)

        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.dailyLimitMinutes, 0)
    }

    /// A stale view can name a category that has since gone. Every writer has to absorb that
    /// without touching anything else.
    func testEveryWriterIsANoOpAgainstAnUnknownCategory() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Bystander"))
        let before = store.loadCategories()
        let missingID = 999_999

        store.updateCategoryName(categoryID: missingID, name: "Ghost")
        store.updateCategoryColour(categoryID: missingID, colourID: 1)
        store.updateCategoryIcon(categoryID: missingID, iconID: 1)
        store.updateCategoryActive(categoryID: missingID, isActive: false)
        store.updateCategoryDailyLimit(categoryID: missingID, minutes: 10)

        XCTAssertEqual(store.loadCategories(), before)
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.name, "Bystander")
    }

    // MARK: - findCategory

    func testFindCategoryMatchesCaseInsensitively() {
        XCTAssertEqual(makeStore().findCategory(named: "meeting")?.name, "Meeting")
    }

    /// Unlike `loadCategories`, which filters it out. Typing "Unassigned" has to be reported as a
    /// collision rather than quietly inserting a second one.
    func testFindCategoryFindsTheSentinelThatLoadCategoriesHides() {
        XCTAssertEqual(makeStore().findCategory(named: "Unassigned")?.id, 0)
    }

    func testFindCategoryReturnsNilForAnEmptyName() {
        XCTAssertNil(makeStore().findCategory(named: ""))
    }

    /// Categories may legitimately share a name as long as only one of them is active. The answer
    /// has to be that active row: reporting an inactive namesake instead would have the tab offer
    /// to reinstate a category whose name is already taken, which `UN1_category` then refuses.
    ///
    /// **A failure here is a real bug** -- the create and rename collision paths both ask this
    /// question and act on the answer.
    func testFindCategoryPrefersTheActiveRowWhenTwoShareAName() throws {
        let store = makeStore()
        let retiredID = try XCTUnwrap(store.createCategory(name: "Standup"))
        store.updateCategoryActive(categoryID: retiredID, isActive: false)
        let activeID = try XCTUnwrap(store.createCategory(name: "Standup"))

        let answers = (0..<5).map { _ in store.findCategory(named: "Standup")?.id }

        XCTAssertEqual(Set(answers.compactMap { $0 }).count, 1, "repeated lookups must agree")
        XCTAssertEqual(answers.first ?? nil, activeID)
        XCTAssertNotEqual(answers.first ?? nil, retiredID)
    }

    /// With no active row to prefer, the oldest wins. Pinned so the answer is stable rather than
    /// whatever SQLite happens to return first.
    func testFindCategoryReturnsTheOldestWhenEveryMatchIsInactive() throws {
        let store = makeStore()
        let firstID = try XCTUnwrap(store.createCategory(name: "Standup"))
        store.updateCategoryActive(categoryID: firstID, isActive: false)
        let secondID = try XCTUnwrap(store.createCategory(name: "Standup"))
        store.updateCategoryActive(categoryID: secondID, isActive: false)

        XCTAssertEqual(store.findCategory(named: "Standup")?.id, firstID)
    }

    // MARK: - findCategories

    /// The lookup the create flow needs: every match, so it can tell one retired namesake from
    /// several. Ordered like `findCategory`'s single answer -- active first, then oldest.
    func testFindCategoriesReturnsEveryMatchActiveFirstThenOldest() throws {
        let store = makeStore()
        let olderRetiredID = try XCTUnwrap(store.createCategory(name: "Email"))
        store.updateCategoryActive(categoryID: olderRetiredID, isActive: false)
        let newerRetiredID = try XCTUnwrap(store.createCategory(name: "Email"))
        store.updateCategoryActive(categoryID: newerRetiredID, isActive: false)
        let activeID = try XCTUnwrap(store.createCategory(name: "Email"))

        let matches = store.findCategories(named: "email")

        XCTAssertEqual(matches.map(\.id), [activeID, olderRetiredID, newerRetiredID])
        XCTAssertEqual(store.findCategory(named: "email")?.id, matches.first?.id, "the two lookups must agree on the best match")
    }

    func testFindCategoriesReturnsEmptyForANameNobodyHolds() {
        XCTAssertTrue(makeStore().findCategories(named: "Nothing called this").isEmpty)
    }

    func testFindCategoriesReturnsEmptyForAnEmptyName() {
        XCTAssertTrue(makeStore().findCategories(named: "").isEmpty)
    }

    // MARK: - One active category per name (UN1_category)

    /// The partial unique index: `category_name COLLATE NOCASE` where `active = 1`.
    func testASecondActiveCategoryCannotTakeAnActiveName() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.createCategory(name: "Email"))

        XCTAssertNil(store.createCategory(name: "Email"))
        XCTAssertEqual(store.loadCategories().filter { $0.name == "Email" }.count, 1)
    }

    /// `COLLATE NOCASE` on the index, matching `findCategory`. Without it the database and the
    /// app's own collision check would disagree about what a duplicate is.
    func testTheActiveNameIsTakenCaseInsensitively() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.createCategory(name: "Email"))

        XCTAssertNil(store.createCategory(name: "email"))
    }

    /// The point of a *partial* index. Retired namesakes accumulate freely, which is what makes
    /// "create a new category with the same name" a supported choice.
    func testAnyNumberOfInactiveCategoriesMayShareAName() throws {
        let store = makeStore()
        for _ in 0..<3 {
            let id = try XCTUnwrap(store.createCategory(name: "Email"))
            store.updateCategoryActive(categoryID: id, isActive: false)
        }

        XCTAssertEqual(store.loadCategories().filter { $0.name == "Email" }.count, 3)
        XCTAssertTrue(store.loadCategories().filter { $0.name == "Email" }.allSatisfy { !$0.isActive })
    }

    /// An active category may sit alongside its retired namesakes -- one active, any number
    /// retired.
    func testOneActiveMaySitAlongsideRetiredNamesakes() throws {
        let store = makeStore()
        let retiredID = try XCTUnwrap(store.createCategory(name: "Email"))
        store.updateCategoryActive(categoryID: retiredID, isActive: false)

        XCTAssertNotNil(store.createCategory(name: "Email"))
    }

    func testReinstatingSucceedsWhenNoActiveCategoryHoldsTheName() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Email"))
        store.updateCategoryActive(categoryID: id, isActive: false)

        XCTAssertTrue(store.updateCategoryActive(categoryID: id, isActive: true))
        XCTAssertEqual(store.loadCategories().first { $0.id == id }?.isActive, true)
    }

    /// The case that makes the return value necessary. The Categories tab patches its loaded list
    /// rather than re-reading, so a refusal reported as success would tick the checkbox over a row
    /// that is still retired.
    func testReinstatingIsRefusedWhenAnActiveCategoryHoldsTheName() throws {
        let store = makeStore()
        let retiredID = try XCTUnwrap(store.createCategory(name: "Email"))
        store.updateCategoryActive(categoryID: retiredID, isActive: false)
        _ = try XCTUnwrap(store.createCategory(name: "Email"))

        XCTAssertFalse(store.updateCategoryActive(categoryID: retiredID, isActive: true))
        XCTAssertEqual(store.loadCategories().first { $0.id == retiredID }?.isActive, false, "still retired")
    }

    /// Retiring is never refused: the index only constrains active rows, so leaving is always
    /// possible even when coming back would not be.
    func testRetiringIsAlwaysAllowed() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Email"))

        XCTAssertTrue(store.updateCategoryActive(categoryID: id, isActive: false))
    }

    // MARK: - Cross-table

    // Waiting on `time_entry`.
    //
    // Both of these assert what happens to a category's history when it is retired or renamed, and
    // nothing writes `time_entry` yet. Reinstate them, and the raw SQL helpers at the foot of the
    // file, once there is a real writer and reader for that table -- and route them through those
    // rather than through raw SQL at that point.
    //
    // The version that ran here passed, but it only demonstrated that SQLite joins on a foreign
    // key: no app code put the row there or read it back. Both claims stay worth making, since
    // retiring being an UPDATE and never a DELETE is the whole reason `active` exists, and a rename
    // reaching back over old history is exactly what the confirmation dialog warns about.
    //
    // /// Retiring is an UPDATE, never a DELETE, and this is the whole reason `active` exists. A
    // /// `time_entry` written before the category was retired still has to resolve to it.
    // ///
    // /// Inserted with raw SQL because nothing writes `time_entry` yet. That makes this a test of the
    // /// schema contract the feature will rest on rather than of app code, which is worth having now:
    // /// the retire path already ships, so the row it must not break should already be protected.
    // func testRetiringACategoryLeavesItsTimeEntriesResolvable() throws {
    //     let store = makeStore()
    //     let id = try XCTUnwrap(store.createCategory(name: "Historic"))
    //     try insertTimeEntry(categoryID: id)
    //
    //     store.updateCategoryActive(categoryID: id, isActive: false)
    //
    //     XCTAssertEqual(try resolvedCategoryNameForTimeEntry(), "Historic")
    // }
    //
    // /// The behaviour the rename confirmation warns about, asserted rather than assumed: everything
    // /// links by `category_id`, so history recorded before the rename reports the new name too.
    // func testRenamingACategoryChangesWhatItsHistoryReports() throws {
    //     let store = makeStore()
    //     let id = try XCTUnwrap(store.createCategory(name: "Old name"))
    //     try insertTimeEntry(categoryID: id)
    //
    //     store.updateCategoryName(categoryID: id, name: "New name")
    //
    //     XCTAssertEqual(try resolvedCategoryNameForTimeEntry(), "New name")
    // }

    /// Retiring drops the category from every list that offers one, so a face left holding it would
    /// go on drawing a category nothing can pick and nothing can clear. The retire takes it off.
    func testRetiringACategoryTakesItOffTheFaceItWasOn() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Was on a face"))
        store.updateFaceCategory(faceID: 3, categoryID: id)

        store.updateCategoryActive(categoryID: id, isActive: false)

        let onFace = try XCTUnwrap(store.loadFaceCategories()[3])
        XCTAssertEqual(onFace.id, TimeFlipConstants.unassignedCategoryID, "back on the sentinel")
        XCTAssertEqual(onFace.name, "Unassigned")
    }

    /// One category can sit on several faces, and retiring it has to reach all of them -- while
    /// leaving every face that held something else exactly as it was.
    func testRetiringACategoryClearsEveryFaceHoldingItAndNoOthers() throws {
        let store = makeStore()
        let retired = try XCTUnwrap(store.createCategory(name: "On two faces"))
        let kept = try XCTUnwrap(store.createCategory(name: "On one face"))
        store.updateFaceCategory(faceID: 3, categoryID: retired)
        store.updateFaceCategory(faceID: 5, categoryID: retired)
        store.updateFaceCategory(faceID: 6, categoryID: kept)

        store.updateCategoryActive(categoryID: retired, isActive: false)

        let faces = store.loadFaceCategories()
        XCTAssertEqual(faces[3]?.id, TimeFlipConstants.unassignedCategoryID)
        XCTAssertEqual(faces[5]?.id, TimeFlipConstants.unassignedCategoryID)
        XCTAssertEqual(faces[6]?.id, kept, "a face holding a different category is untouched")
    }

    /// The lock stops a face being *reassigned* by accident. Retiring is neither: the category the
    /// face was locked to is no longer one anything can choose, so keeping it there would pin the
    /// exact display this fix is about. The lock itself survives.
    func testRetiringACategoryClearsALockedFaceToo() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Locked on"))
        store.updateFaceCategory(faceID: 4, categoryID: id)
        store.updateFaceLocked(faceID: 4, locked: true)

        store.updateCategoryActive(categoryID: id, isActive: false)

        XCTAssertEqual(store.loadFaceCategories()[4]?.id, TimeFlipConstants.unassignedCategoryID)
        XCTAssertEqual(store.loadFaceLocks()[4], true, "still locked, just no longer holding a retired category")
    }

    /// Nothing records which face a category came off, so reinstating cannot put it back. The Faces
    /// tab's reactivate path assigns to the face on show itself; this one is the Categories tab's,
    /// which has no face in front of it.
    func testReinstatingACategoryDoesNotPutItBackOnItsOldFace() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.createCategory(name: "Came back"))
        store.updateFaceCategory(faceID: 3, categoryID: id)
        store.updateCategoryActive(categoryID: id, isActive: false)

        XCTAssertTrue(store.updateCategoryActive(categoryID: id, isActive: true))

        XCTAssertEqual(store.loadFaceCategories()[3]?.id, TimeFlipConstants.unassignedCategoryID)
    }

    /// Retiring a category no face holds changes no mapping at all, so the faces the seed laid down
    /// are still exactly where they were.
    func testRetiringACategoryOnNoFaceLeavesEveryFaceAlone() throws {
        let store = makeStore()
        let before = store.loadFaceCategories().mapValues(\.id)
        let id = try XCTUnwrap(store.createCategory(name: "Never assigned"))

        store.updateCategoryActive(categoryID: id, isActive: false)

        XCTAssertEqual(store.loadFaceCategories().mapValues(\.id), before)
    }

    // MARK: - Raw SQL helpers (waiting on `time_entry`)
    //
    // Used only by the two commented-out tests above, and commented with them so reinstating is one
    // uncomment rather than a rewrite. `import SQLite3` at the top of the file is for these alone.
    //
    //
    // /// `time_entry` has no writer in `AppDataStore` yet, so the cross-table tests lay their own row
    // /// down. `device_event_id` points at nothing in particular: foreign keys are not enforced on
    // /// these connections, and what is under test is the category join.
    // private func insertTimeEntry(categoryID: Int) throws {
    //     try execute("""
    //     INSERT INTO time_entry (category_id, device_event_id, started_at, ended_at, duration_seconds)
    //     VALUES (\(categoryID), 1, '2026-07-31T09:00:00Z', '2026-07-31T09:30:00Z', 1800);
    //     """)
    // }
    //
    // private func resolvedCategoryNameForTimeEntry() throws -> String? {
    //     try queryFirstString("""
    //     SELECT c.category_name FROM time_entry t
    //     JOIN category c ON c.category_id = t.category_id
    //     ORDER BY t.time_entry_id DESC LIMIT 1;
    //     """)
    // }
    //
    // private func openRawConnection() throws -> OpaquePointer {
    //     var handle: OpaquePointer?
    //     guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let handle else {
    //         throw XCTSkip("could not open the test database directly")
    //     }
    //     return handle
    // }
    //
    // private func execute(_ sql: String) throws {
    //     let handle = try openRawConnection()
    //     defer { sqlite3_close(handle) }
    //     var error: UnsafeMutablePointer<CChar>?
    //     guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
    //         let message = error.map { String(cString: $0) } ?? "unknown"
    //         sqlite3_free(error)
    //         return XCTFail("raw exec failed: \(message)")
    //     }
    // }
    //
    // private func queryFirstString(_ sql: String) throws -> String? {
    //     let handle = try openRawConnection()
    //     defer { sqlite3_close(handle) }
    //     var stmt: OpaquePointer?
    //     defer { sqlite3_finalize(stmt) }
    //     guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    //     guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    //     return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    // }
}
