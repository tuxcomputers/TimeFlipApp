import AppKit

// Before anything else: a second copy of the app stands down here rather than in the delegate, so a
// duplicate launch never opens the database, never claims a status item and never puts a second BLE
// client on the air. Held in a top-level binding so the descriptor stays open for the process
// lifetime -- the lock lives on the open file description, and letting this deinit would hand the
// lock to the next launch while this one is still running.
let singleInstanceLock = SingleInstanceLock()
switch singleInstanceLock.acquire() {
case .acquired:
    break
case .heldByAnotherInstance:
    // stderr rather than a DeveloperMode.debugPrint: the debug setting and the log sink both come
    // from the database, which is exactly what a duplicate must not open. Exit 0 because standing
    // down is the correct outcome, not a failure -- a non-zero status would make `run_tests.sh`
    // treat an already-running app as a broken launch.
    FileHandle.standardError.write(Data("TimeFlip is already running; this instance is exiting.\n".utf8))
    exit(0)
case let .unavailable(reason):
    // Could not tell either way. Carry on rather than refuse to start: a lock file that cannot be
    // opened is not evidence of a second instance, and refusing here would turn a read-only home
    // directory into an app that never launches at all.
    FileHandle.standardError.write(Data("TimeFlip single-instance check skipped: \(reason)\n".utf8))
}

let app = NSApplication.shared
let delegate = ApplicationDelegate()

app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
