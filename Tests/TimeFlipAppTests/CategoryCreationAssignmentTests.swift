@testable import TimeFlipApp
import XCTest

/// Covers the store-level contract the Faces tab's "create a category and put it on the face I'm
/// looking at" behaviour rests on: `createCategory` has to hand back the `category_id` it just
/// inserted, and that id has to be assignable to a face.
///
/// The duplicate-name case is why the return value exists. A name is not a key: creating a second
/// category with an inactive one's name is a supported choice, so the Faces tab cannot create a
/// category and then find it by name.
///
/// It is no longer the *hazard* it once was. `findCategory` now prefers the active row and
/// `UN1_category` allows only one of those per name, so a lookup straight after a create does find
/// the new row. What remains is that the id is the only answer that is right by construction rather
/// than by two rules lining up.
final class CategoryCreationAssignmentTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CategoryCreationAssignmentTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("appdata.sqlite")
        // Opened and dropped purely to lay the schema down, so each test starts from a database that
        // is fully seeded -- `category` inserts need the `colour`/`icon`/`project` sentinel rows its
        // foreign keys point at. Deliberately a *separate* open from the one the tests use: a DDL
        // file carrying a live `ALTER TABLE ... ADD COLUMN` for a column its own `CREATE TABLE`
        // already declares abandons the rest of that file on the very first open (the app logs it and
        // the next launch heals it), which would otherwise leave `colour` and `category` empty here.
        _ = AppDataStore(databaseURL: dbURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> AppDataStore {
        AppDataStore(databaseURL: dbURL)
    }

    func testCreateCategoryReturnsTheIDOfTheRowItInserted() throws {
        let store = makeStore()

        let newID = try XCTUnwrap(store.createCategory(name: "Deep work"))

        let created = try XCTUnwrap(store.loadCategories().first { $0.id == newID })
        XCTAssertEqual(created.name, "Deep work")
        XCTAssertTrue(created.isActive)
    }

    func testCreateCategoryRejectsAnEmptyName() {
        XCTAssertNil(makeStore().createCategory(name: ""))
    }

    /// The id must be the new row's, not the existing same-named one's -- see the type comment.
    func testCreatingADuplicateNameReturnsTheNewRowNotTheExistingOne() throws {
        let store = makeStore()
        // A name the DDL doesn't seed, so the two rows the test makes are the only ones with it.
        let firstID = try XCTUnwrap(store.createCategory(name: "Standup"))
        store.updateCategoryActive(categoryID: firstID, isActive: false)

        let secondID = try XCTUnwrap(store.createCategory(name: "Standup"))

        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(store.findCategory(named: "Standup")?.id, secondID, "the lookup prefers the active row, which is the one just created")
    }

    func testANewlyCreatedCategoryCanBeAssignedToAnUnlockedFace() throws {
        let store = makeStore()
        let newID = try XCTUnwrap(store.createCategory(name: "Email"))

        store.updateFaceCategory(faceID: 3, categoryID: newID)

        XCTAssertEqual(store.loadFaceCategories()[3]?.id, newID)
    }

    /// The Faces tab doesn't offer to assign to a locked face, and the write is the backstop for
    /// that -- so an auto-assign that got past the UI guard still leaves the locked face alone.
    func testAssigningANewCategoryToALockedFaceIsRefused() throws {
        let store = makeStore()
        let keptID = try XCTUnwrap(store.createCategory(name: "Coffee"))
        store.updateFaceCategory(faceID: 4, categoryID: keptID)
        store.updateFaceLocked(faceID: 4, locked: true)
        let newID = try XCTUnwrap(store.createCategory(name: "Lunch"))

        store.updateFaceCategory(faceID: 4, categoryID: newID)

        XCTAssertEqual(store.loadFaceCategories()[4]?.id, keptID)
    }
}
