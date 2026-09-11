@testable import FacetCore
import Foundation
import Testing

/// Proving a factory reset, driven with no radio and no cube.
///
/// **This sequence has never had a test.** It lived in `BluetoothRadio` wound through the connect machinery, so
/// exercising it needed a real cube and a real wipe, and the only thing that ever ran it was
/// `Tests/Scripted/52-device-reset` with somebody watching. What that could never do is the cases below: a cube
/// that takes the command and never comes back, one that answers on the wrong PIN, and the window closing.
///
/// **The measured trap is the one worth pinning.** The archive waited for the cube to sever the link before it
/// started proving, and on this firmware it does not sever it: a reset on 2026-08-17 was acknowledged and the
/// link stayed up for 104 seconds, so nothing was tried and a wipe that had really happened went unconfirmed
/// (finding 6, `docs/timeflip2-firmware-observations.md`).
@Suite @MainActor
struct CubeResetProofTests {
    /// Records what the proof asked the platform to do, in order.
    @MainActor
    final class Wire {
        var events: [String] = []
        /// What the cube says to `0xFF`. `nil` leaves the write unanswered.
        var takesTheCommand: Bool? = true

        func proof(_ clock: HandDrivenScheduler) -> CubeResetProof {
            CubeResetProof(
                scheduler: clock,
                sendReset: { [self] answered in
                    events.append("sent")
                    if let takesTheCommand { answered(takesTheCommand) }
                },
                letGo: { [self] reason in events.append("let go: \(reason)") },
                tryVendorPIN: { [self] in events.append("tried the vendor PIN") },
                debugLog: nil
            )
        }
    }

    // MARK: - the shape of a run that works

    @Test func testTheLinkIsLetGoBeforeAnythingIsTried() throws {
        // **The measured correction, and the reason this is not written the obvious way.** Waiting for the cube
        // to drop the link first is what the archive did, and this firmware holds it open.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)

        proof.begin { _ in }

        #expect(wire.events == ["sent", "let go: the cube is being reset"])
        #expect(!wire.events.contains("tried the vendor PIN"), "nothing is tried until the wait has passed")
    }

    @Test func testTheCubeAnsweringOnTheVendorPINIsTheProof() throws {
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.loggedIn)

        #expect(outcome == .confirmed)
        #expect(wire.events.last == "let go: the reset is over", "a pristine cube is not held on to")
        #expect(!proof.isRunning)
    }

    @Test func testACubeStillRebootingIsTriedAgainRatherThanFailed() throws {
        // Anything that is not a login is "not back yet": erasing flash and restarting takes longer than one
        // attempt, and the window is what decides when to give up.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.unreachable)
        #expect(outcome == nil, "still proving")
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.timedOut)
        #expect(outcome == nil, "still proving")
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.loggedIn)

        #expect(outcome == .confirmed)
        #expect(wire.events.filter { $0 == "tried the vendor PIN" }.count == 3)
    }

    @Test func testTheCubeDroppingTheLinkIsTheRebootAndIsTriedAgain() throws {
        // The other firmware. Both are expected, which is why letting go is unconditional and a drop is not an
        // ending.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }
        proof.linkDropped()
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.loggedIn)

        #expect(outcome == .confirmed)
    }

    // MARK: - the ways it does not work

    @Test func testACommandTheCubeRefusesIsNotSentAndNothingIsProved() throws {
        let wire = Wire()
        wire.takesTheCommand = false
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }

        #expect(outcome == .notSent)
        #expect(!wire.events.contains("tried the vendor PIN"), "there is nothing to prove")
        #expect(clock.isEmpty, "and no window left armed behind it")
    }

    @Test func testTheWindowClosingIsNotConfirmedRatherThanConfirmed() throws {
        // **The important negative.** A reset that cannot be proved must not be reported as done: the app would
        // forget a cube that is still on the app's own PIN, and nothing could log in to it again.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }
        clock.tickAll(after: CubeResetProof.windowSeconds)

        #expect(outcome == .notConfirmed)
        #expect(wire.events.last == "let go: the reset is over", "an unproved cube is let go of too")
    }

    @Test func testItReportsExactlyOnce() throws {
        // Every path ends in `finish`, and a window that fired after a confirmation would report twice: the
        // caller writes the reset down, so twice is two forgettings and an alert nobody can explain.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcomes: [FactoryResetOutcome] = []

        proof.begin { outcomes.append($0) }
        clock.tickAll(after: CubeResetProof.retrySeconds)
        proof.loginEnded(.loggedIn)
        clock.tickAll()
        proof.loginEnded(.loggedIn)
        proof.linkDropped()

        #expect(outcomes == [.confirmed])
    }

    @Test func testAbandoningReportsNothingAndLeavesNoTimers() throws {
        // Quitting, or forgetting the device, ends the proof on this app's terms. Reporting an outcome there
        // would tell the surface something about a cube nobody asked about any more.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let proof = wire.proof(clock)
        var outcome: FactoryResetOutcome?

        proof.begin { outcome = $0 }
        proof.abandon()
        clock.tickAll()

        #expect(outcome == nil)
        #expect(!proof.isRunning)
        #expect(!wire.events.contains("tried the vendor PIN"))
    }
}
