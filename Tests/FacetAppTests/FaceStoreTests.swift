@testable import FacetApp
import XCTest

/// Covers `FaceStore`: which category a face holds, and what it takes to change it.
@MainActor
final class FaceStoreTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var faces: FaceStore!
    private var categories: CategoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            try database.bootstrap()
            let connection = database.connection()
            faces = FaceStore(connection: connection)
            categories = CategoryStore(connection: connection)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            faces = nil
            categories = nil
            database.remove()
        }
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

    // MARK: - which faces hold a category

    func testEveryFaceHoldingACategoryIsReported() throws {
        let meeting = try categoryID(named: "Meeting")
        XCTAssertTrue(faces.assign(categoryID: meeting, toFace: 13))
        XCTAssertTrue(faces.assign(categoryID: meeting, toFace: 14))

        let holding = faces.facesHolding(categoryID: meeting).map(\.face)

        // Face 2 is seeded with Meeting, and both manual faces now hold it too: one category, many faces, which is
        // exactly why retiring has to look at all of them.
        XCTAssertEqual(holding, [2, 13, 14])
    }

    func testALockedFaceIsReportedAsLocked() throws {
        // Face 8 is seeded locked, holding Break.
        let holding = faces.facesHolding(categoryID: try categoryID(named: "Break"))

        XCTAssertEqual(holding.first { $0.face == 8 }?.isLocked, true)
        XCTAssertEqual(holding.filter(\.isLocked).map(\.face), [8], "and nothing else is")
    }

    func testACategoryOnNoFaceHoldsNothing() throws {
        // A category nobody has put anywhere, which is what every newly created one is.
        let fresh = try XCTUnwrap(categories.insert(name: "Reading"))

        XCTAssertTrue(faces.facesHolding(categoryID: fresh).isEmpty)
    }

    // MARK: - asking whether a face is locked

    func testTheSeededFacesReportTheirLock() {
        // Faces 2 and 8 are the two the DDL seeds with a category, and both are seeded locked -- which makes a locked
        // face the ordinary case on a fresh database rather than an edge of it.
        XCTAssertEqual(faces.isLocked(face: 2), true)
        XCTAssertEqual(faces.isLocked(face: 8), true)
        XCTAssertEqual(faces.isLocked(face: 5), false, "an Unassigned face is free to take one")
    }

    func testAManualFaceIsNeverLocked() {
        // Being reassigned is the whole point of them, so the guard `assign` shares must never catch one.
        for face in ManualFace.all {
            XCTAssertEqual(faces.isLocked(face: face), false, "manual face \(face)")
        }
    }

    func testAFaceWithNoRowAnswersNothingRatherThanUnlocked() {
        // The two are different faults and a caller reports them differently: one is a face somebody protected, the
        // other is not a face at all.
        XCTAssertNil(faces.isLocked(face: 99))
    }

    func testALockChangedElsewhereIsSeenByTheNextRead() {
        XCTAssertEqual(faces.isLocked(face: 2), true, "precondition")

        XCTAssertTrue(database.execute("UPDATE face SET locked = 0 WHERE face_id = 2;"))

        XCTAssertEqual(faces.isLocked(face: 2), false)
    }

    // MARK: - locking a face

    func testAFaceCanBeLockedAndUnlocked() {
        XCTAssertTrue(faces.setLocked(true, face: 5))
        XCTAssertEqual(faces.isLocked(face: 5), true)

        XCTAssertTrue(faces.setLocked(false, face: 5))
        XCTAssertEqual(faces.isLocked(face: 5), false)
    }

    func testUnlockingASeededFaceLetsItTakeACategoryAgain() {
        // The gesture the lock exists for, end to end: face 2 is seeded locked holding Meeting, and refuses Break
        // until it is unlocked.
        let breakID = try? categoryID(named: "Break")
        XCTAssertFalse(faces.assign(categoryID: breakID ?? 1, toFace: 2), "precondition: locked faces refuse")

        XCTAssertTrue(faces.setLocked(false, face: 2))

        XCTAssertTrue(faces.assign(categoryID: breakID ?? 1, toFace: 2))
    }

    func testLockingIsNotItselfRefusedByTheLock() {
        // Or it would be a switch that can only be flicked one way. Locking stops a *category* landing; it does not
        // stop the lock being changed.
        XCTAssertEqual(faces.isLocked(face: 8), true, "precondition: seeded locked")

        XCTAssertTrue(faces.setLocked(false, face: 8))
        XCTAssertTrue(faces.setLocked(true, face: 8))
    }

    func testAFaceWithNoRowRefusesTheLock() {
        // Reported rather than silently doing nothing, so a caller can tell "not a face" from "done".
        XCTAssertFalse(faces.setLocked(true, face: 99))
    }

    // MARK: - the design rule

    func testAChangeMadeElsewhereIsSeenByTheNextRead() throws {
        let meeting = try categoryID(named: "Meeting")

        XCTAssertTrue(database.execute("UPDATE face SET category_id = \(meeting) WHERE face_id = \(ManualFace.first);"))

        XCTAssertEqual(faces.categoryID(forFace: ManualFace.first), meeting, "read again, not remembered")
    }
}
