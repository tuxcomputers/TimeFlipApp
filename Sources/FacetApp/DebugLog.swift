import Foundation
import SQLite3

/// Dev-only logging. One call, two destinations: a line on the terminal, and a `debug_log` row.
///
/// The row is the point of it. A terminal transcript is whatever the person running the app happened
/// to still have in a scrollback buffer, while a row outlives the session and can be queried
/// afterwards -- which is the difference between reconstructing what a failed run did and re-running
/// it in the hope it fails the same way twice.
///
/// **Its own connection to the database, deliberately.** Not because sharing one would be hard, but
/// because a diagnostic record that rides inside somebody else's transaction is rolled back with it:
/// the log of what the app was doing when it went wrong would disappear along with the work that went
/// wrong. Separate connection, no shared transaction, nothing to undo it.
///
/// Gated on `DeveloperMode.isEnabled` at the point of construction, so an app built without the dev
/// flag has no logger at all rather than a logger that returns early. (`011_setting.sql` also seeds a
/// `debug` setting for turning this on and off without a rebuild. Nothing reads it yet -- one gate is
/// enough while the only audience is a developer with a terminal open.)
@MainActor
final class DebugLog {
    /// Which subsystem a message came from. The table's `tag` column and the console prefix are the
    /// same value, so there is one list rather than two that can disagree.
    ///
    /// `bracketed` right-pads to the width of the longest case, so console lines stay aligned however
    /// they interleave. The width is derived rather than written down, which means a new case re-pads
    /// every existing tag automatically -- so **add a case here** rather than putting a literal
    /// `[Tag]` in a message, and check the console after adding a long one.
    enum Tag: String, CaseIterable {
        /// Clicks on the status item, and which half they landed on.
        case click
        /// What the status item is drawn in: the colour of its name, its glyph and its figure
        /// (`StatusItemTitle.colourDescription`). **A row per change, not per draw**, as `battery` and `face` are:
        /// the figure moves every second, so a row per drawn title would be a row per second for the life of the
        /// launch. Its own tag because it is the only evidence there is -- the accessibility tree carries no colour
        /// at all, so a scripted check has no other way to see what the line said.
        case status
        /// Selections from the dropdown.
        case menu
        /// Moving between the Settings window's tabs.
        case tab
        /// Which mode a launch is running in.
        case mode
        /// Segments written to `device_event`, and what recording each one did to the rows already there.
        case event
        /// The history timer: every time it fires, and when the interval it asks on changes.
        case history
        /// Whether a finished segment became tracked time, and what it was filed under.
        case entry
        /// A value typed or stepped into a field, and what became of it.
        case field
        /// The Report tab's date range: which days are picked, and which month a calendar is showing.
        case report
        /// The steps the app takes on its way out (`QuitSequence`).
        case quit
        /// Entries on their way into the Google calendar, and what stopped them (`CalendarSync`).
        case sync
        /// A category spending its `daily_limit`, and the clock being stopped for it (`DailyLimitWatch`).
        case limit
        /// A pause the app put on the cube for a reason of its own, and what lifted it (`ForcedPause`). Its own tag
        /// rather than `command`, which says what went down the wire: a scripted check needs to tell a pause the app
        /// forced from one the user asked for, and the two put the same bytes on the wire.
        case forced
        /// Looking for a device: what the radio is doing, and both names of every advertisement listed
        /// (`BluetoothRadio`). Both, because the scan list is where the two disagree.
        case scan
        /// Reaching a cube and presenting its PIN: each attempt, which PIN was tried, and what the cube made of it
        /// (`BluetoothRadio`, `DeviceLogin`).
        case login
        /// Setting a cube's PIN once it has let the app in, and what became of the new one: whether the cube proved
        /// it took it, and whether it was written down (`DeviceLogin`, `DeveloperConfigFile`). Its own tag rather
        /// than `login`, because reaching a cube and changing what it will answer to next time are different
        /// questions, and the second is the one somebody reads the log for when a cube stops letting them in.
        case pin
        /// What a confirmed login wrote down about the device: the pairing, the cube's name, and the connection going
        /// up and down (`DevicePairingRecorder`). Separate from `login` because these rows outlive the link -- they
        /// are what the next launch reads to know it has a device at all.
        case pair
        /// What a cube says it is: the Device Information reads that follow a login, and what became of them
        /// (`DeviceLogin`, `DevicePairingRecorder`). Its own tag rather than `login`, because these run after the
        /// verdict and cannot change it -- a cube that answers none of them is logged in exactly the same -- so a row
        /// here is never part of the story of why a device could or could not be reached.
        case info
        /// The cube's double-tap registers as the cube itself reports them (`DoubleTapRules`), which is a different
        /// thing from the `double_tap_settings` row: that is what the app would like them to be, and the two have no
        /// reason to agree until the Device tab sends a `0x16`. Its own tag because the answer explains a physical
        /// behaviour -- why a knock through a desk pauses the cube and a finger tap does not -- rather than anything
        /// about a connection. What the Device tab does about it is `field`, that being a control being used.
        case tap
        /// The cube's charge: the figure being shown as it changes, and the warning arming and clearing
        /// (`BluetoothRadio`, `LowBatteryWatch`). **A row per change, not per reading** -- the cube pushes a value
        /// every time it wavers between two adjacent percentages, which the archive measured at 2,168 notifications
        /// in one day for a charge that was only ever 98 or 99. Every one of those is already in the trace below, so
        /// a row here means the answer moved rather than that the cube spoke.
        case battery
        /// Which face the cube is resting on: the read taken when the link comes up, and every flip after it
        /// (`DeviceLogin`, `BluetoothRadio`). **A row per change**, as `battery` is, so a row here means the cube
        /// turned over rather than that it spoke -- every arrival is already in the trace below.
        case face
        /// Commands the app tells the cube to obey, and whether it acknowledged them (`DeviceCommandRules`,
        /// `DeviceLogin.send`). Its own tag rather than `login`, because these are the app changing the device's
        /// behaviour rather than reaching it -- and an acknowledgement here says the cube heard, never that it obeyed.
        case command
        /// Bytes written to the device. See `BLETrace` for why the traffic is logged in full and in both directions.
        case transmit = "ble-tx"
        /// Bytes received from it, whether asked for or notified.
        case receive = "ble-rx"

