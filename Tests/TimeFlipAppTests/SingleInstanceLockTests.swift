@testable import TimeFlipApp
import XCTest

/// The lock that stops a second copy of the app running.
///
/// These exercise the real `flock`, not a stand-in, because the whole reason the lock was chosen
/// over counting `NSRunningApplication`s is that the kernel arbitrates it. A fake would test the
/// part that was never in doubt. `flock` is held against the open file description rather than the
/// process, so a second `open()` of the same path conflicts with the first even from inside one
/// test process, which is what makes this hermetic: no second app, no window server, no radio.
final class SingleInstanceLockTests: XCTestCase {
    private var lockURL: URL!

    override func setUp() {
        super.setUp()
        lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("timeflip-singleinstance-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lockURL)
        super.tearDown()
    }

    func testTheFirstInstanceTakesTheLock() {
        let first = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(first.acquire(), .acquired)
        first.release()
    }

    /// The bug this exists to stop: a second launch while the first is still running.
    func testASecondInstanceIsToldTheLockIsHeld() {
        let first = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(first.acquire(), .acquired)

        let second = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(second.acquire(), .heldByAnotherInstance)

        first.release()
    }

    /// Quitting has to hand the lock on, or the app would only ever run once per reboot. This is
    /// the case the test suite leans on hardest: every checklist that quits and relaunches (Method 3
    /// then Method 2) depends on the next launch getting the lock the previous one dropped.
    func testTheLockIsAvailableAgainOnceTheHolderGoesAway() {
        let first = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(first.acquire(), .acquired)
        first.release()

        let next = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(next.acquire(), .acquired)
        next.release()
    }

    /// Acquiring twice on one instance is the same lock, not a second one, so an accidental repeat
    /// call cannot report the app as its own duplicate.
    func testAcquiringTwiceOnOneInstanceStaysAcquired() {
        let lock = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.acquire(), .acquired)
        lock.release()
    }

    /// A lock file that cannot be opened says nothing about whether another instance exists, so it
    /// must not read as "already running" -- that would turn an unwritable directory into an app
    /// that never starts. The path here is under a file, so the directory can never be created.
    func testAnUnopenableLockFileIsReportedAsUnavailableRatherThanHeld() {
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("timeflip-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }

        let lock = SingleInstanceLock(url: blocker.appendingPathComponent("nested.lock"))
        guard case .unavailable = lock.acquire() else {
            return XCTFail("expected .unavailable, got \(lock.acquire())")
        }
    }

    /// The real path is fixed rather than derived from the database, so switching between
    /// test.sqlite and production.sqlite cannot allow one instance per database.
    func testTheDefaultLockPathSitsBesideTheAppsOtherSupportFiles() {
        let path = SingleInstanceLock.defaultURL.path
        XCTAssertTrue(path.hasSuffix("/TimeFlip/singleinstance.lock"), "unexpected lock path: \(path)")
    }
}
