import Foundation

/// The `timezone` table: the id every stored date and time hangs its zone on.
///
/// Get-or-create, because the table is seeded with one row (`Unknown`, id 0) and fills up as the machine
/// visits zones. That makes it the one reference-shaped table that is **not** covered by the
/// reference-table exception in `CLAUDE.md`: the app writes to it.
///
/// Read at the point of use like everything else. The previous app resolved this once at startup and held
/// it, reasoning that the identifier only changes if the machine physically moves between zones, which is
/// true -- but a lookup at the rate a person flips a cube buys nothing for the risk of a row filed under
/// the zone the app launched in.
@MainActor
final class TimezoneStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// The id for the machine's current zone, creating the row if this is the first time it has been seen.
    ///
    /// Falls back to the seeded `Unknown` row (id 0) rather than failing: a segment recorded against an
    /// unknown zone is a small loss, and a segment not recorded at all is the time itself.
    func currentID() -> Int {
        id(for: TimeZone.current.identifier)
    }

    /// The id for a named IANA zone (`Australia/Sydney`), creating the row if it is not there yet.
    func id(for name: String) -> Int {
        // Guarded insert rather than `INSERT OR IGNORE`, which would consume an AUTOINCREMENT id for the
        // row it then discards, and the same shape the DDL's own seeds use.
        connection.execute(
            "INSERT INTO timezone (timezone_name) SELECT ?1 "
                + "WHERE NOT EXISTS (SELECT 1 FROM timezone WHERE timezone_name = ?1);",
            bind: [name]
        )

        var found: Int?
        connection.forEachRow("SELECT timezone_id FROM timezone WHERE timezone_name = ?;", bind: [name]) { row in
            found = Int(row.int(0))
        }
        return found ?? 0
    }
}
