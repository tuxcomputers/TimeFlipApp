import Foundation
import SQLite3

/// The trace as a **file**: whether there is one, taking a copy of it, and emptying it.
///
/// **Separate from `DebugLog` because the file outlives the launch, and outlives logging being on.** The support
/// sequence is turn it on, reproduce the fault, quit, then send the file -- and by the time somebody is sending it,
/// the launch they are sending it from very often has no logger at all (`debug.enabled` off is the ordinary state,
/// being what a fresh install seeds). Hanging these three on `DebugLog` made all three buttons on the App tab dead
/// while an 800KB trace sat in the folder beside them, which is where this type came from.
///
/// **Its own connection, opened per operation and closed after it.** Nothing here is on a hot path -- a person
/// presses a button -- and a connection held open would be a second handle on a file the logger may also have open,
/// for no gain. sqlite's own locking is what keeps the two apart, with a busy timeout so a write in flight is waited
/// for rather than reported as a failure.
///
/// **Every operation answers whether it worked, and says on the terminal why not.** A copy that did not happen looks
/// exactly like one that did until somebody opens it, and a clear that did not happen leaves somebody sending in a
/// trace they believe starts at the fault.
struct DebugTraceFile {
    let url: URL

    /// The one the app is writing to, or would write to.
    ///
    /// **The logger's own file wins.** `debug.directory` is what the *next* launch will use, so a folder chosen a
    /// minute ago names somewhere that holds no trace yet; the logger's is where this launch would write, including
    /// the fallback folder it moved to if the chosen one could not be opened. With no logger at all -- which is what
    /// a test builds -- the setting is the only answer there is.
    ///
    /// `@MainActor` because `DebugLog` is: the URL can move when a folder turns out to be unwritable.
    @MainActor
    static func inUse(by log: DebugLog?, directory: String) -> DebugTraceFile {
        if let url = log?.databaseURL { return DebugTraceFile(url: url) }
        return DebugTraceFile(
            url: DatabaseBootstrap.debugDatabaseURL(in: DebugTraceRules.directoryURL(from: directory))
        )
    }

    /// Whether there is a file to act on at all. Nothing here is offered when there is not.
    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes a complete copy of the trace to `destination`, and answers whether it is there.
    ///
    /// **`VACUUM INTO` rather than copying the file.** A trace may be being written while it is being sent, so
    /// copying the bytes takes whatever was half-written at that moment and leaves any `-wal` and `-shm` beside it
    /// behind; this asks sqlite for one consistent file. What lands is a single file that opens on its own, which is
    /// what somebody can attach to an email.
    ///
    /// **The destination is removed first if it exists**, because `VACUUM INTO` refuses to write over a file and the
    /// save panel has already had the conversation about replacing one.
    func copy(to destination: URL) -> Bool {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try? FileManager.default.removeItem(at: destination)) != nil else {
                report("the trace could not be copied: \(destination.path) is in the way")
                return false
            }
        }
        return open { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "VACUUM INTO ?;", -1, &statement, nil) == SQLITE_OK else {
                report("the trace could not be copied: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            sqlite3_bind_text(statement, 1, destination.path, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                report("the trace could not be copied: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    /// Empties the trace, and answers whether it is empty.
    ///
    /// **The rows go and the file stays.** Deleting `debug.sqlite` and building it again would mean re-applying the
    /// DDL, and doing it under a running logger would pull the file out from under an open connection and a prepared
    /// insert. Emptying the table cannot do that: whatever has the file open goes on writing to it exactly as before.
    ///
    /// **`timezone` is deliberately left alone.** A running `DebugLog` resolved its `timezone_id` when it opened and
    /// every row it writes carries that id as a real foreign key, so clearing that table as well would make the very
    /// next message fail to insert.
    ///
    /// **`VACUUM` afterwards, because the point of clearing is usually the size.** sqlite frees the pages for reuse
    /// but does not shrink the file, and somebody clearing the trace before reproducing a fault is about to send
    /// whatever is left. A `VACUUM` that fails is reported and does not fail the clear: the rows are gone either way,
    /// which is what was asked for.
    ///
    /// **The answer comes from counting what is left**, not from the statement's return code, which is the same rule
    /// `SettingStore.write` follows.
    ///
    /// **`debug_log_id` deliberately does not go back to 1.** The column is `AUTOINCREMENT`, so sqlite keeps the
    /// highest id it has ever issued in `sqlite_sequence` and neither the delete nor the `VACUUM` touches it: the
    /// next row after a clear carries on from where the last one stopped. Resetting it would take a deliberate
    /// `DELETE FROM sqlite_sequence` and must not be added -- every scripted check is a baseline of
    /// `MAX(debug_log_id)` followed by a poll for rows above it (`Tests/Scripted/lib.sh`), so ids that start again
    /// would put every later row underneath a baseline taken before the clear, and every wait would time out
    /// against an app that was answering perfectly well.
    func clear() -> Bool {
        open { db in
            guard sqlite3_exec(db, "DELETE FROM debug_log;", nil, nil, nil) == SQLITE_OK else {
                report("the trace could not be cleared: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            if sqlite3_exec(db, "VACUUM;", nil, nil, nil) != SQLITE_OK {
                report("the trace was cleared but the file was not shrunk: \(String(cString: sqlite3_errmsg(db)))")
            }
            guard rowCount(on: db) == 0 else {
                report("the trace still holds rows after being cleared")
                return false
            }
            return true
        }
    }

    private func open(_ work: (OpaquePointer) -> Bool) -> Bool {
        var handle: OpaquePointer?
        // **No `SQLITE_OPEN_CREATE`.** Acting on a trace that is not there should say so rather than quietly bring an
        // empty one into being and report success.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            report("the trace at \(url.path) could not be opened: \(message)")
            return false
        }
        defer { sqlite3_close(db) }
        // The app may have this file open and be part way through a write. Wait rather than report a fault: a button
        // press is worth a few milliseconds of patience, which is what `DebugLog` does on the same file.
        sqlite3_busy_timeout(db, 2_000)
        return work(db)
    }

    private func rowCount(on db: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM debug_log;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Says what went wrong where the trace itself cannot, the trace being the thing that is not working.
    private func report(_ message: String) {
        FileHandle.standardError.write(Data("facet: \(message)\n".utf8))
    }
}

/// sqlite's own "copy this string" sentinel, which the C macro defines as `((sqlite3_destructor_type) -1)` and so
/// does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
