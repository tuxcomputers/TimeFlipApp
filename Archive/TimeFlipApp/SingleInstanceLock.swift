import Foundation

/// Proves this launch is the only one, by holding an exclusive `flock` for the life of the process.
///
/// Two instances were possible before this, and each one brought its own status item and its own BLE
/// client competing for the same cube (`Tests/Methods.md` Method 2 carried a standing warning about
/// exactly that, after `09b` inlined a bare launch on 2026-08-02). Whoever takes the lock is the app;
/// whoever cannot take it is a duplicate and stands down.
///
/// **Why a lock rather than asking the OS who else is running.** The obvious approach is
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)`, and it does find every
/// instance, including ones started by executing the binary directly. What it cannot do is order
/// them: measured on 2026-08-10, an instance launched directly (which is how `Tests/Methods.md`
/// Method 2 starts the app, and so how every checklist does) reports a **nil** `launchDate`, and
/// only a Launch Services start populates it. With three instances up, two read nil and one read a
/// date, so "whoever started first wins" had nothing to compare and would have picked the wrong
/// survivor. Ordering by pid instead invents a rule the OS never promised, and pids wrap.
///
/// A lock needs no ordering at all. The kernel arbitrates, so two apps racing from the same instant
/// cannot both lose (which would leave no app running, a worse outcome than the bug being fixed),
/// and the lock is released when the process dies however it dies, so a crash or a `kill -9` leaves
/// nothing stale to recover from and there is no pid file to validate.
final class SingleInstanceLock {
    /// Why an acquisition attempt ended. `unavailable` is deliberately distinct from
    /// `heldByAnotherInstance`: not being able to open the lock file at all (a missing directory, a
    /// read-only home) says nothing about whether another instance exists, and standing down on it
    /// would let a broken file system stop the app from ever starting.
    enum Outcome: Equatable {
        case acquired
        case heldByAnotherInstance
        case unavailable(String)
    }

    let url: URL
    private var fileDescriptor: Int32 = -1

    init(url: URL = SingleInstanceLock.defaultURL) {
        self.url = url
    }

    deinit {
        release()
    }

    /// The lock file, alongside `config.json` and the database in Application Support.
    ///
    /// Fixed, and deliberately not derived from the database path: the app switches between
    /// `test.sqlite` and `production.sqlite` (see `scripts/switch-database.sh`), and a lock that
    /// moved with it would let one instance per database run at once, which is the same bug wearing
    /// a hat.
    static var defaultURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TimeFlip", isDirectory: true)
            .appendingPathComponent("singleinstance.lock")
    }

    /// Takes the lock, or reports who has it. The descriptor is kept open on success: the lock lives
    /// on the open file description, so closing it would release the lock while the app runs on.
    func acquire() -> Outcome {
        guard fileDescriptor < 0 else { return .acquired }

        // The directory is normally already there (the database and config.json live in it), but a
        // first-ever launch on a clean machine reaches here before anything else has created it.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return .unavailable("could not open \(url.path): \(String(cString: strerror(errno)))")
        }

        // LOCK_NB so this answers now rather than waiting for the other instance to quit.
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            close(descriptor)
            // EWOULDBLOCK is the whole point: someone else holds it. Anything else is a broken
            // lock file rather than a duplicate launch, and is reported as such.
            return failure == EWOULDBLOCK
                ? .heldByAnotherInstance
                : .unavailable("could not lock \(url.path): \(String(cString: strerror(failure)))")
        }

        fileDescriptor = descriptor
        return .acquired
    }

    /// Drops the lock. Not needed on the normal path, since process exit releases it, but it makes
    /// the type usable in a test that takes and drops the lock repeatedly.
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }
}
