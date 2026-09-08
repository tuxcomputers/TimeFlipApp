import FacetCore
import Foundation

// **The Linux entry point, and it is deliberately only the part that has an answer.** Startup, in the
// same order as the macOS `main.swift` and for the same reasons: prove this is the only instance, bring
// the database up, then start the trace. Every step is ahead of the one that would be wrong to do twice.
//
// **What is missing here is missing on purpose, not forgotten.** There is a menu bar item and there is no
// radio and no Settings window: the radio is item 10 of `docs/linux-port.md` and the rest of the UI is the
// remainder of item 11. What this file settles is that the app exists on this platform at all --
// `Package.swift` declares a product, so `swift build` has something to build and `Tests/Scripted/` builds
// and launches it exactly as it does on the Mac.
//
// **The boot is not Linux-specific and the bar is.** Everything down to the debug log is `FacetCore` and
// a near-transcription of lines 14 to 72 of `Sources/FacetApp/main.swift`, which is AppKit-free until line
// 110 -- the two platforms start the same way because there is only one way to start. What differs begins
// at `MenuBar`, which is GTK where the other is AppKit.

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

debugLog?.record(.launch, "Facet started on Linux, with no radio yet")
debugLog?.record(.launch, "Database at \(databaseURL.path)")

// **The bar, and then the run loop.** From here on quit is the only way out, exactly as the macOS launch
// says: `gtk_main` does not return until something calls `gtk_main_quit`, and the only thing that does is
// the menu item below.
let menuBar = MenuBar(debugLog: debugLog)
menuBar.setLabel("Facet", guide: "00:00:00")

// **One item, because one item works.** Settings and the timing readout are the next slices of item 11;
// a menu of controls that do nothing would be worse than a short menu, and this app already has a rule
// about things that quietly do not happen.
menuBar.add("Quit Facet") {
    debugLog?.record(.quit, "Quit was chosen from the menu bar")
    MenuBar.quit()
}

menuBar.run()
