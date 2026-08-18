@testable import FacetApp
import Foundation
import XCTest

/// Covers locking the cube and starting it again: which commands go, in which order, and when none go at all.
///
/// **The order is the part worth pinning**, and it is not symmetry for its own sake. A locked cube reports itself
/// paused whatever its pause byte says, so the pause has to be confirmed before the lock is sent and the unlock has
/// to land before the resume can be confirmed. Get either backwards and the app reports a state it has no evidence
/// for -- and neither would be visible in `swift test` without a test that looks at the order.
@MainActor
final class CubeLockTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    override func tearDown() {
        settings = nil
        database.remove()
        super.tearDown()
    }

    private func setPauseOnLock(_ enabled: Bool) {
        XCTAssertTrue(
            database.execute(
                "UPDATE setting SET setting_value = '{\"enabled\":\(enabled)}' WHERE setting_name = 'pause_on_lock';"
            )
        )
    }

    /// Records what was sent, and hands back the answer the cube is pretending to give.
    private func cubeLock(
        connected: Bool = true,
        answering: Bool = true,
        into sent: NSMutableArray
    ) -> CubeLock {
        CubeLock(
            settings: settings,
            isConnected: { connected },
            send: { command, reported in
                sent.add(command)
                reported(answering)
            },
            debugLog: nil
        )
    }

    // MARK: - stopping it

    func testItPausesAndThenLocks() {
        setPauseOnLock(true)
        let sent = NSMutableArray()
        var stopped = false

        XCTAssertTrue(cubeLock(into: sent).lock { stopped = $0 })

        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.pause(true), "the pause has to be confirmed first")
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.lock(true))
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(stopped)
    }

    func testTheLockIsStillSentWhenThePauseDidNotTake() {
        // A pause that did not take is a reason to want the lock more, not less: giving up here would let one failure
        // cost both steps. What is reported is the lock's own read-back.
        setPauseOnLock(true)
        let sent = NSMutableArray()
        var stopped = true

        cubeLock(answering: false, into: sent).lock { stopped = $0 }

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.lock(true))
        XCTAssertFalse(stopped)
    }

    func testNothingIsSentWithPauseOnLockOff() {
        // The setting says what locking from the app means, so with it off the app does not lock from either of the
        // two places it can.
        setPauseOnLock(false)
        let sent = NSMutableArray()

        XCTAssertFalse(cubeLock(into: sent).lock { _ in })

        XCTAssertEqual(sent.count, 0)
    }

    func testAnUnreadableSettingLeavesTheCubeAlone() {
        // Deliberately not the seeded default: a launch that cannot read its own settings is not one to be handing a
        // lock, since leaving the cube running is the failure somebody can get out of by flipping it.
        XCTAssertTrue(database.execute("UPDATE setting SET setting_value = '{}' WHERE setting_name = 'pause_on_lock';"))
        let sent = NSMutableArray()

        XCTAssertFalse(cubeLock(into: sent).lock { _ in })

        XCTAssertEqual(sent.count, 0)
    }

    func testNothingIsSentWithNoCubeConnected() {
        setPauseOnLock(true)
        let sent = NSMutableArray()

        XCTAssertFalse(cubeLock(connected: false, into: sent).lock { _ in })

        XCTAssertEqual(sent.count, 0)
    }

    // MARK: - starting it again

    func testItUnlocksAndThenResumes() {
        let sent = NSMutableArray()
        var running = false

        XCTAssertTrue(cubeLock(into: sent).resume { running = $0 })

        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(false), "the unlock has to land before the resume")
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.pause(false))
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(running)
    }

    func testResumingIsNotGatedOnPauseOnLock() {
        // That setting says what locking does. Refusing to undo a lock because it has since been turned off would
        // strand a cube in the one state this app can otherwise not get it out of.
        setPauseOnLock(false)
        let sent = NSMutableArray()

        XCTAssertTrue(cubeLock(into: sent).resume { _ in })

        XCTAssertEqual(sent.count, 2)
    }

    func testTheResumeIsStillSentWhenTheUnlockDidNotTake() {
        // A cube left paused and unlocked records nothing while somebody flips it, which is worse than a lock they
        // can see. The failure is still reported.
        let sent = NSMutableArray()
        var running = true

        cubeLock(answering: false, into: sent).resume { running = $0 }

        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(running)
    }

    func testResumingNeedsACubeToo() {
        let sent = NSMutableArray()

        XCTAssertFalse(cubeLock(connected: false, into: sent).resume { _ in })

        XCTAssertEqual(sent.count, 0)
    }
}
