@testable import FacetCore
import Foundation
import Testing

/// Covers `FaceStore`: which category a face holds, and what it takes to change it.
@Suite @MainActor
final class FaceStoreTests {
    private let database: TemporaryDatabase
    private var faces: FaceStore!
    private var categories: CategoryStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        faces = FaceStore(connection: connection)
        categories = CategoryStore(connection: connection)
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    private func categoryID(named name: String) throws -> Int {
try #require(categories.matching(name: name).first?.id)
    }

    @Test func testTheManualFaceStartsEmpty() {
        // Seeded pointing at Unassigned, which is a face with nothing on it rather than a face holding a
        // category called Unassigned -- so it reads as nil.
        #expect(faces.categoryID(forFace: ManualFace.first) == nil)
    }

    @Test func testASeededFaceReportsItsCategory() throws {
        // Face 8 is seeded with Break, and locked.
let breakID = try categoryID(named: "Break")
        #expect(faces.categoryID(forFace: 8) == breakID)
    }

    @Test func testAssigningToTheManualFaceTakes() throws {
        let meeting = try categoryID(named: "Meeting")

        #expect(faces.assign(categoryID: meeting, toFace: ManualFace.first))

        #expect(faces.categoryID(forFace: ManualFace.first) == meeting)
    }

    @Test func testReassigningReplacesWhatWasThere() throws {
        let meeting = try categoryID(named: "Meeting")
        let breakID = try categoryID(named: "Break")
        #expect(faces.assign(categoryID: meeting, toFace: ManualFace.first))

        #expect(faces.assign(categoryID: breakID, toFace: ManualFace.first))

        #expect(faces.categoryID(forFace: ManualFace.first) == breakID, "one category at a time")
    }

    @Test func testALockedFaceKeepsWhatItHas() throws {
        // Face 2 is seeded locked. Locking exists to stop a face being reassigned by accident, so the write
        // refuses rather than trusting every caller to have checked.
        let before = faces.categoryID(forFace: 2)
        let breakID = try categoryID(named: "Break")

        #expect(!(faces.assign(categoryID: breakID, toFace: 2)))

        #expect(faces.categoryID(forFace: 2) == before)
    }

    @Test func testClearingPutsAFaceBackToNothing() throws {
#expect(faces.assign(categoryID: try categoryID(named: "Meeting"), toFace: ManualFace.first))

        #expect(faces.clear(face: ManualFace.first))

        #expect(faces.categoryID(forFace: ManualFace.first) == nil)
    }

    @Test func testAFaceThatDoesNotExistHoldsNothing() {
        #expect(faces.categoryID(forFace: 99) == nil)
    }

    // MARK: - which faces hold a category

    @Test func testEveryFaceHoldingACategoryIsReported() throws {
        let meeting = try categoryID(named: "Meeting")
        #expect(faces.assign(categoryID: meeting, toFace: 13))
        #expect(faces.assign(categoryID: meeting, toFace: 14))

        let holding = faces.facesHolding(categoryID: meeting).map(\.face)

        // Face 2 is seeded with Meeting, and both manual faces now hold it too: one category, many faces, which is
        // exactly why retiring has to look at all of them.
        #expect(holding == [2, 13, 14])
    }

    @Test func testALockedFaceIsReportedAsLocked() throws {
        // Face 8 is seeded locked, holding Break.
        let holding = faces.facesHolding(categoryID: try categoryID(named: "Break"))

        #expect(holding.first { $0.face == 8 }?.isFaceLocked == true)
        #expect(holding.filter(\.isFaceLocked).map(\.face) == [8], "and nothing else is")
    }

    @Test func testACategoryOnNoFaceHoldsNothing() throws {
        // A category nobody has put anywhere, which is what every newly created one is.
        let fresh = try #require(categories.insert(name: "Reading"))

        #expect(faces.facesHolding(categoryID: fresh).isEmpty)
    }

    // MARK: - asking whether a face is locked

    @Test func testTheSeededFacesReportTheirLock() {
        // Faces 2 and 8 are the two the DDL seeds with a category, and both are seeded locked -- which makes a locked
        // face the ordinary case on a fresh database rather than an edge of it.
        #expect(faces.isFaceLocked(face: 2) == true)
        #expect(faces.isFaceLocked(face: 8) == true)
        #expect(faces.isFaceLocked(face: 5) == false, "an Unassigned face is free to take one")
    }

    @Test func testAManualFaceIsNeverLocked() {
        // Being reassigned is the whole point of them, so the guard `assign` shares must never catch one.
        for face in ManualFace.all {
            #expect(faces.isFaceLocked(face: face) == false, "manual face \(face)")
        }
    }

    @Test func testAFaceWithNoRowAnswersNothingRatherThanUnlocked() {
        // The two are different faults and a caller reports them differently: one is a face somebody protected, the
        // other is not a face at all.
        #expect(faces.isFaceLocked(face: 99) == nil)
    }

    @Test func testALockChangedElsewhereIsSeenByTheNextRead() {
        #expect(faces.isFaceLocked(face: 2) == true, "precondition")

        #expect(database.execute("UPDATE face SET locked = 0 WHERE face_id = 2;"))

        #expect(faces.isFaceLocked(face: 2) == false)
    }

    // MARK: - locking a face

    @Test func testAFaceCanBeLockedAndUnlocked() {
        #expect(faces.setLocked(true, face: 5))
        #expect(faces.isFaceLocked(face: 5) == true)

        #expect(faces.setLocked(false, face: 5))
        #expect(faces.isFaceLocked(face: 5) == false)
    }

    @Test func testUnlockingASeededFaceLetsItTakeACategoryAgain() {
        // The gesture the lock exists for, end to end: face 2 is seeded locked holding Meeting, and refuses Break
        // until it is unlocked.
        let breakID = try? categoryID(named: "Break")
        #expect(!(faces.assign(categoryID: breakID ?? 1, toFace: 2)), "precondition: locked faces refuse")

        #expect(faces.setLocked(false, face: 2))

        #expect(faces.assign(categoryID: breakID ?? 1, toFace: 2))
    }

    @Test func testLockingIsNotItselfRefusedByTheLock() {
        // Or it would be a switch that can only be flicked one way. Locking stops a *category* landing; it does not
        // stop the lock being changed.
        #expect(faces.isFaceLocked(face: 8) == true, "precondition: seeded locked")

        #expect(faces.setLocked(false, face: 8))
        #expect(faces.setLocked(true, face: 8))
    }

    @Test func testAFaceWithNoRowRefusesTheLock() {
        // Reported rather than silently doing nothing, so a caller can tell "not a face" from "done".
        #expect(!(faces.setLocked(true, face: 99)))
    }

    // MARK: - the design rule

    @Test func testAChangeMadeElsewhereIsSeenByTheNextRead() throws {
        let meeting = try categoryID(named: "Meeting")

        #expect(database.execute("UPDATE face SET category_id = \(meeting) WHERE face_id = \(ManualFace.first);"))

        #expect(faces.categoryID(forFace: ManualFace.first) == meeting, "read again, not remembered")
    }
}
