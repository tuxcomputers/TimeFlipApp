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
final class CubeLockTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            try database.bootstrap()
            settings = SettingStore(connection: database.connection())
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            settings = nil
            database.remove()
        }
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
        cubePauseState: CubePauseState = .unknown,
        cubeLockState: CubeLockState = .unknown,
        limitReached: Bool = false,
        into sent: NSMutableArray
    ) -> CubeLock {
        let lock = CubeLock(
            settings: settings,
            isCubeConnected: { connected },
            send: { command, reported in
                sent.add(command)
                reported(answering)
            },
            cubePauseState: { cubePauseState },
            cubeLockState: { cubeLockState },
            debugLog: nil
        )
        lock.isLimitReached = { limitReached }
        return lock
    }

    // MARK: - a spent limit is a limit the unlock does not spend

    func testUnlockingACubeOnASpentLimitLeavesItStopped() {
        // **The way round a hard limit that this closes.** Unlocking resumes, so lock-then-unlock was a resume the
        // limit never saw: measured on a real cube on 2026-08-27 as `The cube is unlocked`, `Sending 06 02`, `The cube
        // is running`, and `DailyLimitWatch` stopping it again two seconds later.
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: true, into: sent)

        XCTAssertTrue(lock.resume { _ in })

        XCTAssertEqual(sent.count, 1, "the unlock goes and the resume does not")
        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(false))
    }

    func testUnlockingIsNeverRefusedByTheLimit() {
        // The other half: refusing the unlock would strand the cube in the one state this app cannot get it out of.
        // A limit is about recording time, not about holding somebody's hardware shut.
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: true, into: sent)

        var reported: Bool?
        XCTAssertTrue(lock.resume { reported = $0 })

        XCTAssertEqual(reported, true, "the unlock took, and that is what the caller is told")
    }

    func testUnlockingWithBudgetInHandStillResumes() {
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: false, into: sent)

        XCTAssertTrue(lock.resume { _ in })

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(false))
        XCTAssertEqual(sent[1] as? Data, DeviceCommandRules.pause(false))
    }

    // MARK: - the plain pause, without a lock

    func testARunningCubeIsPaused() {
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        XCTAssertEqual(sent as! [Data], [DeviceCommandRules.pause(true)])
    }

    func testAPausedCubeIsStarted() {
        // The direction comes out of `device_event`, which is the same answer both surfaces draw their glyph from --
        // so the click flips what is on show rather than something only the app can see.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .paused, into: sent).togglePause { _ in }

        XCTAssertEqual(sent as! [Data], [DeviceCommandRules.pause(false)])
    }

    func testNothingElseGoesWithIt() {
        // A pause, not the lock sequence. Somebody stopping the cube from the menu bar has not asked for it to be
        // frozen on the face it is on, and a lock is recoverable only from the dropdown or the vendor's app.
        let sent = NSMutableArray()
        setPauseOnLock(true)
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        XCTAssertEqual(sent.count, 1)
    }

    func testItIsNotGatedOnPauseOnLock() {
        // That setting says what *locking* does. Pausing is its own gesture and nothing about it locks anything.
        setPauseOnLock(false)
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        XCTAssertEqual(sent as! [Data], [DeviceCommandRules.pause(true)])
    }

    func testALockedCubeIsLeftAlone() {
        // Measured, not tidiness: a locked cube reports itself paused whatever its pause byte says, so nothing sent
        // here could be read back afterwards. The way out is the lock.
        let sent = NSMutableArray()
        var reported = false
        let sending = cubeLock(cubePauseState: .running, cubeLockState: .locked, into: sent).togglePause { _ in reported = true }

        XCTAssertFalse(sending)
        XCTAssertEqual(sent.count, 0)
        XCTAssertFalse(reported, "nothing was sent, so there is nothing to report")
    }

    func testACubeNobodyHasAskedAboutIsStillPausable() {
        // `nil` is "not asked yet", not "locked". Refusing on it would leave the gesture dead until something else
        // happened to put a command on the wire.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, cubeLockState: .unknown, into: sent).togglePause { _ in }

        XCTAssertEqual(sent as! [Data], [DeviceCommandRules.pause(true)])
    }

    func testACubeWithNoOpenSegmentIsPaused() {
        // Reset and not yet flipped: there is no record to read a direction out of. Of the two ways to be wrong,
        // stopping a cube nobody is timing on costs nothing and is undone by clicking again.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .unknown, into: sent).togglePause { _ in }

        XCTAssertEqual(sent as! [Data], [DeviceCommandRules.pause(true)])
    }

    func testPausingNeedsACube() {
        let sent = NSMutableArray()
        var reported = false
        let sending = cubeLock(connected: false, cubePauseState: .running, into: sent).togglePause { _ in reported = true }

        XCTAssertFalse(sending)
        XCTAssertEqual(sent.count, 0)
        XCTAssertFalse(reported)
    }

    func testACubeThatWouldNotTakeItSaysSo() {
        // The read-back is what decides, not the write landing. `send` reports the `0x10` verdict and it is passed
        // straight on rather than being softened into a success.
        var took: Bool?
        cubeLock(answering: false, cubePauseState: .running, into: NSMutableArray()).togglePause { took = $0 }

        XCTAssertEqual(took, false)
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

    func testWithPauseOnLockOffItStillLocksAndOnlySkipsThePause() {
        // **The whole of this branch, and it used to send nothing at all.** The setting is named for what it does:
        // whether locking *also* pauses. It never decided whether locking happens, and while it did, turning it off
        // meant a double click on the right half and a quit both answered by leaving the cube running and unlocked,
        // with `pause_on_lock is off, so the cube is left as it is` the only sign anything had been asked.
        setPauseOnLock(false)
        let sent = NSMutableArray()
        var stopped = false

        XCTAssertTrue(cubeLock(into: sent).lock { stopped = $0 })

        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(true))
        XCTAssertEqual(sent.count, 1, "the lock, and no pause in front of it")
        XCTAssertTrue(stopped)
    }

    func testAnUnreadableSettingLocksWithoutPausing() {
        // An unreadable row still counts as off, which is deliberate and now costs only the pause: the lock was what
        // somebody asked for, and a launch that cannot read its own settings simply does not take the extra liberty
        // of stopping the clock as well.
        XCTAssertTrue(database.execute("UPDATE setting SET setting_value = '{}' WHERE setting_name = 'pause_on_lock';"))
        let sent = NSMutableArray()

        XCTAssertTrue(cubeLock(into: sent).lock { _ in })

        XCTAssertEqual(sent[0] as? Data, DeviceCommandRules.lock(true))
        XCTAssertEqual(sent.count, 1)
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
