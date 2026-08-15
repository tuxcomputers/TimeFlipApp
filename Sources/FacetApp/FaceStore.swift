import Foundation

/// The `face` table: which category each face of the cube is assigned to, including the app's own face 13.
///
/// One read per ask and nothing kept -- see `SettingStore` for the rule. It deals in ids rather than
/// whole categories, so the two tables stay with their own readers: what a category *is* comes from
/// `CategoryStore`, and which one a face holds comes from here.
@MainActor
final class FaceStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// The category assigned to a face, or `nil` if the face holds the seeded *Unassigned* row (id 0) --
    /// which is a face with nothing on it, not a face holding a category called Unassigned.
    func categoryID(forFace faceID: Int) -> Int? {
        var assigned: Int?
        connection.forEachRow("SELECT category_id FROM face WHERE face_id = \(faceID);") { row in
            let categoryID = Int(row.int(0))
            assigned = categoryID == 0 ? nil : categoryID
        }
        return assigned
    }

    /// Puts a category on a face, and reports whether it took.
    ///
    /// A locked face keeps what it has: locking exists to stop a face being reassigned by accident, so the
    /// write refuses rather than trusting every caller to have checked. Face 13 is never locked -- being
    /// reassigned is the whole point of it -- so manual mode is unaffected by the guard it shares.
    @discardableResult
    func assign(categoryID: Int, toFace faceID: Int) -> Bool {
        // The row count, not just the step: the statement runs happily against a locked face and changes
        // nothing, and "refused" has to be distinguishable from "done".
        return connection.execute(
            "UPDATE face SET category_id = \(categoryID) WHERE face_id = \(faceID) AND locked = 0;"
        ) && connection.changes > 0
    }

    /// Clears a face back to *Unassigned*.
    func clear(face faceID: Int) -> Bool {
        assign(categoryID: 0, toFace: faceID)
    }

    /// Every face holding this category, and whether each is locked.
    ///
    /// Both halves in one read because both answers are needed together: retiring a category takes it off the faces
    /// it is on, and a locked face is one the user has said keeps what it has, so the question is never "which faces"
    /// without "and may I".
    func facesHolding(categoryID: Int) -> [(face: Int, isLocked: Bool)] {
        var found: [(face: Int, isLocked: Bool)] = []
        connection.forEachRow(
            "SELECT face_id, locked FROM face WHERE category_id = \(categoryID) ORDER BY face_id;"
        ) { row in
            found.append((face: Int(row.int(0)), isLocked: row.bool(1)))
        }
        return found
    }
}
