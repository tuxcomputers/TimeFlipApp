import Foundation

/// The `timezone` table: the id every stored date and time hangs its zone on.
///
/// **Seeded with every zone tzdb knows, at ids that are the same in every Facet database.** 447 zones plus
/// the `Unknown` sentinel at 0, written out in `002_timezone.sql`, so `timezone_id 116` is
/// `America/Havana` in this machine's database, in the next machine's, and in the debug file beside it.
/// Before that they were handed out in visit order, which made an id mean whatever the file it sat in
/// happened to have seen first -- two databases on one Mac disagreed about what id 1 meant.
///
/// **Reads go through `timezone_lookup`, never the table**, because that view carries the 151 legacy names
/// as well (`Cuba`, `US/Pacific`, `Asia/Calcutta`) and answers each with the id of the zone that replaced
/// it. A machine set to a legacy name is not a hypothetical: measured 2026-09-07, `TZ=Cuba` makes
/// `TimeZone.current.identifier` answer `Cuba` verbatim, and nothing in Foundation canonicalises it.
///
/// It is still **not** covered by the reference-table exception in `CLAUDE.md`, and by a narrower margin
/// than before: the app writes a row only for a zone the seed does not know, which is a tzdb release
/// newer than `002_timezone.sql`.
///
/// Read at the point of use like everything else. The previous app resolved this once at startup and held
/// it, reasoning that the identifier only changes if the machine physically moves between zones, which is
/// true -- but a lookup at the rate a person flips a cube buys nothing for the risk of a row filed under
/// the zone the app launched in.
@MainActor
package final class TimezoneStore {
    private let connection: DatabaseConnection

    package init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// The id for the machine's current zone, creating the row if this is the first time it has been seen.
    ///
    /// Falls back to the seeded `Unknown` row (id 0) rather than failing: a segment recorded against an
    /// unknown zone is a small loss, and a segment not recorded at all is the time itself.
    func currentID() -> Int {
        id(for: TimeZone.current.identifier)
    }

    /// The id for a named IANA zone (`Australia/Sydney`), or for any legacy name that resolves to one
    /// (`Cuba`), creating the row only for a zone the seed has never heard of.
    func id(for name: String) -> Int {
        if let seeded = lookup(name) { return seeded }

        // **A name the seed does not carry, which means a tzdb release newer than `002_timezone.sql`.**
        // Recorded rather than dropped: filing it under `Unknown` would lose which zone the time was
        // taken in, and that is the one thing the column exists to say. `AUTOINCREMENT` is what makes
        // this safe now that the seeded ids are fixed -- the row lands above the whole seeded block
        // (448 and up), so it cannot take an id that a later release of the seed then claims for a
        // different zone. **A row up there is the signal to add the zone to the DDL**, and until
        // somebody does, that id means this zone on this machine only.
        //
        // Guarded insert rather than `INSERT OR IGNORE`, which would consume an id for the row it then
        // discards, and the same shape the DDL's own seeds use.
        connection.execute(
            "INSERT INTO timezone (timezone_name) SELECT ?1 "
                + "WHERE NOT EXISTS (SELECT 1 FROM timezone WHERE timezone_name = ?1);",
            bind: [name]
        )

        // **Read back off the table, not the view.** The row just written is in `timezone` by
        // definition, and this is the write's own read-back rather than another name resolution -- so it
        // asks the question it means. It also keeps the one path that reaches this far from depending on
        // the view twice: `forEachRow` returns silently on a query it cannot prepare, so a database
        // somehow missing `timezone_lookup` would otherwise file every row under `Unknown` and say
        // nothing about it.
        var written: Int?
        connection.forEachRow(
            "SELECT timezone_id FROM timezone WHERE timezone_name = ?;",
            bind: [name]
        ) { row in
            written = Int(row.int(0))
        }
        return written ?? 0
    }

    /// What `timezone_lookup` answers for a name, or `nil` if it answers nothing.
    ///
    /// The view is `timezone` and `timezone_alias` unioned, so one query covers both a canonical name and
    /// a legacy one, and the answer for either is the canonical row's id. It is read-only, which is the
    /// half that matters here: the resolution rule lives in the database, where a scripted check reads it
    /// with the same query the app does.
    private func lookup(_ name: String) -> Int? {
        var found: Int?
        connection.forEachRow(
            "SELECT timezone_id FROM timezone_lookup WHERE timezone_name = ?;",
            bind: [name]
        ) { row in
            found = Int(row.int(0))
        }
        return found
    }
}
