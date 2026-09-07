@testable import FacetCore
import Foundation
import Testing

/// Covers locking the cube and starting it again: which commands go, in which order, and when none go at all.
///
/// **The order is the part worth pinning**, and it is not symmetry for its own sake. A locked cube reports itself
/// paused whatever its pause byte says, so the pause has to be confirmed before the lock is sent and the unlock has
/// to land before the resume can be confirmed. Get either backwards and the app reports a state it has no evidence
/// for -- and neither would be visible in `swift test` without a test that looks at the order.
@Suite @MainActor
final class CubeLockTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    private func setPauseOnLock(_ enabled: Bool) {
        #expect(
            database.execute( "UPDATE setting SET setting_value = '{\"enabled\":\(enabled)}' WHERE setting_name = 'pause_on_lock';" )
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

    @Test func testUnlockingACubeOnASpentLimitLeavesItStopped() {
        // **The way round a hard limit that this closes.** Unlocking resumes, so lock-then-unlock was a resume the
        // limit never saw: measured on a real cube on 2026-08-27 as `The cube is unlocked`, `Sending 06 02`, `The cube
        // is running`, and `DailyLimitWatch` stopping it again two seconds later.
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: true, into: sent)

        #expect(lock.resume { _ in })

        #expect(sent.count == 1, "the unlock goes and the resume does not")
        #expect(sent[0] as? Data == DeviceCommandRules.lock(false))
    }

    @Test func testUnlockingIsNeverRefusedByTheLimit() {
        // The other half: refusing the unlock would strand the cube in the one state this app cannot get it out of.
        // A limit is about recording time, not about holding somebody's hardware shut.
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: true, into: sent)

        var reported: Bool?
        #expect(lock.resume { reported = $0 })

        #expect(reported == true, "the unlock took, and that is what the caller is told")
    }

    @Test func testUnlockingWithBudgetInHandStillResumes() {
        let sent = NSMutableArray()
        let lock = cubeLock(cubeLockState: .locked, limitReached: false, into: sent)

        #expect(lock.resume { _ in })

        #expect(sent.count == 2)
        #expect(sent[0] as? Data == DeviceCommandRules.lock(false))
        #expect(sent[1] as? Data == DeviceCommandRules.pause(false))
    }

    // MARK: - the plain pause, without a lock

    @Test func testARunningCubeIsPaused() {
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        #expect(sent as! [Data] == [DeviceCommandRules.pause(true)])
    }

    @Test func testAPausedCubeIsStarted() {
        // The direction comes out of `device_event`, which is the same answer both surfaces draw their glyph from --
        // so the click flips what is on show rather than something only the app can see.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .paused, into: sent).togglePause { _ in }

        #expect(sent as! [Data] == [DeviceCommandRules.pause(false)])
    }

    @Test func testNothingElseGoesWithIt() {
        // A pause, not the lock sequence. Somebody stopping the cube from the menu bar has not asked for it to be
        // frozen on the face it is on, and a lock is recoverable only from the dropdown or the vendor's app.
        let sent = NSMutableArray()
        setPauseOnLock(true)
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        #expect(sent.count == 1)
    }

    @Test func testItIsNotGatedOnPauseOnLock() {
        // That setting says what *locking* does. Pausing is its own gesture and nothing about it locks anything.
        setPauseOnLock(false)
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, into: sent).togglePause { _ in }

        #expect(sent as! [Data] == [DeviceCommandRules.pause(true)])
    }

    @Test func testALockedCubeIsLeftAlone() {
        // Measured, not tidiness: a locked cube reports itself paused whatever its pause byte says, so nothing sent
        // here could be read back afterwards. The way out is the lock.
        let sent = NSMutableArray()
        var reported = false
        let sending = cubeLock(cubePauseState: .running, cubeLockState: .locked, into: sent).togglePause { _ in reported = true }

        #expect(!(sending))
        #expect(sent.count == 0)
        #expect(!(reported), "nothing was sent, so there is nothing to report")
    }

    @Test func testACubeNobodyHasAskedAboutIsStillPausable() {
        // `nil` is "not asked yet", not "locked". Refusing on it would leave the gesture dead until something else
        // happened to put a command on the wire.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .running, cubeLockState: .unknown, into: sent).togglePause { _ in }

        #expect(sent as! [Data] == [DeviceCommandRules.pause(true)])
    }

    @Test func testACubeWithNoOpenSegmentIsPaused() {
        // Reset and not yet flipped: there is no record to read a direction out of. Of the two ways to be wrong,
        // stopping a cube nobody is timing on costs nothing and is undone by clicking again.
        let sent = NSMutableArray()
        cubeLock(cubePauseState: .unknown, into: sent).togglePause { _ in }

        #expect(sent as! [Data] == [DeviceCommandRules.pause(true)])
    }

    @Test func testPausingNeedsACube() {
        let sent = NSMutableArray()
        var reported = false
        let sending = cubeLock(connected: false, cubePauseState: .running, into: sent).togglePause { _ in reported = true }

        #expect(!(sending))
        #expect(sent.count == 0)
        #expect(!(reported))
    }

    @Test func testACubeThatWouldNotTakeItSaysSo() {
        // The read-back is what decides, not the write landing. `send` reports the `0x10` verdict and it is passed
        // straight on rather than being softened into a success.
        var took: Bool?
        cubeLock(answering: false, cubePauseState: .running, into: NSMutableArray()).togglePause { took = $0 }

        #expect(took == false)
    }

    // MARK: - stopping it

    @Test func testItPausesAndThenLocks() {
        setPauseOnLock(true)
        let sent = NSMutableArray()
        var stopped = false

        #expect(cubeLock(into: sent).lock { stopped = $0 })

        #expect(sent[0] as? Data == DeviceCommandRules.pause(true), "the pause has to be confirmed first")
        #expect(sent[1] as? Data == DeviceCommandRules.lock(true))
        #expect(sent.count == 2)
        #expect(stopped)
    }

    @Test func testTheLockIsStillSentWhenThePauseDidNotTake() {
        // A pause that did not take is a reason to want the lock more, not less: giving up here would let one failure
        // cost both steps. What is reported is the lock's own read-back.
        setPauseOnLock(true)
        let sent = NSMutableArray()
        var stopped = true

        cubeLock(answering: false, into: sent).lock { stopped = $0 }

        #expect(sent.count == 2)
        #expect(sent[1] as? Data == DeviceCommandRules.lock(true))
        #expect(!(stopped))
    }

    @Test func testWithPauseOnLockOffItStillLocksAndOnlySkipsThePause() {
        // **The whole of this branch, and it used to send nothing at all.** The setting is named for what it does:
        // whether locking *also* pauses. It never decided whether locking happens, and while it did, turning it off
        // meant a double click on the right half and a quit both answered by leaving the cube running and unlocked,
        // with `pause_on_lock is off, so the cube is left as it is` the only sign anything had been asked.
        setPauseOnLock(false)
        let sent = NSMutableArray()
        var stopped = false

        #expect(cubeLock(into: sent).lock { stopped = $0 })

        #expect(sent[0] as? Data == DeviceCommandRules.lock(true))
        #expect(sent.count == 1, "the lock, and no pause in front of it")
        #expect(stopped)
    }

    @Test func testAnUnreadableSettingLocksWithoutPausing() {
        // An unreadable row still counts as off, which is deliberate and now costs only the pause: the lock was what
        // somebody asked for, and a launch that cannot read its own settings simply does not take the extra liberty
        // of stopping the clock as well.
        #expect(database.execute("UPDATE setting SET setting_value = '{}' WHERE setting_name = 'pause_on_lock';"))
        let sent = NSMutableArray()

        #expect(cubeLock(into: sent).lock { _ in })

        #expect(sent[0] as? Data == DeviceCommandRules.lock(true))
        #expect(sent.count == 1)
    }

    @Test func testNothingIsSentWithNoCubeConnected() {
        setPauseOnLock(true)
        let sent = NSMutableArray()

        #expect(!(cubeLock(connected: false, into: sent).lock { _ in }))

        #expect(sent.count == 0)
    }

    // MARK: - starting it again

    @Test func testItUnlocksAndThenResumes() {
        let sent = NSMutableArray()
        var running = false

        #expect(cubeLock(into: sent).resume { running = $0 })

        #expect(sent[0] as? Data == DeviceCommandRules.lock(false), "the unlock has to land before the resume")
        #expect(sent[1] as? Data == DeviceCommandRules.pause(false))
        #expect(sent.count == 2)
        #expect(running)
    }

    @Test func testResumingIsNotGatedOnPauseOnLock() {
        // That setting says what locking does. Refusing to undo a lock because it has since been turned off would
        // strand a cube in the one state this app can otherwise not get it out of.
        setPauseOnLock(false)
        let sent = NSMutableArray()

        #expect(cubeLock(into: sent).resume { _ in })

        #expect(sent.count == 2)
    }

    @Test func testTheResumeIsStillSentWhenTheUnlockDidNotTake() {
        // A cube left paused and unlocked records nothing while somebody flips it, which is worse than a lock they
        // can see. The failure is still reported.
        let sent = NSMutableArray()
        var running = true

        cubeLock(answering: false, into: sent).resume { running = $0 }

        #expect(sent.count == 2)
        #expect(!(running))
    }

    @Test func testResumingNeedsACubeToo() {
        let sent = NSMutableArray()

        #expect(!(cubeLock(connected: false, into: sent).resume { _ in }))

        #expect(sent.count == 0)
    }
}
