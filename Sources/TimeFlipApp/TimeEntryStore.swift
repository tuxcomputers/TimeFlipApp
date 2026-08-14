import AppKit

/// One category's share of a range: what it is called, what it is drawn with, and how many seconds of it fall inside.
///
/// Carries what a row needs to draw rather than a category id to look up, because the totals are one read: joining the
/// name, the icon and the colour in the same statement is what stops a list of totals becoming a query per row.
struct CategoryTotal: Equatable {
    let categoryID: Int
    let name: String
    /// `nil` for the None icon (`icon_id` 0), a sentinel row rather than a bundled asset.
    let iconName: String?
    /// `nil` for the None colour (`colour_id` 0), which has no hex of its own.
    let colour: NSColor?
    let usesWhiteLines: Bool
    /// Seconds inside the range, with a stretch that straddles either end clipped to it.
    let seconds: TimeInterval
}

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

    /// What every category recorded inside a range, biggest first, and **only the ones that recorded something**.
    ///
    /// A category with nothing in the range is absent rather than listed as `0:00`: the question this answers is what
    /// the time went on, and a page of zeroes would bury the answer in categories that have nothing to do with it. It
    /// is also why the empty range says so in words instead of drawing an empty table.
    ///
    /// **Clipped at both ends**, so a stretch running across the boundary is split between the two reports that
    /// contain its halves rather than counted whole in both. The archive's statement, and its reason for grouping in
    /// sqlite rather than summing in Swift: this is one read however much history it covers.
    ///
    /// The start comes from `device_event.start_epoch` rather than `time_entry.started_at`, as everywhere else here:
    /// the epoch is a number, where the text column is local time with no offset and could not be compared.
    ///
    /// A **still-running** segment contributes nothing, because it is not an entry yet. `time_entry` is what the app
    /// counts, written when a segment closes, so a clock running right now shows on the Faces tab and in the menu bar
    /// and arrives here when it stops.
    func totals(from windowStart: Date, to windowEnd: Date) -> [CategoryTotal] {
        let startEpoch = windowStart.timeIntervalSince1970
        let endEpoch = windowEnd.timeIntervalSince1970
        var totals: [CategoryTotal] = []
        connection.forEachRow(
            """
            SELECT te.category_id, c.category_name, i.icon_name, l.device_hex, l.white_lines,
                   SUM(MIN(de.start_epoch + te.duration_seconds, \(endEpoch)) - MAX(de.start_epoch, \(startEpoch)))
                   AS seconds
              FROM time_entry te
              JOIN device_event de ON de.device_event_id = te.device_event_id
              JOIN category c ON c.category_id = te.category_id
              JOIN icon i ON i.icon_id = c.icon_id
              JOIN colour l ON l.colour_id = c.colour_id
             WHERE de.start_epoch < \(endEpoch)
               AND (de.start_epoch + te.duration_seconds) > \(startEpoch)
             GROUP BY te.category_id, c.category_name, i.icon_name, l.device_hex, l.white_lines
            HAVING seconds > 0
             ORDER BY seconds DESC, c.category_name;
            """
        ) { row in
            let iconName = row.string(2)
            totals.append(
                CategoryTotal(
                    categoryID: Int(row.int(0)),
                    name: row.string(1) ?? "",
                    // The None row is named "None" rather than left null, so the name is the sentinel.
                    iconName: iconName == "None" ? nil : iconName,
                    colour: row.string(3).flatMap(NSColor.init(hex:)),
                    usesWhiteLines: row.bool(4),
                    seconds: row.double(5)
                )
            )
        }
        return totals
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
