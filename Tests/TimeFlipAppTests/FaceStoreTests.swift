@testable import TimeFlipApp
import XCTest

/// Covers `FaceStore`: which category a face holds, and what it takes to change it.
@MainActor
final class FaceStoreTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var faces: FaceStore!
    private var categories: CategoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        faces = FaceStore(connection: connection)
        categories = CategoryStore(connection: connection)
    }

    override func tearDown() {
        faces = nil
        categories = nil
        database.remove()
        super.tearDown()
    }

    private func categoryID(named name: String) throws -> Int {
        try XCTUnwrap(categories.matching(name: name).first?.id)
    }

    func testTheManualFaceStartsEmpty() {
        // Seeded pointing at Unassigned, which is a face with nothing on it rather than a face holding a
        // category called Unassigned -- so it reads as nil.
        XCTAssertNil(faces.categoryID(forFace: ManualFace.first))
    }

    func testASeededFaceReportsItsCategory() throws {
        // Face 8 is seeded with Break, and locked.
        XCTAssertEqual(faces.categoryID(forFace: 8), try categoryID(named: "Break"))
    }

    func testAssigningToTheManualFaceTakes() throws {
        let meeting = try categoryID(named: "Meeting")

        XCTAssertTrue(faces.assign(categoryID: meeting, toFace: ManualFace.first))

        XCTAssertEqual(faces.categoryID(forFace: ManualFace.first), meeting)
    }

    func testReassigningReplacesWhatWasThere() throws {
        let meeting = try categoryID(named: "Meeting")
        let breakID = try categoryID(named: "Break")
        XCTAssertTrue(faces.assign(categoryID: meeting, toFace: ManualFace.first))

        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: ManualFace.first))

        XCTAssertEqual(faces.categoryID(forFace: ManualFace.first), breakID, "one category at a time")
    }

    func testALockedFaceKeepsWhatItHas() throws {
        // Face 2 is seeded locked. Locking exists to stop a face being reassigned by accident, so the write
        // refuses rather than trusting every caller to have checked.
        let before = faces.categoryID(forFace: 2)
        let breakID = try categoryID(named: "Break")

        XCTAssertFalse(faces.assign(categoryID: breakID, toFace: 2))

        XCTAssertEqual(faces.categoryID(forFace: 2), before)
    }

    func testClearingPutsAFaceBackToNothing() throws {
        XCTAssertTrue(faces.assign(categoryID: try categoryID(named: "Meeting"), toFace: ManualFace.first))

        XCTAssertTrue(faces.clear(face: ManualFace.first))

        XCTAssertNil(faces.categoryID(forFace: ManualFace.first))
    }

    func testAFaceThatDoesNotExistHoldsNothing() {
        XCTAssertNil(faces.categoryID(forFace: 99))
    }

    // MARK: - the design rule

    func testAChangeMadeElsewhereIsSeenByTheNextRead() throws {
        let meeting = try categoryID(named: "Meeting")

        XCTAssertTrue(database.execute("UPDATE face SET category_id = \(meeting) WHERE face_id = \(ManualFace.first);"))

        XCTAssertEqual(faces.categoryID(forFace: ManualFace.first), meeting, "read again, not remembered")
    }
}
