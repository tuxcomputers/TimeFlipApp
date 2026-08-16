import Foundation
import SQLite3

/// Brings the app's database up to the schema and seed data the code expects, and reports what it
/// did. One job, no opinions about what the database is then used for.
///
/// **Unconditional, deliberately.** There is no "does it exist yet" branch. `sqlite3_open_v2` with
/// `SQLITE_OPEN_CREATE` brings the file into being if it is missing, every live `CREATE` in
/// `database/*.sql` is `IF NOT EXISTS`, and every seed row is guarded by `WHERE NOT EXISTS` -- so
/// running the lot on a fresh database builds it, and running it on an established one changes
/// nothing. Branching would mean the first-launch path and the every-launch path were different
/// code, and only one of them runs on any given launch: the untravelled one is then the one that
/// breaks. This way a new install takes the path a daily user takes.
///
/// The invariant that makes it safe is that those files contain **no live `ALTER TABLE`** (see
/// `database/CLAUDE.md`: migrations are written commented-out and run by hand). If that ever
/// changes, `sqlite3_exec` stops at the first failing statement and silently abandons the rest of
/// that file -- the archived implementation carried a `skipSatisfiedColumnAdditions` pass for
/// exactly this, worth copying back on the day a migration lands rather than before.
enum DatabaseBootstrap {
    /// What one run did, so the caller can say so rather than guess.
    struct Outcome {
        let databaseURL: URL
        /// Whether the database file had to be brought into being. Reported, not acted on: the work
        /// below is identical either way.
        let createdDatabase: Bool
        /// Filenames applied, in the order they were applied.
        let filesApplied: [String]
    }

    enum Failure: Error, CustomStringConvertible {
        case ddlDirectoryNotFound
        case ddlDirectoryUnreadable(URL, String)
        case cannotCreateContainer(URL, String)
        case cannotOpenDatabase(URL, String)
        case fileUnreadable(String)
        case statementFailed(file: String, message: String)

        var description: String {
            switch self {
            case .ddlDirectoryNotFound:
                return "could not locate the bundled Database directory (Resources/Database)"
            case let .ddlDirectoryUnreadable(url, message):
                return "could not read the Database directory at \(url.path): \(message)"
            case let .cannotCreateContainer(url, message):
                return "could not create \(url.path): \(message)"
            case let .cannotOpenDatabase(url, message):
                return "could not open \(url.path): \(message)"
            case let .fileUnreadable(name):
                return "could not read \(name)"
            case let .statementFailed(file, message):
                return "\(file) failed: \(message)"
            }
        }
    }

    /// `~/Library/Application Support/Facet/appdata.sqlite`.
    ///
    /// Note for later: the archived app pointed this at a **symlink** to `production.sqlite`, so a
    /// testing session could repoint it at `test.sqlite` without touching real data. That scheme is
    /// not here yet, because nothing yet needs a test database. `scripts/switch-database.sh` still
    /// expects it, so it comes back when the device tests do.
    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Facet", isDirectory: true)
            .appendingPathComponent("appdata.sqlite")
    }

    /// The bundled `database/` directory, found by asking for a file known to be in it.
    ///
    /// Two bundles, because the executable runs two ways: `Bundle.main` when it is a built `.app`,
    /// and `Bundle.module` under `swift run`/`swift test`. Asking for a specific resource and
    /// stripping the filename is how the directory is located; SwiftPM flattens processed resources,
    /// so there is no directory to ask for by name.
    static func bundledDDLDirectory() -> URL? {
        (Bundle.main.url(forResource: "001_event_type", withExtension: "sql")
            ?? Bundle.module.url(forResource: "001_event_type", withExtension: "sql"))?
            .deletingLastPathComponent()
    }

    /// Open (creating if needed), then apply every `.sql` file in filename order.
    ///
    /// Both parameters are injectable so this is testable against a temporary database and the
    /// repository's own `database/` directory, with no bundle involved.
    @discardableResult
    static func ensureDatabase(
        at databaseURL: URL? = nil,
        ddlDirectory: URL? = nil
    ) throws -> Outcome {
        let url = databaseURL ?? defaultDatabaseURL()
        guard let ddl = ddlDirectory ?? bundledDDLDirectory() else {
            throw Failure.ddlDirectoryNotFound
        }

        // Filename order is load-bearing: the seeds carry real foreign keys, so parent tables have
        // to exist and be populated before children reference them (006_project before
        // 007_category, and so on). It is why the files are numbered rather than named.
        let files: [URL]
        do {
            files = try FileManager.default
                .contentsOfDirectory(at: ddl, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "sql" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw Failure.ddlDirectoryUnreadable(ddl, error.localizedDescription)
        }

        let container = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateContainer(container, error.localizedDescription)
        }

        // Recorded before opening, because opening is what creates it.
        let createdDatabase = !FileManager.default.fileExists(atPath: url.path)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw Failure.cannotOpenDatabase(url, message)
        }
        defer { sqlite3_close(db) }

        // Off by default in sqlite, and per-connection rather than a property of the file. Set
        // before any seed runs so the seeds' foreign keys are actually checked -- a seed inserting a
        // dangling reference should fail here, loudly, rather than sit in the database being wrong.
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)

        var applied: [String] = []
        for file in files {
            guard let sql = try? String(contentsOf: file, encoding: .utf8) else {
                throw Failure.fileUnreadable(file.lastPathComponent)
            }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw Failure.statementFailed(
                    file: file.lastPathComponent,
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
            applied.append(file.lastPathComponent)
        }

        return Outcome(databaseURL: url, createdDatabase: createdDatabase, filesApplied: applied)
    }
}