        private static let width = allCases.map(\.rawValue.count).max() ?? 0

        var bracketed: String {
            "[\(rawValue.padding(toLength: Self.width, withPad: " ", startingAt: 0))]"
        }
    }

    /// The sqlite handles, held in their own object so they can be closed when the log goes away.
    ///
    /// A `@MainActor` class's `deinit` is not itself main-actor-isolated, so it cannot touch the
    /// class's own non-Sendable stored properties -- which is a compile error rather than a subtlety.
    /// An unisolated owner sidesteps it and puts the close next to the open, instead of leaving the
    /// handles to be leaked for the life of the process.
    private final class Connection {
        var db: OpaquePointer?
        var insert: OpaquePointer?

        deinit {
            sqlite3_finalize(insert)
            sqlite3_close(db)
        }
    }

    private let connection = Connection()
    /// Resolved once. The zone identifier only changes if the machine moves between zones mid-session
    /// -- daylight saving stays within one IANA id -- so re-resolving per row would be a lookup per
    /// click to catch something that happens on a plane.
    private var timezoneID: Int64 = 0
    /// A failed write is reported once, not once per click. Silence would be worse: a run reconstructed
    /// from an empty table looks like a run where nothing happened.
    private var hasReportedWriteFailure = false

    init(databaseURL: URL) {
        // Line-buffered stdout. Otherwise a click's line sits in the buffer until the process exits
        // normally, so a killed run prints nothing at all -- and this app is quit from a menu, which
        // is exactly the case where somebody reaches for Ctrl-C instead and loses the lot.
        setvbuf(stdout, nil, _IOLBF, 0)
        openDatabase(at: databaseURL)
    }

