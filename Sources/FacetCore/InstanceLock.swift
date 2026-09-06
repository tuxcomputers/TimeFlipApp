import Foundation

/// Proof that this process is the app, rather than a second copy of it.
///
/// Held for as long as the object lives, as an exclusive `flock` on a file in Application Support.
/// Whoever takes it is the app; whoever cannot take it stands down. Without this, a second launch
/// brings a second status item, a second claim on the database, and eventually a second radio talking
/// to one cube.
///
/// **A lock rather than asking the OS who else is running.** The obvious alternative,
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)`, does find every instance --
/// including one started by running the binary directly -- but it cannot *order* them: an instance
/// launched directly reports a `nil` `launchDate`, and only a Launch Services start fills it in
/// (measured). So "first one wins" has nothing to compare when two of three read nil, and ordering by
/// pid instead invents a rule the OS never promised, on numbers that wrap.
///
/// A lock needs no ordering. The kernel arbitrates, so two launches racing from the same instant
/// cannot both lose -- which would leave no app running at all, worse than the problem being solved --
/// and the kernel drops the lock however the process dies, so a crash or a `kill -9` leaves nothing
/// stale behind and there is no pid file anyone has to validate.
///
/// **`flock` rather than an `fcntl` record lock**, which is the other way to do this. `flock` belongs
/// to the open file description, so a second attempt conflicts even from the same process; `fcntl`
/// locks belong to the process, so a second attempt inside one process quietly succeeds. Both work
/// against a real second launch, but only the first can be tested without spawning one.
final class InstanceLock {
    /// Why a claim did not succeed.
    ///
    /// `cannotTell` is deliberately not folded into `heldByAnotherInstance`: failing to open the lock
    /// file (no directory, a read-only home) says nothing about whether another instance exists, and
    /// treating it as one would let a filesystem problem stop the app from ever starting.
    enum Denial: Error, Equatable {
        case heldByAnotherInstance
        case cannotTell(String)
    }

    /// The lock file, alongside the database in Application Support.
    ///
    /// Fixed, and deliberately **not** derived from the database path. The app is meant to switch
    /// between a production and a test database, and a lock that moved with it would permit one
    /// instance per database -- the same bug wearing a hat.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Facet", isDirectory: true)
            .appendingPathComponent("singleinstance.lock")
    }

    private let descriptor: Int32

    /// Takes the lock, or says why not.
    ///
    /// Returning the lock itself on success is the point of the shape: there is no way to hold an
    /// `InstanceLock` that is not locked, and no second call that could report success for having done
    /// nothing. **Keep what it returns** -- the lock lives on the open file description, so letting the
    /// object go releases it and hands the app's identity to the next launch while this one runs on.
    static func claim(at url: URL = defaultURL) -> Result<InstanceLock, Denial> {
        // Normally already there, since the database lives in it, but a first-ever launch reaches here
        // before anything has created it.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return .failure(.cannotTell("could not open \(url.path): \(String(cString: strerror(errno)))"))
        }

        // LOCK_NB so this answers now instead of waiting for the other instance to quit.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            // EWOULDBLOCK is the whole point: somebody else holds it. Anything else is a broken lock
            // file rather than a duplicate launch, and is reported as its own thing.
            return .failure(
                failure == EWOULDBLOCK
                    ? .heldByAnotherInstance
                    : .cannotTell("could not lock \(url.path): \(String(cString: strerror(failure)))")
            )
        }
        return .success(InstanceLock(descriptor: descriptor))
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Releases the lock. Process exit would do it anyway; this is what makes the lock testable, and
    /// what keeps the release beside the claim rather than relying on the process ending.
    ///
    /// The file itself is left where it is. It is somewhere to hold a lock, not a record of anything,
    /// so nothing ever reads it and there is nothing stale to clean up.
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
