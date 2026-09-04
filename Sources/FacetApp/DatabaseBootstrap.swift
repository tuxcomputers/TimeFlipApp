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
    /// **This is a symlink in practice**, pointing at `production.sqlite` or `test.sqlite`, so a
    /// testing session can be repointed without touching real data. The app never creates or follows
    /// it deliberately -- it opens this path and sqlite resolves whatever is there --
    /// `scripts/switch-database.sh` is what makes and moves the link, and `setting.db_type` is how a
    /// launch says which one it landed on.
    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Facet", isDirectory: true)
            .appendingPathComponent("appdata.sqlite")
    }

    /// `~/Library/Application Support/Facet/debug.sqlite`, beside the app's own database.
    ///
    /// **A separate file, and that is the point of it.** It is what somebody sends in when they turn the debug setting
    /// on, so it carries the trace and nothing else: no `time_entry`, no `category`, no Google account. It also takes
    /// the log out of the file the app is trying to write, which is not a theoretical tidiness -- `debug_log` was a
    /// table in `appdata.sqlite` until 2026-08-22, anything reading it locked the file against the app, and a
    /// confirmed pairing was lost to exactly that (see `DatabaseConnection`'s busy timeout).
    ///
    /// It sits in the same directory as `production.sqlite` and `test.sqlite` so a session switching between those
    /// finds its log in the one place. That is only the default: the `debug` setting names the folder, which is what
    /// `directory` carries, and this is where the file inside it gets its name.
    ///
    /// - Parameter directory: the folder to keep the trace in. `nil` for the one beside the app's own database.
    static func debugDatabaseURL(in directory: URL? = nil) -> URL {
        (directory ?? defaultDatabaseURL().deletingLastPathComponent()).appendingPathComponent("debug.sqlite")
    }

    /// Brings the debug database up: `debug.sqlite`, with the `500` files and nothing else.
    @discardableResult
    static func ensureDebugDatabase(at databaseURL: URL? = nil, ddlDirectory: URL? = nil) throws -> Outcome {
        try ensureDatabase(
            at: databaseURL ?? debugDatabaseURL(),
            ddlDirectory: ddlDirectory,
            numbered: firstDebugDDLNumber..<Int.max
        )
    }

    /// Which database a numbered DDL file belongs to.
    ///
    /// **Below 500 is the app's; 500 and above is the debug log's.** One flat directory holds both, because
    /// `Package.swift` processes `Resources` and SwiftPM flattens what it processes -- a real subdirectory would be
    /// folded back in here and applied to whichever database asked first. So the number carries the answer, the same
    /// way `Tests/Scripted` numbers a check by whether it needs a TimeFlip.
    ///
    /// The gap between `011` and `500` is deliberate room: the app's schema grows upwards into it and the debug
    /// database's grows upwards from `500`, and neither renumbers the other to make space.
    static let firstDebugDDLNumber = 500

    private static func ddlNumber(of file: URL) -> Int {
        Int(file.lastPathComponent.prefix(3)) ?? 0
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

    /// Open (creating if needed), then apply the `.sql` files this database owns, in filename order.
    ///
    /// **`numbered` is what keeps the two schemas apart.** One flat directory holds both, so without it the debug
    /// log's tables would be created in `appdata.sqlite` and the app's in `debug.sqlite` -- each database getting the
    /// other's schema as well as its own. It defaults to the app's range, so an existing caller keeps its meaning.
    ///
    /// All three parameters are injectable so this is testable against a temporary database and the repository's own
    /// `database/` directory, with no bundle involved.
    @discardableResult
    static func ensureDatabase(
        at databaseURL: URL? = nil,
        ddlDirectory: URL? = nil,
        numbered: Range<Int> = 0..<firstDebugDDLNumber
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
                .filter { numbered.contains(ddlNumber(of: $0)) }
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