    /// Prints the message and records it.
    ///
    /// Printing does not depend on the recording: if the database could not be opened the terminal
    /// half still works, because the two halves fail for unrelated reasons and losing both to one of
    /// them would be a poor trade.
    ///
    /// Writes synchronously, on the main thread the click arrived on. Fine at the rate a person
    /// clicks; if a tag ever logs on a timer, this needs a queue before it gets one.
    func record(_ tag: Tag, _ message: String) {
        let now = Date()
        print("\(Self.consoleTime.string(from: now)) \(tag.bracketed) \(message)")
        write(tag: tag, message: message, at: now)
    }

    // MARK: - the row

    private func write(tag: Tag, message: String, at moment: Date) {
        guard let insert = connection.insert else { return }
        sqlite3_reset(insert)
        sqlite3_clear_bindings(insert)
        // SQLITE_TRANSIENT: sqlite copies the bytes rather than holding a pointer into a Swift string
        // whose lifetime ends with this call.
        sqlite3_bind_text(insert, 1, Self.rowTime.string(from: moment), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insert, 2, timezoneID)
        sqlite3_bind_text(insert, 3, tag.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(insert, 4, message, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            reportWriteFailure()
            return
        }
    }

    private func reportWriteFailure() {
        guard !hasReportedWriteFailure else { return }
        hasReportedWriteFailure = true
        let message = connection.db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database connection"
        print("\(Self.consoleTime.string(from: Date())) \(Tag.click.bracketed) debug_log rows are not being written: \(message)")
    }

    // MARK: - the connection

    private func openDatabase(at databaseURL: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle
        else {
            sqlite3_close(handle)
            reportWriteFailure()
            return
        }
        connection.db = handle
        // Enforced per connection, not stored in the file, so this one needs it too: the row's
        // `timezone_id` is a real foreign key and a bad one should fail here rather than sit in the
        // table pointing at nothing.
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        // Two connections to one file means one can find the other mid-write. Wait rather than drop
        // the row: a click log is worth a few milliseconds of patience.
        sqlite3_busy_timeout(handle, 2_000)
        timezoneID = resolveTimezoneID(TimeZone.current.identifier, on: handle)
        prepareInsert(on: handle)
    }

    private func prepareInsert(on handle: OpaquePointer) {
        // Prepared once and reused, since this runs on every logged message.
        guard sqlite3_prepare_v2(
            handle,
            "INSERT INTO debug_log (logged_at, timezone_id, tag, message) VALUES (?, ?, ?, ?);",
            -1,
            &connection.insert,
            nil
        ) == SQLITE_OK else {
            connection.insert = nil
            reportWriteFailure()
            return
        }
    }

    /// Get-or-create against `timezone`, falling back to the seeded `Unknown` row (id 0) so a row can
    /// always satisfy the foreign key.
    private func resolveTimezoneID(_ name: String, on handle: OpaquePointer) -> Int64 {
        var upsert: OpaquePointer?
        defer { sqlite3_finalize(upsert) }
        if sqlite3_prepare_v2(
            handle,
            "INSERT INTO timezone (timezone_name) SELECT ?1 WHERE NOT EXISTS "
                + "(SELECT 1 FROM timezone WHERE timezone_name = ?1);",
            -1,
            &upsert,
            nil
        ) == SQLITE_OK {
            sqlite3_bind_text(upsert, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_step(upsert)
        }

        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT timezone_id FROM timezone WHERE timezone_name = ?;",
            -1,
            &query,
            nil
        ) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_text(query, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(query) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(query, 0)
    }

    // MARK: - formats

    /// `13:25:38`, the console prefix. Local time, zero-padded 24-hour, and POSIX-locale so a machine
    /// set to a 12-hour region still logs 13:25:38.
    private static let consoleTime = timeFormatter("HH:mm:ss")

    /// `2026-08-12T13:25:38.472`, the stored form: local time, no offset (the zone is the row's own
    /// foreign key), and milliseconds. Every BLE round trip this app makes is sub-second, so at
    /// whole-second resolution a duration between two log lines could only be guessed at.
    private static let rowTime = timeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")

    private static func timeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

/// sqlite's own "copy this string" sentinel, which the C macro defines as `((sqlite3_destructor_type)
/// -1)` and so does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
