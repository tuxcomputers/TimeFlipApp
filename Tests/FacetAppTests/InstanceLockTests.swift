@testable import FacetApp
import Foundation
import XCTest

/// Covers `InstanceLock`: that one claim succeeds, a second is refused while the first is held, and the
/// lock comes back once it is released.
///
/// Testable in a single process only because the lock is an `flock`, which belongs to the open file
/// description rather than the process -- so a second claim here conflicts exactly as a second launch
/// would. An `fcntl` record lock would let every one of these pass while the guard did nothing.
final class InstanceLockTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("instance-lock-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var lockURL: URL { directory.appendingPathComponent("singleinstance.lock") }

    private func claim() -> Result<InstanceLock, InstanceLock.Denial> {
        InstanceLock.claim(at: lockURL)
    }

    func testTheFirstClaimSucceedsAndCreatesTheFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path), "precondition")

        let lock = try claim().get()

        XCTAssertNotNil(lock)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "the containing directory and the lock file are both created on a first-ever launch"
        )
    }

    func testASecondClaimIsRefusedWhileTheFirstIsHeld() throws {
        let first = try claim().get()

        switch claim() {
        case .success:
            XCTFail("a second instance took the lock while the first held it")
        case let .failure(denial):
            XCTAssertEqual(denial, .heldByAnotherInstance)
        }

        // Referenced after the assertion, so ARC cannot release the lock before the second claim runs
        // and quietly turn this into a test of nothing.
        XCTAssertNotNil(first)
    }

    func testTheLockComesBackWhenTheHolderGoesAway() throws {
        var first: InstanceLock? = try claim().get()
        XCTAssertNotNil(first)

        first = nil // what process exit does

        XCTAssertNoThrow(try claim().get(), "the next launch should be able to take it")
    }

    func testAnUnusableLockPathIsNotReportedAsASecondInstance() {
        // A path that cannot be created: `/dev/null` is a file, so no directory can exist beneath it.
        // The distinction matters -- reporting this as a second instance would stop the app starting for
        // a reason that has nothing to do with one.
        switch InstanceLock.claim(at: URL(fileURLWithPath: "/dev/null/nowhere/singleinstance.lock")) {
        case .success:
            XCTFail("a lock was claimed on a path that cannot exist")
        case let .failure(denial):
            guard case let .cannotTell(reason) = denial else {
                return XCTFail("expected cannotTell, got \(denial)")
            }
            XCTAssertTrue(reason.contains("/dev/null/nowhere"), "the reason should name the path: \(reason)")
        }
    }
}
