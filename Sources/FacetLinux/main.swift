import FacetCore
import Foundation

// **The Linux entry point, and it is deliberately only the part that has an answer.** Startup, in the
// same order as the macOS `main.swift` and for the same reasons: prove this is the only instance, bring
// the database up, then start the trace. Every step is ahead of the one that would be wrong to do twice.
//
// **What is missing here is missing on purpose, not forgotten.** There is no window and no radio, because
// the toolkit is undecided (item 11 of `docs/linux-port.md`) and the BlueZ backend is item 10. This exists
// so that the thing above it can be true: `Package.swift` declares a product on this platform, so
// `swift build` has something to build and `Tests/Scripted/` can build and launch it the way it does on
// the Mac. It is the boot, and the boot alone.
//
// **Nothing in here is Linux-specific.** Every line below is `FacetCore`, and it is a near-transcription
// of lines 14 to 72 of `Sources/FacetApp/main.swift`, which is AppKit-free until line 110. That is the
// point: whichever way the toolkit goes, this prefix is what runs before it -- the `main` of a headless
// daemon in the two-process design, and the part before `Gtk.main()` in the one-process design.

// Kept for the life of the process, which is the whole of what it does: the lock lives on an open file
// descriptor, so letting this go would hand the app's identity to the next launch mid-run.
let instanceLock: InstanceLock?
switch InstanceLock.claim() {
case let .success(lock):
    instanceLock = lock
case .failure(.heldByAnotherInstance):
    // stderr rather than the debug log, which lives in the database a duplicate must not open. Exit 0
    // because standing down is this code working, not failing -- a non-zero status would tell a script
    // that launched the app that the launch was broken.
    FileHandle.standardError.write(Data("facet: already running, so this copy is exiting.\n".utf8))
    exit(EXIT_SUCCESS)
case let .failure(.cannotTell(reason)):
    // No answer either way, so carry on rather than refuse: a lock file that cannot be opened is not
    // evidence of a second instance, and standing down here would turn a read-only home directory into
    // an app that never starts at all.
    FileHandle.standardError.write(Data("facet: could not check for a second instance: \(reason)\n".utf8))
    instanceLock = nil
}

let databaseURL: URL
do {
    databaseURL = try DatabaseBootstrap.ensureDatabase().databaseURL
} catch {
    // The app is refusing to start, so the reason has to reach whoever launched it. On this platform that
    // is more than a formality: the DDL is found through `Bundle.module`, which resolves beside the
    // executable, so a binary installed without `FacetApp_FacetCore.resources` next to it fails here.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("facet: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

// One read connection, held open for the life of the app, with a reader per table on top of it. Asked
// again every time an answer is wanted, and caching nothing: see the first design rule in `CLAUDE.md`.
let database = DatabaseConnection(databaseURL: databaseURL)
let settings = SettingStore(connection: database)

// **The trace goes in its own file**, and both of the `debug` row's fields are read here, at launch, so
// that a scripted check has something to poll for. `DebugLog` creates nothing until the first message it
// actually records, so a launch with logging off leaves no `debug.sqlite` behind.
let debugLog: DebugLog? = {
    let stored = settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
        ?? DebugTraceRules.defaultDirectory
    return DebugLog(
        databaseURL: DatabaseBootstrap.debugDatabaseURL(in: DebugTraceRules.directoryURL(from: stored)),
        isRecording: settings.flag(DebugTraceRules.setting, field: DebugTraceRules.enabledField)
            ?? DebugTraceRules.defaultEnabled
    )
}()

debugLog?.record(.launch, "Facet started on Linux, with no window and no radio yet")
debugLog?.record(.launch, "Database at \(databaseURL.path)")

// **It stays up, because an app that exits is an app no check can find.** `is_running` in
// `Tests/Scripted/lib.sh` asks whether the process is there, and every step after it assumes it is.
//
// **Quit is a signal until there is a menu to quit from.** `platform_kill_app` is what stops it, and the
// default disposition of SIGTERM is what makes that work. When item 11 brings a menu bar, this loop is
// what its event loop replaces -- so there is nothing here to unpick, only something to swap.
FileHandle.standardError.write(Data("facet: up. No window and no radio yet -- see docs/linux-port.md items 10 and 11.\n".utf8))
dispatchMain()
