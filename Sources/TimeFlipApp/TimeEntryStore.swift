import Foundation

/// The `time_entry` table, read. `TimeEntryRecorder` is what writes it.
///
/// Split because the questions are different sizes: writing an entry is a decision about one segment, and
/// reading is "how much time does this category have". They share a table and nothing else.
@MainActor
final class TimeEntryStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// Seconds recorded against a category inside a window, clipped to it.
    ///
    /// **Summed from the rows every time it is asked, never accumulated.** The previous app kept a running
    /// tally per category and had to delete it: a figure the database cannot be asked to confirm drifts from
    /// the rows it claims to summarise, and it did -- segments are deliberately re-written as their durations
    /// grow, so adding each one as it arrived double-counted. Re-deriving cannot drift.
    ///
    /// The start of a stretch comes from `device_event.start_epoch` rather than `time_entry.started_at`: the
    /// epoch is a number, where the text column is local time with no offset and would need converting back
    /// before it could be compared with anything.
    ///
    /// Clipped in the statement rather than row by row in Swift, so this is one read of one row however much
    /// history it covers -- it is asked once a second while a clock is on screen.
    func seconds(categoryID: Int, from windowStart: Date, to now: Date) -> TimeInterval {
        let windowEpoch = windowStart.timeIntervalSince1970
        let nowEpoch = now.timeIntervalSince1970
        var total: TimeInterval = 0
        connection.forEachRow(
            """
            SELECT IFNULL(SUM(
                MAX(0, MIN(de.start_epoch + te.duration_seconds, \(nowEpoch)) - MAX(de.start_epoch, \(windowEpoch)))
            ), 0)
            FROM time_entry te
            JOIN device_event de ON de.device_event_id = te.device_event_id
            WHERE te.category_id = \(categoryID)
              AND (de.start_epoch + te.duration_seconds) > \(windowEpoch)
              AND de.start_epoch < \(nowEpoch);
            """
        ) { row in
            total = row.double(0)
        }
        return total
    }

    /// When this category last finished recording time, or `nil` if it never has.
    ///
    /// The end of its last entry rather than the start: "last used" is when the using stopped. **From the epoch on
    /// the segment, not from `started_at`**, which is the archive's finding rather than a preference -- a local-time
    /// string cannot be compared or ordered across a daylight-saving change, so the two rows either side of a
    /// changeover would sort wrongly.
    ///
    /// Asked per retired row as the Inactive list is built, rather than joined onto every category read. The archive
    /// carried it as a column on its category load, which this app cannot afford: `CategoryStore.category(id:)` is
    /// read once a second while a clock is on screen, and a subquery over `time_entry` on each of those buys nothing
    /// -- an active row draws no date at all (see `CategoryLastUsedText`).
    func lastUsed(categoryID: Int) -> Date? {
        var epoch: Double?
        connection.forEachRow(
            """
            SELECT MAX(de.start_epoch + te.duration_seconds)
            FROM time_entry te
            JOIN device_event de ON de.device_event_id = te.device_event_id
            WHERE te.category_id = \(categoryID);
            """
        ) { row in
            // MAX over no rows is one row holding NULL, which reads back as 0 -- a category that has never recorded
            // time, not one used at the epoch.
            let value = row.double(0)
            epoch = value > 0 ? value : nil
        }
        return epoch.map(Date.init(timeIntervalSince1970:))
    }
}
